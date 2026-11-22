import ContainerResource
import Foundation
import Logging

/// The host-side writes to volume images that a container create makes: the copy-up, and nothing
/// else. It happens after the native create has succeeded, so a create that the runtime refuses
/// changes no volume.
///
/// A volume is prepared at most once per create, by its first mount in the order of the request
/// (Binds, then Mounts, then the image's declared volumes, as on 166bbd5). When that mount has no
/// `nocopy`, and `VolumeImageEligibility` finds the image empty and clean, the copy-up builds a
/// new image with what the container's image has at the mount path (nothing when the path is
/// absent), without `/lost+found`. With `nocopy`, the volume is not touched, as in Docker.
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
        /// Copies up each volume for `container`; returns why each copy-up that did not complete
        /// failed, keyed by the volume's image path.
        func copyUp(_ volumes: [(source: String, destination: String)], into container: ContainerSnapshot) -> [String: String]
    }

    struct Production: Writer {
        let logger: Logger

        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict {
            VolumeImageEligibility.check(imagePath: imagePath)
        }

        func copyUp(_ volumes: [(source: String, destination: String)], into container: ContainerSnapshot) -> [String: String] {
            ContainerCreateRoute.populateEmptyVolumes(volumes, for: container, logger: logger)
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

    /// The text of a create warning for a volume that was not prepared. It says only what the
    /// check saw: the copy-up part only when a copy-up was wanted, and /lost+found as present
    /// only when the check found it.
    static func notPrepared(_ volume: Volume, reason: String, verdict: VolumeImageEligibility.Verdict) -> String {
        var missed: [String] = []
        if !volume.noCopy {
            missed.append("the image's files at \(volume.destination) were not copied into it")
        }
        switch verdict {
        case .replaceable(hasLostFound: true):
            missed.append("its /lost+found directory was not removed")
        case .replaceable(hasLostFound: false):
            break
        case .doubtful, .holdsData:
            missed.append("a /lost+found directory, if it has one, was not removed")
        }
        return "volume \"\(volume.name)\" was not prepared (\(reason)): " + missed.joined(separator: ", and ")
            + ". If the container needs either, stop every container that uses the volume, then copy the files in or run "
            + "`docker run --rm -v \(volume.name):/v busybox rmdir /v/lost+found`, or create and start the container that "
            + "fills the volume first"
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

        // One plan per volume: its first mount decides.
        var seen = Set<String>()
        let firstMounts = volumes.filter { seen.insert($0.source).inserted }

        var warnings: [String] = []
        var candidates: [(volume: Volume, verdict: VolumeImageEligibility.Verdict)] = []
        let pgdata = pgdata(mergedEnv)
        for volume in firstMounts {
            let verdict = writer.verdict(imagePath: volume.source)
            if case .holdsData = verdict {
                continue
            }
            if volume.noCopy {
                // Not touched. A Postgres data directory at the volume root refuses /lost+found.
                if case .replaceable(hasLostFound: true) = verdict, pgdata == volume.destination {
                    warnings.append(notPrepared(volume, reason: "nocopy is set", verdict: verdict))
                }
                continue
            }
            if case .doubtful(let reason) = verdict {
                warnings.append(notPrepared(volume, reason: "its image could not be judged: \(reason)", verdict: verdict))
                continue
            }
            candidates.append((volume, verdict))
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
            var targets: [(volume: Volume, verdict: VolumeImageEligibility.Verdict)] = []
            for (volume, verdict) in candidates {
                guard let named else {
                    warnings.append(notPrepared(volume, reason: "the container list could not be read", verdict: verdict))
                    continue
                }
                guard VolumeImageWriters.mayWrite(name: volume.name, source: volume.source, named: named) else {
                    warnings.append(notPrepared(volume, reason: "another container names it, in any state", verdict: verdict))
                    continue
                }
                targets.append((volume, verdict))
            }
            if !targets.isEmpty {
                let failures = writer.copyUp(targets.map { (source: $0.volume.source, destination: $0.volume.destination) }, into: container)
                for (volume, verdict) in targets {
                    if let failure = failures[volume.source] {
                        warnings.append(notPrepared(volume, reason: failure, verdict: verdict))
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
