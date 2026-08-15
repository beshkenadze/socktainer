import Foundation
import Synchronization

/// Whether the runtime has ever booted a container.
///
/// `ContainerSnapshot.startedDate` cannot answer this. It lives in the daemon's memory and is set
/// only once a start fully succeeds, so it reads nil in two situations that are not "never ran":
///
///   - after a daemon restart, where `ContainersService` rebuilds every snapshot from the on-disk
///     bundle as `status: .stopped, startedDate: nil`, losing the start times of everything that
///     had been running;
///   - after a start that booted the guest and then failed, which never reaches the assignment.
///
/// The runtime does leave a durable trace: it materialises the guest's boot artifacts inside the
/// container's directory the first time it starts. A container that has run owns a `vminitd.log`;
/// one that has only been created owns nothing but its runtime configuration. That file outlives
/// the daemon, so it answers across restarts where the clock cannot.
public enum ContainerRunHistory {
    private static let root = Mutex<URL?>(nil)

    /// `storageDirectory` is Apple Container's application-support root, the parent of `containers/`.
    public static func configure(storageDirectory: URL) {
        root.withLock { $0 = storageDirectory }
    }

    /// False when the answer is unknowable — no configured root, or the runtime keeps its state
    /// elsewhere — which leaves callers on the snapshot's own account of itself.
    public static func hasRun(id: String) -> Bool {
        guard let root = root.withLock({ $0 }) else { return false }
        let bootLog = root.appending(path: "containers").appending(path: id).appending(path: "vminitd.log")
        return FileManager.default.fileExists(atPath: bootLog.path)
    }
}
