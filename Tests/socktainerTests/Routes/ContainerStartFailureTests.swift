import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `docker run` on a container whose executable does not exist has to exit the way it does on
/// dockerd: the classified reason reaches the client through `/start` (issue #19).
@Suite("Container start failure — the reason reaches the client")
struct ContainerStartFailureTests {

    /// docker/cli's `toStatusError` picks the run's exit status by grepping the /start error text,
    /// so the classification is what makes `docker run <missing>` exit 127 as it does on dockerd
    /// rather than 125.
    @Test("a missing executable is 400 and 127, carrying the phrase the CLI greps for")
    func classifiesMissingExecutable() {
        let failure = ContainerStartFailure.classify(
            "Failed to start container: vmexec error: failed to find target executable /nonexistent-binary")

        #expect(failure.status == .badRequest)
        #expect(failure.exitCode == 127)
        #expect(failure.message.contains("/nonexistent-binary"))
        #expect(failure.message.lowercased().contains("no such file or directory"))
    }

    @Test("permission denied is 126, and anything unrecognised is 500 and 128")
    func classifiesTheOtherTwo() {
        let denied = ContainerStartFailure.classify("Failed to start container: permission denied")
        #expect(denied.status == .badRequest)
        #expect(denied.exitCode == 126)

        let unknown = ContainerStartFailure.classify("Failed to start container: the vm went sideways")
        #expect(unknown.status == .internalServerError)
        #expect(unknown.exitCode == 128)
    }
}
