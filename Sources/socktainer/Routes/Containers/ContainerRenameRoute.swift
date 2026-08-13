import ContainerAPIClient
import ContainerResource
import Vapor

/// `POST /containers/{id}/rename`.
///
/// Apple Container has no rename: a container's id *is* its name, and the client API offers only
/// create/get/list/bootstrap/start/stop/kill/delete. So this recreates the container under the new
/// name from its own configuration and deletes the original. Everything the configuration carries —
/// image, command, environment, labels, mounts, published ports, networks, resources — survives;
/// the previous run's logs and exit code do not, because they belong to the container that was
/// replaced.
///
/// `docker compose up` on a changed service depends on this route: Compose stops the old container,
/// renames it aside, creates the replacement under the canonical name, then deletes the moved-aside
/// one. Without rename, editing a service's ports or volumes fails at the recreate step.
struct ContainerRenameRoute: RouteCollection {
    let client: ClientContainerProtocol

    init(client: ClientContainerProtocol) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/rename", use: ContainerRenameRoute.handler(client: client))
    }

    struct RenameQuery: Content {
        let name: String?
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
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

            let containerClient = ContainerClient()
            do {
                let kernel = try await ClientKernel.getDefaultKernel(for: .current)
                try await containerClient.create(configuration: configuration, options: .default, kernel: kernel)
            } catch {
                req.logger.error("Failed to recreate \(container.id) as \(newName): \(error)")
                throw Abort(.internalServerError, reason: "Failed to rename container: \(error)")
            }

            do {
                try await client.delete(id: container.id)
            } catch {
                // The replacement exists, so leaving the original behind would double the name in
                // every listing. Roll back to the state the client asked us to change.
                req.logger.error("Failed to delete \(container.id) after recreating it as \(newName): \(error)")
                try? await containerClient.delete(id: newName, force: true)
                throw Abort(.internalServerError, reason: "Failed to rename container: \(error)")
            }

            let renamed = try await client.getContainer(id: newName)
            await ContainerRenameMap.shared.record(
                retiredHexId: retiredHexId,
                previousNativeId: container.id,
                nativeId: newName
            )
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

    /// Moves the bookkeeping that is keyed by container identity: DNS aliases, the info cache the
    /// event paths read, and the restart-policy lifecycle. The recreated container is a different
    /// container to everything downstream, so nothing carries over on its own.
    private static func transferSideState(
        from previous: ContainerSnapshot,
        to renamed: ContainerSnapshot?,
        newName: String,
        req: Request
    ) async {
        let dnsServer = req.application.storage[SocktainerDNSServerKey.self]
        if let dnsServer {
            ContainerAliasCleanup.unregisterAllAliases(
                nativeId: previous.id,
                labels: previous.configuration.labels,
                cachedIP: nil,
                dnsServer: dnsServer
            )
        }

        await ContainerInfoCache.shared.remove(id: DockerContainerID.hexId(for: previous))
        await ContainerRestartState.shared.reset(id: previous.id)

        guard let renamed else { return }
        await ContainerInfoCache.shared.set(
            hexId: DockerContainerID.hexId(for: renamed),
            nativeId: newName,
            image: renamed.configuration.image.reference,
            labels: renamed.configuration.labels,
            ip: nil
        )
    }
}
