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
        refusesDelete: Bool = false,
        recreate: (@Sendable (RenameContainerStore, ContainerConfiguration) async throws -> Void)? = nil,
        test: @escaping (Application, RenameContainerStore) async throws -> Void
    ) async throws {
        let store = RenameContainerStore(containers: containers, refusesDelete: refusesDelete)
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(
                collection: ContainerRenameRoute(
                    client: RenameMock(store: store),
                    // Defaults to the store's own create, so the rename is observable end to end.
                    recreate: { configuration in
                        if let recreate {
                            try await recreate(store, configuration)
                        } else {
                            await store.add(configuration)
                        }
                    }
                )
            )
            try await test(app, store)
        }
    }

    @Test("A rename recreates the container under the new name and removes the original")
    func renameRecreatesUnderTheNewName() async throws {
        let recorder = RenameRecorder()
        let container = Self.snapshot(id: "web", status: .stopped)

        try await withRoute(
            containers: [container],
            recreate: { store, configuration in
                await recorder.recordCreate(configuration)
                await store.add(configuration)
            }
        ) { app, store in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web-old") { res async in
                #expect(res.status == .noContent)
            }
            // The rename has to be observable in the runtime, not merely attempted: exactly one
            // container, under the new name.
            #expect(await store.names() == ["web-old"])
            #expect(await store.get("web") == nil, "the original must be gone, not merely shadowed")
        }

        let created = await recorder.created
        #expect(created?.id == "web-old", "the replacement must carry the new name as its id")
        // Everything the client asked to keep travels with the configuration.
        #expect(created?.image.reference == container.configuration.image.reference)
        #expect(await recorder.discarded == nil, "nothing to roll back on the happy path")
    }

    @Test("A rename preserves the container's Docker id, as Docker does")
    func renamePreservesTheDockerId() async throws {
        let recorder = RenameRecorder()
        let storedId = String(repeating: "ab12", count: 16)
        var configuration = Self.snapshot(id: "web", status: .stopped).configuration
        configuration.labels[DockerContainerID.idLabel] = storedId
        let container = ContainerSnapshot(configuration: configuration, status: .stopped, networks: [], startedDate: nil)
        let idBefore = DockerContainerID.hexId(for: container)

        try await withRoute(
            containers: [container],
            recreate: { store, configuration in
                await recorder.recordCreate(configuration)
                await store.add(configuration)
            }
        ) { app, store in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web-old") { res async in
                #expect(res.status == .noContent)
            }
            let renamed = await store.get("web-old")
            #expect(renamed.map(DockerContainerID.hexId(for:)) == idBefore, "the id must not change with the name")
        }

        // Nothing to redirect: clients holding the id still reach the container natively.
        #expect(await ContainerRenameMap.shared.nativeId(forRetiredHexId: idBefore) == nil)
        #expect(await recorder.created?.labels[DockerContainerID.idLabel] == storedId)
    }

    @Test("The replacement gets a hostname of its own, since the original still holds its own")
    func replacementGetsAFreshHostname() async throws {
        let recorder = RenameRecorder()
        var configuration = Self.snapshot(id: "web", status: .stopped).configuration
        configuration.networks = [AttachmentConfiguration(network: "demo", options: AttachmentOptions(hostname: "web-abc123"))]
        let container = ContainerSnapshot(configuration: configuration, status: .stopped, networks: [], startedDate: nil)

        try await withRoute(
            containers: [container],
            recreate: { store, configuration in
                await recorder.recordCreate(configuration)
                await store.add(configuration)
            }
        ) { app, _ in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web-old") { res async in
                #expect(res.status == .noContent)
            }
        }

        let hostname = await recorder.created?.networks.first?.options.hostname
        #expect(hostname != "web-abc123", "copying the retired container's hostname is what the runtime rejects")
        #expect(hostname?.hasPrefix("web-old-") == true, "the hostname follows the new name, as in Docker")
        #expect(await recorder.created?.networks.first?.network == "demo", "the attachment itself is preserved")
    }

    @Test("A failed create leaves the original alone rather than half-renaming it")
    func failedRecreateIsReported() async throws {
        try await withRoute(
            containers: [Self.snapshot(id: "web", status: .stopped)],
            recreate: { _, _ in throw RenameFailure() }
        ) { app, _ in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web-old") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("Failed to rename container"))
            }
        }
    }

    @Test("A delete that fails leaves the container alone: no replacement is created")
    func failedDeleteAbortsBeforeCreating() async throws {
        let recorder = RenameRecorder()

        try await withRoute(
            containers: [Self.snapshot(id: "web", status: .stopped)],
            refusesDelete: true,
            recreate: { store, configuration in
                await recorder.recordCreate(configuration)
                await store.add(configuration)
            }
        ) { app, store in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web-old") { res async in
                #expect(res.status == .internalServerError)
            }
            #expect(await store.names() == ["web"], "the container must survive a failed rename")
        }

        #expect(await recorder.created == nil, "nothing may be created while the original still exists")
    }

    @Test("A create that fails puts the container back under the name the client still knows")
    func failedRecreateRestoresTheOriginal() async throws {
        let attempts = RenameRecorder()

        try await withRoute(
            containers: [Self.snapshot(id: "web", status: .stopped)],
            recreate: { store, configuration in
                // The rename attempt fails; the rollback recreates the original and must succeed.
                if configuration.id == "web-old" {
                    await attempts.recordCreate(configuration)
                    throw RenameFailure()
                }
                await store.add(configuration)
            }
        ) { app, store in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web-old") { res async in
                #expect(res.status == .internalServerError)
            }
            #expect(await store.names() == ["web"], "a failed rename must not leave the container deleted")
        }

        #expect(await attempts.created?.id == "web-old")
    }

    @Test("Renaming to a name already in use is a conflict, as in Docker")
    func nameConflictIsRejected() async throws {
        let containers = [Self.snapshot(id: "web", status: .stopped), Self.snapshot(id: "taken", status: .stopped)]
        try await withRoute(containers: containers) { app, _ in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=taken") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("already in use"))
            }
        }
    }

    @Test("A running container is refused, because recreating it would kill the process")
    func runningContainerIsRefused() async throws {
        try await withRoute(containers: [Self.snapshot(id: "web", status: .running)]) { app, _ in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web-old") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("stop it first"))
            }
        }
    }

    @Test("An unknown container is a 404")
    func unknownContainerIsNotFound() async throws {
        try await withRoute(containers: []) { app, _ in
            try await app.testing().test(.POST, "/v1.51/containers/ghost/rename?name=whatever") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("A missing name is rejected before anything is touched")
    func missingNameIsRejected() async throws {
        try await withRoute(containers: [Self.snapshot(id: "web", status: .stopped)]) { app, _ in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Renaming a container to its current name succeeds without recreating it")
    func renameToSameNameIsANoOp() async throws {
        try await withRoute(containers: [Self.snapshot(id: "web", status: .stopped)]) { app, _ in
            try await app.testing().test(.POST, "/v1.51/containers/web/rename?name=web") { res async in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("A leading slash on the requested name is accepted, as Docker hands names out that way")
    func leadingSlashIsStripped() async throws {
        let containers = [Self.snapshot(id: "web", status: .stopped), Self.snapshot(id: "taken", status: .stopped)]
        try await withRoute(containers: containers) { app, _ in
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

/// Holds the container set the way the runtime does, so a rename is observable: the replacement
/// becomes queryable and the original stops being. An immutable list would let a route that created
/// nothing, or deleted nothing, still pass.
private actor RenameContainerStore {
    private var containers: [ContainerSnapshot]
    private let refusesDelete: Bool

    init(containers: [ContainerSnapshot], refusesDelete: Bool) {
        self.containers = containers
        self.refusesDelete = refusesDelete
    }

    func all() -> [ContainerSnapshot] { containers }
    func get(_ id: String) -> ContainerSnapshot? { containers.first { $0.id == id } }

    func add(_ configuration: ContainerConfiguration) {
        containers.append(ContainerSnapshot(configuration: configuration, status: .stopped, networks: [], startedDate: nil))
    }

    func remove(_ id: String) throws {
        if refusesDelete { throw RenameFailure() }
        containers.removeAll { $0.id == id }
    }

    func names() -> [String] { containers.map(\.id).sorted() }
}

private struct RenameMock: ClientContainerProtocol {
    let store: RenameContainerStore

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { await store.all() }
    func getContainer(id: String) async throws -> ContainerSnapshot? { await store.get(id) }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws { try await store.remove(id) }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

/// Captures what the route asked the runtime to do, so the success path is asserted on the
/// configuration that would have been created rather than on a live daemon.
private actor RenameRecorder {
    private(set) var created: ContainerConfiguration?
    private(set) var discarded: String?

    func recordCreate(_ configuration: ContainerConfiguration) {
        created = configuration
    }

    func recordDiscard(_ name: String) {
        discarded = name
    }
}

private struct RenameFailure: Error {}
