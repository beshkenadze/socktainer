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
/// - every "incompatible" feature flag is one that the image reader of this build reads correctly
///   (compat and ro_compat flags do not change how a file system is read), and the root and
///   `/lost+found` use extents: the reader lists any other directory layout as empty;
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

    /// "Incompatible" features that the pinned `EXT4Reader` reads correctly, from its source:
    /// - extents (0x40): required; directories are read only through extent trees;
    /// - filetype (0x2), flex_bg (0x200), csum_seed (0x2000), largedir (0x4000) and casefold
    ///   (0x20000) do not change where the reader finds inodes or how it walks directory blocks
    ///   (it skips entries with inode 0, which covers checksum tails and htree nodes);
    /// - 64bit (0x80): the reader uses the 64-bit descriptor size and the low halves of block
    ///   numbers, so it is read correctly while the block count fits in 32 bits.
    /// Refused: compression, journal_dev, meta_bg (descriptors elsewhere), mmp, ea_inode (xattr
    /// inodes), dirdata, inline_data and encrypt, and any unknown flag. Compat and ro_compat flags
    /// do not change how a file system is read, by their definition, and are all accepted.
    private static let requiredIncompat: UInt32 = 0x40
    private static let allowedIncompat: UInt32 = 0x2 | 0x40 | 0x80 | 0x200 | 0x2000 | 0x4000 | 0x2_0000
    private static let incompat64bit: UInt32 = 0x80
    private static let compatOrphanFile: UInt32 = 0x1000
    private static let extentsFlag: UInt32 = 0x8_0000

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
        let blocksCountHigh: UInt32
        let orphanFileInode: UInt32
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
            roCompat: u32(0x64),
            blocksCountHigh: u32(0x150),
            orphanFileInode: u32(0x280)
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
        guard sb.incompat & ~(allowedIncompat | incompatRecover) == 0 else {
            return "the file system uses a feature that this build does not read (incompat 0x\(String(sb.incompat, radix: 16)))"
        }
        guard sb.incompat & incompat64bit == 0 || sb.blocksCountHigh == 0 else {
            return "the file system has more blocks than this build reads"
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
            let (_, root) = try reader.stat(FilePath("/"), followSymlinks: false)
            guard root.flags & extentsFlag != 0 else {
                return .doubtful("the root directory does not use extents, so its entries cannot be read")
            }
            let hasLostFound = !entries.isEmpty
            if hasLostFound {
                let (_, inode) = try reader.stat(FilePath("/lost+found"), followSymlinks: false)
                guard inode.isDirectory else {
                    return .holdsData
                }
                guard inode.flags & extentsFlag != 0 else {
                    return .doubtful("/lost+found does not use extents, so its entries cannot be read")
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
            // An orphan file (mke2fs makes one by default since 1.47) takes an ordinary inode.
            let orphanFile: UInt64 = sb.compat & compatOrphanFile != 0 && sb.orphanFileInode >= sb.firstIno ? 1 : 0
            let reserved = UInt64(sb.firstIno) - 1 + orphanFile
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
