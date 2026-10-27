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
