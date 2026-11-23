import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// An app with the container routes of main, a fake runtime and fake image facts, and
/// `--shared-runtimes` on (unless `sharedRuntimes` is false).
enum SessionRouteHarness {
    struct NoContainers: ClientContainerProtocol {
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
        func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
        func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws {}
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws {}
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { RESTContainerWait(statusCode: 0) }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
    }

    /// Dedicated containers that answer to the names that a test adds.
    actor DedicatedNames: ClientContainerProtocol {
        private var names: Set<String> = []
        private var ambiguous: Set<String> = []
        func add(_ name: String) { names.insert(name) }
        /// A reference that two dedicated containers match.
        func addAmbiguous(_ reference: String) { ambiguous.insert(reference) }
        func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
        func getContainer(id: String) async throws -> ContainerSnapshot? {
            if ambiguous.contains(id) { throw ClientContainerError.ambiguousId(reference: id, matches: ["a", "b"]) }
            return names.contains(id) ? try makeContainerSnapshot(nativeId: id, networks: [], labels: [:]) : nil
        }
        nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
        func start(id: String, detachKeys: String?) async throws {}
        func stop(id: String, signal: String?, timeout: Int?) async throws {}
        func restart(id: String, signal: String?, timeout: Int?) async throws {}
        func kill(id: String, signal: String?) async throws {}
        func delete(id: String) async throws {}
        func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { RESTContainerWait(statusCode: 0) }
        func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
    }

    static let mcpCatalogOn =
        #"{"version":1,"groups":[{"name":"mcp-catalog","kind":"exec","idleMinutes":10,"enabled":true},{"name":"stdio-sessions","kind":"exec","idleMinutes":10,"enabled":false}],"rules":[{"group":"mcp-catalog","image":"mcp/*"},{"group":"stdio-sessions","stdioSession":true}]}"#

    static func withApp(
        sharedRuntimes: Bool = true,
        client: FakeSharedRuntimeClient = FakeSharedRuntimeClient(),
        facts: SharedRuntimeImageFacts = FakeImageFacts(),
        groups: String? = mcpCatalogOn,
        containers: ClientContainerProtocol = NoContainers(),
        _ test: (Application, SharedRuntimeService?) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let groupsPath = directory.appendingPathComponent("runtime-groups.json").path
        if let groups { try Data(groups.utf8).write(to: URL(fileURLWithPath: groupsPath)) }

        try await VaporTesting.withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            app.middleware.use(DockerErrorMiddleware(), at: .beginning)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(
                collection: ContainerCreateRoute(client: containers, systemConfig: ContainerSystemConfig(), controlSocketPath: "/tmp/test.sock"))
            try app.register(collection: ContainerListRoute(client: containers))
            try app.register(collection: ContainerInspectRoute(client: containers))
            try app.register(collection: ContainerDeleteRoute(client: containers))
            try app.register(collection: ContainerWaitRoute(client: containers))
            try app.register(collection: ContainerStartRoute(client: containers))
            try app.register(collection: ContainerStopRoute(client: containers))
            try app.register(collection: ContainerKillRoute(client: containers))
            try app.register(collection: ContainerLogsRoute(client: containers))
            try app.register(collection: ContainerAttachRoute(client: containers))
            try app.register(collection: ExecRoute(client: containers))
            try app.register(collection: NetworkConnectRoute())
            try app.register(collection: ContainerRenameRoute(client: containers))
            try app.register(collection: NetworkDisconnectRoute())
            // A stand-in under the pattern of the archive route, which needs an archive client.
            try app.regexRouter.register(.GET, pattern: "/containers/{id:.*}/archive") { _ in "archive of main" }

            await SharedRuntimeService.install(on: app, enabled: sharedRuntimes, containers: containers) {
                SharedRuntimeService(
                    manager: SharedRuntimeManagerTests.manager(client), file: RuntimeGroupsFile(path: groupsPath), imageFacts: facts)
            }
            let service = app.storage[SharedRuntimeServiceKey.self]
            _ = await service?.admission()
            try await test(app, service)
        }
    }

    /// Creates a session from the recorded `docker run -i --rm` body for `mcp/time` and returns its ID.
    static func createSession(_ app: Application, name: String? = nil, edit: @escaping (inout [String: Any]) -> Void = { _ in }) async throws -> String {
        let body = try SharedRuntimeFixtures.body {
            $0["Image"] = SharedRuntimeFixtures.absentImage
            edit(&$0)
        }
        var id = ""
        try await app.testing().test(
            .POST, "/containers/create" + (name.map { "?name=\($0)" } ?? ""),
            beforeRequest: { req in
                req.headers.contentType = .json
                req.body = ByteBuffer(data: body)
            },
            afterResponse: { res in
                #expect(res.status == .created, "\(res.body.string)")
                id = (try? res.content.decode(RESTContainerCreate.self).Id) ?? ""
            })
        return id
    }
}
