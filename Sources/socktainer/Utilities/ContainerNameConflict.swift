import ContainerAPIClient
import ContainerizationError
import Foundation
import Logging
import Vapor

/// A container name that is already in use, decided by the file system that holds the runtime's
/// container directories.
///
/// Docker names are case-sensitive, but on a case-insensitive data root (the macOS default)
/// `web` and `WEB` name one directory, `containers/web`. A runtime without reserved state
/// directories (apple/container up to 1.7.1, the fork up to 1.7.1-bshk.1) then lets a create of
/// `WEB` overwrite web's runtime configuration, and a later delete of `WEB` removes web's bundle
/// with its writable root file system.
///
/// `guardCreate` is a mitigation for those runtimes, not the fix: it refuses the create before the
/// runtime sees it, but its check and the runtime's create are separate steps, so two creates at
/// the same moment can still collide. Only the runtime's reservation of the directory closes that.
/// `conflict(after:)` turns the runtime's own refusal of a name in use into Docker's 409.
enum ContainerNameConflict {
    /// The name, as it is on disk, of the entry in `containersDirectory` that the file system
    /// treats as `id`; nil when there is none.
    static func existingEntry(id: String, containersDirectory: URL) -> String? {
        let path = containersDirectory.appendingPathComponent(id)
        // fileExists compares names the way the file system does: case and Unicode form included.
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        var target = stat()
        guard lstat(path.path, &target) == 0 else {
            return id
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: containersDirectory.path)) ?? []
        for entry in entries {
            var info = stat()
            if lstat(containersDirectory.appendingPathComponent(entry).path, &info) == 0,
                info.st_dev == target.st_dev, info.st_ino == target.st_ino
            {
                return entry
            }
        }
        return id
    }

    static func abort(name: String, existing: String) -> Abort {
        Abort(
            .conflict,
            reason:
                "Conflict. The container name \"/\(name)\" is already in use by container \"\(existing)\". You have to remove (or rename) that container to be able to reuse that name."
        )
    }

    /// The 409 for a create that the runtime refused because the name is in use, or nil when the
    /// error is something else.
    static func conflict(after error: Error, name: String, containersDirectory: URL?) -> Abort? {
        guard let error = error as? ContainerizationError, error.code == .exists, let containersDirectory,
            let existing = existingEntry(id: name, containersDirectory: containersDirectory)
        else {
            return nil
        }
        return abort(name: name, existing: existing)
    }

    /// Refuses a create whose name is already in use on disk. A runtime that cannot be asked for
    /// its data root skips the check; the runtime's own refusal still maps to 409.
    static func guardCreate(name: String, containersDirectory: URL?) throws {
        guard let containersDirectory, let existing = existingEntry(id: name, containersDirectory: containersDirectory) else {
            return
        }
        throw abort(name: name, existing: existing)
    }

    /// `<runtime app root>/containers`, read once from the runtime's health answer.
    static func containersDirectory(logger: Logger) async -> URL? {
        await RuntimeContainersDirectory.shared.value(logger: logger)
    }
}

private actor RuntimeContainersDirectory {
    static let shared = RuntimeContainersDirectory()
    private var cached: URL?
    /// A failed lookup is not repeated for a minute, so a create does not wait on a runtime
    /// that does not answer.
    private var failedAt: ContinuousClock.Instant?

    func value(logger: Logger) async -> URL? {
        if let cached {
            return cached
        }
        if let failedAt, ContinuousClock.now - failedAt < .seconds(60) {
            return nil
        }
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(2))
            let directory = URL(fileURLWithPath: health.appRoot.path(percentEncoded: false)).appendingPathComponent("containers")
            cached = directory
            return directory
        } catch {
            failedAt = .now
            logger.debug("[container-name] no runtime data root for the name check: \(error)")
            return nil
        }
    }
}
