import Foundation
import Testing
import Vapor

@testable import socktainer

/// `GET /images/json` has to decode in clients generated from Docker's schema. Two divergences broke
/// that: optional fields sent as explicit `null` where moby omits them, and Apple Container's
/// `untagged@sha256:…` marker leaking through as if it were a repository tag.
@Suite("ImageSummary serialization")
struct ImageSummarySchemaTests {
    private static func encode(_ summary: RESTImageSummary) throws -> [String: Any] {
        let data = try JSONEncoder().encode(summary)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func summary(
        manifests: [ImageManifestSummary]? = nil,
        descriptor: OCIDescriptor? = nil
    ) -> RESTImageSummary {
        RESTImageSummary(
            Id: "sha256:abc",
            ParentId: "",
            RepoTags: ["alpine:3.20"],
            RepoDigests: [],
            Created: 1_700_000_000,
            Size: 123,
            SharedSize: -1,
            Labels: [:],
            Containers: 0,
            Manifests: manifests,
            Descriptor: descriptor
        )
    }

    @Test("Absent Manifests and Descriptor are omitted, not sent as null")
    func absentOptionalsAreOmitted() throws {
        let json = try Self.encode(Self.summary())

        // moby marks both `omitempty`; the schema types them as an array and an object, so a null is a
        // value a generated client has no case for.
        #expect(json.keys.contains("Manifests") == false)
        #expect(json.keys.contains("Descriptor") == false)
        // The required fields stay present.
        for key in ["Id", "ParentId", "RepoTags", "RepoDigests", "Created", "Size", "SharedSize", "Labels", "Containers"] {
            #expect(json.keys.contains(key), "\(key) is required by the schema")
        }
    }

    @Test("A present Descriptor is encoded, and its own absent fields are omitted too")
    func presentDescriptorOmitsItsOwnOptionals() throws {
        let descriptor = OCIDescriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:abc",
            size: 2385,
            urls: nil,
            annotations: nil,
            data: nil,
            platform: nil,
            artifactType: nil
        )
        let json = try Self.encode(Self.summary(descriptor: descriptor))
        let encoded = json["Descriptor"] as? [String: Any] ?? [:]

        #expect(encoded["mediaType"] as? String == "application/vnd.oci.image.index.v1+json")
        #expect(encoded["digest"] as? String == "sha256:abc")
        for key in ["platform", "data", "artifactType", "annotations", "urls"] {
            #expect(encoded.keys.contains(key) == false, "\(key) is optional in the OCI descriptor and empty here")
        }
    }

    @Test("An untagged image reports no names at all, as moby does, so dangling filters find it")
    func untaggedImageReportsNoNames() {
        // What Apple Container hands us for an image with no tag: its own internal marker, the
        // counterpart of moby's `moby-dangling@sha256:…`, which moby never puts in a name array.
        let reference = "untagged@sha256:4c2bdddbf3e88a7c990a1b60c3a55aba31c902ecc45b2b1df9e6531e7ad4ca89"

        #expect(ImageListRoute.repoTags(forReference: reference).isEmpty)
        #expect(ImageListRoute.repoDigests(forReference: reference, includeDigests: true).isEmpty)
        // Empty names are what `--filter dangling=true` keys on; the raw marker reads as a tag.
        #expect(ImageListFilter.isDangling(repoTags: ImageListRoute.repoTags(forReference: reference)))
        #expect(ImageListFilter.isDangling(repoTags: [reference]) == false)
        // And a nameless image must not answer a reference filter.
        #expect(ImageListFilter.referenceMatches(patterns: ["*"], repoTags: ImageListRoute.repoTags(forReference: reference)) == false)
    }

    @Test("A tagged image is untouched, and its digest still honours the query flag")
    func taggedImageKeepsItsReference() {
        let tagged = "docker.io/library/alpine:3.20"
        #expect(ImageListRoute.repoTags(forReference: tagged) == [tagged])
        #expect(ImageListRoute.repoDigests(forReference: tagged, includeDigests: true).isEmpty)

        let both = "docker.io/library/alpine:3.20@sha256:abc"
        #expect(ImageListRoute.repoTags(forReference: both) == [both])
        #expect(ImageListRoute.repoDigests(forReference: both, includeDigests: true) == [both])
        #expect(ImageListRoute.repoDigests(forReference: both, includeDigests: false).isEmpty)
    }

