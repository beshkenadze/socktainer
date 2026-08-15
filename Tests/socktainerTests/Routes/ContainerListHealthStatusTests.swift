import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

// MARK: - Minimal mock client

private struct MockContainerClient: ClientContainerProtocol {
    let containers: [ContainerSnapshot]

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { containers }
    func getContainer(id: String) async throws -> ContainerSnapshot? { containers.first { $0.id == id } }
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

// MARK: - Helpers

private func makeSnapshot(id: String, status: RuntimeStatus = .running, startedDate: Date? = Date(timeIntervalSinceNow: -30)) -> ContainerSnapshot {
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

@Suite("ContainerListRoute status")
struct ContainerListStatusTests {

    @Test("Exited container list status includes exit code and age")
    func listIncludesExitCodeForStoppedContainers() async throws {
        let snapshot = makeSnapshot(id: "c-exited-code", status: .stopped, startedDate: Date(timeIntervalSinceNow: -0.2))
        await ContainerExitCodeStore.shared.set(id: snapshot.id, code: 7)
        defer { Task { await ContainerExitCodeStore.shared.remove(id: snapshot.id) } }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()

            let client = MockContainerClient(containers: [snapshot])
            try app.register(collection: ContainerListRoute(client: client))

            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                let status = summaries.first?.Status ?? ""
                // The age is wall-clock: asserting the exact "Less than a second" makes the test a
                // race with the suite's own scheduling. The contract is the code and the shape;
                // `humanReadableAge` is pinned separately against fixed intervals.
                #expect(status.hasPrefix("Exited (7) "), "got: \(status)")
                #expect(status.hasSuffix(" ago"), "got: \(status)")
            }
        }
    }

    @Test("Stopped container falls back to hexId exit code when native id has no code")
    func listFallsBackToHexIdExitCode() async throws {
        let snapshot = makeSnapshot(id: "c-exited-hex", status: .stopped, startedDate: Date(timeIntervalSinceNow: -0.2))
        let hexId = DockerContainerID.hexId(for: snapshot)
        await ContainerExitCodeStore.shared.set(id: hexId, code: 13)
        defer {
            Task {
                await ContainerExitCodeStore.shared.remove(id: snapshot.id)
                await ContainerExitCodeStore.shared.remove(id: hexId)
            }
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()

            let client = MockContainerClient(containers: [snapshot])
            try app.register(collection: ContainerListRoute(client: client))

            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                let status = summaries.first?.Status ?? ""
                // The age is wall-clock: asserting the exact "Less than a second" makes the test a
                // race with the suite's own scheduling. The contract is the code and the shape;
                // `humanReadableAge` is pinned separately against fixed intervals.
                #expect(status.hasPrefix("Exited (13) "), "got: \(status)")
                #expect(status.hasSuffix(" ago"), "got: \(status)")
            }
        }
    }
}

// MARK: - Tests

@Suite("ContainerListRoute health status")
struct ContainerListHealthStatusTests {

    private func withRoute(
        containers: [ContainerSnapshot],
        healthManager: HealthCheckManager? = nil,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)

            if let healthManager {
                app.storage[HealthCheckManagerKey.self] = healthManager
            }
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()

