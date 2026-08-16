import Foundation
import Testing

@testable import socktainer

/// Both of this bridge's locations used to come from the home directory with no way to say
/// otherwise, and no environment variable could stand in: `NSHomeDirectory()` ignores `$HOME` —
/// measured, with `HOME=/tmp/fake-home` it still answers `/Users/<you>` — so a runtime started on a
/// throwaway root (`container system start --app-root`) had a bridge still reading the real one, and
/// two bridges could not run side by side at all (ContainerStack #48).
@Suite("Where this instance serves and reads")
struct RuntimeLocationTests {

    @Test("with neither flag it is Apple Container's own root and the usual socket")
    func defaultsMatchTheMachine() throws {
        let location = try RuntimeLocation(appRootOption: nil, socketOption: nil, homeDirectory: "/Users/someone")

        #expect(location.appRoot == RuntimeLocation.defaultAppRoot())
        #expect(location.socketPath == "/Users/someone/.socktainer/container.sock")
        #expect(location.hasCustomSocket == false)
    }

    @Test("a given root is followed, and does not disturb the socket")
    func appRootIsFollowed() throws {
        let location = try RuntimeLocation(
            appRootOption: "/tmp/sweep-root", socketOption: nil, homeDirectory: "/Users/someone")

        #expect(location.appRoot.path == "/tmp/sweep-root")
        #expect(location.socketPath == "/Users/someone/.socktainer/container.sock")
        #expect(location.hasCustomSocket == false)
    }

    /// The marker the rest of the daemon reads to know it is not the machine's main instance: it
    /// keeps its hands off the shared Docker context and off startup's network sweep.
    @Test("a given socket marks the instance as a second one")
    func customSocketIsMarked() throws {
        let location = try RuntimeLocation(
            appRootOption: nil, socketOption: "/tmp/second/container.sock", homeDirectory: "/Users/someone")

        #expect(location.socketPath == "/tmp/second/container.sock")
        #expect(location.hasCustomSocket)
    }

    @Test("tildes are expanded, since a shell that did not is how they arrive")
    func tildesExpand() throws {
        let location = try RuntimeLocation(
            appRootOption: "~/throwaway", socketOption: "~/throwaway/container.sock", homeDirectory: "/Users/someone")

        #expect(location.appRoot.path.hasPrefix(NSHomeDirectory()))
        #expect(location.socketPath.hasPrefix(NSHomeDirectory()))
    }

    /// An empty value is what an unset shell variable expands to; it means "not given", not "serve
    /// on the empty path".
    @Test("empty values fall back rather than being taken literally")
    func emptyIsNotAPath() throws {
        let location = try RuntimeLocation(appRootOption: "  ", socketOption: "", homeDirectory: "/Users/someone")

        #expect(location.appRoot == RuntimeLocation.defaultAppRoot())
        #expect(location.socketPath == "/Users/someone/.socktainer/container.sock")
    }

    /// Without a socket to derive and none given there is nothing to serve on, and starting anyway
    /// would bind somewhere nobody is looking.
    @Test("no socket and no home is a refusal, not a guess")
    func noHomeAndNoSocketRefuses() {
        #expect(throws: UnixSocketError.self) {
            _ = try RuntimeLocation(appRootOption: nil, socketOption: nil, homeDirectory: nil)
        }
    }

    @Test("a given socket needs no home at all")
    func customSocketNeedsNoHome() throws {
        let location = try RuntimeLocation(
            appRootOption: "/tmp/root", socketOption: "/tmp/sock/container.sock", homeDirectory: nil)

        #expect(location.socketPath == "/tmp/sock/container.sock")
    }
}
