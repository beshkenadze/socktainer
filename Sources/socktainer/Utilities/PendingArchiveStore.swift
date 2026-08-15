import Foundation
import Logging

/// Archives written into a container that has only been created, held until it starts.
///
/// The runtime materialises a container's filesystem when it first boots, so a container that has
/// been created and never started has no `rootfs.ext4` to write into — `PUT /containers/{id}/archive`
/// answered 404 `Rootfs not found`. buildx does exactly this: it creates its builder, copies files
/// in, and only then starts it, so the very first `docker build` failed before BuildKit ever ran
/// (ContainerStack #9). Docker's filesystem exists from create, and clients rely on it.
///
/// Booting the guest at write time would answer the 404, and would also make the container look like
/// it had run: the boot leaves the artifacts `ContainerRunHistory` reads to tell `created` from
/// `exited`, so `docker create` + `docker cp` would flip the container's reported state. Holding the
/// bytes until the start that was coming anyway keeps both answers honest.
///
/// Memory-only, like the copy it is standing in for: a bridge restart between the create and the
/// start loses the pending write, and the container starts without it — the same outcome as the
/// write never having been made.
actor PendingArchiveStore {
    static let shared = PendingArchiveStore()

    struct Pending: Sendable {
        let tarPath: URL
        let destination: String
        let noOverwriteDirNonDir: Bool
    }

    private var pending: [String: [Pending]] = [:]
    private let log = Logger(label: "socktainer.pending-archive")

    /// Takes ownership of a copy of `tarPath`: the caller's file is a request-scoped temporary that
    /// is deleted as soon as the response is written.
    func stash(id: String, tarPath: URL, destination: String, noOverwriteDirNonDir: Bool) throws {
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-archive-\(UUID().uuidString).tar")
        try FileManager.default.copyItem(at: tarPath, to: owned)
        pending[id, default: []].append(
            Pending(tarPath: owned, destination: destination, noOverwriteDirNonDir: noOverwriteDirNonDir))
        log.debug("holding an archive for \(id) until it starts: \(destination)")
    }

    /// Hands over everything held for `id`, in the order it was written, and forgets it. The caller
    /// owns the files and deletes them.
    func take(id: String) -> [Pending] {
        pending.removeValue(forKey: id) ?? []
    }

    /// The container went away before it ever started; the bytes go with it.
    func discard(id: String) {
        for entry in pending.removeValue(forKey: id) ?? [] {
            try? FileManager.default.removeItem(at: entry.tarPath)
        }
    }

    /// Whether anything is waiting — lets the start path skip the work in the ordinary case.
    func hasPending(id: String) -> Bool {
        !(pending[id]?.isEmpty ?? true)
    }
}
