import Foundation

/// A network whose vmnet helper has died cannot be removed, and neither shape of that failure tells
/// anyone what to do about it. Apple's `NetworksService` keeps a `busyNetworks` set in memory,
/// inserted before a delete and cleared by a `defer` a hung call never reaches, so the second attempt
/// comes back as `network <id> has a pending operation` — and the first attempt often comes back as
/// nothing at all, because the removal never returns.
///
/// Measured on a disposable runtime (ContainerStack `scripts/verify-stage0-remedies.sh pending`):
///
///   * killing the helper alone is harmless — with no container attached the network deleted in 5s;
///   * restarting the *container* on it, which is what a person tries, wedges the removal: two
///     deletes in a row each hit a 120s client timeout with no answer;
///   * restarting the *runtime* made the same network deletable immediately, because the busy set
///     does not survive the process.
///
/// So there is a remedy, it is one step, and it is not guessable from either message. This type
/// bounds the wait so the explanation can be delivered at all, and words it.
enum WedgedNetworkRemoval {
    struct TimedOut: Error {}

    /// Far past a healthy removal, far short of a client's patience. A normal delete measured 5s even
    /// with the helper already dead; a wedged one never returned at all. Bounding at twelve times the
    /// healthy case buys an explanation without cutting off a removal that was going to succeed.
    static let bound: Duration = .seconds(60)

    /// What was actually observed, kept separate from the remedy so the message never claims to know
    /// more than it saw. A silence is strong evidence, not the daemon's own word for it.
    enum Observation: Equatable, Sendable {
        case daemonReportedPendingOperation
        case noAnswerWithin(Duration)
    }

    static func isPendingOperation(_ text: String) -> Bool {
        text.contains("pending operation")
    }

    static func message(network: String, observed: Observation) -> String {
        let seen =
            switch observed {
            case .daemonReportedPendingOperation:
                "the runtime still has an unfinished operation on it"
            case .noAnswerWithin(let bound):
                "the runtime did not answer within \(bound.components.seconds) seconds"
            }
        return
            "cannot remove network \(network): \(seen). This follows the death of the network's "
            + "helper process and does not clear on its own — restart the runtime, then remove the "
            + "network again."
    }

    /// Runs `body`, answering with `TimedOut` if it has not finished within `bound`.
    ///
    /// The work is deliberately unstructured. A wedged XPC call does not observe cancellation, so as
    /// a child task it would hold the task group — and with it the request — open for as long as it
    /// stayed wedged, which is the very hang being bounded. Whichever of the two finishes first
    /// answers the caller; the loser's result is dropped.
    static func bounded<T: Sendable>(
        within bound: Duration = bound,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let settlement = Settlement()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await body()
                    if settlement.claim() { continuation.resume(returning: value) }
                } catch {
                    if settlement.claim() { continuation.resume(throwing: error) }
                }
            }

            Task {
                try? await Task.sleep(for: bound)
                if settlement.claim() {
                    work.cancel()
                    continuation.resume(throwing: TimedOut())
                }
            }
        }
    }

    /// Resuming a continuation twice traps, so exactly one of the two racers may answer. A reference
    /// box because both racers are escaping closures and a `Mutex` is non-copyable; `@unchecked`
    /// because every access to `settled` is inside the lock.
    private final class Settlement: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return false }
            settled = true
            return true
        }
    }
}
