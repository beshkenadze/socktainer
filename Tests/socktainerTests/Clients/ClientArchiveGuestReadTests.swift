import ContainerizationArchive
import Foundation
import Testing

@testable import socktainer

/// `GET /containers/{id}/archive` used to read `rootfs.ext4` on the host even while the container was
/// running, so it answered with the image and 404'd everything the container had written — while
/// `docker exec cat` printed the same file (issue #10). A running guest now packs the path itself, and
/// these cover the two halves of that: how `tar` is invoked, and how the stat header is recovered from
/// what came back.
@Suite("ClientArchiveService — reading through the guest")
struct ClientArchiveGuestReadTests {

    /// `tar -cf - -C <parent> <name>`: the archive's top entry has to be the requested path, not the
    /// absolute path with every parent directory along the way, which is the shape docker returns.
    @Test("a path splits into the directory to enter and the name to pack")
    func splitting() {
        #expect(ClientArchiveService.splitForTar("/etc/hostname") == ("/etc", "hostname"))
        #expect(ClientArchiveService.splitForTar("/data") == ("/", "data"))
        #expect(ClientArchiveService.splitForTar("/a/b/c") == ("/a/b", "c"))
    }

    /// A trailing slash is how clients spell "the directory itself"; it must not become an empty name,
    /// which `tar` would reject.
    @Test("a trailing slash names the directory, and the root names itself")
    func splittingEdges() {
        #expect(ClientArchiveService.splitForTar("/data/") == ("/", "data"))
        #expect(ClientArchiveService.splitForTar("/a/b/") == ("/a", "b"))
        #expect(ClientArchiveService.splitForTar("/") == ("/", "."))
    }

    @Test("the stat header carries the mode the container has, not the mode the host would give")
    func statKeepsMode() throws {
        let tar = try makeTar { writer in
            try writer.writeEntry(entry: entry("exe.sh", type: .regular, mode: 0o755), data: Data())
        }

        let stat = try ClientArchiveService.pathStat(fromTar: tar, path: "/data/exe.sh")
        #expect(stat.name == "exe.sh")
        #expect(stat.mode & 0o777 == 0o755)
        #expect(stat.mode & UInt32(S_IFMT) == UInt32(S_IFREG))
        #expect(stat.linkTarget == nil)
    }

    /// `docker cp` decides whether it is copying a file or a tree from this bit, so a directory read
    /// as a plain file lands the copy in the wrong place.
    @Test("a directory is marked as one")
    func statMarksDirectory() throws {
        let tar = try makeTar { writer in
            try writer.writeEntry(entry: entry("sub", type: .directory, mode: 0o755), data: Data())
        }

        let stat = try ClientArchiveService.pathStat(fromTar: tar, path: "/data/sub")
        #expect(stat.mode & UInt32(S_IFMT) == UInt32(S_IFDIR))
    }

    @Test("a symlink reports where it points")
    func statCarriesLinkTarget() throws {
        let tar = try makeTar { writer in
            try writer.writeEntry(
                entry: entry("mtab", type: .symbolicLink, mode: 0o777, symlink: "/proc/mounts"), data: Data())
        }

        let stat = try ClientArchiveService.pathStat(fromTar: tar, path: "/etc/mtab")
        #expect(stat.mode & UInt32(S_IFMT) == UInt32(S_IFLNK))
        #expect(stat.linkTarget == "/proc/mounts")
    }

    @Test("an empty archive is a path that is not there")
    func emptyArchiveIsNotFound() throws {
        #expect(throws: ClientArchiveError.self) {
            _ = try ClientArchiveService.pathStat(fromTar: Data(), path: "/nope")
        }
    }
}

/// Stands in for what the guest's `tar` writes: the requested path is the archive's first entry,
/// carrying its own type and mode — which is exactly what `tar -cf - -C <parent> <name>` produces and
/// what `ArchiveUtility.create` does not, since that archives the directory it is handed.
private func makeTar(_ build: (ArchiveWriter) throws -> Void) throws -> Data {
    let tarPath = FileManager.default.temporaryDirectory.appending(path: "guest-read-\(UUID().uuidString).tar")
    defer { try? FileManager.default.removeItem(at: tarPath) }
    let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: tarPath)
    try build(writer)
    try writer.finishEncoding()
    return try Data(contentsOf: tarPath)
}

private func entry(_ path: String, type: URLFileResourceType, mode: mode_t, symlink: String? = nil) -> WriteEntry {
    let entry = WriteEntry()
    entry.path = path
    entry.fileType = type
    entry.permissions = mode
    entry.size = 0
    entry.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    if let symlink { entry.symlinkTarget = symlink }
    return entry
}
