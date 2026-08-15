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
///
/// Identity comes from the container id, not from a private root: `ContainerRunHistory` holds one
/// root process-wide, so a suite that repoints it steals it from everything running beside it.
@Suite("ContainerRunHistory")
struct ContainerRunHistoryTests {
    @Test("a container the runtime booted is exited, not created, once its start time is gone")
    func bootedContainerSurvivesRestart() throws {
        let id = "ran-\(UUID().uuidString)"
        try RunHistoryFixture.markRan(id)

        let ran = try makeSnapshot(id: id, status: .stopped, startedDate: nil)
        #expect(MobyContainerStatus.state(for: ran) == "exited")
    }

    @Test("a container that never started is created")
    func neverStartedIsCreated() throws {
        RunHistoryFixture.configure()
        let fresh = try makeSnapshot(id: RunHistoryFixture.unmarkedId(), status: .stopped, startedDate: nil)
        #expect(MobyContainerStatus.state(for: fresh) == "created")
    }

    @Test("a running container is running whatever the disk says")
    func runningIsUnaffected() throws {
        let id = "up-\(UUID().uuidString)"
        try RunHistoryFixture.markRan(id)

        let live = try makeSnapshot(id: id, status: .running, startedDate: Date())
        #expect(MobyContainerStatus.state(for: live) == "running")
    }

    /// `docker ps -a --filter status=exited` is how Compose finds work that has finished. A restart
    /// must not empty it.
    @Test("filters place a restarted container with the exited, not the created")
    func filtersFollowTheBootRecord() throws {
        let ranId = "ran-\(UUID().uuidString)"
        try RunHistoryFixture.markRan(ranId)
        let freshId = RunHistoryFixture.unmarkedId()

        let containers = [
            try makeSnapshot(id: ranId, status: .stopped, startedDate: nil),
            try makeSnapshot(id: freshId, status: .stopped, startedDate: nil),
        ]

        let exited = ClientContainerService.applyFilters(containers, filters: ["status": ["exited"]])
        let created = ClientContainerService.applyFilters(containers, filters: ["status": ["created"]])
        #expect(exited.map(\.id) == [ranId])
        #expect(created.map(\.id) == [freshId])
    }

    /// The runtime can keep its state somewhere this build cannot read. Then the boot record is not
    /// evidence of anything, and the snapshot's own account is all there is.
    @Test("a container with no boot record on disk keeps the clock's answer")
    func noRecordFallsBackToTheClock() throws {
        RunHistoryFixture.configure()
        let id = RunHistoryFixture.unmarkedId()
        #expect(ContainerRunHistory.hasRun(id: id) == false)

        let ran = try makeSnapshot(id: id, status: .stopped, startedDate: Date(timeIntervalSinceNow: -60))
        // A start time still stands on its own: this one ran within this daemon's lifetime.
        #expect(MobyContainerStatus.state(for: ran) == "exited")
    }
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
