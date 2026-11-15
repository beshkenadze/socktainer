import Foundation

@testable import socktainer

/// A `SharedRuntimeClient` that records calls. `create` and `remove` can be held: a held call
/// suspends until the test releases it. Tests wait for a state with `waitUntil`, which
/// suspends and never blocks a thread.
actor FakeSharedRuntimeClient: SharedRuntimeClient {
    struct State: Sendable {
        var created: [SharedContainerSpec] = []
        var removed: [String] = []
        var createsInFlight = 0
        var removesInFlight = 0
        var removeAttempts = 0
        var signals: [(containerID: String, processID: String, signal: String)] = []
    }

    enum Failure: Error { case injected }

    private(set) var state = State()
    var records: [SharedRuntimeContainerRecord] = []
    var holdCreates = false
    var holdRemoves = false
    var failCreates = false
    var failList = false
    /// The number of next removals that fail.
    var failRemoves = 0
    /// When set, `listContainers` never returns.
    var listNeverReturns = false

    private var heldCreates: [CheckedContinuation<Void, Never>] = []
    private var heldRemoves: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func configure(_ change: @Sendable (isolated FakeSharedRuntimeClient) -> Void) { change(self) }

    func createSharedContainer(_ spec: SharedContainerSpec) async throws {
        state.created.append(spec)
        state.createsInFlight += 1
        changed()
        if holdCreates { await withCheckedContinuation { heldCreates.append($0) } }
        state.createsInFlight -= 1
        changed()
        if failCreates { throw Failure.injected }
    }

    func removeSharedContainer(nativeID: String) async throws {
        state.removesInFlight += 1
        changed()
        if holdRemoves { await withCheckedContinuation { heldRemoves.append($0) } }
        state.removesInFlight -= 1
        state.removeAttempts += 1
        if failRemoves > 0 {
            failRemoves -= 1
            changed()
            throw Failure.injected
        }
        state.removed.append(nativeID)
        records.removeAll { $0.nativeID == nativeID }
        changed()
    }

    func listContainers() async throws -> [SharedRuntimeContainerRecord] {
        if listNeverReturns {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        if failList { throw Failure.injected }
        return records
    }

    func signalProcess(containerID: String, processID: String, signal: String) async throws {
        state.signals.append((containerID, processID, signal))
        changed()
    }

    func releaseCreates() {
        holdCreates = false
        heldCreates.forEach { $0.resume() }
        heldCreates = []
    }

    func releaseRemoves() {
        holdRemoves = false
        heldRemoves.forEach { $0.resume() }
        heldRemoves = []
    }

    /// Suspends until `condition` holds for the recorded state.
    func waitUntil(_ condition: @Sendable (State) -> Bool) async {
        while !condition(state) {
            await withCheckedContinuation { observers.append($0) }
        }
    }

    private func changed() {
        let waiting = observers
        observers = []
        waiting.forEach { $0.resume() }
    }
}
