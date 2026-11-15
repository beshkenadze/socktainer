import Foundation

/// A fake clock for `sleep(for:)`: each sleep suspends until `fireAll()` or until its task is
/// cancelled. Tests wait for a state with `waitUntil`, which suspends and never blocks a thread.
final class ManualSleeper: @unchecked Sendable {
    struct State: Sendable {
        var pending: [Duration] = []
        var cancelled = 0
        var fired = 0
    }

    private let lock = NSLock()
    private var state = State()
    private var sleepers: [UUID: (duration: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelledBeforeStart: Set<UUID> = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    var snapshot: State { lock.withLock { state } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow: Bool = lock.withLock {
                    if cancelledBeforeStart.remove(id) != nil { return true }
                    sleepers[id] = (duration, continuation)
                    state.pending.append(duration)
                    return false
                }
                if resumeNow {
                    continuation.resume(throwing: CancellationError())
                } else {
                    notify()
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                state.cancelled += 1
                guard let sleeper = sleepers.removeValue(forKey: id) else {
                    cancelledBeforeStart.insert(id)
                    return nil
                }
                if let index = state.pending.firstIndex(of: sleeper.duration) { state.pending.remove(at: index) }
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
            notify()
        }
    }

    func fireAll() {
        let continuations: [CheckedContinuation<Void, Error>] = lock.withLock {
            let all = sleepers.values.map(\.continuation)
            state.fired += all.count
            sleepers = [:]
            state.pending = []
            return all
        }
        continuations.forEach { $0.resume() }
        notify()
    }

    func waitUntil(_ condition: @Sendable (State) -> Bool) async {
        while !lock.withLock({ condition(state) }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let met: Bool = lock.withLock {
                    if condition(state) { return true }
                    observers.append(continuation)
                    return false
                }
                if met { continuation.resume() }
            }
        }
    }

    private func notify() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            let all = observers
            observers = []
            return all
        }
        waiting.forEach { $0.resume() }
    }
}
