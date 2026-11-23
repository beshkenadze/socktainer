import ContainerAPIClient
import ContainerResource
import ContainerizationError
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

    /// The create route has no node check: the runtime refuses a name that a node holds, and the
    /// route maps that refusal to Docker's name conflict. The native create is not reachable with a
    /// fake runtime, so this test starts at the refusal.
    @Test("the runtime's refusal of a node's name becomes the Docker name conflict, and the node is not changed")
    func createWithNodeName() async throws {
        let name = Fixtures.uniqueName("node-create")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])

        let conflict = await ContainerNameConflict.conflict(
            after: ContainerizationError(.exists, message: "container already exists: \(name)"), name: name, client: runtime)

        #expect(conflict?.status == .conflict)
        #expect(conflict?.reason == ContainerNameConflict.abort(name: name, holderID: name).reason)
        #expect(await runtime.calls.isEmpty)
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

    /// A real socket with a read deadline: before the fix these attaches parked stdio and waited
    /// for a start, which the in-memory tester cannot end.
    @Test(
        "attach to a stopped node is refused at entry, with no preparation and no parked stdio",
        arguments: [AttachRequest.http, .httpUpgrade, .webSocket])
    func attachToStoppedNode(request: AttachRequest) async throws {
        let name = Fixtures.uniqueName("node-attach")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name, status: .stopped)])

        try await withNodeApp(runtime) { app in
            app.http.server.configuration.shutdownTimeout = .milliseconds(100)
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(app.http.server.shared.localAddress?.port)
            let client = try RawHTTPClient(port: port)
            client.send(request.text(name: name))
            let answer = try await blockingTestIO { client.read(deadline: 3) }
            client.close()
            await app.server.shutdown()

            let text = String(data: answer ?? Data(), encoding: .utf8) ?? ""
            #expect(text.hasPrefix("HTTP/1.1 409"), "\(text)")
            #expect(text.contains(Fixtures.stoppedAttach))
        }

        #expect(await PendingAttachStart.shared.claim(containerId: name) == nil, "no parked stdio")
        #expect(await runtime.calls.isEmpty, "no preparation")
    }

    @Test("the preparation step of both attach routes refuses a stopped node and returns a running one")
    func attachPreparation() async throws {
        let stopped = Fixtures.uniqueName("node-prepare")
        let running = Fixtures.uniqueName("node-running")
        let runtime = RecordingNodeRuntime([try Fixtures.node(stopped, status: .stopped), try Fixtures.node(running)])

        await #expect(throws: Abort.self) { try await ContainerAttachRoute.preparedContainer(id: stopped, client: runtime) }
        let prepared = try await ContainerAttachRoute.preparedContainer(id: running, client: runtime)

        #expect(prepared.id == running)
        #expect(await runtime.calls.isEmpty, "no preparation")
    }

    @Test("the start preparation does not rebuild a node that took the name before its refresh")
    func preparationRefresh() async throws {
        let name = Fixtures.uniqueName("node-refresh")
        let node = try Fixtures.node(name, status: .stopped)
        let rebuilt = Recorder()

        await #expect(throws: Abort.self) {
            try await ClientContainerService.prepareRefreshed(
                id: name, current: { _ in node }, rebuild: { await rebuilt.add($0.id) })
        }

        #expect(await rebuilt.entries.isEmpty, "no delete and recreate with the staged mounts")
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

enum AttachRequest: CaseIterable, Sendable {
    case http, httpUpgrade, webSocket

    func text(name: String) -> String {
        switch self {
        case .http:
            "POST /v1.51/containers/\(name)/attach?stream=1&stdout=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        case .httpUpgrade:
            "POST /v1.51/containers/\(name)/attach?stream=1&stdout=1&stdin=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n"
                + "Connection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
        case .webSocket:
            "GET /v1.51/containers/\(name)/attach/ws?stream=1&stdout=1 HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n"
                + "Upgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        }
    }
}

/// A raw TCP client with a read deadline.
private final class RawHTTPClient: @unchecked Sendable {
    private var fd: Int32

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Abort(.internalServerError, reason: "socket() failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw Abort(.internalServerError, reason: "connect() failed: \(errno)")
        }
    }

    func send(_ text: String) {
        _ = text.withCString { Darwin.send(fd, $0, strlen($0), 0) }
    }

    /// Reads once. Empty data means EOF; nil means that the deadline elapsed with nothing to read.
    func read(deadline: TimeInterval) -> Data? {
        var tv = timeval(tv_sec: Int(deadline), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let received = recv(fd, &buffer, buffer.count, 0)
        if received == 0 { return Data() }
        guard received > 0 else { return nil }
        return Data(buffer.prefix(received))
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }
}

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
        try app.register(collection: ContainerArchiveRoute(containerClient: runtime, archiveClient: archive))
        try app.register(collection: ContainerAttachRoute(client: runtime))
        try app.register(collection: ContainerAttachWSRoute(client: runtime))
        try app.register(collection: ExecRoute(client: runtime))
        try await test(app)
    }
}
