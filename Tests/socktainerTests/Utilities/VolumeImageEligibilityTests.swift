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

    /// A container image whose root file system has `/data/seed`.
    private func rootfs(_ path: String) throws {
        let formatter = try EXT4.Formatter(FilePath(path), blockSize: 4096, minDiskSize: 16 * 1024 * 1024)
        try formatter.create(path: FilePath("/data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/data/seed"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: InputStream(data: Data("seed".utf8)))
        try formatter.close()
    }

    // MARK: The writers leave every image that is not shown to be empty and clean as it is.

    @Test("the /lost+found clean-up leaves the image as it is", arguments: Shape.allCases)
    func cleanUpRefuses(_ shape: Shape) throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        try make(shape, at: image)
        let before = try state(image)

        VolumeImageCleaner.removeLostFound(imagePath: image, logger: logger)

        #expect(try state(image) == before, "\(shape): the image was written")
    }

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

    @Test("the clean-up builds a new image beside the old one and leaves an empty volume without /lost+found")
    func cleanUpReplacesAnEmptyImage() throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        try formatted(image)
        let before = try state(image)

        VolumeImageCleaner.removeLostFound(imagePath: image, logger: logger)

        #expect(try state(image).inode != before.inode, "the formatter ran over the existing file")
        #expect(VolumeImageEligibility.check(imagePath: image) == .replaceable(hasLostFound: false))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.dir.path) == ["volume.img"])
    }

    @Test("the copy-up fills an empty volume from the image")
    func copyUpFillsAnEmptyImage() throws {
        let scratch = try Scratch()
        let image = scratch.path("volume.img")
        let source = scratch.path("rootfs.ext4")
        try formatted(image)
        try rootfs(source)

        try VolumeCopyUp.populate(volumeImagePath: image, fromRootfs: source, sourcePath: "/data", logger: logger)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image))
        #expect(try reader.listDirectory(FilePath("/")).filter { $0 != "." && $0 != ".." } == ["seed"])
        #expect(VolumeImageEligibility.check(imagePath: image) == .holdsData)
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
}