            let client = MockContainerClient(containers: containers)
            try app.register(collection: ContainerListRoute(client: client))
            try await test(app)
        }
    }

    @Test("Status is plain mobyState when no healthcheck configured")
    func statusWithoutHealthcheck() async throws {
        let snapshot = makeSnapshot(id: "c1")
        try await withRoute(containers: [snapshot]) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.Status.hasPrefix("Up") == true)
                #expect(summaries.first?.Status.range(of: "\\((starting|healthy|unhealthy)\\)", options: .regularExpression) == nil)
            }
        }
    }

    @Test("Status includes (health: starting) immediately after healthcheck is registered")
    func statusWithHealthcheckStarting() async throws {
        let snapshot = makeSnapshot(id: "c2")
        let mgr = HealthCheckManager(
            probe: { _, _, _ in
                // Slow probe — stays in "starting"
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c2", config: cfg)
        defer { Task { await mgr.stop(containerId: "c2") } }

        try await withRoute(containers: [snapshot], healthManager: mgr) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.Status.contains("(starting)") == true)
            }
        }
    }

    @Test("Status is plain mobyState (no health suffix) for running container without healthcheck — filter returns 'none'")
    func noHealthcheckFilterNone() async throws {
        let snapshot = makeSnapshot(id: "c-none")
        let mgr = HealthCheckManager(probe: { _, _, _ in 0 }, intervalFloorNs: 1_000_000)
        // mgr has no entry for "c-none" — no healthcheck started

        try await withRoute(containers: [snapshot], healthManager: mgr) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                // Status should be plain "running" (no health suffix)
                #expect(summaries.first?.Status.hasPrefix("Up") == true)
                #expect(summaries.first?.Status.range(of: "\\((starting|healthy|unhealthy)\\)", options: .regularExpression) == nil)
            }
            // Filter by health=none should return the container
            try await app.testing().test(.GET, "/v1.51/containers/json?filters=%7B%22health%22%3A%5B%22none%22%5D%7D") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.count == 1)
            }
            // Filter by health=healthy should NOT return the container
            try await app.testing().test(.GET, "/v1.51/containers/json?filters=%7B%22health%22%3A%5B%22healthy%22%5D%7D") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.count == 0)
            }
        }
    }

    @Test("Status includes (health: healthy) once probe passes")
    func statusWithHealthcheckHealthy() async throws {
        let snapshot = makeSnapshot(id: "c3")
        let mgr = HealthCheckManager(
            probe: { _, _, _ in 0 },
            intervalFloorNs: 1_000_000
        )
        let cfg = HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil)
        await mgr.start(containerId: "c3", config: cfg)
        // Wait until healthy
        for _ in 0..<200 {
            if await mgr.currentHealth(for: "c3")?.Status == "healthy" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        defer { Task { await mgr.stop(containerId: "c3") } }

        try await withRoute(containers: [snapshot], healthManager: mgr) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.Status.contains("(healthy)") == true)
            }
        }
    }
}

/// The duration wording `docker ps` prints, pinned against fixed intervals so it cannot drift and
/// cannot race the clock. moby renders these with `units.HumanDuration` (docker/go-units).
@Suite("ContainerListRoute age formatting")
struct ContainerListAgeTests {
    @Test(
        "durations read the way Docker prints them",
        arguments: [
            (0.2, "Less than a second"),
            (1.0, "1 second"),
            (5.0, "5 seconds"),
            (60.0, "1 minute"),
            (150.0, "2 minutes"),
            (3_600.0, "1 hour"),
            (7_200.0, "2 hours"),
            (86_400.0, "1 day"),
            (172_800.0, "2 days"),
        ])
    func humanReadableAge(interval: Double, expected: String) {
        let past = Date(timeIntervalSinceNow: -interval)
        #expect(MobyContainerStatus.humanReadableAge(since: past) == expected)
    }
}

/// A container created and never started is `created`, not `exited` (issue #16). The runtime reports
/// it as stopped with no start date, so the list has to make the same judgement inspect does —
/// Compose reads this to decide what needs starting, and a service that never ran looked like one
/// that had already finished.
@Suite("ContainerListRoute — created containers")
struct ContainerListCreatedStateTests {
    @Test("a container that never ran lists as created, not exited")
    func neverStartedListsAsCreated() async throws {
        let snapshot = makeSnapshot(id: "never-started", status: .stopped, startedDate: nil)
        // An exit code recorded under this id would still not make it exited: it never ran.
        await ContainerExitCodeStore.shared.remove(id: snapshot.id)

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerListRoute(client: MockContainerClient(containers: [snapshot])))

