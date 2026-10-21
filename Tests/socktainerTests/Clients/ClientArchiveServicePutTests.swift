import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import socktainer

/// A header the tar parser rejects ends iteration with a recorded stream failure, not with an error.
/// A write that does not check for it applies only the entries before the damage and reports
/// success. moby rejects such an archive.
@Suite("ClientArchiveService.putArchive — damaged archives")
struct ClientArchiveServicePutTests {

    @Test("a stopped container keeps its filesystem when the archive has a damaged header")
    func stoppedContainerRejectsDamagedArchive() async throws {
        let fixture = try PutFixture()
        defer { fixture.cleanUp() }
        let rootfs = try fixture.writeEmptyRootfs(containerId: "web")
        let snapshot = try makeContainerSnapshot(nativeId: "web", networks: [], labels: [:])
        let tarPath = try fixture.damagedTar()

        await #expect(throws: ArchiveError.self) {
            try await fixture.service.putArchive(container: snapshot, path: "/", tarPath: tarPath, noOverwriteDirNonDir: false)
        }
        let applied = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path)).exists(FilePath("/before.txt"))
        #expect(!applied, "the entry before the damaged header must not be applied")
    }

    /// Any other error means the write got as far as the guest.
    @Test("a running container rejects an archive with a damaged header before the guest is changed")
    func runningContainerRejectsDamagedArchive() async throws {
        let fixture = try PutFixture()
        defer { fixture.cleanUp() }
        let snapshot = try makeContainerSnapshot(nativeId: "web", networks: [], labels: [:], status: .running)
        let tarPath = try fixture.damagedTar()

        await #expect(throws: ArchiveError.self) {
            try await fixture.service.putArchive(container: snapshot, path: "/", tarPath: tarPath, noOverwriteDirNonDir: false)
        }
    }
}

private struct PutFixture {
    let root: URL
    let service: ClientArchiveService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-put-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = ClientArchiveService(appSupportPath: root)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeEmptyRootfs(containerId: String) throws -> URL {
        let dir = root.appendingPathComponent("containers/\(containerId)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rootfs = dir.appendingPathComponent("rootfs.ext4")
        try EXT4.Formatter(FilePath(rootfs.path)).close()
        return rootfs
    }

    /// One valid entry, then a block that is not a tar header.
    func damagedTar() throws -> URL {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("before the damaged header\n".utf8).write(to: source.appendingPathComponent("before.txt"))
        let tarPath = root.appendingPathComponent("damaged.tar")
        try ArchiveUtility.create(tarPath: tarPath, from: source)

        var tar = try Data(contentsOf: tarPath)
        let zeroBlock = Data(count: 512)
        while tar.count >= 512, tar.suffix(512) == zeroBlock {
            tar.removeLast(512)
        }
        tar += Data(repeating: 0x58, count: 512)
        try tar.write(to: tarPath)
        return tarPath
    }
}
