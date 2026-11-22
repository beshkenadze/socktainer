import ContainerResource
import Foundation
import Logging

/// The host-side writes to volume images that a container create makes. They all happen after
/// the native create has succeeded: a create that the runtime refuses changes no volume.
///
/// A volume that `VolumeImageEligibility` finds empty and clean is prepared, as on 166bbd5:
/// - without `nocopy`, the copy-up builds a new image with what the container's image has at the
///   mount path (nothing when the path is absent), without `/lost+found`;
/// - with `nocopy`, only a Postgres container (`PGDATA`, no opt-out) gets one change: the empty
///   `/lost+found` is dropped. Otherwise nothing is wanted.
/// A wanted preparation needs the container list, read after the native create: no write to a
/// volume that another container configuration names (by volume name or image path), and none
/// when the list cannot be read. Every wanted preparation that does not happen gives a create
/// warning that says why and what to do. A volume that holds data is not touched and gives no
/// warning.
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

    /// One preparation of one volume.
    enum Job: Equatable, Sendable {
        case copyUp(source: String, destination: String)
        case dropLostFound(source: String)

        var source: String {
            switch self {
            case .copyUp(let source, _), .dropLostFound(let source): source
            }
        }
    }

    /// What touches images; replaced in tests.
    protocol Writer: Sendable {
        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict
        /// Runs the jobs for `container`; returns why each job that did not complete failed,
        /// keyed by the volume's image path.
        func prepare(_ jobs: [Job], for container: ContainerSnapshot) -> [String: String]
    }

    struct Production: Writer {
        let logger: Logger

        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict {
            VolumeImageEligibility.check(imagePath: imagePath)
        }

        func prepare(_ jobs: [Job], for container: ContainerSnapshot) -> [String: String] {
            var failures: [String: String] = [:]
            var copies: [(source: String, destination: String)] = []
            for job in jobs {
                switch job {
                case .copyUp(let source, let destination):
                    copies.append((source: source, destination: destination))
                case .dropLostFound(let source):
                    do {
                        try VolumeImageCleaner.removeLostFound(imagePath: source, logger: logger)
                    } catch {
                        failures[source] = "\(error)"
                    }
                }
            }
            failures.merge(ContainerCreateRoute.populateEmptyVolumes(copies, for: container, logger: logger)) { $1 }
            return failures
        }
    }

    /// Splits the `nocopy` option off a named volume's options: it is not a mount option.
    static func splitNoCopy(_ options: [String]) -> (options: [String], noCopy: Bool) {
        let kept = options.filter { $0.lowercased() != "nocopy" }
        return (kept, kept.count != options.count)
    }

    /// The text of a create warning for a volume whose preparation did not happen.
    static func notPrepared(_ volume: Volume, reason: String) -> String {
        "volume \"\(volume.name)\" was not prepared (\(reason)): it keeps /lost+found and "
            + (volume.noCopy ? "" : "the image's \(volume.destination) was not copied into it. ")
            + "A Postgres container with PGDATA at the volume root refuses /lost+found: stop every container that uses the volume, "
            + "then run `docker run --rm -v \(volume.name):/v busybox rmdir /v/lost+found`, or create and start the service "
            + "that fills the volume before the others"
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

        let postgres = VolumeImageCleaner.isPostgresDataVolume(mergedEnv: mergedEnv)
        // The preparation each volume wants, decided on its image after the create.
        var wanted: [(volume: Volume, verdict: VolumeImageEligibility.Verdict)] = []
        for volume in volumes {
            let verdict = writer.verdict(imagePath: volume.source)
            if case .holdsData = verdict {
                continue
            }
            if volume.noCopy {
                guard postgres, VolumeImageCleaner.isEnabled(labels: volume.labels) else {
                    continue
                }
                if case .replaceable(hasLostFound: false) = verdict {
                    continue
                }
            }
            wanted.append((volume, verdict))
        }
        var warnings: [String] = []
        var replaceable: [Volume] = []
        for (volume, verdict) in wanted {
            if case .doubtful(let reason) = verdict {
                warnings.append(notPrepared(volume, reason: "its image could not be shown to be empty: \(reason)"))
            } else {
                replaceable.append(volume)
            }
        }

        var jobs: [(volume: Volume, job: Job)] = []
        // The list is read only when a volume can be prepared.
        let named =
            replaceable.isEmpty ? nil : (try? await listContainers()).map { VolumeImageWriters.named(by: $0, except: container.id) }
        for volume in replaceable {
            guard let named else {
                warnings.append(notPrepared(volume, reason: "the container list could not be read"))
                continue
            }
            guard VolumeImageWriters.mayWrite(name: volume.name, source: volume.source, named: named) else {
                warnings.append(notPrepared(volume, reason: "another container uses it, in any state"))
                continue
            }
            let job: Job =
                volume.noCopy
                ? .dropLostFound(source: volume.source)
                : .copyUp(source: volume.source, destination: volume.destination)
            jobs.append((volume, job))
        }
        if !jobs.isEmpty {
            let failures = writer.prepare(jobs.map(\.job), for: container)
            for (volume, job) in jobs {
                if let failure = failures[job.source] {
                    warnings.append(notPrepared(volume, reason: failure))
                }
            }
        }
        for warning in warnings {
            logger.warning("[volume-prepare] \(warning)")
        }
        return (container, warnings)
    }
}
