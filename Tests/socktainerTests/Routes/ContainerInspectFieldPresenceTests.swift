import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for issue #11: dockerd always emits `Config.Labels` (`{}`),
/// `HostConfig.Binds` (`null`), `HostConfig.PortBindings` (`{}`) and
/// `HostConfig.RestartPolicy.MaximumRetryCount` (`0`), plus a storage-driver
/// `Driver` and the image digest in `.Image` — even when empty. The synthesized
/// Swift encoder omitted the nil/empty ones, so generated clients nil-deref'd
/// where dockerd never gives them the chance. These assert the raw JSON shape
/// (key presence, null vs empty) rather than the decoded model, because the
/// decoded optionals cannot distinguish absent from empty.
@Suite("ContainerInspectRoute field presence")
struct ContainerInspectFieldPresenceTests {

    private static func makeSnapshot(
        id: String,
        labels: [String: String] = [:],
        publishedPorts: [PublishPort] = []
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
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc123", size: 0)
        )
        var config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
        config.labels = labels
        config.publishedPorts = publishedPorts
        return ContainerSnapshot(
            configuration: config,
            status: .running,
            networks: [],
            startedDate: Date(timeIntervalSinceNow: -30)
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
            try app.register(collection: ContainerInspectRoute(client: InspectFieldsMock(snapshot: snapshot)))
            try await test(app)
        }
    }

    private func inspectJSON(_ body: ByteBuffer) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any])
    }

    @Test("A bare container still reports Labels, Binds, PortBindings, MaximumRetryCount, Driver")
    func emptyFieldsAreEmitted() async throws {
        try await withRoute(snapshot: Self.makeSnapshot(id: "fields-bare")) { app in
            try await app.testing().test(.GET, "/v1.51/containers/fields-bare/json") { res async throws in
                let json = try inspectJSON(res.body)

                let config = try #require(json["Config"] as? [String: Any])
                #expect((config["Labels"] as? [String: Any])?.isEmpty == true)

                let hostConfig = try #require(json["HostConfig"] as? [String: Any])
                // `Binds` must be present and JSON null — not absent, not [].
                #expect(hostConfig["Binds"] is NSNull)
                #expect((hostConfig["PortBindings"] as? [String: Any])?.isEmpty == true)
                let restartPolicy = try #require(hostConfig["RestartPolicy"] as? [String: Any])
                #expect((restartPolicy["MaximumRetryCount"] as? Int) == 0)
                #expect((restartPolicy["Name"] as? String) == "no")

                #expect((json["Driver"] as? String) == "overlayfs")
            }
        }
    }

    @Test(".Image is the sha256 digest of the image, like dockerd's image ID")
    func imageIsDigest() async throws {
        try await withRoute(snapshot: Self.makeSnapshot(id: "fields-image")) { app in
            try await app.testing().test(.GET, "/v1.51/containers/fields-image/json") { res async throws in
                let json = try inspectJSON(res.body)
                #expect((json["Image"] as? String) == "sha256:abc123")
                // Config.Image stays the user-facing reference the container was
                // created with, matching moby's split between the two.
                let config = try #require(json["Config"] as? [String: Any])
                #expect((config["Image"] as? String) == "alpine:latest")
            }
        }
    }

    @Test("Labels and PortBindings carry their real values when set")
    func populatedFieldsRoundTrip() async throws {
        let snapshot = Self.makeSnapshot(
            id: "fields-populated",
            labels: ["com.docker.compose.project": "demo"],
            publishedPorts: [
                try PublishPort(
                    hostAddress: try IPAddress("0.0.0.0"),
                    hostPort: 3000,
                    containerPort: 8080,
                    proto: .tcp,
                    count: 1
                )
            ]
        )
        try await withRoute(snapshot: snapshot) { app in
            try await app.testing().test(.GET, "/v1.51/containers/fields-populated/json") { res async throws in
                let json = try inspectJSON(res.body)

                let config = try #require(json["Config"] as? [String: Any])
                let labels = try #require(config["Labels"] as? [String: String])
                #expect(labels["com.docker.compose.project"] == "demo")

                // dockerd reports the same bindings under HostConfig and NetworkSettings.
                let hostConfig = try #require(json["HostConfig"] as? [String: Any])
                let bindings = try #require(
                    ((hostConfig["PortBindings"] as? [String: Any])?["8080/tcp"] as? [[String: Any]])
                )
                #expect(bindings.map { $0["HostPort"] as? String } == ["3000"])
                #expect(bindings.map { $0["HostIp"] as? String } == ["0.0.0.0"])
            }
        }
    }
}

private struct InspectFieldsMock: ClientContainerProtocol {
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
