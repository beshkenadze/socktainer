import Foundation

/// Where this bridge instance serves and where it reads the runtime's data.
///
/// Both used to be derived from the home directory with no way to say otherwise, which made two
/// things impossible. A runtime started on a throwaway root (`container system start --app-root`)
/// could not be paired with a bridge, because `NSHomeDirectory()` ignores `$HOME` — measured: with
/// `HOME=/tmp/fake-home` it still answers the login home — so the bridge kept reading the real root
/// while the daemon wrote elsewhere. And two bridges could not coexist on one machine, which is why
/// work on this project could not be verified live while someone else was using the runtime.
struct RuntimeLocation: Sendable {
    /// Apple Container's application data root — the parent of `containers/`, `volumes/` and the
    /// stores this bridge persists beside them.
    let appRoot: URL
    /// The unix socket this instance listens on.
    let socketPath: String
    /// Whether the socket was chosen rather than derived, which is what marks this a second instance.
    let hasCustomSocket: Bool

    /// Apple Container's own default, and the only path its daemon uses without `--app-root`.
    static func defaultAppRoot() -> URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/com.apple.container")
    }

    init(appRootOption: String?, socketOption: String?, homeDirectory: String?) throws {
        if let appRootOption, !appRootOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appRoot = URL(fileURLWithPath: (appRootOption as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            appRoot = Self.defaultAppRoot()
        }

        if let socketOption, !socketOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            socketPath = (socketOption as NSString).expandingTildeInPath
            hasCustomSocket = true
        } else {
            guard let homeDir = homeDirectory, !homeDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UnixSocketError.missingHomeDirectory
            }
            socketPath = containerSocketPath(homeDirectory: homeDir)
            hasCustomSocket = false
        }
    }
}
