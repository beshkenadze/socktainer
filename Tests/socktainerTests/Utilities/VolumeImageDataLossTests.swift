import ContainerResource
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage
import Testing

@testable import socktainer

/// The two data-loss paths of a container create (D-1, D-2): the host writes a volume's backing
/// image only when that cannot destroy data or race a container that may hold the volume.
@Suite struct VolumeImageDataLossTests {
    private let logger = Logger(label: "test.volume-data-loss")

    private func image(with files: [String]) throws -> (dir: URL, path: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vol-data-loss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("volume.img")
        // As Apple's `volume create` formats it: with /lost+found.
        let formatter = try EXT4.Formatter(FilePath(path.path), blockSize: 4096, minDiskSize: 16 * 1024 * 1024)
        for file in files {
            let parent = (file as NSString).deletingLastPathComponent
            if parent != "/" { try formatter.create(path: FilePath(parent), mode: EXT4.Inode.Mode(.S_IFDIR, 0o700)) }
            try formatter.create(path: FilePath(file), mode: EXT4.Inode.Mode(.S_IFREG, 0o600), buf: InputStream(data: Data("data".utf8)))
        }
        try formatter.close()
        return (dir, path)
    }

    // MARK: D-1

    /// A Postgres volume whose data did not come from a copy-up keeps /lost+found next to its
    /// data. A Postgres create on it (through the production writer, on a real image) must leave
    /// the image byte for byte as it was.
    @Test func aPostgresCreateKeepsTheDataOfAVolumeThatHasData() async throws {
        let (dir, img) = try image(with: ["/pgdata/PG_VERSION"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try Data(contentsOf: img)
        let new = try makeContainerSnapshot(nativeId: "new", networks: [], labels: [:])
        let volume = VolumeImageWrites.Volume(name: "v", source: img.path, destination: "/var/lib/postgresql/data", labels: [:], noCopy: false)

        let result = try await VolumeImageWrites.create(
            volumes: [volume], mergedEnv: ["PGDATA=/var/lib/postgresql/data"],
            listContainers: { [] }, nativeCreate: { new },
            writer: VolumeImageWrites.Production(logger: logger), logger: logger)

        #expect(try Data(contentsOf: img) == before, "the volume's data was changed")
        #expect(result.warnings.isEmpty)
    }

    /// With nocopy the volume is not touched, also an empty Postgres volume with /lost+found; the
    /// create warns instead (through the production writer, on a real image).
    @Test func aNoCopyVolumeIsNeverWritten() async throws {
        let (dir, img) = try image(with: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try Data(contentsOf: img)
        let new = try makeContainerSnapshot(nativeId: "new", networks: [], labels: [:])
        let volume = VolumeImageWrites.Volume(name: "v", source: img.path, destination: "/var/lib/postgresql/data", labels: [:], noCopy: true)

        let result = try await VolumeImageWrites.create(
            volumes: [volume], mergedEnv: ["PGDATA=/var/lib/postgresql/data"],
            listContainers: { [] }, nativeCreate: { new },
            writer: VolumeImageWrites.Production(logger: logger), logger: logger)

        #expect(try Data(contentsOf: img) == before)
        #expect(result.warnings.count == 1 && result.warnings[0].contains("nocopy is set"))
    }

    /// A create that the runtime refuses leaves every volume byte for byte as it was, also a
    /// Postgres volume with /lost+found (166bbd5 wrote nothing before the native create either).
    @Test func aRefusedCreateChangesNoVolume() async throws {
        let (dir, img) = try image(with: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try Data(contentsOf: img)
        let volumes = [false, true].map {
            VolumeImageWrites.Volume(name: "v", source: img.path, destination: "/var/lib/postgresql/data", labels: [:], noCopy: $0)
        }
        for volume in volumes {
            await #expect(throws: CancellationError.self) {
                _ = try await VolumeImageWrites.create(
                    volumes: [volume], mergedEnv: ["PGDATA=/var/lib/postgresql/data"],
                    listContainers: { [] }, nativeCreate: { throw CancellationError() },
                    writer: VolumeImageWrites.Production(logger: logger), logger: logger)
            }
            #expect(try Data(contentsOf: img) == before)
        }
    }

    // MARK: D-2

    private func config(_ id: String, _ mounts: [Filesystem]) -> (id: String, mounts: [Filesystem]) { (id, mounts) }

    /// Copy-up replaces the image; it may do that only while no other container configuration
    /// names the volume, by name or by its image path, in any state. The runtime's status does
    /// not prove that a container has let go of its disks.
    @Test func copyUpSkipsAVolumeThatAnotherContainerNames() {
        let v = Filesystem.volume(name: "shared", format: "ext4", source: "/vols/shared/volume.img", destination: "/data", options: [])
        let other = Filesystem.volume(name: "other", format: "ext4", source: "/vols/other/volume.img", destination: "/x", options: [])
        let alias = Filesystem.block(format: "ext4", source: "/vols/shared/volume.img", destination: "/y", options: [])
        func mayWrite(_ named: VolumeImageWriters.Named) -> Bool {
            VolumeImageWriters.mayWrite(name: "shared", source: "/vols/shared/volume.img", named: named)
        }

        // Only the new container names it: copy-up goes ahead.
        #expect(mayWrite(VolumeImageWriters.named(by: [config("new", [v]), config("a", [other])], except: "new")))
        // Another container (stopped or running, it does not matter) names it by name.
        #expect(!mayWrite(VolumeImageWriters.named(by: [config("new", [v]), config("a", [v])], except: "new")))
        // Another container names the same image as a block device.
        #expect(!mayWrite(VolumeImageWriters.named(by: [config("new", [v]), config("b", [alias])], except: "new")))
    }
}
