import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

/// `PUT /containers/{id}/archive` into a container that has only been created answered 404 `Rootfs
/// not found`: the runtime materialises a container's filesystem when the guest first boots, so
/// there was nothing to write into. buildx does exactly this — create the builder, copy into it,
/// then start it — which is why the first `docker build` failed before BuildKit ran (#9).
///
/// The write is held until the start that was coming anyway. Booting at write time would have
/// answered the 404 and broken something else: the boot leaves the artifacts `ContainerRunHistory`
/// reads, so `docker create` + `docker cp` would have reported the container as having run.
@Suite("Archives held for a container that has not started", .serialized)
struct PendingArchiveStoreTests {

    @Test("a write into a created container is held, not refused")
    func writeIsHeld() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }

        try await fixture.service.putArchive(
            container: fixture.snapshot, path: "/etc/buildkit", tarPath: fixture.tar, noOverwriteDirNonDir: false)

        #expect(await PendingArchiveStore.shared.hasPending(id: fixture.id))
        let held = await PendingArchiveStore.shared.take(id: fixture.id)
        #expect(held.count == 1)
        #expect(held.first?.destination == "/etc/buildkit")
    }

    /// The caller's tar is a request-scoped temporary deleted as soon as the response is written, so
    /// the store has to own a copy rather than a path that will be gone at start.
    @Test("the held copy outlives the request's temporary file")
    func heldCopySurvives() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }

        try await fixture.service.putArchive(
            container: fixture.snapshot, path: "/etc", tarPath: fixture.tar, noOverwriteDirNonDir: false)
        try FileManager.default.removeItem(at: fixture.tar)

        let held = await PendingArchiveStore.shared.take(id: fixture.id)
        let path = try #require(held.first?.tarPath)
        #expect(FileManager.default.fileExists(atPath: path.path))
        try? FileManager.default.removeItem(at: path)
    }

    @Test("writes come back in the order they were made")
    func orderIsKept() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }

        for destination in ["/first", "/second", "/third"] {
            try await fixture.service.putArchive(
                container: fixture.snapshot, path: destination, tarPath: fixture.tar, noOverwriteDirNonDir: false)
        }

        let held = await PendingArchiveStore.shared.take(id: fixture.id)
        #expect(held.map(\.destination) == ["/first", "/second", "/third"])
        for entry in held { try? FileManager.default.removeItem(at: entry.tarPath) }
    }

    /// A container deleted before it ever starts takes the held bytes with it; nothing will replay
    /// them, and the copies would sit in the temporary directory forever.
    @Test("deleting the container drops what was held")
    func discardClearsTheHold() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }

        try await fixture.service.putArchive(
            container: fixture.snapshot, path: "/etc", tarPath: fixture.tar, noOverwriteDirNonDir: false)
        await PendingArchiveStore.shared.discard(id: fixture.id)

        #expect(await PendingArchiveStore.shared.hasPending(id: fixture.id) == false)
    }

    /// A container that has run has a filesystem, so a missing image file there is a real fault and
    /// still refuses — holding the write would silently swallow it.
    @Test("a container that has run still reports a missing rootfs")
    func ranContainerStillFails() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        try RunHistoryFixture.markRan(fixture.id)

        await #expect(throws: ClientArchiveError.self) {
            try await fixture.service.putArchive(
                container: fixture.snapshot, path: "/etc", tarPath: fixture.tar, noOverwriteDirNonDir: false)
        }
    }
}

/// An application-support directory with a container directory but no `rootfs.ext4` — the shape a
/// container has between `docker create` and its first start.
private struct StoreFixture {
    let id: String
    let appSupport: URL
    let service: ClientArchiveService
    let snapshot: ContainerSnapshot
    let tar: URL

    init() throws {
        id = "pending-\(UUID().uuidString)"
        appSupport = FileManager.default.temporaryDirectory.appending(path: "pending-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: appSupport.appending(path: "containers").appending(path: id), withIntermediateDirectories: true)
        service = ClientArchiveService(appSupportPath: appSupport)

        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "moby/buildkit:buildx-stable-1",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        snapshot = ContainerSnapshot(
            configuration: ContainerConfiguration(id: id, image: image, process: process),
            status: .stopped, networks: [], startedDate: nil)

        tar = FileManager.default.temporaryDirectory.appending(path: "pending-input-\(UUID().uuidString).tar")
        try Data("not a real tar, never unpacked on this path".utf8).write(to: tar)
        RunHistoryFixture.configure()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: appSupport)
        try? FileManager.default.removeItem(at: tar)
    }
}
