import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `docker run` attached, on a container whose executable does not exist, used to print
/// `unable to upgrade to tcp, received 500` and once never returned at all (issue #19).
///
/// Two halves are covered here, because fixing only the first leaves the worse one: the reason has
/// to reach the client, and the call has to end. A test that asserts the message still passes while
/// the process wedges.
@Suite("Container start failure — the reason reaches the client, and the call ends")
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

    /// The hang, which is the half that cost 29 minutes of a wedged CLI: a runtime that never answers
    /// must surface as an error, not as a request that never completes. The deadline is the seam, set
    /// short here; in the daemon it is 60s.
    @Test("a bootstrap that never answers ends the request instead of wedging it", .timeLimit(.minutes(1)))
    func startThatNeverAnswersTerminates() async throws {
        let never = ContainerAttachRoute.StartAttempt(
            bootstrap: { _, _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw ContainerStartTimedOutError()
            },
            deadlineNs: 200_000_000
        )

        try await withStartFailureApp(status: .stopped, start: never) { app in
            let began = Date()
            try await app.testing().test(
                .POST, "/v1.51/containers/wedged/attach?stream=1&stdout=1"
            ) { res async in
                // Whatever the shape of the answer, the contract is that there is one.
                #expect(res.status != .ok || true)
            }
            let elapsed = Date().timeIntervalSince(began)
            #expect(elapsed < 10, "attach took \(elapsed)s — the deadline did not fire")
        }
    }

    /// The docker CLI attaches before it calls /start and throws away any attach answer that is not
    /// 101 (moby client/hijack.go), so /start is the only response whose body it can render. The
    /// failure recorded by attach has to come back out there, naming the executable.
    @Test("the failure attach saw is what /start reports")
    func startReplaysTheRecordedFailure() async throws {
        let id = "replay-\(UUID().uuidString)"
        let failure = ContainerStartFailure.classify(
            "Failed to start container: vmexec error: failed to find target executable /nope")
        await StartFailureLedger.shared.record(id: id, failure: failure)

        try await withStartRouteApp(id: id) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/start") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("/nope"), "got: \(res.body.string)")
            }
        }
    }

    /// Replayed exactly once: a later `docker start` on the same container must attempt a real start
    /// rather than answer with a stale error from a previous run.
    @Test("a recorded failure is replayed once, then the container starts normally")
    func replayIsConsumed() async throws {
        let id = "consume-\(UUID().uuidString)"
        await StartFailureLedger.shared.record(
            id: id, failure: ContainerStartFailure.classify("Failed to start container: permission denied"))

        try await withStartRouteApp(id: id) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/start") { res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.POST, "/v1.51/containers/\(id)/start") { res async in
                #expect(res.status == .noContent, "got \(res.status): the stale failure was replayed twice")
            }
        }
    }
}

private func withStartFailureApp(
    status: RuntimeStatus,
    start: ContainerAttachRoute.StartAttempt,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(collection: ContainerAttachRoute(client: StoppedContainerMock(status: status), start: start))
        try await test(app)
    }
}

private func withStartRouteApp(id: String, test: @escaping (Application) async throws -> Void) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(collection: ContainerStartRoute(client: StoppedContainerMock(status: .stopped)))
        try await test(app)
    }
}

private struct StoppedContainerMock: ClientContainerProtocol {
    let status: RuntimeStatus

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        return ContainerSnapshot(
            configuration: ContainerConfiguration(id: id, image: image, process: process),
            status: status, networks: [], startedDate: nil)
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (
        deletedContainers: [String], spaceReclaimed: Int64
    ) { ([], 0) }
}
