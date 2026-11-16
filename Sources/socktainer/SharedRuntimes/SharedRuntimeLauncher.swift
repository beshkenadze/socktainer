import CSSessionBinary
import CryptoKit
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
        case checksumMismatch(expected: String, actual: String)

        var description: String {
            switch self {
            case .checksumMismatch(let expected, let actual):
                "the cs-session launcher in this build is damaged: SHA-256 \(actual), expected \(expected)"
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

/// The launcher of the `cs-session` package, compiled into socktainer. Its bytes are checked
/// against the SHA-256 that the package publishes before they are installed.
struct PackagedLauncherSource: SharedRuntimeLauncherSource {
    var bytes: @Sendable () -> Data = { CSSessionBinary.data }
    var expectedSHA256: String = CSSessionBinary.sha256

    func launcherBytes() throws -> Data {
        let data = bytes()
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256.lowercased() else {
            throw SharedRuntimeLauncher.Failure.checksumMismatch(expected: expectedSHA256, actual: actual)
        }
        return data
    }
}
