import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Vapor

struct RESTImageListQuery: Vapor.Content {
    let manifests: Bool?
    let digests: Bool?
    let filters: String?
}

struct ImageListRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/json", use: ImageListRoute.handler(client: client))
    }
}

struct CustomImageDetail: Decodable {
    public let name: String
}

/// The two fields grouping needs from a runtime image record, so the rules below can be exercised
/// without an Apple Container store behind them.
protocol ImageDigestNamed {
    var digest: String { get }
    var reference: String { get }
}

extension ClientImage: ImageDigestNamed {}

extension ImageListRoute {
    /// Apple Container names an image it no longer has a tag for `untagged@sha256:…`, the same trick
    /// moby's containerd store plays with `moby-dangling@sha256:…`. moby never reports that internal
    /// name: `singlePlatformImage` fails to parse it as a reference, sees `isDanglingImage`, and leaves
    /// both name arrays empty (daemon/containerd/image_list.go). `docker images` renders the `<none>`
    /// row itself. Passing the raw marker through instead makes it look like a repository tag, so
    /// `--filter dangling=true` finds nothing and `--filter reference=…` can match a nameless image.
    static func repoTags(forReference reference: String) -> [String] {
        if isUntagged(reference) || isDigestOnly(reference) {
            return []
        }
        return [reference]
    }

    /// A reference that is only a digest is the image's sole name, and moby files it under
    /// `RepoDigests`; the legacy `digests` query flag governs the tagged case alone.
    static func repoDigests(forReference reference: String, includeDigests: Bool) -> [String] {
        if isUntagged(reference) {
            return []
        }
        if isDigestOnly(reference) {
            return [reference]
        }
        return includeDigests && reference.contains("@sha256:") ? [reference] : []
    }

    private static func isUntagged(_ reference: String) -> Bool {
        reference.isEmpty || reference.hasPrefix("untagged@")
    }

    /// `alpine@sha256:…` carries a digest and no tag; `alpine:3.20@sha256:…` carries both.
    private static func isDigestOnly(_ reference: String) -> Bool {
        guard let at = reference.firstIndex(of: "@") else { return false }
        return !reference[reference.startIndex..<at].contains(":")
    }

    /// One image is one entry per digest, carrying every name that points at it. moby builds exactly
    /// that: `uniqueImages[dgst]` keeps a single record per digest and `RepoTags: tagsByDigest[digest]`
    /// fills it with all of them (daemon/containerd/image_list.go). Apple Container instead stores one
    /// record per reference, so `docker tag alpine:3.20 myalpine:1` produced two rows sharing an ID,
    /// and an image whose tag was removed kept an `untagged@sha256:…` record beside the tagged one —
    /// which made `docker images` list the same ID twice and offered a tagged image to
    /// `docker image prune` under `--filter dangling=true`.
    ///
    /// Grouping subsumes both: the untagged marker contributes no name, so it disappears into a named
    /// group and only survives as its own dangling entry when nothing names that digest.
    struct DigestGroup<Image: ImageDigestNamed> {
        let representative: Image
        let references: [String]

        /// Sorted so a client sees a stable order; moby's own order comes from map iteration.
        var repoTags: [String] {
            references.filter { !ImageListRoute.repoTags(forReference: $0).isEmpty }.sorted()
        }

        func repoDigests(includeDigests: Bool) -> [String] {
            references.flatMap { ImageListRoute.repoDigests(forReference: $0, includeDigests: includeDigests) }.sorted()
        }
    }

