import ContainerResource
import Foundation
import Logging

/// The host-side writes to volume images that a container create makes: the copy-up, and nothing
/// else. It happens after the native create has succeeded, so a create that the runtime refuses
/// changes no volume.
///
/// Every mount without `nocopy` is a copy-up candidate, in the order of the request (Binds, then
/// Mounts, then the image's declared volumes, as on 166bbd5). Each candidate is judged again by
/// `VolumeImageEligibility` right before its write: a volume that an earlier candidate filled is
/// skipped, and one that an earlier candidate left empty gets the next. The copy-up builds a new
/// image with what the container's image has at the mount path (nothing when the path is absent),
/// without `/lost+found`. A mount with `nocopy` is never a candidate: the volume is not touched
/// for it, as in Docker.
///
/// A copy-up needs the container list, read after the native create (three attempts): no write to
/// a volume that another container configuration names (by volume name or image path), and none
/// when the list cannot be read. Every wanted copy-up that does not happen gives a create warning
/// that says why. A volume that holds data is not touched and gives no warning.
enum VolumeImageWrites {
    /// An ext4 volume that the new container mounts.
    struct Volume: Equatable, Sendable {
        let name: String
        let source: String
        let destination: String
        let labels: [String: String]
        /// `nocopy` (bind option) or `VolumeOptions.NoCopy` (mount): no copy-up.
        let noCopy: Bool
    }

    /// What touches images; replaced in tests.
    protocol Writer: Sendable {
        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict
        /// Copies up each mount in order, judging each again right before its write; returns why
        /// each volume that was not prepared was not, keyed by its image path.
        func copyUp(_ mounts: [(source: String, destination: String)], into container: ContainerSnapshot) -> [String: String]
    }

    struct Production: Writer {
        let logger: Logger

        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict {
            VolumeImageEligibility.check(imagePath: imagePath)
        }

        func copyUp(_ mounts: [(source: String, destination: String)], into container: ContainerSnapshot) -> [String: String] {
            ContainerCreateRoute.populateEmptyVolumes(mounts, for: container, logger: logger)
        }
    }

    static let listAttempts = 3
    static let listPause = Duration.milliseconds(200)

    /// Splits the `nocopy` option off a named volume's options: it is not a mount option.
    static func splitNoCopy(_ options: [String]) -> (options: [String], noCopy: Bool) {
        let kept = options.filter { $0.lowercased() != "nocopy" }
        return (kept, kept.count != options.count)
    }

    /// The `PGDATA` value of the container, when it sets one.
    static func pgdata(_ mergedEnv: [String]) -> String? {
        mergedEnv.first { $0.hasPrefix("PGDATA=") }.map { String($0.dropFirst("PGDATA=".count)) }
    }

