import Foundation

/// Gives the bytes of the `cs-session` launcher, a static Linux arm64 binary (spec §3.3).
protocol SharedRuntimeLauncherSource: Sendable {
    func launcherBytes() throws -> Data
}

/// Installs the launcher in a host directory that shared containers mount read-only at
/// `/run/containerstack`.
enum SharedRuntimeLauncher {
    static let fileName = "cs-session"

    enum Failure: Error, Equatable, CustomStringConvertible {
        case missing

        var description: String {
            switch self {
            case .missing: "this build of socktainer has no cs-session launcher"
            }
        }
    }

    static func directory(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("socktainer-shared-runtimes/launcher", isDirectory: true)
    }

    /// Writes the launcher into `directory` with mode 0555, unless the file there already has the
    /// same bytes. The file is replaced with a rename, so a container that runs the old file
    /// keeps it.
    @discardableResult
    static func install(from source: SharedRuntimeLauncherSource, into directory: URL) throws -> URL {
        let bytes = try source.launcherBytes()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(fileName)
        if let existing = try? Data(contentsOf: target), existing == bytes {
            return directory
        }
        let temporary = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        do {
            try bytes.write(to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temporary.path)
            guard rename(temporary.path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return directory
    }
}

/// The source for a build that does not carry the launcher: shared containers cannot start.
struct MissingLauncherSource: SharedRuntimeLauncherSource {
    func launcherBytes() throws -> Data { throw SharedRuntimeLauncher.Failure.missing }
}
