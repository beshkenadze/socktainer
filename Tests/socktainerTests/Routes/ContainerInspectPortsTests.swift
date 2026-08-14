import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Two host ports can publish the same container port — `-p 3000:3000 -p 3100:3000`, or a Compose
/// service that grew a second entry for one port. `ExposedPorts` is keyed by `port/proto`, so those
/// two publishers collapse to one key. Building that dictionary while assuming unique keys traps,
/// and a trap in the daemon takes every container's client down with it.
@Suite("ContainerInspectRoute published ports")
struct ContainerInspectPortsTests {
    private static func snapshot(publishedPorts: [PublishPort]) throws -> ContainerSnapshot {
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
        var config = ContainerConfiguration(id: "ports", image: imageDesc, process: processConfig)
        config.publishedPorts = publishedPorts
        return ContainerSnapshot(configuration: config, status: .running, networks: [], startedDate: Date())
    }

    private static func publish(host: UInt16, container: UInt16, proto: PublishProtocol = .tcp) throws -> PublishPort {
        try PublishPort(
            hostAddress: try IPAddress("0.0.0.0"),
            hostPort: host,
            containerPort: container,
            proto: proto,
            count: 1
        )
    }

    private func withRoute(
        snapshot: ContainerSnapshot,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerInspectRoute(client: InspectPortsMock(snapshot: snapshot)))
            try await test(app)
        }
    }

    @Test("Two host ports on one container port inspect without trapping")
    func duplicateContainerPortIsCollapsed() async throws {
        let snapshot = try Self.snapshot(publishedPorts: [
            Self.publish(host: 3000, container: 3000),
            Self.publish(host: 3100, container: 3000)
        ])

        try await withRoute(snapshot: snapshot) { app in
            try await app.testing().test(.GET, "/v1.51/containers/ports/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.Config.ExposedPorts?.keys.sorted() == ["3000/tcp"])
                // Docker keeps both host bindings under the single port key.
                let bindings = inspect.NetworkSettings.Ports?["3000/tcp"]?.compactMap(\.HostPort).sorted()
                #expect(bindings == ["3000", "3100"])
            }
        }
    }

    @Test("The same port number on tcp and udp stays two exposed keys")
    func distinctProtocolsRemainSeparate() async throws {
        let snapshot = try Self.snapshot(publishedPorts: [
            Self.publish(host: 3000, container: 3000, proto: .tcp),
            Self.publish(host: 3000, container: 3000, proto: .udp)
        ])

        try await withRoute(snapshot: snapshot) { app in
            try await app.testing().test(.GET, "/v1.51/containers/ports/json") { res async throws in
                let inspect = try res.content.decode(RESTContainerInspect.self)
                #expect(inspect.Config.ExposedPorts?.keys.sorted() == ["3000/tcp", "3000/udp"])
            }
        }
    }
}

private struct InspectPortsMock: ClientContainerProtocol {
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
