import Foundation
import Testing

@testable import socktainer

@Suite("Removing a network whose helper died")
struct WedgedNetworkRemovalTests {
    @Test("Apple's busy-network wording is recognised, an ordinary failure is not")
    func recognisesThePendingOperation() {
        // NetworksService.delete: `ContainerizationError(.exists, message: "network \(id) has a
        // pending operation")`.
        #expect(WedgedNetworkRemoval.isPendingOperation("network app_default has a pending operation"))
        #expect(!WedgedNetworkRemoval.isPendingOperation("cannot delete subnet app_default with referring containers"))
        #expect(!WedgedNetworkRemoval.isPendingOperation("no network for id app_default"))
    }

    @Test("the message names the network, what was seen, and the one step that clears it")
    func messageCarriesTheRemedy() {
        let reported = WedgedNetworkRemoval.message(network: "app_default", observed: .daemonReportedPendingOperation)
        #expect(reported.contains("app_default"))
        #expect(reported.contains("unfinished operation"))
        #expect(reported.contains("restart the runtime"))

        // A silence is not the daemon's own word for the state, so it is worded as what was observed.
        let silent = WedgedNetworkRemoval.message(network: "app_default", observed: .noAnswerWithin(.seconds(60)))
        #expect(silent.contains("did not answer within 60 seconds"))
        #expect(silent.contains("restart the runtime"))
    }

    @Test("a removal that finishes in time answers with its own result")
    func fastWorkIsNotDisturbed() async throws {
        let value = try await WedgedNetworkRemoval.bounded(within: .seconds(5)) { "removed" }
        #expect(value == "removed")
    }

    @Test("a removal that never returns still answers the client")
    func wedgedWorkIsBounded() async {
        // The measured shape: two deletes in a row, neither returning. Without the bound the request
        // hangs for as long as the daemon does and the diagnosis never reaches anyone.
        await #expect(throws: WedgedNetworkRemoval.TimedOut.self) {
            try await WedgedNetworkRemoval.bounded(within: .milliseconds(200)) {
                try await Task.sleep(for: .seconds(30))
                return "never"
            }
        }
    }

    @Test("a real failure from the daemon is passed through, not turned into a timeout")
    func realErrorsSurvive() async {
        struct Refused: Error, Equatable {}
        await #expect(throws: Refused.self) {
            try await WedgedNetworkRemoval.bounded(within: .seconds(5)) { throw Refused() }
        }
    }
}
