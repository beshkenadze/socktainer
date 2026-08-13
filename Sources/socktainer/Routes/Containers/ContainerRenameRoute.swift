import ContainerAPIClient
import ContainerResource
import Vapor

/// Apple Container has no rename: a container's id *is* its name, and the client API offers only
/// create/get/list/bootstrap/start/stop/kill/delete. So this recreates the container under the new
/// name from its own configuration and deletes the original. Everything the configuration carries —
/// image, command, environment, labels, mounts, published ports, networks, resources — survives.
///
/// What a Docker rename would keep and this cannot, because the runtime offers no way to move a
/// container's storage or history to another id:
/// - the writable layer: files written inside the container outside a mount are gone; volumes and
///   bind mounts are unaffected, since they live outside the container;
/// - the previous run's logs and exit code;
/// - the Docker id: recreating derives a new one, so `inspect` after a rename reports a different
///   `Id`. `ContainerRenameMap` keeps the retired id *resolving* for the life of the daemon, which
///   is what clients holding the old id need, but it is in-memory and does not survive a restart.
///
/// `docker compose up` on a changed service depends on this route: Compose stops the old container,
/// renames it aside, creates the replacement under the canonical name, then deletes the moved-aside
/// one — which is deleted moments later, so nothing above is lost in that flow. Without rename,
/// editing a service's ports or volumes fails at the recreate step.
struct ContainerRenameRoute: RouteCollection {
    /// Creates the replacement container. Injected so the success path — which is the whole point
    /// of the route — can be exercised without an Apple Container daemon.
    typealias Recreate = @Sendable (ContainerConfiguration) async throws -> Void
    let client: ClientContainerProtocol
    let recreate: Recreate

