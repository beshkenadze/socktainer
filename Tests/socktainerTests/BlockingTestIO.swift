import Foundation

/// Suspend the test while blocking fixture I/O runs on its own thread.
/// A detached Swift task still uses the cooperative pool and cannot host this work.
/// Keep assertions in the calling task so they retain their test context.
func blockingTestIO<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(with: Result { try operation() })
        }
    }
}
