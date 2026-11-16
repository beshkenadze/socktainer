import CSSessionBinary
import Foundation
import Testing

@testable import socktainer

@Suite struct SharedRuntimeLauncherTests {
    struct FakeSource: SharedRuntimeLauncherSource {
        let bytes: Data
        func launcherBytes() throws -> Data { bytes }
    }

    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString)")
    private var directory: URL { SharedRuntimeLauncher.directory(appSupport: root) }
    private var file: URL { directory.appendingPathComponent("cs-session") }

    private func cleanup() { try? FileManager.default.removeItem(at: root) }

    private func inode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }

    @Test func installWritesTheBytesReadOnlyAndExecutable() throws {
        defer { cleanup() }
        let installed = try SharedRuntimeLauncher.install(from: FakeSource(bytes: Data("one".utf8)), into: directory)
        #expect(installed == directory)
        #expect(try Data(contentsOf: file) == Data("one".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o555)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["cs-session"])
    }

    @Test func theSameBytesAreNotWrittenAgain() throws {
        defer { cleanup() }
        try SharedRuntimeLauncher.install(from: FakeSource(bytes: Data("one".utf8)), into: directory)
        let before = try inode(file)
        try SharedRuntimeLauncher.install(from: FakeSource(bytes: Data("one".utf8)), into: directory)
        #expect(try inode(file) == before)
    }

    @Test func otherBytesReplaceTheFile() throws {
        defer { cleanup() }
        try SharedRuntimeLauncher.install(from: FakeSource(bytes: Data("one".utf8)), into: directory)
        try SharedRuntimeLauncher.install(from: FakeSource(bytes: Data("two".utf8)), into: directory)
        #expect(try Data(contentsOf: file) == Data("two".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["cs-session"])
    }

    @Test func theBuildCarriesTheReleasedLauncher() throws {
        let bytes = try PackagedLauncherSource().launcherBytes()
        #expect(bytes.count == 462_872)
        #expect(Array(bytes.prefix(4)) == [0x7F, 0x45, 0x4C, 0x46])
        #expect(CSSessionBinary.sha256 == "7990b4d98b6b37d9d57c3450eafe0e6ee508e6f3e514e2cf1ad5907774bb16a5")
    }

    @Test func damagedBytesAreNotInstalled() {
        defer { cleanup() }
        let source = PackagedLauncherSource(bytes: { Data("not the launcher".utf8) })
        #expect(throws: SharedRuntimeLauncher.Failure.self) { try SharedRuntimeLauncher.install(from: source, into: directory) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