    static func groupByDigest<Image: ImageDigestNamed>(_ images: [Image]) -> [DigestGroup<Image>] {
        var order: [String] = []
        var referencesByDigest: [String: [String]] = [:]
        var representatives: [String: Image] = [:]

        for image in images {
            if referencesByDigest[image.digest] == nil {
                order.append(image.digest)
                representatives[image.digest] = image
            }
            referencesByDigest[image.digest, default: []].append(image.reference)
            // A named record is the better representative: its index and config are the ones moby
            // reports, and an untagged marker can outlive the content it pointed at.
            if !ImageListRoute.repoTags(forReference: image.reference).isEmpty,
                let current = representatives[image.digest],
                ImageListRoute.repoTags(forReference: current.reference).isEmpty
            {
                representatives[image.digest] = image
            }
        }

        return order.compactMap { digest in
            guard let representative = representatives[digest] else { return nil }
            return DigestGroup(representative: representative, references: referencesByDigest[digest] ?? [])
        }
    }
    private static func makeOCIDescriptor(
        from descriptor: Descriptor,
        appSupportURL: URL? = nil,
        parentDigest: String? = nil
    ) -> OCIDescriptor {
        let platform = descriptor.platform.map {
            OCIDescriptor.OCIPlatform(
                architecture: $0.architecture,
                os: $0.os,
                osVersion: $0.osVersion,
                osFeatures: $0.osFeatures,
                variant: $0.variant
            )
        }

        let extras: AppleContainerImageStoreResolver.DescriptorExtras? =
            if let appSupportURL, let parentDigest {
                AppleContainerImageStoreResolver.descriptorExtras(
                    appSupportURL: appSupportURL,
                    parentDigest: parentDigest,
                    childDigest: descriptor.digest
                )
            } else {
                nil
            }

        return OCIDescriptor(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest,
            size: descriptor.size,
            urls: descriptor.urls,
            annotations: descriptor.annotations,
            data: extras?.data,
            platform: platform,
            artifactType: extras?.artifactType
        )
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> [RESTImageSummary] {
        { req in
            let query = try req.query.decode(RESTImageListQuery.self)
            // moby validates the filters before doing any listing work. Key/shape
            // validation already happens inside the parser; running applyFilters
            // against an empty list here additionally fail-fasts on an invalid
            // `dangling` value (e.g. `dangling=bogus`) before the real listing
            // and image-summary work below, at the cost of a second (cheap,
            // no-op-on-empty-input) filter pass once the real summaries exist.
            let filters = try DockerImageFilterUtility.parseImageListFilters(filterParam: query.filters, logger: req.logger)
            _ = try ImageListRoute.applyFilters([], filters: filters)
            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
            }
            let images = try await client.list()
            let containers = try await ContainerClient().list()
            let includeManifests = query.manifests ?? false
            let includeDigests = query.digests ?? false
            var imagesSummaries: [RESTImageSummary] = []

            for group in Self.groupByDigest(images) {
                let image = group.representative
                let imageIndex = try await image.index()
                let manifests = imageIndex.manifests
                var manifestSummaries: [ImageManifestSummary] = []
                var created = 0
                var size: Int64 = 0
                var labels: [String: String] = [:]
                var foundUsableManifest = false

                for descriptor in manifests {
                    if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                        referenceType == "attestation-manifest"
                    {
                        continue
                    }

                    guard let platform = descriptor.platform else {
                        continue
                    }

                    let available: Bool
                    let manifest: ContainerizationOCI.Manifest?
                    let config: ContainerizationOCI.Image?
                    do {
                        let resolvedConfig = try await image.config(for: platform)
                        let resolvedManifest = try await image.manifest(for: platform)
                        config = resolvedConfig
                        manifest = resolvedManifest
                        available = true
                    } catch {
                        config = nil
                        manifest = nil
                        available = false
                    }

                    let contentSize = (manifest?.config.size ?? 0) + (manifest?.layers.reduce(0) { $0 + $1.size } ?? 0)
                    let totalSize = descriptor.size + contentSize

                    if includeManifests {
                        let unpackedSize = AppleContainerSnapshotResolver.unpackedSize(
                            appSupportURL: appleContainerAppSupportUrl,
                            descriptor: descriptor
                        )
                        let platformSummary = descriptor.platform.map {
                            OCIDescriptor.OCIPlatform(
                                architecture: $0.architecture,
                                os: $0.os,
                                osVersion: $0.osVersion,
                                osFeatures: $0.osFeatures,
                                variant: $0.variant
                            )
                        }

                        manifestSummaries.append(
                            ImageManifestSummary(
                                ID: descriptor.digest,
                                Descriptor: makeOCIDescriptor(
                                    from: descriptor,
                                    appSupportURL: appleContainerAppSupportUrl,
                                    parentDigest: image.descriptor.digest
                                ),
                                Available: available,
                                Kind: "image",
                                Size: .init(Total: totalSize + unpackedSize, Content: contentSize),
                                ImageData: .init(
                                    Platform: platformSummary,
                                    Containers: [],
                                    Size: .init(Unpacked: unpackedSize)
                                ),
                                AttestationData: nil
                            )
                        )
                    }

                    if !foundUsableManifest, let config, available {
                        created = Int(AppleContainerTimestampResolver.unixTimestampSeconds(config.created))
                        size = totalSize
                        labels = config.config?.labels ?? [:]
                        foundUsableManifest = true
                    }
                }

                let repoTags = group.repoTags
                let repoDigests = group.repoDigests(includeDigests: includeDigests)
                let groupReferences = Set(group.references)
                let containersUsingImage = containers.filter { groupReferences.contains($0.configuration.image.reference) }
                let summary = RESTImageSummary(
                    Id: image.digest,
                    ParentId: "",
                    RepoTags: repoTags,
                    RepoDigests: repoDigests,
                    Created: created,
                    Size: size,
                    SharedSize: -1,
                    Labels: labels,
                    Containers: containersUsingImage.count,
                    Manifests: includeManifests ? manifestSummaries : nil,
                    Descriptor: makeOCIDescriptor(
                        from: image.descriptor,
                        appSupportURL: appleContainerAppSupportUrl
                    )
                )

                imagesSummaries.append(summary)
            }

            return try ImageListRoute.applyFilters(imagesSummaries, filters: filters)
        }
    }

