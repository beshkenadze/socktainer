import ContainerAPIClient
import ContainerResource
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import socktainer

/// `docker cp <container>:/etc .` — archiving a directory, which is the shape of the operation people
/// actually run (issue #12). It answered 500 for any directory because the walk followed symlinks:
/// every image ships `/etc/mtab -> /proc/mounts`, whose target does not exist inside the filesystem,
/// so resolving it threw and took the whole archive with it. Copying a single file worked, which is
/// what made it look like an id-resolution problem.
@Suite("ClientArchiveService.getArchive — directories")
struct ClientArchiveServiceDirectoryTests {

    @Test("a directory containing a symlink out of the filesystem archives instead of failing")
    func directoryWithDanglingSymlink() async throws {
        let fixture = DirectoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(
            containerId: "web",
            files: ["/etc/hostname": "web\n", "/etc/hosts": "127.0.0.1 localhost\n"],
            symlinks: ["/etc/mtab": "/proc/mounts"]
        )

        let (tarData, stat) = try await fixture.service.getArchive(container: DirectoryFixture.stopped("web"), path: "/etc")

        #expect(stat.name == "etc")
        let extracted = try fixture.extract(tarData)
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("etc/hostname").path))
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("etc/hosts").path))

        // The symlink is archived as a symlink, target intact — dropping it would make `docker cp`
        // silently return fewer files than the container has.
        let mtab = extracted.appendingPathComponent("etc/mtab").path
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: mtab)
        #expect(target == "/proc/mounts")
    }

    @Test("a single file still archives, and a missing path is still not found")
    func fileAndMissingPathUnchanged() async throws {
        let fixture = DirectoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: ["/etc/hostname": "web\n"], symlinks: [:])

        let (tarData, stat) = try await fixture.service.getArchive(container: DirectoryFixture.stopped("web"), path: "/etc/hostname")
        #expect(stat.name == "hostname")
        let extracted = try fixture.extract(tarData)
        let contents = try String(contentsOf: extracted.appendingPathComponent("hostname"), encoding: .utf8)
        #expect(contents == "web\n")

        await #expect(throws: ClientArchiveError.self) {
            _ = try await fixture.service.getArchive(container: DirectoryFixture.stopped("web"), path: "/nonexistent")
        }
    }

    @Test("the symlink itself can be archived, and its stat reports the target")
    func symlinkPathReportsTarget() async throws {
        let fixture = DirectoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeRootfs(containerId: "web", files: [:], symlinks: ["/etc/mtab": "/proc/mounts"])

        // moby lstats the path (daemon/archive_unix.go), so a symlink is described by the link, not by
        // whatever it points at — which here does not exist at all.
        let (tarData, stat) = try await fixture.service.getArchive(container: DirectoryFixture.stopped("web"), path: "/etc/mtab")
        #expect(stat.name == "mtab")
        #expect(stat.linkTarget == "/proc/mounts")

        let extracted = try fixture.extract(tarData)
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: extracted.appendingPathComponent("mtab").path)
        #expect(target == "/proc/mounts")
    }

    @Test("a relative target survives the trip through the staging directory")
    func relativeSymlinkTarget() async throws {
        let fixture = DirectoryFixture()
        defer { fixture.cleanUp() }
        // `/etc/ssl/cert.pem -> certs/ca-certificates.crt` is the shape every image ships. A tar
        // writer that resolves entries against the staging root can drop a relative link that climbs
        // out of it, so the archive has to be checked for the link itself, not just for "some entry".
        try fixture.writeRootfs(
            containerId: "web",
            files: ["/etc/certs/ca.crt": "cert\n"],
            symlinks: ["/etc/cert.pem": "certs/ca.crt", "/etc/upward": "../usr/lib/os-release"]
        )

        let (tarData, _) = try await fixture.service.getArchive(container: DirectoryFixture.stopped("web"), path: "/etc")
        let extracted = try fixture.extract(tarData)

        let inside = try FileManager.default.destinationOfSymbolicLink(
            atPath: extracted.appendingPathComponent("etc/cert.pem").path)
        #expect(inside == "certs/ca.crt")
        let outside = try FileManager.default.destinationOfSymbolicLink(
            atPath: extracted.appendingPathComponent("etc/upward").path)
        #expect(outside == "../usr/lib/os-release", "a target climbing out of the copied tree is still the target")
    }

    @Test("a target too long to read fails the archive instead of omitting the entry")
    func unreadableSymlinkTargetFailsLoudly() async throws {
        let fixture = DirectoryFixture()
        defer { fixture.cleanUp() }
        // ext4 keeps targets under 60 bytes in the inode; longer ones live in data blocks the reader
        // does not expose. Skipping such an entry would hand back a tar quietly missing a file.
        let longTarget = "/" + String(repeating: "d", count: 40) + "/" + String(repeating: "n", count: 30)
        #expect(longTarget.count >= 60)
        try fixture.writeRootfs(containerId: "web", files: [:], symlinks: ["/etc/long": longTarget])

        await #expect(throws: ClientArchiveError.self) {
            _ = try await fixture.service.getArchive(container: DirectoryFixture.stopped("web"), path: "/etc")
        }
    }

    @Test("a file below a symlinked directory is reachable")
    func fileBelowSymlinkedDirectory() async throws {
        let fixture = DirectoryFixture()
        defer { fixture.cleanUp() }
        // lstat must not stop the walk *through* a symlink: `/var/run -> /run` is standard, and
        // `docker cp ctr:/var/run/app.sock .` has to keep working.
        try fixture.writeRootfs(
            containerId: "web",
            files: ["/run/app.sock": "socket\n"],
            symlinks: ["/var/run": "/run"]
        )

        let (tarData, stat) = try await fixture.service.getArchive(container: DirectoryFixture.stopped("web"), path: "/var/run/app.sock")
        #expect(stat.name == "app.sock")
        let extracted = try fixture.extract(tarData)
        let contents = try String(contentsOf: extracted.appendingPathComponent("app.sock"), encoding: .utf8)
        #expect(contents == "socket\n")
    }
}

private struct DirectoryFixture {
    let appSupport: URL
    let service: ClientArchiveService

    init() {
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("archive-dir-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        service = ClientArchiveService(appSupportPath: appSupport)
    }

    /// These tests own a rootfs.ext4 and no runtime, which is exactly a container that is not
    /// running — the state whose archive is read from the image on the host.
    static func stopped(_ id: String) -> ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        return ContainerSnapshot(
            configuration: ContainerConfiguration(id: id, image: image, process: proc),
            status: .stopped, networks: [], startedDate: nil)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
    }

    func writeRootfs(containerId: String, files: [String: String], symlinks: [String: String]) throws {
        let dir = appSupport.appendingPathComponent("containers/\(containerId)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = try EXT4.Formatter(FilePath(dir.appendingPathComponent("rootfs.ext4").path))
        for (path, contents) in files {
            let stream = InputStream(data: Data(contents.utf8))
            stream.open()
            try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream, recursion: true)
        }
        for (path, target) in symlinks {
            try formatter.create(
                path: FilePath(path),
                link: FilePath(target),
                mode: EXT4.Inode.Mode(.S_IFLNK, 0o777),
                recursion: true
            )
        }
        try formatter.close()
    }

    func extract(_ tarData: Data) throws -> URL {
        let tarPath = appSupport.appendingPathComponent("\(UUID().uuidString).tar")
        try tarData.write(to: tarPath)
        let destination = appSupport.appendingPathComponent("extracted-\(UUID().uuidString)")
        try ArchiveUtility.extract(tarPath: tarPath, to: destination)
        return destination
    }
}
