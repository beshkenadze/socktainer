import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage
import Testing

@testable import socktainer

/// The host replaces a volume's image (the /lost+found clean-up, the copy-up) only when the image
/// is shown to be empty and clean; anything else is left exactly as it is.
@Suite struct VolumeImageEligibilityTests {
    private let logger = Logger(label: "test.volume-eligibility")

    private final class Scratch {
        let dir: URL
        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("vol-eligibility-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
    }

    enum Shape: CaseIterable, CustomStringConvertible {
        case lostFoundHoldsAFile
        case lostFoundIsAFile
        case ext2WithFiles
        case needsRecovery
        case notClean
        case holdsData

        var description: String {
            switch self {
            case .lostFoundHoldsAFile: "/lost+found holds a recovered file"
            case .lostFoundIsAFile: "/lost+found is a regular file"
            case .ext2WithFiles: "an ext2 image that holds files"
            case .needsRecovery: "an image that needs journal recovery"
            case .notClean: "an image not marked clean (mounted)"
            case .holdsData: "an image with data next to /lost+found"
            }
        }
    }

    /// An image as Apple's `volume create` formats it (with /lost+found), plus `files`.
    private func formatted(_ path: String, files: [String] = [], removeLostFound: Bool = false) throws {
        let formatter = try EXT4.Formatter(FilePath(path), blockSize: 4096, minDiskSize: 16 * 1024 * 1024)
        if removeLostFound {
            try formatter.unlink(path: FilePath("/lost+found"))
        }
        for file in files {
            let parent = (file as NSString).deletingLastPathComponent
            if parent != "/", parent != "/lost+found" {
                try formatter.create(path: FilePath(parent), mode: EXT4.Inode.Mode(.S_IFDIR, 0o700))
            }
            try formatter.create(path: FilePath(file), mode: EXT4.Inode.Mode(.S_IFREG, 0o600), buf: InputStream(data: Data("data".utf8)))
        }
        try formatter.close()
    }

    private func patchSuperblock(_ path: String, offset: UInt64, bytes: [UInt8]) throws {
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: 1024 + offset)
        try handle.write(contentsOf: Data(bytes))
    }

