import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Spec F-101: a route that can change a container refuses a node of a Kubernetes cluster with 409,
/// before any fast return, bookkeeping or side effect. Maintenance access stays open.
@Suite("Cluster node guard — container routes")
struct ClusterNodeGuardRouteTests {
    private typealias Fixtures = ClusterNodeFixtures

    // MARK: - Lifecycle

    @Test("start refuses a node before the restart-state reset and the fast return", arguments: [RuntimeStatus.running, .stopped])
    func start(status: RuntimeStatus) async throws {
        let name = Fixtures.uniqueName("node-start")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name, status: status)])
        let generation = await ContainerRestartState.shared.currentGeneration(id: name)

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(name)/start") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await ContainerRestartState.shared.currentGeneration(id: name) == generation, "no restart-state reset")
        #expect(await ContainerExitCodeStore.shared.get(id: name) == nil, "no start failure recorded")
        #expect(await runtime.calls.isEmpty)
    }

    @Test("stop refuses a node, also a stopped one that would get 304", arguments: [RuntimeStatus.running, .stopped])
    func stop(status: RuntimeStatus) async throws {
        let name = Fixtures.uniqueName("node-stop")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name, status: status)])

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(name)/stop") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await runtime.calls.isEmpty)
    }

    @Test("kill refuses a node")
    func kill() async throws {
        let name = Fixtures.uniqueName("node-kill")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(name)/kill?signal=SIGKILL") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await runtime.calls.isEmpty)
    }

    @Test("restart refuses a node before the restart-state reset")
    func restart() async throws {
        let name = Fixtures.uniqueName("node-restart")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])
        let generation = await ContainerRestartState.shared.currentGeneration(id: name)

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(name)/restart") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await ContainerRestartState.shared.currentGeneration(id: name) == generation, "no restart-state reset")
        #expect(await runtime.calls.isEmpty)
    }

    @Test("delete refuses a node before the health-check stop and the DNS alias removal")
    func delete() async throws {
        let name = Fixtures.uniqueName("node-delete")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])
        let health = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000)
        await health.start(
            containerId: name,
            config: HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil))
        let dns = SocktainerDNSServer()
        dns.register(hostname: name, ip: "192.168.64.3")

        try await withNodeApp(
            runtime,
            configure: { app in
                app.storage[HealthCheckManagerKey.self] = health
                app.storage[SocktainerDNSServerKey.self] = dns
            }
        ) { app in
            try await app.testing().test(.DELETE, "/v1.51/containers/\(name)?force=1&v=1") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await health.currentHealth(for: name) != nil, "no health-check stop")
        #expect(!dns.listEntries().isEmpty, "no DNS alias removal")
        #expect(await runtime.calls.isEmpty, "no stop and no delete")
        await health.stop(containerId: name)
    }

    @Test("delete refuses a node that only its second lookup finds")
    func deleteAfterFailedLookup() async throws {
        let name = Fixtures.uniqueName("node-delete-retry")
        let runtime = FirstLookupFails(try Fixtures.node(name))
        let health = HealthCheckManager(
            probe: { _, _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            },
            intervalFloorNs: 1_000_000)
        await health.start(
            containerId: name,
            config: HealthcheckConfig(Test: ["CMD", "true"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 3, StartPeriod: nil))

        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            app.middleware.use(DockerErrorMiddleware(), at: .beginning)
            app.storage[HealthCheckManagerKey.self] = health
            try app.register(collection: ContainerDeleteRoute(client: runtime))
            try await app.testing().test(.DELETE, "/v1.51/containers/\(name)?force=1") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await health.currentHealth(for: name) != nil, "no health-check stop")
        #expect(await runtime.calls.isEmpty, "no stop and no delete")
        await health.stop(containerId: name)
    }

    @Test("update refuses a node before the restart-policy store write")
    func update() async throws {
        let name = Fixtures.uniqueName("node-update")
        let node = try Fixtures.node(name)
        let runtime = RecordingNodeRuntime([node])

        try await withNodeApp(runtime) { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/\(name)/update",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"RestartPolicy":{"Name":"always","MaximumRetryCount":0}}"#)
                },
                afterResponse: { res async in
                    #expect(res.status == .conflict)
                    #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
                })
        }

        #expect(await RestartPolicyOverrideStore.shared.get(id: DockerContainerID.hexId(for: node)) == nil, "no restart-policy write")
    }

    // MARK: - Rename

    @Test("rename refuses a node as source, also to its own name", arguments: ["other-name", nil])
    func renameSource(target: String?) async throws {
        let name = Fixtures.uniqueName("node-rename")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name, status: .stopped)])
        let recreated = Recorder()

        try await withNodeApp(runtime, recreated: recreated) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(name)/rename?name=\(target ?? name)") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await runtime.calls.isEmpty, "no delete")
        #expect(await recreated.entries.isEmpty, "no recreate")
    }

    @Test("rename refuses a node as target, also when the target differs only in case", arguments: [false, true])
    func renameTarget(caseOnly: Bool) async throws {
        let source = Fixtures.uniqueName("source")
        let name = Fixtures.uniqueName("node-target")
        let runtime = RecordingNodeRuntime([try Fixtures.ordinary(source), try Fixtures.node(name, status: .stopped)])
        let recreated = Recorder()
        let target = caseOnly ? name.uppercased() : name

        try await withNodeApp(runtime, recreated: recreated) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(source)/rename?name=\(target)") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await runtime.calls.isEmpty, "no delete")
        #expect(await recreated.entries.isEmpty, "no recreate")
    }

    // MARK: - Create

    @Test("create with the name of a node answers the Docker name conflict before any write", arguments: [false, true])
    func create(caseOnly: Bool) async throws {
        let name = Fixtures.uniqueName("node-create")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])
        try await PreStartInjectionStore.shared.rememberCreateOptions(containerId: name, autoRemove: true)
        let requested = caseOnly ? name.uppercased() : name

        try await withNodeApp(runtime) { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/create?name=\(requested)",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"Image":"\#(SharedRuntimeFixtures.absentImage)"}"#)
                },
                afterResponse: { res async in
                    #expect(res.status == .conflict)
                    #expect(Fixtures.message(res.body) == ContainerNameConflict.abort(name: requested, holderID: name).reason)
                })
        }

        #expect(await PreStartInjectionStore.shared.createOptions(containerId: name).autoRemove, "no create-option write")
        try await PreStartInjectionStore.shared.clear(containerId: name)
    }

    // MARK: - Archive

    @Test("archive PUT refuses a node; archive GET returns its bytes")
    func archive() async throws {
        let name = Fixtures.uniqueName("node-archive")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])
        let archive = RecordingArchive()

        try await withNodeApp(runtime, archive: archive) { app in
            try await app.testing().test(
                .PUT, "/v1.51/containers/\(name)/archive?path=/etc",
                beforeRequest: { req in req.body = ByteBuffer(string: "not a tar, never read") },
                afterResponse: { res async in
                    #expect(res.status == .conflict)
                    #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
                })
            try await app.testing().test(.GET, "/v1.51/containers/\(name)/archive?path=/etc/hostname") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == RecordingArchive.tar)
            }
        }

        #expect(await archive.puts.isEmpty, "no file system write")
    }

    // MARK: - Maintenance access

    @Test("HTTP attach to a stopped node runs no preparation", arguments: ["0", "1"])
    func httpAttach(stdin: String) async throws {
        let name = Fixtures.uniqueName("node-attach")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name, status: .stopped)])
        // Another client already waits for this node, so the attach answers 409 right after its
        // preparation step instead of waiting for a start.
        // The parked pipes belong to PendingAttachStart until `cancel` gives them back; when the
        // test ends early, its adoption timeout closes them.
        let pipes = try #require(StdioPipes.make(.all))
        guard let token = await PendingAttachStart.shared.park(containerId: name, pipes: pipes) else {
            pipes.closeAll()
            Issue.record("could not park the other client")
            return
        }

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(name)/attach?stream=1&stdout=1&stdin=\(stdin)") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body)?.contains("already has a client attached") == true)
            }
        }

        if await PendingAttachStart.shared.cancel(containerId: name, token: token) {
            pipes.closeAll()
        }
        #expect(await runtime.calls.isEmpty, "no preparation")
    }

    @Test("WebSocket attach to a stopped node runs no preparation")
    func webSocketAttach() async throws {
        let name = Fixtures.uniqueName("node-attach-ws")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name, status: .stopped)])

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.GET, "/v1.51/containers/\(name)/attach/ws?stream=1&stdout=1") { res async in
                #expect(res.status.code < 400, "the attach is allowed")
            }
        }

        #expect(await runtime.calls.isEmpty, "no preparation")
    }

    @Test("the preparation step of both attach routes returns a stopped node unchanged")
    func attachPreparation() async throws {
        let name = Fixtures.uniqueName("node-prepare")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name, status: .stopped)])

        let prepared = try await ContainerAttachRoute.preparedContainer(id: name, client: runtime)

        #expect(prepared.id == name)
        #expect(prepared.status == .stopped)
        #expect(await runtime.calls.isEmpty, "no preparation")
    }

    @Test("exec into a running node is allowed")
    func exec() async throws {
        let name = Fixtures.uniqueName("node-exec")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])

        try await withNodeApp(runtime) { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/\(name)/exec",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"Cmd":["kubectl","get","nodes"]}"#)
                },
                afterResponse: { res async in
                    #expect(res.status == .created)
                })
        }
    }

    // MARK: - Resolution

    @Test("a node found by an ID prefix is refused under its own name")
    func idPrefix() async throws {
        let name = Fixtures.uniqueName("node-prefix")
        let node = try Fixtures.node(name, status: .stopped)
        let runtime = RecordingNodeRuntime([node])
        let prefix = String(DockerContainerID.hexId(for: node).prefix(12))

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(prefix)/stop") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        #expect(await runtime.calls.isEmpty)
    }

    @Test("a node found by a retired ID is refused under its own name")
    func retiredId() async throws {
        let name = Fixtures.uniqueName("node-retired")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])
        let retired = String(repeating: "e", count: 52) + String(format: "%012x", Int.random(in: 0..<(1 << 47)))
        await ContainerRenameMap.shared.record(retiredHexId: retired, previousNativeId: "\(name)-old", nativeId: name)

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.DELETE, "/v1.51/containers/\(retired)?force=1") { res async in
                #expect(res.status == .conflict)
                #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
            }
        }

        await ContainerRenameMap.shared.forget(nativeId: name)
        #expect(await runtime.calls.isEmpty)
    }

    // MARK: - Ordinary containers

    @Test("an ordinary container is not refused")
    func ordinary() async throws {
        let name = Fixtures.uniqueName("plain")
        let runtime = RecordingNodeRuntime([try Fixtures.ordinary(name, status: .running)])

        try await withNodeApp(runtime) { app in
            try await app.testing().test(.POST, "/v1.51/containers/\(name)/kill") { res async in
                #expect(res.status == .noContent)
            }
        }

        #expect(await runtime.calls == ["kill \(name)"])
    }
}

