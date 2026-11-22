import ContainerizationEXT4
import Foundation
import SystemPackage

/// Whether the host may replace a volume's backing image: the `/lost+found` clean-up and the
/// copy-up both build a new image and put it in place of the old one, so the old one must hold
/// nothing that anybody could want. Fail closed: any read error, unknown feature or doubt is
/// "no".
///
/// An image qualifies only when all of these hold:
/// - it is a regular file of at least 4 MiB with an ext4 superblock;
/// - the superblock says the file system is clean (`s_state` is exactly "valid", no errors) and
///   does not ask for journal recovery. Linux clears "valid" on a mounted file system without a
///   journal and sets "recover" on a mounted one with a journal, so an image that a VM has
///   mounted does not qualify;
/// - every feature flag is one that the image formatter of this build writes (which also turns
///   away ext2 and ext3 images, whose directories this reader cannot list);
/// - the root holds nothing, or only `lost+found`, and that is a directory that holds nothing;
/// - the count of used inodes is that of an empty file system, so an entry that the directory
///   reader missed still turns the image away.
enum VolumeImageEligibility {
    enum Verdict: Equatable {
        /// Empty and clean: the image may be replaced. `hasLostFound` tells whether the root has
        /// the empty `/lost+found` directory.
        case replaceable(hasLostFound: Bool)
        /// The volume holds data: it is left as it is, as Docker leaves a volume with contents.
        case holdsData
        /// The image could not be shown to be empty and clean: it is left as it is, and a create
        /// that wanted to fill it says so.
        case doubtful(String)
    }

    private static let superblockOffset: UInt64 = 1024
    private static let superblockMagic: UInt16 = 0xEF53
    private static let stateValid: UInt16 = 0x1
    private static let incompatRecover: UInt32 = 0x4

    /// The features that `EXT4.Formatter` writes: incompat filetype, extents and flex_bg;
    /// ro_compat large_file, huge_file and extra_isize; compat sparse_super2, ext_attr and, with a
    /// journal, has_journal.
    private static let requiredIncompat: UInt32 = 0x2 | 0x40
    private static let allowedIncompat: UInt32 = 0x2 | 0x40 | 0x200
    private static let allowedRoCompat: UInt32 = 0x2 | 0x8 | 0x40
    private static let allowedCompat: UInt32 = 0x200 | 0x8 | 0x4

    static func check(imagePath: String) -> Verdict {
        var info = stat()
        guard lstat(imagePath, &info) == 0 else {
            return .doubtful("cannot read \(imagePath)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .doubtful("\(imagePath) is not a regular file")
        }
        guard info.st_size >= 4 * 1024 * 1024 else {
            return .doubtful("\(imagePath) is too small for an ext4 volume")
        }
        guard let superblock = readSuperblock(imagePath) else {
            return .doubtful("cannot read the superblock of \(imagePath)")
        }
        if let reason = formatReason(superblock) {
            return .doubtful(reason)
        }
        // A root with data decides on its own: nothing is written, whatever the state. A root
        // that looks empty counts only on a clean file system: a mounted one can hold data that
        // is not on the disk yet.
        let root = rootVerdict(imagePath: imagePath, superblock: superblock)
        guard case .replaceable = root else {
            return root
        }
        if let reason = stateReason(superblock) {
            return .doubtful(reason)
        }
        return root
    }

    private struct Superblock {
        let inodesCount: UInt32
        let freeInodesCount: UInt32
        let magic: UInt16
        let state: UInt16
        let revLevel: UInt32
        let firstIno: UInt32
        let compat: UInt32
        let incompat: UInt32
        let roCompat: UInt32
    }

    private static func readSuperblock(_ path: String) -> Superblock? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: superblockOffset)) != nil,
            let data = try? handle.read(upToCount: 1024), data.count == 1024
        else {
            return nil
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
        }
        return Superblock(
            inodesCount: u32(0x00),
            freeInodesCount: u32(0x10),
            magic: u16(0x38),
            state: u16(0x3A),
            revLevel: u32(0x4C),
            firstIno: u32(0x54),
            compat: u32(0x5C),
            incompat: u32(0x60),
            roCompat: u32(0x64)
        )
    }

    private static func formatReason(_ sb: Superblock) -> String? {
        guard sb.magic == superblockMagic else {
            return "not an ext4 image"
        }
        guard sb.revLevel >= 1, sb.firstIno >= 11, sb.inodesCount > sb.firstIno else {
            return "an ext2 revision 0 image, or an inode layout that this build does not know"
        }
        guard sb.incompat & requiredIncompat == requiredIncompat else {
            return "the file system does not use ext4 extents (ext2 or ext3)"
        }
        guard sb.incompat & ~(allowedIncompat | incompatRecover) == 0, sb.roCompat & ~allowedRoCompat == 0,
            sb.compat & ~allowedCompat == 0
        else {
            return "the file system uses a feature that this build does not read"
        }
        return nil
    }

    private static func stateReason(_ sb: Superblock) -> String? {
        guard sb.incompat & incompatRecover == 0 else {
            return "the file system needs journal recovery (it is mounted, or was not unmounted cleanly)"
        }
        guard sb.state == stateValid else {
            return "the file system is not marked clean (it is mounted, or was not unmounted cleanly)"
        }
        return nil
    }

    private static func rootVerdict(imagePath: String, superblock sb: Superblock) -> Verdict {
        do {
            let reader = try EXT4.EXT4Reader(blockDevice: FilePath(imagePath))
            let entries = try reader.listDirectory(FilePath("/")).filter { $0 != "." && $0 != ".." }
            guard entries.allSatisfy({ $0 == "lost+found" }) else {
                return .holdsData
            }
            let hasLostFound = !entries.isEmpty
            if hasLostFound {
                let (_, inode) = try reader.stat(FilePath("/lost+found"), followSymlinks: false)
                guard inode.isDirectory else {
                    return .holdsData
                }
                let inside = try reader.listDirectory(FilePath("/lost+found")).filter { $0 != "." && $0 != ".." }
                guard inside.isEmpty else {
                    return .holdsData
                }
            }
            // Inodes 1 to first_ino - 1 are reserved (the root is inode 2), and lost+found takes
            // the first free one. Any other used inode is an entry that the listing did not show.
            // The image formatter's unlink of /lost+found leaves that inode counted as used, so an
            // image that this bridge rebuilt without /lost+found also has first_ino used inodes.
            let used = UInt64(sb.inodesCount) - UInt64(min(sb.freeInodesCount, sb.inodesCount))
            let reserved = UInt64(sb.firstIno) - 1
            let expected: Set<UInt64> = hasLostFound ? [reserved + 1] : [reserved, reserved + 1]
            guard expected.contains(used) else {
                return .doubtful("the root looks empty, but \(used) inodes are in use where an empty volume has \(reserved + 1)")
            }
            return .replaceable(hasLostFound: hasLostFound)
        } catch {
            return .doubtful("cannot read the root directory: \(error)")
        }
    }
}
