import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `docker compose up` on a changed service renames the old container aside, creates the
/// replacement, then deletes the moved-aside one *by the id it inspected*. Apple Container has no
/// rename, so socktainer recreates the container under the new name — these cover the preconditions
/// that decide whether that is safe, and the identity continuity clients depend on afterwards.
@Suite("ContainerRenameRoute")
struct ContainerRenameRouteTests {
    private static func snapshot(id: String, status: RuntimeStatus) -> ContainerSnapshot {
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
        return ContainerSnapshot(configuration: config, status: status, networks: [], startedDate: nil)
    }

    private func withRoute(
        containers: [ContainerSnapshot],
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerRenameRoute(client: RenameMock(containers: containers)))
            try await test(app)
        }
    }

    @Test("Renaming to a name already in use is a conflict, as in Docker")
    func nameConflictIsRejected() async throws {
        let containers = [Self.snapshot(id: "web", status: .stopped), Self.snapshot(id: "taken", status: .stopped)]
        try await withRoute(containers: containers) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=taken") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("already in use"))
            }
        }
    }

    @Test("A running container is refused, because recreating it would kill the process")
    func runningContainerIsRefused() async throws {
        try await withRoute(containers: [Self.snapshot(id: "web", status: .running)]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web-old") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("stop it first"))
            }
        }
    }

    @Test("An unknown container is a 404")
    func unknownContainerIsNotFound() async throws {
        try await withRoute(containers: []) { app in
            try await app.testing().test(.POST, "/v1.51/containers/ghost/rename?name=whatever") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("A missing name is rejected before anything is touched")
    func missingNameIsRejected() async throws {
        try await withRoute(containers: [Self.snapshot(id: "web", status: .stopped)]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Renaming a container to its current name succeeds without recreating it")
    func renameToSameNameIsANoOp() async throws {
        try await withRoute(containers: [Self.snapshot(id: "web", status: .stopped)]) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web") { res async in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("A leading slash on the requested name is accepted, as Docker hands names out that way")
    func leadingSlashIsStripped() async throws {
        let containers = [Self.snapshot(id: "web", status: .stopped), Self.snapshot(id: "taken", status: .stopped)]
        try await withRoute(containers: containers) { app in
            // Reaching the conflict check proves the slash was stripped before the lookup.
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=/taken") { res async in
                #expect(res.status == .conflict)
            }
        }
    }
}

@Suite("ContainerRenameMap")
struct ContainerRenameMapTests {
    @Test("A retired id resolves to the container it became")
    func retiredIdResolves() async {
        let map = ContainerRenameMap()
        await map.record(retiredHexId: "hexA", previousNativeId: "web", nativeId: "web-old")

        #expect(await map.nativeId(forRetiredHexId: "hexA") == "web-old")
        #expect(await map.nativeId(forRetiredHexId: "hexB") == nil)
    }

    @Test("A container renamed twice stays reachable under its original id")
    func chainedRenamesCollapse() async {
        let map = ContainerRenameMap()
        await map.record(retiredHexId: "hexA", previousNativeId: "web", nativeId: "web-1")
        await map.record(retiredHexId: "hexB", previousNativeId: "web-1", nativeId: "web-2")

        #expect(await map.nativeId(forRetiredHexId: "hexA") == "web-2")
        #expect(await map.nativeId(forRetiredHexId: "hexB") == "web-2")
    }

    @Test("Deleting the container retires its old ids too")
    func deleteForgetsRetiredIds() async {
        let map = ContainerRenameMap()
        await map.record(retiredHexId: "hexA", previousNativeId: "web", nativeId: "web-old")
        await map.forget(nativeId: "web-old")

        #expect(await map.nativeId(forRetiredHexId: "hexA") == nil)
    }

    @Test("Forgetting one container leaves another's retired id intact")
    func forgetIsScopedToOneContainer() async {
        let map = ContainerRenameMap()
        await map.record(retiredHexId: "hexA", previousNativeId: "web", nativeId: "web-old")
        await map.record(retiredHexId: "hexC", previousNativeId: "api", nativeId: "api-old")
        await map.forget(nativeId: "web-old")

        #expect(await map.nativeId(forRetiredHexId: "hexC") == "api-old")
    }
}

private struct RenameMock: ClientContainerProtocol {
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
