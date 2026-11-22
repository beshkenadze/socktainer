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
    /// data. Removing /lost+found must never write a new filesystem over that data.
    @Test func removeLostFoundKeepsTheDataOfAVolumeThatHasData() throws {
        let (dir, img) = try image(with: ["/pgdata/PG_VERSION"])
        defer { try? FileManager.default.removeItem(at: dir) }
        VolumeImageCleaner.removeLostFound(imagePath: img.path, logger: logger)
        let after = try EXT4Editor(devicePath: FilePath(img.path))
        #expect(after.exists(path: "/pgdata/PG_VERSION"), "the volume's data was erased")
    }

    /// The create cleans /lost+found only from an empty volume that no other container names.
    @Test func theCreateCleansOnlyAnEmptyVolumeThatNoOtherContainerNames() throws {
        let (dir, img) = try image(with: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        let (dataDir, data) = try image(with: ["/pgdata/PG_VERSION"])
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let postgres = ["PGDATA=/var/lib/postgresql/data"]
        let none = VolumeImageWriters.Named(names: [], sources: [])
        #expect(VolumeImageCleaner.shouldClean(mergedEnv: postgres, name: "v", format: "ext4", source: img.path, labels: [:], named: none))
        #expect(!VolumeImageCleaner.shouldClean(mergedEnv: postgres, name: "v", format: "ext4", source: data.path, labels: [:], named: none))
        let used = VolumeImageWriters.Named(names: ["v"], sources: [])
        #expect(!VolumeImageCleaner.shouldClean(mergedEnv: postgres, name: "v", format: "ext4", source: img.path, labels: [:], named: used))
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
        let candidates = [(source: "/vols/shared/volume.img", destination: "/data", name: "shared")]

        // Only the new container names it: copy-up goes ahead.
        var named = VolumeImageWriters.named(by: [config("new", [v]), config("a", [other])], except: "new")
        #expect(VolumeCopyUp.targets(candidates, named: named).map(\.name) == ["shared"])
        // Another container (stopped or running, it does not matter) names it by name.
        named = VolumeImageWriters.named(by: [config("new", [v]), config("a", [v])], except: "new")
        #expect(VolumeCopyUp.targets(candidates, named: named).isEmpty)
        // Another container names the same image as a block device.
        named = VolumeImageWriters.named(by: [config("new", [v]), config("b", [alias])], except: "new")
        #expect(VolumeCopyUp.targets(candidates, named: named).isEmpty)
    }
}