    @Test("A digest-only reference is a digest, not a tag, whatever the query flag says")
    func digestOnlyReferenceIsADigest() {
        // moby derives RepoDigests from the target digest and leaves RepoTags empty for such an
        // image; it is named, so it is not dangling either.
        let digested = "docker.io/library/alpine@sha256:abc"
        #expect(ImageListRoute.repoTags(forReference: digested).isEmpty)
        #expect(ImageListRoute.repoDigests(forReference: digested, includeDigests: false) == [digested])
        #expect(ImageListRoute.repoDigests(forReference: digested, includeDigests: true) == [digested])
    }

    @Test("An empty reference is the same case as an untagged one")
    func emptyReferenceReportsNoNames() {
        #expect(ImageListRoute.repoTags(forReference: "").isEmpty)
        #expect(ImageListRoute.repoDigests(forReference: "", includeDigests: true).isEmpty)
    }
}

/// Apple Container stores one record per reference; Docker reports one per digest carrying every name.
@Suite("Image digest grouping")
struct ImageDigestGroupingTests {
    private struct Record: ImageDigestNamed {
        let digest: String
        let reference: String
    }

    private static let untaggedAlpine = Record(digest: "sha256:aaa", reference: "untagged@sha256:aaa")

    @Test("Two tags on one digest are one entry carrying both, as moby's tagsByDigest does")
    func twoTagsOneEntry() {
        let groups = ImageListRoute.groupByDigest([
            Record(digest: "sha256:aaa", reference: "docker.io/library/alpine:3.20"),
            Record(digest: "sha256:bbb", reference: "docker.io/library/busybox:latest"),
            Record(digest: "sha256:aaa", reference: "docker.io/library/myalpine:1"),
        ])

        #expect(groups.count == 2, "one entry per digest, not per reference")
        #expect(groups[0].repoTags == ["docker.io/library/alpine:3.20", "docker.io/library/myalpine:1"])
        #expect(groups[1].repoTags == ["docker.io/library/busybox:latest"])
        // Order follows the runtime's listing, so a client's image order does not shuffle.
        #expect(groups.map(\.representative.digest) == ["sha256:aaa", "sha256:bbb"])
    }

    @Test("An untagged marker beside a tagged record disappears into it, whichever arrives first")
    func untaggedMarkerIsAbsorbed() {
        let tagged = Record(digest: "sha256:aaa", reference: "socktainer-dns:embedded")

        for records in [[Self.untaggedAlpine, tagged], [tagged, Self.untaggedAlpine]] {
            let groups = ImageListRoute.groupByDigest(records)
            #expect(groups.count == 1)
            #expect(groups[0].repoTags == ["socktainer-dns:embedded"])
            // The tagged record is the one whose index and config get read.
            #expect(groups[0].representative.reference == "socktainer-dns:embedded")
            // And the entry is no longer dangling, so `image prune` cannot claim it.
            #expect(ImageListFilter.isDangling(repoTags: groups[0].repoTags) == false)
        }
    }

    @Test("An untagged image nothing else names stays, once, as a dangling entry")
    func loneUntaggedImageSurvives() {
        let groups = ImageListRoute.groupByDigest([
            Self.untaggedAlpine,
            Record(digest: "sha256:aaa", reference: "untagged@sha256:aaa"),
        ])

        #expect(groups.count == 1)
        #expect(groups[0].repoTags.isEmpty)
        #expect(groups[0].repoDigests(includeDigests: true).isEmpty)
        #expect(ImageListFilter.isDangling(repoTags: groups[0].repoTags))
    }

    @Test("Digest-only references collect under RepoDigests, tags under RepoTags")
    func namesSplitByKind() {
        let groups = ImageListRoute.groupByDigest([
            Record(digest: "sha256:aaa", reference: "docker.io/library/alpine@sha256:aaa"),
            Record(digest: "sha256:aaa", reference: "docker.io/library/alpine:3.20"),
        ])

        #expect(groups.count == 1)
        #expect(groups[0].repoTags == ["docker.io/library/alpine:3.20"])
        #expect(groups[0].repoDigests(includeDigests: false) == ["docker.io/library/alpine@sha256:aaa"])
    }
}
