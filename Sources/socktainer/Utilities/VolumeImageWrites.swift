import ContainerResource
import Foundation
import Logging

/// The host-side writes to volume images that a container create makes, in their order: the
/// `/lost+found` clean-up before the native create, the copy-up after it. The create route
/// performs its native create through `create`, so the order is fixed in one place.
///
/// A write happens only to an image that `VolumeImageEligibility` finds empty and clean and that
/// no other container configuration names (by volume name or by image path), with the container
/// list read just before the write. A list that cannot be read means no write.
enum VolumeImageWrites {
    /// An ext4 named volume that the new container mounts.
    struct Volume: Equatable, Sendable {
        let name: String
        let source: String
        let destination: String
        let labels: [String: String]
    }

    /// What touches images; replaced in tests.
    protocol Writer: Sendable {
        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict
        func removeLostFound(imagePath: String)
        func copyUp(_ volumes: [(source: String, destination: String)], into container: ContainerSnapshot)
    }

    struct Production: Writer {
        let logger: Logger

        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict {
            VolumeImageEligibility.check(imagePath: imagePath)
        }

        func removeLostFound(imagePath: String) {
            VolumeImageCleaner.removeLostFound(imagePath: imagePath, logger: logger)
        }

        func copyUp(_ volumes: [(source: String, destination: String)], into container: ContainerSnapshot) {
            ContainerCreateRoute.populateEmptyVolumes(volumes, for: container, logger: logger)
        }
    }

    static func create(
        volumes: [Volume],
        mergedEnv: [String],
        listContainers: () async throws -> [ContainerSnapshot],
        nativeCreate: () async throws -> ContainerSnapshot,
        writer: Writer,
        logger: Logger
    ) async throws -> (container: ContainerSnapshot, warnings: [String]) {
        let toClean = volumes.filter {
            VolumeImageCleaner.isPostgresDataVolume(mergedEnv: mergedEnv) && VolumeImageCleaner.isEnabled(labels: $0.labels)
                && writer.verdict(imagePath: $0.source) == .replaceable(hasLostFound: true)
        }
        if !toClean.isEmpty, let others = try? await listContainers() {
            let named = VolumeImageWriters.named(by: others, except: nil)
            for volume in toClean where VolumeImageWriters.mayWrite(name: volume.name, source: volume.source, named: named) {
                writer.removeLostFound(imagePath: volume.source)
            }
        }

        let container = try await nativeCreate()

        var warnings: [String] = []
        let candidates = volumes
        guard !candidates.isEmpty else {
            return (container, warnings)
        }
        // Read after the create: a container created meanwhile that names the volume counts too.
        let named = (try? await listContainers()).map { VolumeImageWriters.named(by: $0, except: container.id) }
        var targets: [(source: String, destination: String)] = []
        for volume in candidates {
            switch writer.verdict(imagePath: volume.source) {
            case .holdsData:
                continue
            case .doubtful(let reason):
                warnings.append("volume \"\(volume.name)\" could not be shown to be empty (\(reason)): the image's \(volume.destination) was not copied into it")
            case .replaceable:
                guard let named else {
                    warnings.append(
                        "volume \"\(volume.name)\" may be used by another container (the container list could not be read): the image's \(volume.destination) was not copied into it"
                    )
                    continue
                }
                guard VolumeImageWriters.mayWrite(name: volume.name, source: volume.source, named: named) else {
                    warnings.append("volume \"\(volume.name)\" is used by another container: the image's \(volume.destination) was not copied into it")
                    continue
                }
                targets.append((source: volume.source, destination: volume.destination))
            }
        }
        for warning in warnings {
            logger.warning("[volume-copyup] \(warning)")
        }
        if !targets.isEmpty {
            writer.copyUp(targets, into: container)
        }
        return (container, warnings)
    }
}