    /// Applies the `dangling` and `reference` image-ls filters. Different keys
    /// AND together, matching moby.
    static func applyFilters(_ summaries: [RESTImageSummary], filters: [String: [String]]) throws -> [RESTImageSummary] {
        var result = summaries
        // A present (even empty) `dangling` key is validated, unlike `reference`
        // (where a present-but-empty filter matches nothing): real Docker 400s
        // `{"dangling":[]}` outright rather than treating it as "no filter" —
        // verified live. `!dangling.isEmpty` would treat it as absent instead.
        if let dangling = filters["dangling"] {
            // moby's filters.GetBoolOrDefault recognizes only 0/1/true/false
            // here (stricter than the MobyBool query-parameter semantics) and
            // rejects the value set if it has no recognized true/false token,
            // or has both — but does NOT reject an extra unrecognized token
            // once a real one is present: `dangling=[true,maybe]` behaves as
            // `dangling=true` on real Docker (verified live), so `maybe` here
            // is silently irrelevant, not itself invalid.
            let isTrue = dangling.contains("1") || dangling.contains("true")
            let isFalse = dangling.contains("0") || dangling.contains("false")
            guard isTrue != isFalse else {
                throw Abort(.badRequest, reason: "invalid filter 'dangling=[\(dangling.joined(separator: " "))]'")
            }
            result = result.filter { ImageListFilter.isDangling(repoTags: $0.RepoTags) == isTrue }
        }
        // A present `reference` key with zero values (an empty array, or a
        // boolean map with no true entries) is a real Docker filter that
        // matches nothing — not the same as the key being absent. `contains`
        // over an empty `patterns` array already returns false for every
        // image, which is exactly that "matches nothing" behavior.
        if let patterns = filters["reference"] {
            result = result.filter { ImageListFilter.referenceMatches(patterns: patterns, repoTags: $0.RepoTags) }
        }
        return result
    }
}
