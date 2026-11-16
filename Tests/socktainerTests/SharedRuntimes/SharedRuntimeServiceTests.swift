import Foundation
import Testing

@testable import socktainer

@Suite(.timeLimit(.minutes(1))) struct SharedRuntimeServiceTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shared-service-\(UUID().uuidString)")
    private var filePath: String { directory.appendingPathComponent("runtime-groups.json").path }

    private func cleanup() { try? FileManager.default.removeItem(at: directory) }

    private func service(
        _ client: FakeSharedRuntimeClient, timeout: Duration = .seconds(30), timer: ManualSleeper = ManualSleeper()
    ) -> SharedRuntimeService {
        SharedRuntimeService(
            manager: SharedRuntimeManagerTests.manager(client),
            file: RuntimeGroupsFile(path: filePath),
            imageFacts: FakeImageFacts(),
            cleanupTimeout: timeout,
            timerSleep: { try await timer.sleep($0) })
    }

    @Test func onWhenTheCleanupFinishedAndTheFileIsMissing() async {
        defer { cleanup() }
        let service = service(FakeSharedRuntimeClient())
        await service.startCleanup()
        #expect(await service.admission() == .on(.defaults))
        let entries = await service.infoEntries()
        #expect(entries.label == "containerstack.shared-runtimes=on")
        #expect(entries.warning == nil)
    }

    @Test func aMalformedFileTurnsGroupingOffWithItsCause() async throws {
        defer { cleanup() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"groups":[],"rules":[]}"#.utf8).write(to: URL(fileURLWithPath: filePath))
        let service = service(FakeSharedRuntimeClient())
        await service.startCleanup()
        #expect(await service.admission() == .off(cause: "runtime-groups.json: unsupported version 2"))
        let entries = await service.infoEntries()
        #expect(entries.label == "containerstack.shared-runtimes=off")
        #expect(entries.warning == "shared runtimes are off: runtime-groups.json: unsupported version 2")
    }

    @Test func aFailedCleanupKeepsGroupingOff() async {
        defer { cleanup() }
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.failList = true }
        let service = service(client)
        await service.startCleanup()
        guard case .off(let cause) = await service.admission() else {
            Issue.record("expected grouping off")
            return
        }
        #expect(cause.hasPrefix("shared containers of a previous run could not be removed"))
    }

    @Test func aCleanupThatNeverReturnsTurnsGroupingOffAtItsTimeLimit() async {
        defer { cleanup() }
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.listNeverReturns = true }
        let timer = ManualSleeper()
        let service = service(client, timeout: .seconds(30), timer: timer)
        await service.startCleanup()
        await client.waitUntil { $0.listCalls == 1 }
        await timer.waitUntil { $0.pending == [.seconds(30)] }
        timer.fireAll()
        #expect(await service.admission() == .off(cause: "the removal of shared containers of a previous run did not finish within 30.0 seconds"))
    }

    @Test func aCleanupThatEndsJustAfterItsTimeLimitDoesNotTurnGroupingOn() async {
        defer { cleanup() }
        // The time limit wins the race, and the cleanup completes before the service hears of it.
        let service = SharedRuntimeService(
            manager: SharedRuntimeManagerTests.manager(FakeSharedRuntimeClient()),
            file: RuntimeGroupsFile(path: filePath),
            imageFacts: FakeImageFacts(),
            bounded: { _, work in
                await work()
                return false
            })
        await service.startCleanup()
        #expect(await service.admission() == .off(cause: "the removal of shared containers of a previous run did not finish within 30.0 seconds"))
    }

    @Test func noAdmissionBeforeTheCleanupFinishes() async throws {
        defer { cleanup() }
        let client = FakeSharedRuntimeClient()
        await client.configure {
            $0.records = [SharedRuntimeContainerRecord(nativeID: "old", labels: [SharedRuntimeLabels.sharedSocket: SharedRuntimeManagerTests.socket])]
            $0.holdRemoves = true
        }
        let service = service(client)
        await service.startCleanup()
        await client.waitUntil { $0.removesInFlight == 1 }
        #expect(await service.status() == .off(cause: "the removal of shared containers of a previous run has not finished"))

        let admission = Task { await service.admission() }
        await client.releaseRemoves()
        #expect(await admission.value == .on(.defaults))
        #expect(await client.state.removed == ["old"])
    }
}
