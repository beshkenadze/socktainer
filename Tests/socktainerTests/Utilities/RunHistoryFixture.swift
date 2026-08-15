import Foundation

@testable import socktainer

/// One boot-record root for the whole test process.
///
/// `ContainerRunHistory` holds a single configured root, as it does in the daemon, so a suite that
/// points it at a private directory takes it away from every suite running beside it — Swift Testing
/// runs suites in parallel, and the theft shows up as an unrelated test seeing "created" for a
/// container it had marked as having run. Sharing one root removes the race instead of serializing
/// around it: every suite configures the same path, and identity comes from the container id.
enum RunHistoryFixture {
    static let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "socktainer-run-history-tests")

    /// Writes the artifact the runtime leaves when it boots a container, so `hasRun(id:)` answers
    /// true for `id` — the shape a container that has run has on disk.
    static func markRan(_ id: String) throws {
        let dir = root.appending(path: "containers").appending(path: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "vminitd.log"))
        configure()
    }

    /// Points `ContainerRunHistory` at the shared root. Idempotent, and safe to call from any suite:
    /// every caller sets the same value.
    static func configure() {
        try? FileManager.default.createDirectory(
            at: root.appending(path: "containers"), withIntermediateDirectories: true)
        ContainerRunHistory.configure(storageDirectory: root)
    }

    /// An id no test has marked, so `hasRun` answers false without disturbing anyone else's root.
    static func unmarkedId() -> String {
        "never-ran-\(UUID().uuidString)"
    }
}
