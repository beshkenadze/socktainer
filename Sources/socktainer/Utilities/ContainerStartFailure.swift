import Foundation
import Vapor

/// The outcome moby's daemon derives from a failed container start.
///
/// moby classifies the runtime's start error twice (daemon/errors.go,
/// `setExitCodeFromError`): once into the HTTP status `POST /start` answers with —
/// `errdefs.InvalidParameter` (400) when the failure is the container's own fault
/// (missing executable, permission denied), `errdefs.Unknown` (500) otherwise — and
/// once into the exit code recorded in the container's State (126 EACCES, 127
/// cmd-not-found, 128 unknown), which `docker inspect` reports. `docker run` exits
/// with the same number because docker/cli's `toStatusError`
/// (cli/command/container/run.go) greps the /start error message for the errno
/// phrases below. Apple's runtime phrases the identical conditions without errno
/// text ("failed to find target executable /x"), so the message is annotated with
/// the phrase the CLI greps for — the same "fudge the error string" moby itself
/// applies to EISDIR.
struct ClassifiedStartFailure: Sendable {
    /// Full wire message; keeps the runtime's reason verbatim so it names the executable.
    let message: String
    /// HTTP status for the POST /start error response.
    let status: HTTPResponseStatus
    /// Exit code recorded for the container, mirroring moby's State.ExitCode.
    let exitCode: Int32
}

/// Classifies a container-start failure the way moby's daemon does.
///
/// Check order mirrors daemon/errors.go `setExitCodeFromError`: EACCES, EISDIR,
/// ENOTDIR, invalid command, unknown — the first matching phrase wins.
enum ContainerStartFailure {
    static func classify(_ reason: String) -> ClassifiedStartFailure {
        var message = reason
        var lower = reason.lowercased()

        // Apple's runtime reports a missing init executable without an errno phrase.
        // docker/cli's toStatusError picks the run's exit code by grepping the /start
        // error for the errno text, so append it or `docker run <missing>` exits 125
        // where dockerd's exits 127.
        if lower.contains("failed to find target executable"), !isInvalidCommand(lower) {
            message += ": no such file or directory"
            lower = message.lowercased()
        }

        // set to 126 for container cmd can't be invoked errors
        if lower.contains("permission denied") {
            return ClassifiedStartFailure(message: message, status: .badRequest, exitCode: 126)
        }

        // Go 1.20 changed the error for attempting to execute a directory from
        // EACCES to EISDIR; docker/cli greps for EACCES, so moby appends it.
        if lower.contains("is a directory") {
            message += ": permission denied"
            return ClassifiedStartFailure(message: message, status: .badRequest, exitCode: 126)
        }

        // attempted to mount a file onto a directory, or vice-versa
        if lower.contains("not a directory") {
            message += ": Are you trying to mount a directory onto a file (or vice-versa)? Check if the specified host path exists and is the expected type"
            return ClassifiedStartFailure(message: message, status: .badRequest, exitCode: 127)
        }

        // set to 127 for container cmd not found/does not exist
        if isInvalidCommand(lower) {
            return ClassifiedStartFailure(message: message, status: .badRequest, exitCode: 127)
        }

        return ClassifiedStartFailure(message: message, status: .internalServerError, exitCode: 128)
    }

    /// moby daemon/errors.go `isInvalidCommand`: the phrases that mark a start
    /// failure as "the container's command does not exist".
    static func isInvalidCommand(_ lowercasedMessage: String) -> Bool {
        [
            "executable file not found",
            "no such file or directory",
            "system cannot find the file specified",
            "failed to run runc create/exec call",
        ].contains { lowercasedMessage.contains($0) }
    }
}

/// Bridges a start failure observed inside `POST /attach` to the `POST /start` that
/// follows it. docker's client attaches before it starts (docker/cli
/// cli/command/container/run.go) and closes the body of any attach answer that is
/// not 101 *unread* (moby client/hijack.go: "unable to upgrade to tcp, received
/// %d"), so a start failure can only ever be rendered from /start. The attach path
/// records the classified failure here and answers 101 with an immediately
/// terminated stream; /start replays it instead of re-attempting a start on a
/// container whose bootstrap already failed.
actor StartFailureLedger {
    static let shared = StartFailureLedger()

    private var failures: [String: ClassifiedStartFailure] = [:]

    func record(id: String, failure: ClassifiedStartFailure) {
        failures[id] = failure
    }

    /// Consumes the recorded failure, if any. Replayed exactly once, so a later
    /// manual `docker start` retries the real start rather than replaying a stale
    /// error from an earlier attempt at the same container.
    func take(id: String) -> ClassifiedStartFailure? {
        failures.removeValue(forKey: id)
    }

    /// Drops a recorded failure without reading it (container deleted elsewhere).
    func clear(id: String) {
        failures.removeValue(forKey: id)
    }
}

/// Thrown when the container runtime never answers a bootstrap/start within the
/// attach path's deadline — the wedge behind issue #19, where a client sat attached
/// for 29 minutes on a container that had long exited.
struct ContainerStartTimedOutError: LocalizedError {
    var errorDescription: String? {
        "timed out waiting for the container runtime to start the container"
    }
}

/// Races `operation` against `deadline`, throwing `ContainerStartTimedOutError`
/// when the deadline passes first.
///
/// The operation runs unstructured on purpose: Apple's XPC-backed bootstrap/start
/// do not honour task cancellation, so a task-group race would still block on exit
/// waiting for the child that never returns. A losing operation task is cancelled
/// and its late result discarded; the caller always resumes.
func withDeadline<T: Sendable>(
    until deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    let operationTask = Task.detached(priority: .userInitiated) {
        do {
            race.resume(.success(try await operation()))
        } catch {
            race.resume(.failure(error))
        }
    }
    let timerTask = Task.detached(priority: .userInitiated) {
        let remaining = deadline - ContinuousClock().now
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
        }
        operationTask.cancel()
        race.resume(.failure(ContainerStartTimedOutError()))
    }
    defer {
        operationTask.cancel()
        timerTask.cancel()
    }
    return try await withCheckedThrowingContinuation { race.install($0) }
}

/// Resume-once box shared by the two racing tasks in `withDeadline`. The
/// continuation may be installed before or after a result arrives, whichever wins.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let result {
            finished = true
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
        }
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            self.result = result
        }
    }
}
