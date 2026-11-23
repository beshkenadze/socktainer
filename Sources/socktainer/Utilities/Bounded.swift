import Foundation
import Synchronization

/// An answer within a bound, whatever the operation does.
///
/// A timer in a task group does not bound a call whose reply never comes: the group waits for
/// every child, and an XPC reply continuation ignores cancellation. Here the caller is answered by
/// whichever comes first, the operation or the timer; it never waits for the operation. A late
/// answer is dropped. The operation is cancelled at the bound, and keeps running if it ignores
/// that. The timer fires from a dispatch queue, so blocked cooperative threads do not delay it.
enum Bounded {
    struct TimedOut: Error, CustomStringConvertible {
        let bound: Duration
        var description: String { "no answer within \(bound)" }
    }

    /// `onTimeout` runs on the timer's thread when the bound answers the caller (for tests: the
    /// caller itself resumes when a cooperative thread is free).
    static func value<T: Sendable>(
        within bound: Duration,
        onTimeout: @escaping @Sendable () -> Void = {},
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.arm(continuation)
            let work = Task {
                let result: Result<T, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                gate.answer(result)
            }
            // The timer runs on a dispatch queue, not in a task: a busy cooperative pool cannot
            // delay it. When the operation answers first, the timer's answer is dropped.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.interval(bound)) {
                // Claim the answer, run the hook, then answer: the hook has run when the caller
                // resumes.
                guard let continuation = gate.claim() else { return }
                onTimeout()
                work.cancel()
                continuation.resume(throwing: TimedOut(bound: bound))
            }
        }
    }

    private static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }

    /// Resumes the caller once; later answers are dropped.
    private final class Gate<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, Error>?
            var answered = false
        }
        private let state = Mutex(State())

        func arm(_ continuation: CheckedContinuation<T, Error>) {
            state.withLock { $0.continuation = continuation }
        }

        /// The caller's continuation, to the first claimant only.
        func claim() -> CheckedContinuation<T, Error>? {
            state.withLock { state -> CheckedContinuation<T, Error>? in
                guard !state.answered, let continuation = state.continuation else { return nil }
                state.answered = true
                state.continuation = nil
                return continuation
            }
        }

        /// Answers the caller unless another answer came first.
        func answer(_ result: Result<T, Error>) {
            claim()?.resume(with: result)
        }
    }
}