// MARK: - Harness

/// A runtime whose first lookup fails, as after a dropped connection; later lookups find `node`.
private actor FirstLookupFails: ClientContainerProtocol {
    struct Dropped: Error {}
    let node: ContainerSnapshot
    private var lookups = 0
    private(set) var calls: [String] = []

    init(_ node: ContainerSnapshot) { self.node = node }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        lookups += 1
        if lookups == 1 { throw Dropped() }
        return node
    }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws { calls.append("start \(id)") }
    func stop(id: String, signal: String?, timeout: Int?) async throws { calls.append("stop \(id)") }
    func restart(id: String, signal: String?, timeout: Int?) async throws { calls.append("restart \(id)") }
    func kill(id: String, signal: String?) async throws { calls.append("kill \(id)") }
    func delete(id: String) async throws { calls.append("delete \(id)") }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { RESTContainerWait(statusCode: 0) }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}

private actor Recorder {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

private actor RecordingArchive: ClientArchiveProtocol {
    static let tar = "tar bytes"
    private(set) var puts: [String] = []

    nonisolated func getRootfsPath(containerId: String) -> URL {
        URL(fileURLWithPath: "/nonexistent/rootfs.ext4")
    }

    func getArchive(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat) {
        (Data(Self.tar.utf8), PathStat(name: "hostname", size: 9, mode: 0o644, mtime: "2026-01-01T00:00:00Z", linkTarget: ""))
    }

    func statPath(container: ContainerSnapshot, path: String) async throws -> PathStat {
        PathStat(name: "hostname", size: 9, mode: 0o644, mtime: "2026-01-01T00:00:00Z", linkTarget: "")
    }

    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
        puts.append(path)
    }

    func exportRootfs(containerId: String) async throws -> URL {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }
}