            try await app.testing().test(.GET, "/v1.51/containers/json?all=true") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.State == "created")
                #expect(summaries.first?.Status == "Created", "got: \(summaries.first?.Status ?? "nil")")
            }
        }
    }

    @Test("a container that ran and stopped still lists as exited with its code")
    func stoppedStillExited() async throws {
        let snapshot = makeSnapshot(id: "ran-then-stopped", status: .stopped, startedDate: Date(timeIntervalSinceNow: -60))
        await ContainerExitCodeStore.shared.set(id: snapshot.id, code: 3)
        defer { Task { await ContainerExitCodeStore.shared.remove(id: snapshot.id) } }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerListRoute(client: MockContainerClient(containers: [snapshot])))

            try await app.testing().test(.GET, "/v1.51/containers/json?all=true") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.State == "exited")
                #expect(summaries.first?.Status.hasPrefix("Exited (3)") == true, "got: \(summaries.first?.Status ?? "nil")")
            }
        }
    }
}

/// Issue #20 at the level it was visible: after a bridge restart, `docker ps -a` showed
/// "Exited (0)" for every container that had exited under the previous lifetime — a failed
/// service reading as a clean one. The exit store persists under Apple Container's
/// application-support root and reloads at boot; a container that ran with no record at all
/// reads as the unknown sentinel, never a fabricated 0.
@Suite("ContainerListRoute — exit code durability", .serialized)
struct ContainerListExitCodeDurabilityTests {

    /// A run-history root mirroring the runtime's layout: a booted container owns a
    /// `vminitd.log` under its own directory (see ContainerRunHistory).
    private func makeRunHistoryRoot(bootedId: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "list-exit-root-\(UUID().uuidString)")
        let dir = root.appending(path: "containers").appending(path: bootedId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "vminitd.log"))
        return root
    }

    private func withListRoute(
        containers: [ContainerSnapshot],
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerListRoute(client: MockContainerClient(containers: containers)))
            try await test(app)
        }
    }

    @Test("an exit recorded before a restart renders after it")
    func persistedExitSurvivesRestart() async throws {
        // The runtime restart shape: booted once (boot artifacts on disk), start time gone.
        let id = "durable-exit"
        let root = try makeRunHistoryRoot(bootedId: id)
        ContainerRunHistory.configure(storageDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = makeSnapshot(id: id, status: .stopped, startedDate: nil)
        let hexId = DockerContainerID.hexId(for: snapshot)

        // The previous daemon lifetime records the exit, which persists it.
        let storage = FileManager.default.temporaryDirectory
            .appending(path: "list-exit-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let previousLifetime = ContainerExitCodeStore()
        await previousLifetime.configure(storageDirectory: storage)
        await previousLifetime.set(id: hexId, code: 42)

        // This daemon boots from the file the previous one left.
        await ContainerExitCodeStore.shared.configure(storageDirectory: storage)
        defer { Task { await ContainerExitCodeStore.shared.remove(id: hexId) } }

        try await withListRoute(containers: [snapshot]) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json?all=true") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                let status = summaries.first?.Status ?? ""
                #expect(summaries.first?.State == "exited")
                // The age is wall-clock; the contract is the code and the shape.
                #expect(status.hasPrefix("Exited (42) "), "got: \(status)")
                #expect(status.hasSuffix(" ago"), "got: \(status)")
            }
        }
    }

    @Test("a container that ran with no record renders the unknown code, not a clean 0")
    func ranWithoutRecordIsUnknown() async throws {
        let id = "ran-unknown"
        let root = try makeRunHistoryRoot(bootedId: id)
        ContainerRunHistory.configure(storageDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = makeSnapshot(id: id, status: .stopped, startedDate: nil)
        await ContainerExitCodeStore.shared.remove(id: id)

        try await withListRoute(containers: [snapshot]) { app in
            try await app.testing().test(.GET, "/v1.51/containers/json?all=true") { res async in
                let summaries = (try? JSONDecoder().decode([RESTContainerSummary].self, from: res.body)) ?? []
                #expect(summaries.first?.State == "exited")
                // No record means unknown, not zero — and no finish was observed either,
                // so there is no age to print.
                #expect(summaries.first?.Status == "Exited (-1)", "got: \(summaries.first?.Status ?? "nil")")
            }
        }
    }
}
