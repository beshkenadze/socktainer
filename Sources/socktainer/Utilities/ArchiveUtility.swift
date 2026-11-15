import CArchive
import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage

enum ArchiveUtilityError: Error {
    case invalidPath
    case archiveCreationFailed(String)
    case archiveReadFailed(String)
    case archiveWriteFailed(String)
    case entryReadFailed(String)
    case rejectedArchiveEntries([String])
}

struct ArchiveUtility {

    static func completeFinalTarBlock(at tarPath: URL) throws {
        let file = try FileHandle(forUpdating: tarPath)
        defer { try? file.close() }
        let fileSize = try file.seekToEnd()
        guard fileSize % 512 != 0 else { return }
        try file.seek(toOffset: 0)

        guard let reader = archive_read_new() else { return }
        defer { archive_read_free(reader) }
        guard archive_read_support_format_tar(reader) == ARCHIVE_OK,
            archive_read_support_filter_none(reader) == ARCHIVE_OK,
            archive_read_open_fd(reader, file.fileDescriptor, 4096) == ARCHIVE_OK
        else { return }

        var entry: OpaquePointer?
        while true {
            let result = archive_read_next_header(reader, &entry)
            guard result == ARCHIVE_OK || result == ARCHIVE_WARN else { return }
            let offset = archive_filter_bytes(reader, 0)
            let size = archive_entry_size(entry)
            guard offset >= 0, size >= 0, UInt64(offset) <= fileSize else { return }
            let available = fileSize - UInt64(offset)
            let padding = (512 - UInt64(size) % 512) % 512
            if archive_entry_filetype(entry) == UInt32(S_IFREG),
                archive_entry_sparse_count(entry) == 0,
                UInt64(size) <= available, available - UInt64(size) < padding
            {
                // An unclosed tar writer can omit final padding. Add it only after
                // libarchive confirms the full file body is present.
                try file.seekToEnd()
                try file.write(contentsOf: Data(count: Int(512 - fileSize % 512)))
                return
            }
        }
    }

    static func extract(tarPath: URL, to destination: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: tarPath.path) else {
            throw ArchiveUtilityError.invalidPath
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let archiveReader: ArchiveReader
        do {
            archiveReader = try ArchiveReader(file: tarPath)
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }

        do {
            let rejectedPaths = try archiveReader.extractContents(to: destination)
            if !rejectedPaths.isEmpty {
                throw ArchiveUtilityError.rejectedArchiveEntries(rejectedPaths)
            }
        } catch {
            if let error = error as? ArchiveUtilityError {
                throw error
            }
            throw ArchiveUtilityError.archiveReadFailed(error.localizedDescription)
        }
    }

    static func create(tarPath: URL, from source: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            throw ArchiveUtilityError.invalidPath
        }

        let writer: ArchiveWriter
        do {
            writer = try ArchiveWriter(
                format: .paxRestricted,
                filter: .none,
                file: tarPath
            )
        } catch {
            throw ArchiveUtilityError.archiveCreationFailed(error.localizedDescription)
        }

        do {
            try writer.archiveDirectory(source)
            try writer.finishEncoding()
        } catch {
            throw ArchiveUtilityError.archiveWriteFailed(error.localizedDescription)
        }
    }

    static func destinationPath(for entryPath: String?, under destinationPath: String) -> String? {
        guard var entryPath else {
            return nil
        }

        if entryPath.hasPrefix("./") {
            entryPath = String(entryPath.dropFirst(1))
        }
        if entryPath == "." || entryPath == "/" {
            return destinationPath
        }
        if !entryPath.hasPrefix("/") {
            entryPath = "/" + entryPath
        }

        if destinationPath == "/" {
            return entryPath
        }

        return destinationPath + entryPath
    }

    static func unpack(
        tarPath: URL,
        to formatter: EXT4.Formatter,
        destinationPath targetPath: String
    ) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        let bufferSize = 128 * 1024
        let reusableBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
        defer { reusableBuffer.deallocate() }

        for (entry, streamReader) in archiveReader.makeStreamingIterator() {
            guard let fullPath = destinationPath(for: entry.path, under: targetPath) else {
                continue
            }

            let filePath = FilePath(fullPath)
            let ts = FileTimestamps(
                access: entry.contentAccessDate,
                modification: entry.modificationDate,
                creation: entry.creationDate
            )

            switch entry.fileType {
            case .directory:
                try formatter.create(
                    path: filePath,
                    mode: EXT4.Inode.Mode(.S_IFDIR, entry.permissions),
                    ts: ts,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs
                )
            case .regular:
                try formatter.create(
                    path: filePath,
                    mode: EXT4.Inode.Mode(.S_IFREG, entry.permissions),
                    ts: ts,
                    buf: streamReader,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs,
                    fileBuffer: reusableBuffer
                )
            case .symbolicLink:
                let symlinkTarget = entry.symlinkTarget.map { FilePath($0) }
                try formatter.create(
                    path: filePath,
                    link: symlinkTarget,
                    mode: EXT4.Inode.Mode(.S_IFLNK, entry.permissions),
                    ts: ts,
                    uid: entry.owner,
                    gid: entry.group,
                    xattrs: entry.xattrs
                )
            default:
                continue
            }
        }
        try archiveReader.throwIfStreamFailed()
    }
}
