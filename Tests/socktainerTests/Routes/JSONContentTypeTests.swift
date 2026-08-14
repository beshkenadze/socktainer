import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Docker serves every JSON body with `Content-Type: application/json`; these
/// routes previously built raw `Response`s whose bodies were JSON but carried
/// no content type, so type-sniffing clients and proxies could not treat them
/// as JSON. Error paths likewise returned bare text strings instead of Docker's
/// `{"message": ...}` shape.
@Suite("JSON responses carry Content-Type: application/json")
struct JSONContentTypeTests {

    // MARK: - GET /networks

    @Test("GET /networks returns application/json with a decodable body")
    func networkListContentType() async throws {
        try await withNetworkApp(client: StubNetworkClient()) { app in
            try await app.testing().test(.GET, "/v1.51/networks") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "application/json")
                let networks = try JSONDecoder().decode([RESTNetworkSummary].self, from: Data(buffer: res.body))
                #expect(networks.map(\.Name) == ["bridge"])
            }
        }
    }

    @Test("GET /networks failure keeps 500 and returns Docker's {\"message\": …} shape")
    func networkListErrorShape() async throws {
        struct ListFailed: Error {}
        try await withNetworkApp(client: FailingNetworkClient(error: ListFailed())) { app in
            try await app.testing().test(.GET, "/v1.51/networks") { res async throws in
                #expect(res.status == .internalServerError)
                let body = try #require(JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect(body["message"] is String)
            }
        }
    }

    // MARK: - POST /networks/prune

    @Test("POST /networks/prune returns application/json with a decodable body")
    func networkPruneContentType() async throws {
        try await withNetworkApp(client: StubNetworkClient()) { app in
            try await app.testing().test(.POST, "/v1.51/networks/prune") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "application/json")
                let body = try #require(JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect(body["NetworksDeleted"] is [String])
            }
        }
    }

    // MARK: - POST /containers/{id}/exec

    @Test("POST /containers/{id}/exec returns 201 application/json with a decodable body")
    func execCreateContentType() async throws {
        try await withExecApp { app in
            try await app.testing().test(
                .POST, "/v1.51/containers/running-ctr/exec",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"Cmd":["echo","hi"]}"#)
            ) { res async throws in
                #expect(res.status == .created)
                #expect(res.headers.first(name: .contentType) == "application/json")
                let created = try JSONDecoder().decode(CreateExecResponse.self, from: Data(buffer: res.body))
                #expect(!created.Id.isEmpty)
                await ExecManager.shared.remove(id: created.Id)
            }
        }
    }

    // MARK: - GET /exec/{id}/json

    @Test("GET /exec/{id}/json returns application/json with a decodable body")
    func execInspectContentType() async throws {
        let execId = await ExecManager.shared.create(
            config: ExecManager.ExecConfig(
                containerId: "running-ctr",
                cmd: ["/bin/echo", "hi"],
                attachStdin: false,
                attachStdout: true,
                attachStderr: true,
                tty: false,
                detach: false,
                env: [],
                user: nil,
                workingDir: nil
            )
        )
        try await withExecApp { app in
            try await app.testing().test(.GET, "/v1.51/exec/\(execId)/json") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "application/json")
                let body = try #require(JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect(body["ID"] as? String == execId)
                await ExecManager.shared.remove(id: execId)
            }
        }
    }
}

// MARK: - App helpers

private func withNetworkApp(
    client: ClientNetworkProtocol,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        // Mirror production's outermost error rendering so thrown Aborts come
        // back as Docker's {"message": ...} shape.
        app.middleware.use(DockerErrorMiddleware(), at: .beginning)
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: NetworkListRoute(client: client))
        try app.register(collection: NetworkPruneRoute(client: client))
        try await test(app)
    }
}

private func withExecApp(
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        try app.register(collection: ExecRoute(client: RunningContainerMock()))
        try await test(app)
    }
}

// MARK: - Mocks

private func makeNetworkSummary(name: String) -> RESTNetworkSummary {
    RESTNetworkSummary(
        Name: name,
        Id: name,
        Created: "2026-01-01T00:00:00Z",
        Scope: "local",
        Driver: "nat",
        EnableIPv4: true,
        EnableIPv6: false,
        Internal: false,
        Attachable: false,
        Ingress: false,
        IPAM: NetworkIPAM(Driver: "default", Config: []),
        Options: [:],
        Containers: nil,
        ConfigFrom: nil,
        Labels: [:],
        Subnet: nil,
        Gateway: nil
    )
}

private struct StubNetworkClient: ClientNetworkProtocol {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] {
        [makeNetworkSummary(name: "bridge")]
    }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? { nil }
    func delete(id: String, logger: Logger) async throws {}
    func create(name: String, labels: [String: String], ipv4Subnet: String?, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}

private struct FailingNetworkClient: ClientNetworkProtocol {
    let error: Error
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { throw error }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? { nil }
    func delete(id: String, logger: Logger) async throws {}
    func create(name: String, labels: [String: String], ipv4Subnet: String?, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}

/// Mock whose getContainer always returns a running snapshot, so exec create
/// passes container resolution.
private struct RunningContainerMock: ClientContainerProtocol {
    private var snapshot: ContainerSnapshot {
        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [],
            workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
        )
        let img = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:abc", size: 0
            )
        )
        let config = ContainerConfiguration(id: "running-ctr", image: img, process: proc)
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }
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
