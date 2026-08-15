import Foundation
import Testing

@testable import socktainer

@Suite("ContainerExitCodeStore — waitForCode")
struct ContainerExitCodeStoreTests {

    @Test("waitForCode returns immediately when the code is already recorded")
    func returnsAlreadyRecorded() async throws {
        let store = ContainerExitCodeStore()
        let id = "ctr-pre-\(Int.random(in: 10000...99999))"
        await store.set(id: id, code: 7)
        let code = await store.waitForCode(id: id)
        #expect(code == 7)
    }

    @Test("waitForCode suspends until set() records the code, then returns it")
    func resumesOnSet() async throws {
        let store = ContainerExitCodeStore()
        let id = "ctr-wait-\(Int.random(in: 10000...99999))"

        // Start awaiting before the code exists — this must suspend, not return 0.
        let waiter = Task { await store.waitForCode(id: id) }

        // Give the waiter a moment to register, then record the real code.
        try await Task.sleep(nanoseconds: 100_000_000)
        await store.set(id: id, code: 42)

        let code = await waiter.value
        #expect(code == 42, "must deliver the recorded code, not a 0 fallback")
    }
}

private struct WaitError: Error {}

@Suite("ContainerExitCodeStore — resolveExitCode retry")
struct ResolveExitCodeTests {

    @Test("returns the code immediately when wait() succeeds first try")
    func succeedsFirstTry() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(retryDelayNs: 0) {
            calls += 1
            return 7
        }
        #expect(code == 7)
        #expect(calls == 1)
    }

    // A transient throw from the wait XPC round-trip must NOT be recorded as a fake exit
    // code of 0. Retrying yields the authoritative code (7).
    @Test("retries past transient throws and returns the real code")
    func retriesPastTransientThrows() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(retryDelayNs: 0) {
            calls += 1
            if calls < 3 { throw WaitError() }
            return 7
        }
        #expect(code == 7, "transient wait() failures must not collapse into exit code 0")
        #expect(calls == 3)
    }

    @Test("returns the failure sentinel (not 0) when every attempt throws")
    func sentinelOnPersistentFailure() async {
        var calls = 0
        let code = await ContainerExitCodeStore.resolveExitCode(maxAttempts: 4, retryDelayNs: 0) {
            calls += 1
            throw WaitError()
        }
        #expect(code == ContainerExitCodeStore.waitFailureSentinel)
        #expect(code != 0, "a failed wait must be distinguishable from a genuine exit-0")
        #expect(calls == 4)
    }
}

/// The runtime keeps no durable exit state, so the store's JSON file under Apple
/// Container's application-support root is the only thing that answers "what did
/// this container exit with?" after a bridge restart (issue #20). These pin the
/// file's lifecycle: what survives a reload, what a removed entry leaves behind,
/// and how a missing or corrupt file degrades.
@Suite("ContainerExitCodeStore — persistence")
struct ContainerExitCodeStorePersistenceTests {

    /// A storage directory configured the way `configure(_:)` does at boot, removed afterwards.
    private func makeStorage() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "exit-codes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a recorded code and finish time survive a reload from disk")
    func recordedExitSurvivesReload() async throws {
        let dir = try makeStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let previousLifetime = ContainerExitCodeStore()
        await previousLifetime.configure(storageDirectory: dir)
        await previousLifetime.set(id: "persist-me", code: 42)
        let recordedFinish = await previousLifetime.finishTime(id: "persist-me")

        // A fresh actor over the same directory is what a bridge restart reads.
        let restarted = ContainerExitCodeStore()
        await restarted.configure(storageDirectory: dir)
        #expect(await restarted.get(id: "persist-me") == 42)
        #expect(await restarted.finishTime(id: "persist-me") == recordedFinish)
    }

    @Test("an id with no record reads as nil, never 0")
    func unknownIdIsNil() async {
        let store = ContainerExitCodeStore()
        #expect(await store.get(id: "never-recorded") == nil)
        #expect(await store.finishTime(id: "never-recorded") == nil)
    }

    @Test("a removed record stays gone after a reload — a recreated container cannot inherit it")
    func removalSurvivesReload() async throws {
        let dir = try makeStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let previousLifetime = ContainerExitCodeStore()
        await previousLifetime.configure(storageDirectory: dir)
        await previousLifetime.set(id: "recreated", code: 7)
        await previousLifetime.remove(id: "recreated")  // what the delete route does

        let restarted = ContainerExitCodeStore()
        await restarted.configure(storageDirectory: dir)
        #expect(await restarted.get(id: "recreated") == nil)
    }

    @Test("a moved record answers under its new key only")
    func moveRekeys() async {
        let store = ContainerExitCodeStore()
        await store.set(id: "old-name", code: 5)
        await store.moveRecord(from: "old-name", to: "new-name")
        #expect(await store.get(id: "old-name") == nil)
        #expect(await store.get(id: "new-name") == 5)
    }

    @Test("a missing file degrades to an empty store without throwing")
    func missingFileDegrades() async throws {
        let dir = try makeStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ContainerExitCodeStore()
        await store.configure(storageDirectory: dir)
        #expect(await store.get(id: "anything") == nil)
    }

    @Test("a corrupt file degrades to an empty store and keeps accepting records")
    func corruptFileDegrades() async throws {
        let dir = try makeStorage()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json {".utf8)
            .write(to: dir.appendingPathComponent("socktainer-container-exit-codes.json"))

        let store = ContainerExitCodeStore()
        await store.configure(storageDirectory: dir)
        #expect(await store.get(id: "anything") == nil)

        // Recording must still work — the store cannot stay wedged on a bad file.
        await store.set(id: "after-corruption", code: 3)
        #expect(await store.get(id: "after-corruption") == 3)
    }
}
