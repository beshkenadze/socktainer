import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

/// A daemon restart rebuilds every snapshot without its start time, and a start that boots the
/// guest and then fails never records one. Both leave `startedDate == nil` on a container that
/// certainly ran, which the clock alone cannot tell from one that never started (issue #16's rule,
/// inverted). The runtime's boot artifacts on disk are the durable answer.
@Suite("ContainerRunHistory", .serialized)
struct ContainerRunHistoryTests {
    @Test("a container the runtime booted is exited, not created, once its start time is gone")
    func bootedContainerSurvivesRestart() throws {
        let root = try makeRoot(bootedIds: ["ran"])
        defer { try? FileManager.default.removeItem(at: root) }
        ContainerRunHistory.configure(storageDirectory: root)

        let ran = try makeSnapshot(id: "ran", status: .stopped, startedDate: nil)
        #expect(MobyContainerStatus.state(for: ran) == "exited")
    }

    @Test("a container that never started is created")
    func neverStartedIsCreated() throws {
        let root = try makeRoot(bootedIds: [])
        defer { try? FileManager.default.removeItem(at: root) }
        ContainerRunHistory.configure(storageDirectory: root)

        let fresh = try makeSnapshot(id: "fresh", status: .stopped, startedDate: nil)
        #expect(MobyContainerStatus.state(for: fresh) == "created")
    }

    @Test("a running container is running whatever the disk says")
    func runningIsUnaffected() throws {
        let root = try makeRoot(bootedIds: ["up"])
        defer { try? FileManager.default.removeItem(at: root) }
        ContainerRunHistory.configure(storageDirectory: root)

        let live = try makeSnapshot(id: "up", status: .running, startedDate: Date())
        #expect(MobyContainerStatus.state(for: live) == "running")
    }

    /// `docker ps -a --filter status=exited` is how Compose finds work that has finished. A restart
    /// must not empty it.
    @Test("filters place a restarted container with the exited, not the created")
    func filtersFollowTheBootRecord() throws {
        let root = try makeRoot(bootedIds: ["ran"])
        defer { try? FileManager.default.removeItem(at: root) }
        ContainerRunHistory.configure(storageDirectory: root)

        let containers = [
            try makeSnapshot(id: "ran", status: .stopped, startedDate: nil),
            try makeSnapshot(id: "fresh", status: .stopped, startedDate: nil),
        ]

        let exited = ClientContainerService.applyFilters(containers, filters: ["status": ["exited"]])
        let created = ClientContainerService.applyFilters(containers, filters: ["status": ["created"]])
        #expect(exited.map(\.id) == ["ran"])
        #expect(created.map(\.id) == ["fresh"])
    }

    @Test("an unconfigured store leaves the snapshot's own account standing")
    func unconfiguredFallsBackToTheClock() throws {
        let root = try makeRoot(bootedIds: ["ran"])
        defer { try? FileManager.default.removeItem(at: root) }
        // Point at a directory holding no containers at all: the same shape as never having been
        // configured, and the answer must be the clock's.
        ContainerRunHistory.configure(storageDirectory: root.appending(path: "elsewhere"))

        let ran = try makeSnapshot(id: "ran", status: .stopped, startedDate: nil)
        #expect(MobyContainerStatus.state(for: ran) == "created")
    }
}

/// Mirrors the runtime's layout: a container that has booted owns a `vminitd.log` under its own
/// directory, one that has only been created owns nothing.
private func makeRoot(bootedIds: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "run-history-\(UUID().uuidString)")
    for id in bootedIds {
        let dir = root.appending(path: "containers").appending(path: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "vminitd.log"))
    }
    try FileManager.default.createDirectory(
        at: root.appending(path: "containers"), withIntermediateDirectories: true)
    return root
}

private func makeSnapshot(id: String, status: RuntimeStatus, startedDate: Date?) throws -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
    let img = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:abc", size: 0))
    let config = ContainerConfiguration(id: id, image: img, process: proc)
    return ContainerSnapshot(configuration: config, status: status, networks: [], startedDate: startedDate)
}
