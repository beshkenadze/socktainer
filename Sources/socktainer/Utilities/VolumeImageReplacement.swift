import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage

/// Replaces a volume's backing image with a new one, built beside it.
///
/// The old image is never opened for writing: the new image is formatted in a staging file in
/// the same directory and moved into place with one rename, so a failure at any step leaves the
/// old image whole. Both checks of `VolumeImageEligibility` (before the build and just before the
/// rename) must find the old image empty and clean.
enum VolumeImageReplacement {
    struct Refused: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// Builds the new image with `build`, which gets a formatter for an empty file system with
    /// `/lost+found`, of the old image's size.
    static func replace(imagePath: String, build: (EXT4.Formatter) throws -> Void) throws {
        try requireReplaceable(imagePath)
        removeStaleStaging(beside: imagePath)

        let attributes = try FileManager.default.attributesOfItem(atPath: imagePath)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let destination = URL(fileURLWithPath: imagePath)
        let staging = destination.deletingLastPathComponent().appendingPathComponent("rebuild-\(UUID().uuidString).img")
        var placed = false
        defer {
            if !placed { try? FileManager.default.removeItem(at: staging) }
        }

        let formatter = try EXT4.Formatter(FilePath(staging.path), blockSize: 4096, minDiskSize: max(size, 4 * 1024 * 1024))
        try build(formatter)
        try formatter.close()

        // The build can take a while: check again right before the old image goes away.
        try requireReplaceable(imagePath)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        placed = true
    }

    /// Removes the staging files that a bridge killed during an earlier rebuild of this volume
    /// left beside the image. They are only ever this code's own files: `rebuild-<UUID>.img`.
    private static func removeStaleStaging(beside imagePath: String) {
        let directory = URL(fileURLWithPath: imagePath).deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in entries where entry.hasPrefix("rebuild-") && entry.hasSuffix(".img") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    private static func requireReplaceable(_ imagePath: String) throws {
        switch VolumeImageEligibility.check(imagePath: imagePath) {
        case .replaceable:
            return
        case .holdsData:
            throw Refused(reason: "\(imagePath) holds data")
        case .doubtful(let reason):
            throw Refused(reason: reason)
        }
    }
}
