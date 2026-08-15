import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for issue #8: `docker run`/`docker wait` reported the real
/// exit code while `inspect .State` claimed 0 and `Dead: true` — anything reading
/// inspect (CI scripts, Testcontainers, IDEs) saw a failed container as healthy.
/// The expectations mirror moby's `container/state.go`: a clean exit is
/// `Status: "exited", Running: false, Dead: false, ExitCode: N`.
@Suite("ContainerInspectRoute state fidelity")
struct ContainerInspectStateFidelityTests {

    private static func makeSnapshot(
        id: String,
        status: RuntimeStatus,
        startedDate: Date?
    ) -> ContainerSnapshot {
        let processConfig = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let imageDesc = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
        let config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
        return ContainerSnapshot(
            configuration: config,
            status: status,
            networks: [],
            startedDate: startedDate
        )
    }

    private func withRoute(
        id: String,
        status: RuntimeStatus,
        startedDate: Date?,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        let snapshot = Self.makeSnapshot(id: id, status: status, startedDate: startedDate)
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerInspectRoute(client: InspectStateMock(snapshot: snapshot)))
            try await test(app)
        }
    }

    @Test("A container that exited 7 inspects with ExitCode 7, Dead false, Status exited")
    func exitedContainerReportsRealExitCode() async throws {
        let id = "state-exited-7"
        await ContainerExitCodeStore.shared.set(id: id, code: 7)
        defer { Task { await ContainerExitCodeStore.shared.remove(id: id) } }

        try await withRoute(id: id, status: .stopped, startedDate: Date(timeIntervalSinceNow: -60)) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(id)/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.State.ExitCode == 7)
                #expect(inspect.State.Dead == false)
                #expect(inspect.State.Status == "exited")
                #expect(inspect.State.Running == false)
                #expect(inspect.State.Restarting == false)
                // StartedAt keeps the real start time; FinishedAt is the recorded finish
                // moment, the fact dockerd checkpoints and reloads across restarts.
                #expect(inspect.State.StartedAt != "")
                #expect(inspect.State.StartedAt != "0001-01-01T00:00:00Z")
                #expect(
                    inspect.State.FinishedAt
                        == AppleContainerTimestampResolver.iso8601Timestamp(
                            await ContainerExitCodeStore.shared.finishTime(id: id)))
            }
        }
    }

    @Test("An exited container with no recorded code (daemon restarted) inspects as ExitCode 0")
    func exitedContainerWithoutRecordedCodeDefaultsToZero() async throws {
        try await withRoute(id: "state-exited-unknown", status: .stopped, startedDate: Date(timeIntervalSinceNow: -60)) { app in
            try await app.testing().test(.GET, "/v1.51/containers/state-exited-unknown/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.State.ExitCode == 0)
                #expect(inspect.State.Dead == false)
                #expect(inspect.State.Status == "exited")
            }
        }
    }

    @Test("A created container inspects as created with moby's zero StartedAt")
    func createdContainerReportsCreatedStatus() async throws {
        try await withRoute(id: "state-created", status: .stopped, startedDate: nil) { app in
            try await app.testing().test(.GET, "/v1.51/containers/state-created/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.State.Status == "created")
                #expect(inspect.State.Running == false)
                #expect(inspect.State.ExitCode == 0)
                #expect(inspect.State.Dead == false)
                // moby formats an unknown timestamp as Go's zero time — a value
                // timestamp parsers accept, unlike the empty string sent before.
                #expect(inspect.State.StartedAt == "0001-01-01T00:00:00Z")
            }
        }
    }

    @Test("A running container inspects as ExitCode 0 even with a stale recorded code")
    func runningContainerResetsExitCode() async throws {
        let id = "state-running"
        await ContainerExitCodeStore.shared.set(id: id, code: 7)
        defer { Task { await ContainerExitCodeStore.shared.remove(id: id) } }

        try await withRoute(id: id, status: .running, startedDate: Date(timeIntervalSinceNow: -30)) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(id)/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.State.Status == "running")
                #expect(inspect.State.Running == true)
                #expect(inspect.State.ExitCode == 0)
                #expect(inspect.State.Dead == false)
            }
        }
    }

    @Test("A container in the restart backoff inspects as restarting and still running")
    func pendingRestartReportsRestartingState() async throws {
        let id = "state-restarting"
        await ContainerExitCodeStore.shared.set(id: id, code: 7)
        await ContainerRestartState.shared.markPendingRestart(id: id)
        defer {
            Task {
                await ContainerRestartState.shared.clearPendingRestart(id: id)
                await ContainerRestartState.shared.reset(id: id)
                await ContainerExitCodeStore.shared.remove(id: id)
            }
        }

        try await withRoute(id: id, status: .stopped, startedDate: Date(timeIntervalSinceNow: -60)) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(id)/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.State.Status == "restarting")
                #expect(inspect.State.Restarting == true)
                // moby keeps Running=true through the backoff window.
                #expect(inspect.State.Running == true)
                #expect(inspect.State.Dead == false)
            }
        }
    }
}

private struct InspectStateMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