    init(
        client: ClientContainerProtocol,
        recreate: Recreate? = nil
    ) {
        self.client = client
        self.recreate = recreate ?? { configuration in
            let kernel = try await ClientKernel.getDefaultKernel(for: .current)
            try await ContainerClient().create(configuration: configuration, options: .default, kernel: kernel)
        }
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST,
            pattern: "/containers/{id}/rename",
            use: ContainerRenameRoute.handler(client: client, recreate: recreate)
        )
    }

    struct RenameQuery: Content {
        let name: String?
    }

    static func handler(
        client: ClientContainerProtocol,
        recreate: @escaping Recreate
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let requestedName = try req.query.decode(RenameQuery.self).name?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let requestedName, !requestedName.isEmpty else {
                throw Abort(.badRequest, reason: "Neither the name nor the id was provided")
            }

            // Docker accepts a leading slash on names it hands out (`/web`), and clients feed
            // those straight back.
            let newName = ContainerNameUtility.sanitize(requestedName.hasPrefix("/") ? String(requestedName.dropFirst()) : requestedName)

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }

            if container.id == newName {
                // Renaming to the current name is a no-op in Docker, not a conflict.
                return Response(status: .noContent)
            }

            if try await client.getContainer(id: newName) != nil {
                throw Abort(.conflict, reason: "Conflict. The container name \"/\(newName)\" is already in use")
            }

            // A running container cannot be moved: recreating it means a new VM, which would kill
            // the process the client is renaming around. Compose stops before it renames, so its
            // recreate path is unaffected.
            guard container.status != .running else {
                throw Abort(
                    .conflict,
                    reason: "Cannot rename a running container: stop it first. Apple Container has no rename, "
                        + "so the container is recreated under the new name."
                )
            }

            let retiredHexId = DockerContainerID.hexId(for: container)
            var configuration = container.configuration
            configuration.id = newName
            // Apple Container refuses a create whose hostname is already taken, and the original
            // still holds its own until it is deleted — which happens only after the replacement
            // exists. A fresh unique hostname is minted exactly as the create route does, rather
            // than copying the retired container's: the copy is what the runtime rejects.
            let hostname = ContainerNameUtility.sanitize("\(newName)-\(UUID().uuidString.lowercased())")
            configuration.networks = configuration.networks.map { attachment in
                AttachmentConfiguration(
                    network: attachment.network,
                    options: AttachmentOptions(hostname: hostname, macAddress: nil, mtu: attachment.options.mtu)
                )
            }

            // The original goes first. Creating the replacement while it still exists would put two
            // containers on the same Docker ID — the id now travels with the configuration — so
            // every lookup by that id would be ambiguous and `docker ps` would list it twice. A
            // container that is briefly absent is a transient 404; two containers claiming one id
            // is wrong data.
            do {
                try await client.delete(id: container.id)
            } catch {
                req.logger.error("Failed to delete \(container.id) before recreating it as \(newName): \(error)")
                throw Abort(.internalServerError, reason: "Failed to rename container: \(error)")
            }

            do {
                try await recreate(configuration)
            } catch {
                // Nothing holds the container now, so put it back under the name the client still
                // thinks it has rather than leaving it deleted.
                req.logger.error("Failed to recreate \(container.id) as \(newName): \(error)")
                var rollback = container.configuration
                rollback.id = container.id
                try? await recreate(rollback)
                throw Abort(.internalServerError, reason: "Failed to rename container: \(error)")
            }

            let renamed = try? await client.getContainer(id: newName)
            let renamedHexId = renamed.map(DockerContainerID.hexId(for:))
                ?? DockerContainerID.hexId(nativeId: newName, createdAt: nil)
            // A container carrying its own Docker ID keeps it through the recreate, so there is
            // nothing to redirect. Comparing the ids rather than looking for the label also covers a
            // malformed label, which `hexId` ignores in favour of the derived form.
            if renamedHexId != retiredHexId {
                await ContainerRenameMap.shared.record(
                    retiredHexId: retiredHexId,
                    previousNativeId: container.id,
                    nativeId: newName
                )
            }
            await ContainerRenameRoute.transferSideState(
                from: container,
                to: renamed,
                newName: newName,
                req: req
            )

            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                let eventId = renamed.map { DockerContainerID.hexId(for: $0) } ?? retiredHexId
                var attributes = LabelNormalization.restore(configuration.labels)
                // moby's rename event carries the previous name so listeners can follow the
                // container across the change (daemon/rename.go).
                attributes["oldName"] = container.id
                await broadcaster.broadcast(
                    DockerEvent.simpleEvent(
                        id: eventId,
                        type: "container",
                        status: "rename",
                        image: configuration.image.reference,
                        name: newName,
                        labels: attributes
                    )
                )
            }

            return Response(status: .noContent)
        }
    }

    /// Moves the bookkeeping that is keyed by container identity: DNS aliases, healthchecks, the
    /// info cache the event paths read, and any runtime restart-policy override. The recreated
    /// container is a different container to everything downstream, so nothing carries over on its
    /// own — and anything left behind under the retired name is inherited by the *next* container
    /// to take that name, which for `compose up` is the replacement service.
    private static func transferSideState(
        from previous: ContainerSnapshot,
        to renamed: ContainerSnapshot?,
        newName: String,
        req: Request
    ) async {
        let retiredHexId = DockerContainerID.hexId(for: previous)
        // Read the cached IP before dropping the entry: alias cleanup is a no-op without it, and
        // the stale DNS names would keep answering for a container that no longer exists.
        let cached = await ContainerInfoCache.shared.get(id: retiredHexId)

        if let dnsServer = req.application.storage[SocktainerDNSServerKey.self] {
            ContainerAliasCleanup.unregisterAllAliases(
                nativeId: previous.id,
                labels: previous.configuration.labels,
                cachedIP: cached?.ip,
                dnsServer: dnsServer
            )
        }

        // The healthcheck loop is keyed by the container name, which the replacement service will
        // reuse; leaving it running makes the new container inherit the retired one's probe.
        await req.application.storage[HealthCheckManagerKey.self]?.stop(containerId: previous.id)

        // The exit code is filed under both ids. The name-keyed entry is scrubbed by every start
        // path, but the id-keyed one is only cleaned by the delete *route*, which a rename bypasses
        // by deleting through the client — so it would linger for the life of the daemon.
        await ContainerExitCodeStore.shared.remove(id: retiredHexId)

        // `previous.id` is the name being freed, and in Compose's recreate that is the *canonical*
        // service name — Compose renames the old container aside and gives the replacement the name
        // this container just gave up. Anything still keyed by it is inherited seconds later:
        //
        // - restart state: the replacement would start with the retired container's attempt count
        //   and generation, and its own exit observer would bail on the stale generation. This does
        //   cost the retired container a pending `die` when its observer has not fired yet, which is
        //   the lesser harm: that container is deleted moments later, while the replacement is the
        //   live service.
        // - die-event ownership: an open run left under this name would be *joined* by the
        //   replacement's `beginRun`, so a single `die` would have to cover two containers.
        await ContainerRestartState.shared.reset(id: previous.id)
        await DieEventOwnership.shared.forget(id: previous.id)

        guard let renamed else { return }
        let renamedHexId = DockerContainerID.hexId(for: renamed)

        // The cache entry has to be rewritten even when the id did not change: it carries the native
        // name, and a stale one makes the event paths report the retired name — and lets a delete of
        // this container clear state that by then belongs to whichever container took that name.
        if renamedHexId != retiredHexId {
            await ContainerInfoCache.shared.remove(id: retiredHexId)
            // A `docker update` override is filed under the Docker id; without moving it the
            // container silently reverts to its create-time restart policy.
            if let override = await RestartPolicyOverrideStore.shared.get(id: retiredHexId) {
                await RestartPolicyOverrideStore.shared.set(id: renamedHexId, policy: override)
                await RestartPolicyOverrideStore.shared.remove(id: retiredHexId)
            }
        }
        await ContainerInfoCache.shared.set(
            hexId: renamedHexId,
            nativeId: newName,
            image: renamed.configuration.image.reference,
            labels: renamed.configuration.labels,
            ip: cached?.ip
        )
    }
}