    /// A path with its empty and `.` components dropped and `..` applied, so that `/data/`,
    /// `/data/.` and `/data` compare equal.
    static func normalised(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The text of a create warning for a volume that was not prepared. It says only what the
    /// check saw: the copy-up part only when a copy-up was wanted (`copyTo` is not empty), and the
    /// /lost+found part only when the check saw one or could not tell.
    static func notPrepared(
        _ name: String, copyTo destinations: [String], reason: String, verdict: VolumeImageEligibility.Verdict
    ) -> String {
        var missed: [String] = []
        var remedies: [String] = []
        if !destinations.isEmpty {
            missed.append("the image's files at \(destinations.joined(separator: " and ")) were not copied into it")
            remedies.append("copy those files in")
        }
        switch verdict {
        case .replaceable(hasLostFound: true):
            missed.append("its /lost+found directory was not removed")
        case .replaceable(hasLostFound: false):
            break
        case .doubtful, .holdsData:
            missed.append("a /lost+found directory, if it has one, was not removed")
        }
        if missed.count > remedies.count {
            remedies.append("run `docker run --rm -v \(name):/v busybox rmdir /v/lost+found`")
        }
        let text = "volume \"\(name)\" was not prepared (\(reason))"
        guard !missed.isEmpty else {
            return text
        }
        return text + ": " + missed.joined(separator: ", and ") + ". If the container needs "
            + (missed.count == 1 ? "this" : "either") + ", stop every container that uses the volume, then "
            + remedies.joined(separator: " or ") + ", or create and start the container that fills the volume first"
    }

    static func create(
        volumes: [Volume],
        mergedEnv: [String],
        listContainers: () async throws -> [ContainerSnapshot],
        nativeCreate: () async throws -> ContainerSnapshot,
        writer: Writer,
        logger: Logger
    ) async throws -> (container: ContainerSnapshot, warnings: [String]) {
        let container = try await nativeCreate()

        // The volumes, in the order of their first mount.
        var order: [String] = []
        var mountsOf: [String: [Volume]] = [:]
        for volume in volumes {
            if mountsOf[volume.source] == nil {
                order.append(volume.source)
            }
            mountsOf[volume.source, default: []].append(volume)
        }

        var warnings: [String] = []
        var candidates: [(name: String, source: String, copyTo: [String], verdict: VolumeImageEligibility.Verdict)] = []
        let pgdata = pgdata(mergedEnv).map(normalised)
        for source in order {
            let mounts = mountsOf[source] ?? []
            guard let name = mounts.first?.name else {
                continue
            }
            let verdict = writer.verdict(imagePath: source)
            if case .holdsData = verdict {
                continue
            }
            let copyTo = mounts.filter { !$0.noCopy }.map(\.destination)
            guard !copyTo.isEmpty else {
                // Only nocopy mounts: not touched. A Postgres data directory at a mount path
                // refuses /lost+found.
                if case .replaceable(hasLostFound: true) = verdict, let pgdata,
                    mounts.contains(where: { normalised($0.destination) == pgdata })
                {
                    warnings.append(notPrepared(name, copyTo: [], reason: "nocopy is set", verdict: verdict))
                }
                continue
            }
            if case .doubtful(let reason) = verdict {
                warnings.append(notPrepared(name, copyTo: copyTo, reason: "its image could not be judged: \(reason)", verdict: verdict))
                continue
            }
            candidates.append((name, source, copyTo, verdict))
        }

        if !candidates.isEmpty {
            var list: [ContainerSnapshot]?
            for attempt in 1...listAttempts where list == nil {
                list = try? await listContainers()
                if list == nil, attempt < listAttempts {
                    try? await Task.sleep(for: listPause)
                }
            }
            let named = list.map { VolumeImageWriters.named(by: $0, except: container.id) }
            var targets: [(name: String, source: String, copyTo: [String], verdict: VolumeImageEligibility.Verdict)] = []
            for candidate in candidates {
                guard let named else {
                    warnings.append(
                        notPrepared(candidate.name, copyTo: candidate.copyTo, reason: "the container list could not be read", verdict: candidate.verdict))
                    continue
                }
                guard VolumeImageWriters.mayWrite(name: candidate.name, source: candidate.source, named: named) else {
                    warnings.append(
                        notPrepared(
                            candidate.name, copyTo: candidate.copyTo, reason: "another container names it, in any state", verdict: candidate.verdict))
                    continue
                }
                targets.append(candidate)
            }
            if !targets.isEmpty {
                let allowed = Set(targets.map(\.source))
                let mounts = volumes.filter { !$0.noCopy && allowed.contains($0.source) }
                let failures = writer.copyUp(mounts.map { (source: $0.source, destination: $0.destination) }, into: container)
                for target in targets {
                    if let failure = failures[target.source] {
                        warnings.append(notPrepared(target.name, copyTo: target.copyTo, reason: failure, verdict: target.verdict))
                    }
                }
            }
        }
        for warning in warnings {
            logger.warning("[volume-prepare] \(warning)")
        }
        return (container, warnings)
    }
}
