import Foundation

/// A value that is set once. Any number of waits; a wait with a time limit gives up only itself.
final class SessionLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    var current: Value? { lock.withLock { value } }

    /// The first value wins.
    func resolve(_ newValue: Value) {
        let waiting: [CheckedContinuation<Value?, Never>] = lock.withLock {
            guard value == nil else { return [] }
            value = newValue
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        waiting.forEach { $0.resume(returning: newValue) }
    }

    /// The value, or nil when `limit` passes first. No limit waits until the value is set.
    func wait(limit: Duration? = nil) async -> Value? {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let ready: Value? = lock.withLock {
                if let value { return value }
                waiters[id] = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
                return
            }
            guard let limit else { return }
            Task.detached { [weak self] in
                try? await Task.sleep(for: limit)
                guard let self else { return }
                let expired = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                expired?.resume(returning: nil)
            }
        }
    }
}