    private func readIncompat(_ path: String) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: 1024 + 0x60)
        let data = try #require(try handle.read(upToCount: 4))
        return data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    private func make(_ shape: Shape, at path: String) throws {
        switch shape {
        case .lostFoundHoldsAFile:
            try formatted(path, files: ["/lost+found/#12"])
        case .lostFoundIsAFile:
            try formatted(path, files: ["/lost+found"], removeLostFound: true)
        case .ext2WithFiles:
            let url = try #require(Bundle.module.url(forResource: "ext2-with-files.img.deflate", withExtension: nil))
            let image = try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
            try image.write(to: URL(fileURLWithPath: path))
        case .needsRecovery:
            try formatted(path)
            let incompat = try readIncompat(path) | 0x4
            try patchSuperblock(path, offset: 0x60, bytes: (0..<4).map { UInt8((incompat >> (8 * $0)) & 0xFF) })
        case .notClean:
            try formatted(path)
            try patchSuperblock(path, offset: 0x3A, bytes: [0, 0])
        case .holdsData:
            try formatted(path, files: ["/pgdata/PG_VERSION"])
        }
    }

    private struct FileState: Equatable {
        let inode: UInt64
        let bytes: Data
    }

    private func state(_ path: String) throws -> FileState {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return FileState(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            bytes: try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// A container image whose root file system has `/data/seed`, and `/bad` with a regular file
    /// named `lost+found` (a copy-up from `/bad` fails: the new image already has that directory).
    private func rootfs(_ path: String) throws {
        let formatter = try EXT4.Formatter(FilePath(path), blockSize: 4096, minDiskSize: 16 * 1024 * 1024)
        try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/data/seed"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: InputStream(data: Data("seed".utf8)))
        try formatter.create(path: FilePath("/bad"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/bad/lost+found"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: InputStream(data: Data("x".utf8)))
        try formatter.close()
    }

    private func rootEntries(_ image: String) throws -> [String] {
        try EXT4.EXT4Reader(blockDevice: FilePath(image)).listDirectory(FilePath("/")).filter { $0 != "." && $0 != ".." }.sorted()
    }

    @Test("mounts of one volume in order: a first mount over an absent path does not stop the next from seeding it")
    func absentSourceThenSeed() throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        let source = scratch.path("rootfs.ext4")
        try formatted(image)
        try rootfs(source)

        let failures = VolumeCopyUp.populateInOrder(
            [(source: image, destination: "/nope"), (source: image, destination: "/data")], fromRootfs: source, logger: logger)

        #expect(failures.isEmpty)
        #expect(try rootEntries(image) == ["seed"])
    }

    @Test("mounts of one volume in order: after a failed copy-up the next mount still prepares the volume")
    func failedCopyUpThenNext() throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        let source = scratch.path("rootfs.ext4")
        try formatted(image)
        try rootfs(source)

        let failures = VolumeCopyUp.populateInOrder(
            [(source: image, destination: "/bad"), (source: image, destination: "/nope")], fromRootfs: source, logger: logger)

        #expect(failures.isEmpty)
        #expect(try rootEntries(image) == [])
        #expect(VolumeImageEligibility.check(imagePath: image) == .replaceable(hasLostFound: false))
    }

    @Test("mounts of one volume in order: a volume that an earlier mount filled is skipped, and a lone failure is reported")
    func filledVolumeIsSkipped() throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        let source = scratch.path("rootfs.ext4")
        try formatted(image)
        try rootfs(source)

        var failures = VolumeCopyUp.populateInOrder(
            [(source: image, destination: "/data"), (source: image, destination: "/bad")], fromRootfs: source, logger: logger)
        #expect(failures.isEmpty)
        #expect(try rootEntries(image) == ["seed"])

        let other = scratch.path("other.img")
        try formatted(other)
        failures = VolumeCopyUp.populateInOrder([(source: other, destination: "/bad")], fromRootfs: source, logger: logger)
        #expect(failures[other]?.hasPrefix("the copy-up failed") == true)
        #expect(try rootEntries(other) == ["lost+found"])
    }

    // MARK: The writers leave every image that is not shown to be empty and clean as it is.

    @Test("the copy-up leaves the image as it is", arguments: Shape.allCases)
    func copyUpRefuses(_ shape: Shape) throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        let source = scratch.path("rootfs.ext4")
        try make(shape, at: image)
        try rootfs(source)
        let before = try state(image)

        try? VolumeCopyUp.populate(volumeImagePath: image, fromRootfs: source, sourcePath: "/data", logger: logger)

        #expect(try state(image) == before, "\(shape): the image was written")
    }

    @Test("each image is classified", arguments: Shape.allCases)
    func verdicts(_ shape: Shape) throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        try make(shape, at: image)

        let verdict = VolumeImageEligibility.check(imagePath: image)
        switch shape {
        case .lostFoundHoldsAFile, .lostFoundIsAFile, .holdsData:
            #expect(verdict == .holdsData)
        case .ext2WithFiles, .needsRecovery, .notClean:
            guard case .doubtful = verdict else {
                Issue.record("\(shape): expected doubtful, got \(verdict)")
                return
            }
        }
    }

    // MARK: The writers still do their work on an empty, clean image.

    @Test("a new volume is replaceable, with its /lost+found")
    func newVolumeIsReplaceable() throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        try formatted(image)
        #expect(VolumeImageEligibility.check(imagePath: image) == .replaceable(hasLostFound: true))
    }

    @Test("the copy-up fills an empty volume from the image")
    func copyUpFillsAnEmptyImage() throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        let source = scratch.path("rootfs.ext4")
        try formatted(image)
        try rootfs(source)

        // A file of the user's whose name looks like a staging file: nothing removes by pattern.
        let lookalike = scratch.path("rebuild-not-ours.img")
        try FileManager.default.createDirectory(atPath: lookalike, withIntermediateDirectories: false)
        try Data("user data".utf8).write(to: URL(fileURLWithPath: lookalike).appendingPathComponent("keep"))
        let before = try state(image)

        try VolumeCopyUp.populate(volumeImagePath: image, fromRootfs: source, sourcePath: "/data", logger: logger)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image))
        #expect(try reader.listDirectory(FilePath("/")).filter { $0 != "." && $0 != ".." } == ["seed"])
        #expect(VolumeImageEligibility.check(imagePath: image) == .holdsData)
        #expect(try state(image).inode != before.inode, "the formatter ran over the existing file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.dir.path).sorted() == ["rebuild-not-ours.img", "rootfs.ext4", "volume.img"])
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: lookalike).appendingPathComponent("keep").path))
    }

    @Test("a copy-up from a path that the image does not have leaves an empty volume without /lost+found")
    func copyUpWithoutSourceEmptiesTheVolume() throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        let source = scratch.path("rootfs.ext4")
        try formatted(image)
        try rootfs(source)

        try VolumeCopyUp.populate(volumeImagePath: image, fromRootfs: source, sourcePath: "/missing", logger: logger)

        #expect(VolumeImageEligibility.check(imagePath: image) == .replaceable(hasLostFound: false))
    }

    // MARK: Empty volumes as they were made since ContainerStack 0.1.0

    /// The fixtures in Resources/ext4-volumes: empty volumes formatted by the image formatter of
    /// each runtime that ContainerStack shipped (runtime 1.2.2, 1.3.1, 1.6.0 and 1.7.1-bshk.1:
    /// containerization 0.40.1, 0.42.0, 0.52.1 and the fork at 5a37e406) without a journal and in
    /// each journal mode; volumes that the installed runtime 1.7.1-bshk.1 made with each option
    /// it accepts (`size`, `journal=ordered|writeback|journal`, `journal=ordered:8M`); and three
    /// mke2fs 1.47.2 images (the default ext4 features, which include 64bit, metadata_csum and
    /// orphan_file; the same without 64bit and metadata_csum; and inline_data). Each is stored up
    /// to its last non-zero byte, deflated, with its full size in the name.
    private static let volumeFixtures: [String] = {
        guard let url = Bundle.module.url(forResource: "ext4-volumes", withExtension: nil) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }()

    private func restore(_ fixture: String, into path: String) throws {
        let directory = try #require(Bundle.module.url(forResource: "ext4-volumes", withExtension: nil))
        let size = try #require(UInt64(fixture.split(separator: ".").dropLast().last ?? ""))
        let data = try (Data(contentsOf: directory.appendingPathComponent(fixture)) as NSData).decompressed(using: .zlib) as Data
        try data.write(to: URL(fileURLWithPath: path))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    @Test("an empty volume made by any shipped formatter, runtime option or default mke2fs is replaceable")
    func shippedEmptyVolumesAreReplaceable() throws {
        #expect(Self.volumeFixtures.count == 24)
        for fixture in Self.volumeFixtures {
            let scratch = try Scratch()
            let image = scratch.path("volume.img")
            try restore(fixture, into: image)
            let verdict = VolumeImageEligibility.check(imagePath: image)
            if fixture.hasPrefix("mke2fs-inline-data") {
                guard case .doubtful = verdict else {
                    Issue.record("\(fixture): expected doubtful, got \(verdict)")
                    continue
                }
            } else {
                #expect(verdict == .replaceable(hasLostFound: true), "\(fixture)")
            }
        }
    }

    @Test("the copy-up still rebuilds a default mke2fs volume")
    func copyUpRebuildsAnMke2fsVolume() throws {
        let fixture = try #require(Self.volumeFixtures.first { $0.hasPrefix("mke2fs-default") })
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        let source = scratch.path("rootfs.ext4")
        try restore(fixture, into: image)
        try rootfs(source)

        try VolumeCopyUp.populate(volumeImagePath: image, fromRootfs: source, sourcePath: "/data", logger: logger)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image))
        #expect(try reader.listDirectory(FilePath("/")).filter { $0 != "." && $0 != ".." } == ["seed"])
    }
}
