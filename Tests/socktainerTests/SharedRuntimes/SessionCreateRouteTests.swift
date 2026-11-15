import ContainerResource
import ContainerizationOCI
import CryptoKit
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite(.timeLimit(.minutes(1))) struct SessionCreateRouteTests {
    typealias H = SessionRouteHarness

    private func create(_ app: Application, query: String = "", _ edit: @escaping (inout [String: Any]) -> Void) async throws -> (HTTPStatus, String) {
        let body = try SharedRuntimeFixtures.body {
            $0["Image"] = SharedRuntimeFixtures.absentImage
            edit(&$0)
        }
        var answer: (HTTPStatus, String) = (.ok, "")
        try await app.testing().test(
            .POST, "/containers/create\(query)",
            beforeRequest: { req in
                req.headers.contentType = .json
                req.body = ByteBuffer(data: body)
            }, afterResponse: { res in answer = (res.status, res.body.string) })
        return answer
    }

    /// The dedicated path of the route reaches its image check, which has no image service here.
    private func isDedicated(_ status: HTTPStatus) -> Bool { [.notFound, .internalServerError].contains(status) }

    // MARK: F-014

    @Test func withoutTheFlagAnEligibleMcpRunGoesTheDedicatedWay() async throws {
        try await H.withApp(sharedRuntimes: false) { app, _ in
            let (status, _) = try await create(app) { $0["Image"] = SharedRuntimeFixtures.absentImage }
            #expect(isDedicated(status))
        }
    }

    @Test func withTheFlagTheSameRunIsASessionAndNoContainer() async throws {
        let client = FakeSharedRuntimeClient()
        try await H.withApp(client: client) { app, service in
            let (status, body) = try await create(app) { $0["Image"] = SharedRuntimeFixtures.absentImage }
            #expect(status == .created, "\(body)")
            #expect(await service?.manager.allSessions().count == 1)
            #expect(await client.state.created.isEmpty, "create starts nothing")
        }
    }

    // MARK: F-008

    @Test func aRuleSelectedRunThatIsNotEligibleGoesTheDedicatedWayWithTheSkippedLabel() async throws {
        try await H.withApp { app, service in
            let (status, _) = try await create(app) {
                $0["Image"] = SharedRuntimeFixtures.absentImage
                $0["Tty"] = true
            }
            #expect(isDedicated(status))
            #expect(await service?.manager.allSessions().isEmpty == true)
            let outcome = try await service?.decideCreate(
                data: try SharedRuntimeFixtures.body {
                    $0["Image"] = SharedRuntimeFixtures.absentImage
                    $0["Tty"] = true
                },
                body: try JSONDecoder().decode(
                    CreateContainerRequest.self,
                    from: try SharedRuntimeFixtures.body {
                        $0["Image"] = SharedRuntimeFixtures.absentImage
                        $0["Tty"] = true
                    }),
                name: "x", explicitName: false, platform: .current, containers: H.NoContainers())
            #expect(outcome == .dedicated(skipped: "mcp-catalog:tty"))
        }
    }

    @Test func aLabelSelectedRunThatIsNotEligibleFailsWithTheReason() async throws {
        try await H.withApp { app, _ in
            let (status, body) = try await create(app) {
                $0["Image"] = SharedRuntimeFixtures.absentImage
                $0["Labels"] = ["containerstack.group": "mcp-catalog"]
                var host = $0["HostConfig"] as! [String: Any]
                host["Privileged"] = true
                $0["HostConfig"] = host
            }
            #expect(status == .badRequest)
            #expect(body.contains("option:Privileged"))
        }
    }

    @Test func anUnknownOrDisabledGroupInALabelFails() async throws {
        try await H.withApp { app, _ in
            let unknown = try await create(app) { $0["Labels"] = ["containerstack.group": "nope"] }
            #expect(unknown.0 == .badRequest && unknown.1.contains("unknown-group"))
            let disabled = try await create(app) { $0["Labels"] = ["containerstack.group": "stdio-sessions"] }
            #expect(disabled.0 == .badRequest && disabled.1.contains("disabled-group"))
        }
    }

    @Test func anUnknownOrDisabledGroupFailsAlsoForAnImageThatIsNotInTheStore() async throws {
        try await H.withApp(facts: FakeImageFacts(image: nil)) { app, _ in
            let unknown = try await create(app) { $0["Labels"] = ["containerstack.group": "nope"] }
            #expect(unknown.0 == .badRequest && unknown.1.contains("unknown-group"))
            let disabled = try await create(app) { $0["Labels"] = ["containerstack.group": "stdio-sessions"] }
            #expect(disabled.0 == .badRequest && disabled.1.contains("disabled-group"))
        }
    }

    @Test func aRunThatCanNeverBeASessionReadsNoImage() async throws {
        try await H.withApp(facts: FakeImageFacts(mustNotBeCalled: true)) { app, service in
            let service = try #require(service)
            func decide(_ edit: @escaping (inout [String: Any]) -> Void) async throws -> SharedRuntimeService.CreateOutcome {
                let data = try SharedRuntimeFixtures.body(edit)
                return try await service.decideCreate(
                    data: data, body: try JSONDecoder().decode(CreateContainerRequest.self, from: data), name: "x",
                    explicitName: false, platform: .current, containers: H.NoContainers())
            }
            #expect(
                try await decide {
                    $0["Image"] = SharedRuntimeFixtures.absentOtherImage
                    $0["OpenStdin"] = false
                } == .dedicated(skipped: nil))
            #expect(
                try await decide {
                    $0["Image"] = SharedRuntimeFixtures.absentImage
                    $0["OpenStdin"] = false
                } == .dedicated(skipped: "mcp-catalog:no-stdin"))
            #expect(
                try await decide {
                    $0["Image"] = SharedRuntimeFixtures.absentImage
                    $0["Tty"] = true
                } == .dedicated(skipped: "mcp-catalog:tty"))
            let labelled = try await create(app) {
                $0["Labels"] = ["containerstack.group": "mcp-catalog"]
                $0["OpenStdin"] = false
            }
            #expect(labelled.0 == .badRequest && labelled.1.contains("no-stdin"))
        }
    }

    @Test func labelNoneReadsNoImage() async throws {
        try await H.withApp(facts: FakeImageFacts(failure: FakeSharedRuntimeClient.Failure.injected)) { app, _ in
            let (status, _) = try await create(app) {
                $0["Image"] = SharedRuntimeFixtures.absentImage
                $0["Labels"] = ["containerstack.group": "none"]
            }
            #expect(isDedicated(status))
        }
    }

    @Test func unreadableImageFactsFailALabelSelectedRunAndLeaveAnUnselectedOneDedicated() async throws {
        try await H.withApp(facts: FakeImageFacts(failure: FakeSharedRuntimeClient.Failure.injected)) { app, _ in
            let labelled = try await create(app) { $0["Labels"] = ["containerstack.group": "mcp-catalog"] }
            #expect(labelled.0 == .internalServerError && labelled.1.contains("mcp-catalog"))
            let ruled = try await create(app) { $0["Image"] = SharedRuntimeFixtures.absentImage }
            #expect(isDedicated(ruled.0))
        }
    }

    @Test func anImageThatIsNotInTheStoreGoesOnToTheRoute404() async throws {
        try await H.withApp(facts: FakeImageFacts(image: nil)) { app, _ in
            let (status, _) = try await create(app) { $0["Image"] = SharedRuntimeFixtures.absentImage }
            #expect(isDedicated(status))
        }
    }

    // MARK: F-012

    @Test func aCleanupThatNeverReturnsGivesAnEligibleRunADedicatedContainer() async throws {
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.listNeverReturns = true }
        let timer = ManualSleeper()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("groups-\(UUID().uuidString).json")
        try Data(H.mcpCatalogOn.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let service = SharedRuntimeService(
            manager: SharedRuntimeManagerTests.manager(client), file: RuntimeGroupsFile(path: path.path),
            imageFacts: FakeImageFacts(), timerSleep: { try await timer.sleep($0) })
        await service.startCleanup()
        let data = try SharedRuntimeFixtures.body { $0["Image"] = SharedRuntimeFixtures.absentImage }
        let decision = Task {
            try await service.decideCreate(
                data: data, body: try JSONDecoder().decode(CreateContainerRequest.self, from: data), name: "x", explicitName: false,
                platform: .current, containers: H.NoContainers())
        }
        await timer.waitUntil { $0.pending == [.seconds(30)] }
        timer.fireAll()
        #expect(try await decision.value == .dedicated(skipped: nil))
        #expect(await service.manager.allSessions().isEmpty)
    }

    // MARK: names

    @Test func aNameIsUniqueAcrossSessionsAndContainers() async throws {
        try await H.withApp { app, _ in
            _ = try await H.createSession(app, name: "taken")
            let again = try await create(app, query: "?name=taken") { $0["Image"] = SharedRuntimeFixtures.absentImage }
            #expect(again.0 == .conflict)
            let dedicated = try await create(app, query: "?name=taken") { $0["Image"] = SharedRuntimeFixtures.absentOtherImage }
            #expect(dedicated.0 == .conflict, "a dedicated create cannot take the name of a session")
        }
    }

    // MARK: point 4: the image ID is the config digest

    @Test func theImageIDIsTheSHA256OfTheConfigBlob() throws {
        let blob = Data(
            #"{"architecture":"arm64","os":"linux","config":{"Entrypoint":["/server"],"Cmd":["--stdio"],"Env":["PATH=/bin"],"Volumes":{"/data":{}}},"rootfs":{"type":"layers","diff_ids":[]}}"#
                .utf8)
        let digest = "sha256:" + SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        let indexDigest = "sha256:" + String(repeating: "1", count: 64)
        let manifest = Manifest(
            config: Descriptor(mediaType: "application/vnd.oci.image.config.v1+json", digest: digest, size: Int64(blob.count)), layers: [])
        let description = ImageDescription(
            reference: "docker.io/mcp/time:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: indexDigest, size: 1))

        let facts = try SharedRuntimeImageFactsResult.make(manifest: manifest, configBlob: blob, description: description)
        #expect(facts.image.id == digest)
        #expect(facts.image.id != description.digest)
        #expect(facts.image.config?.entrypoint == ["/server"])
        #expect(facts.image.volumes?.keys.sorted() == ["/data"])

        let other = Manifest(config: Descriptor(mediaType: "application/vnd.oci.image.config.v1+json", digest: indexDigest, size: 1), layers: [])
        #expect(throws: SharedRuntimeImageFactsError.self) { try SharedRuntimeImageFactsResult.make(manifest: other, configBlob: blob, description: description) }
    }
}