private func withNodeApp(
    _ runtime: RecordingNodeRuntime,
    archive: RecordingArchive = RecordingArchive(),
    recreated: Recorder = Recorder(),
    configure: @escaping @Sendable (Application) -> Void = { _ in },
    _ test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let router = app.regexRouter(with: app.logger)
        app.setRegexRouter(router)
        router.installMiddleware(on: app)
        app.middleware.use(DockerErrorMiddleware(), at: .beginning)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        configure(app)
        try app.register(collection: ContainerStartRoute(client: runtime))
        try app.register(collection: ContainerStopRoute(client: runtime))
        try app.register(collection: ContainerKillRoute(client: runtime))
        try app.register(collection: ContainerRestartRoute(client: runtime))
        try app.register(collection: ContainerDeleteRoute(client: runtime))
        try app.register(collection: ContainerUpdateRoute(client: runtime))
        try app.register(
            collection: ContainerRenameRoute(
                client: runtime,
                recreate: { configuration in await recreated.add(configuration.id) },
                runtimeAppRoot: { URL(fileURLWithPath: "/nonexistent") }))
        try app.register(
            collection: ContainerCreateRoute(client: runtime, systemConfig: ContainerSystemConfig(), controlSocketPath: "/tmp/test.sock"))
        try app.register(collection: ContainerArchiveRoute(containerClient: runtime, archiveClient: archive))
        try app.register(collection: ContainerAttachRoute(client: runtime))
        try app.register(collection: ContainerAttachWSRoute(client: runtime))
        try app.register(collection: ExecRoute(client: runtime))
        try await test(app)
    }
}
