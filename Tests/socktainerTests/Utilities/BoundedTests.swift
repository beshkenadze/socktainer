import Foundation
import Synchronization
import Testing

@testable import socktainer

/// A reply that never comes, held so that the test can send it late.
final class NeverAnswered: Sendable {
    private let held = Mutex<CheckedContinuation<Int, Never>?>(nil)
    private let cancelled = Mutex<ContinuousClock.Instant?>(nil)

    /// Waits until `answerLate`, and ignores cancellation, as an XPC reply continuation does. The
    /// moment of the cancellation is recorded on the thread that cancels: at the bound, the
    /// bound's timer thread, which does not wait for a cooperative thread.
    func wait() async -> Int {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in held.withLock { $0 = continuation } }
        } onCancel: {
            cancelled.withLock { $0 = .now }
        }
    }

    var cancelledAt: ContinuousClock.Instant? { cancelled.withLock { $0 } }

    func answerLate() {
        held.withLock {
            $0?.resume(returning: 1)
            $0 = nil
        }
    }
}

@Suite struct BoundedTests {
    @Test("a reply that never comes is answered at the bound, and the late reply is dropped")
    func neverAnswered() async throws {
        let reply = NeverAnswered()
        let fired = Mutex<ContinuousClock.Instant?>(nil)
        let start = ContinuousClock.now
        await #expect(throws: Bounded.TimedOut.self) {
            _ = try await Bounded.value(within: .milliseconds(200), onTimeout: { fired.withLock { $0 = .now } }) { await reply.wait() }
        }
        // The timer answered: the reply never came. No sub-second check here: a busy test run
        // delays the test task before the bound is armed, and again before it resumes.
        #expect(fired.withLock { $0 } != nil, "the timer answered")
        #expect(ContinuousClock.now - start < .seconds(30), "the caller was answered, not held")
        reply.answerLate()
    }

    @Test("an answer before the bound is returned, and an error is passed on")
    func answers() async throws {
        #expect(try await Bounded.value(within: .seconds(5)) { 7 } == 7)
        await #expect(throws: CancellationError.self) {
            _ = try await Bounded.value(within: .seconds(5)) { () async throws -> Int in throw CancellationError() }
        }
    }
}
