import ArgumentParser
import BuildInfo
import ContainerResource
import Foundation
import Vapor

// CLI options
struct CLIOptions: ParsableArguments {
    @ArgumentParser.Flag(name: .long, help: "Show version")
    var version: Bool = false

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Check Apple Container compatibility and exit")
    var checkCompatibility: Bool = true

    @ArgumentParser.Flag(name: .long, inversion: .prefixedNo, help: "Create or update the 'socktainer' Docker context on startup")
    var dockerContext: Bool = true

    @ArgumentParser.Option(
        name: .long,
        help:
            "Sync mode for named volumes: nosync (default, ~1.5x faster for write-heavy workloads), fsync (honors guest fsyncs for durability), full (fully synchronous writes). Override per-volume with: docker volume create -o sync=fsync <name>"
    )
    var volumeSync: String = "nosync"

    @ArgumentParser.Option(
        name: .long,
        help:
            "Apple Container's application data root, matching its own `container system start --app-root`. Defaults to ~/Library/Application Support/com.apple.container. There is no environment override: the default comes from NSHomeDirectory(), which ignores $HOME, so a runtime started on a throwaway root needs this flag for the bridge to follow it."
    )
    var appRoot: String?

    @ArgumentParser.Option(
        name: .long,
        help:
            "Path of the unix socket to serve. Defaults to ~/.socktainer/container.sock. A second bridge needs its own; it also leaves the shared `socktainer` Docker context alone, because that context names one socket and the machine's usual one is not a second instance's to repoint."
    )
    var socket: String?
}

// Parse CLI before starting the app
let options = CLIOptions.parseOrExit()

if options.version {
    print("socktainer: \(getBuildVersion()) (git commit: \(getBuildGitCommit()))")
    exit(0)
}

if options.checkCompatibility {
    await AppleContainerVersionCheck.performCompatibilityCheck()
}

// Ignore real CLI args for Vapor: always behave like `socktainer serve`
let executable = CommandLine.arguments.first ?? "socktainer"
let vaporArgs = [executable, "serve"]

// Detect environment and set up logging
var env = try Environment.detect(arguments: vaporArgs)
try LoggingSystem.bootstrap(from: &env)

// Create and configure the Vapor application
let app = try await Application.make(env)
let homeDirectory = ProcessInfo.processInfo.environment["HOME"]
let runtimeLocation = try RuntimeLocation(
    appRootOption: options.appRoot, socketOption: options.socket, homeDirectory: homeDirectory)
try prepareUnixSocket(for: app, at: runtimeLocation.socketPath)
// A second bridge answers on its own socket and leaves the shared context pointing at the machine's
// usual one: the context names a single socket, and repointing it would take the runtime out from
// under whoever is using it.
if options.dockerContext, !runtimeLocation.hasCustomSocket,
    let homeDir = homeDirectory,
    !homeDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
{
    DockerContextSetup.install(homeDirectory: homeDir)
}
app.storage[VolumeSyncModeKey.self] = Filesystem.SyncMode.resolve(from: options.volumeSync)
try await configure(app, location: runtimeLocation)

// Start the app
try await app.startup()
do {
    try openSocketToAllUsers(at: runtimeLocation.socketPath)
} catch {
    try? await app.asyncShutdown()
    throw error
}
try await app.running?.onStop.get()
