import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// F-014 and §3.2a: without `--shared-runtimes` nothing of the feature runs, and the routes answer
/// as before; with it, `/info` reports the state.
@Suite struct SharedRuntimeFlagTests {
    private struct NoContainers: ClientContainerProtocol {
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

    private struct NoImages: ClientImageProtocol {
        func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
        func delete(id: String) async throws -> ImageDeletionResult { ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil) }
        func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
            ([], 0)
        }
        func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
        func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
            URL(fileURLWithPath: "/dev/null")
        }
        func importImage(
            tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String], platform: Platform,
            appleContainerAppSupportUrl: URL, logger: Logger
        ) async throws -> (reference: String?, digest: String) {
            (nil, "sha256:0000000000000000000000000000000000000000000000000000000000000000")
        }
    }

    private struct Answer: Equatable {
        let status: HTTPStatus
        let body: String
    }

    private static let groupsPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-runtime-groups-\(UUID().uuidString).json").path

    /// Builds the routes that exist on main, with or without the flag, and answers `requests`.
    private func answers(
        sharedRuntimes: Bool, client: FakeSharedRuntimeClient, requests: [(HTTPMethod, String, Data?)]
    ) async throws -> [Answer] {
        var answers: [Answer] = []
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            app.middleware.use(DockerErrorMiddleware(), at: .beginning)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            let containers = NoContainers()
            try app.register(
                collection: InfoRoute(
                    containerClient: containers, imageClient: NoImages(),
                    configLoader: { ContainerSystemConfig() },
                    systemHealthProvider: { ("/root", "1.0") },
                    kernelNameProvider: { "kernel" }))
            try app.register(collection: ContainerListRoute(client: containers))
            try app.register(collection: ContainerInspectRoute(client: containers))
            try app.register(collection: ContainerDeleteRoute(client: containers))
            try app.register(
                collection: ContainerCreateRoute(client: containers, systemConfig: ContainerSystemConfig(), controlSocketPath: "/tmp/test.sock"))

            await SharedRuntimeService.install(on: app, enabled: sharedRuntimes) {
                SharedRuntimeService(
                    manager: SharedRuntimeManagerTests.manager(client), file: RuntimeGroupsFile(path: Self.groupsPath))
            }
            _ = await app.storage[SharedRuntimeServiceKey.self]?.admission()

            for (method, path, body) in requests {
                try await app.testing().test(
                    method, path,
                    beforeRequest: { req in
                        if let body {
                            req.headers.contentType = .json
                            req.body = ByteBuffer(data: body)
                        }
                    },
                    afterResponse: { res in
                        answers.append(Answer(status: res.status, body: res.body.string))
                    })
            }
        }
        return answers
    }

    /// `/info` with its time and the shared runtime label removed.
    private func comparableInfo(_ body: String) throws -> (info: [String: AnyHashable], labels: [String]) {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: AnyHashable])
        object["SystemTime"] = nil
        let labels = object["Labels"] as? [String] ?? []
        object["Labels"] = labels.filter { !$0.hasPrefix(SharedRuntimeService.infoLabelKey) }
        return (object, labels)
    }

    @Test func withoutTheFlagNothingIsInstalledAndNothingRuns() async throws {
        let client = FakeSharedRuntimeClient()
        _ = try await answers(sharedRuntimes: false, client: client, requests: [(.GET, "/info", nil)])
        #expect(await client.state.listCalls == 0)
        #expect(await client.state.created.isEmpty)
    }

    @Test func withoutTheFlagInfoIsAsBefore() async throws {
        let answer = try #require(try await answers(sharedRuntimes: false, client: FakeSharedRuntimeClient(), requests: [(.GET, "/info", nil)]).first)
        #expect(answer.status == .ok)
        #expect(!answer.body.contains("containerstack.shared-runtimes"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(answer.body.utf8)) as? [String: Any])
        #expect(
            object["Warnings"] as? [String] == [
                "WARNING: Apple container system info may differ",
                "NOTE: socktainer is still under active development and considered experimental!",
            ])
    }

    @Test func withTheFlagInfoHasTheLabelAndTheOtherRoutesAnswerAsWithout() async throws {
        let createBody = try SharedRuntimeFixtures.body { $0["Image"] = "mcp/time" }
        let requests: [(HTTPMethod, String, Data?)] = [
            (.GET, "/info", nil),
            (.GET, "/containers/json?all=1", nil),
            (.GET, "/containers/abc/json", nil),
            (.DELETE, "/containers/abc", nil),
            (.POST, "/containers/create", createBody),
            (.POST, "/containers/create?name=x", Data("{}".utf8)),
        ]
        let without = try await answers(sharedRuntimes: false, client: FakeSharedRuntimeClient(), requests: requests)
        let with = try await answers(sharedRuntimes: true, client: FakeSharedRuntimeClient(), requests: requests)

        let infoWithout = try comparableInfo(without[0].body)
        let infoWith = try comparableInfo(with[0].body)
        #expect(infoWith.info == infoWithout.info)
        #expect(infoWith.labels == infoWithout.labels + ["containerstack.shared-runtimes=on"])
        #expect(Array(with.dropFirst()) == Array(without.dropFirst()))
        // Without an image service both creates stop at the image check, past input validation.
        // The full F-014 test, an eligible run that gets a dedicated container, needs the image
        // facts provider of the session routes and comes with them.
        #expect([HTTPStatus.notFound, .internalServerError].contains(with[4].status))
        #expect(with[5].status == .badRequest)
    }

    @Test func withTheFlagAnOffStateIsAWarning() async throws {
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.failList = true }
        let answer = try #require(try await answers(sharedRuntimes: true, client: client, requests: [(.GET, "/info", nil)]).first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(answer.body.utf8)) as? [String: Any])
        #expect((object["Labels"] as? [String])?.contains("containerstack.shared-runtimes=off") == true)
        let warnings = object["Warnings"] as? [String] ?? []
        #expect(warnings.count == 3)
        #expect(warnings.last?.hasPrefix("shared runtimes are off: shared containers of a previous run could not be removed") == true)
    }
}
