import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage

/// Removes `/lost+found` from the EXT4 image backing a named volume.
///
/// Apple Container always creates `/lost+found` at the volume root, which
/// causes Postgres's `initdb` to reject the directory as non-empty. Named
/// volumes are always mounted at their root, so `/lost+found` is always at
/// the top of every mount — the EXT4 reformat is idempotent (no-op when
/// already absent) and safe for all images.
/// Best-effort: failures are logged and never propagate to the caller.
enum VolumeImageCleaner {
    static let optOutLabel = "socktainer.clean-volumes"
    static let optOutEnvVar = "SOCKTAINER_CLEAN_VOLUMES"

    /// Returns true when `PGDATA` is set in `mergedEnv` (any value), which
    /// reliably identifies a Postgres container regardless of the actual path.
    /// Named volumes are always mounted at their root, so any EXT4 named volume
    /// used by a Postgres container may contain `/lost+found` at the mount root.
    static func isPostgresDataVolume(mergedEnv: [String]) -> Bool {
        mergedEnv.contains(where: { $0.hasPrefix("PGDATA=") })
    }

    /// Returns false when opted out via `SOCKTAINER_CLEAN_VOLUMES=false` or
    /// the `socktainer.clean-volumes=false` volume label.
    static func isEnabled(
        labels: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[optOutEnvVar]?.lowercased() == "false" { return false }
        if labels[optOutLabel]?.lowercased() == "false" { return false }
        return true
    }

    /// Replaces an empty EXT4 image that has `/lost+found` with an empty one that does not. The
    /// new image is built beside the old one and moved into place, so a failure leaves the old
    /// image whole; any image that is not shown to be empty and clean is left as it is.
    static func removeLostFound(imagePath: String, logger: Logger) throws {
        guard VolumeImageEligibility.check(imagePath: imagePath) == .replaceable(hasLostFound: true) else {
            throw VolumeImageReplacement.Refused(reason: "not an empty volume with /lost+found")
        }
        try VolumeImageReplacement.replace(imagePath: imagePath) { formatter in
            try formatter.unlink(path: FilePath("/lost+found"))
        }
        logger.info("[volume-clean] removed /lost+found from \(imagePath)")
    }
}
