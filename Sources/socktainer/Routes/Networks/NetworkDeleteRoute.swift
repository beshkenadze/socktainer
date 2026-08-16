import ContainerAPIClient
import Vapor

struct NetworkDeleteRoute: RouteCollection {
    let client: ClientNetworkProtocol
    /// Injectable so a test can prove the answer arrives without waiting out the real bound.
    var bound: Duration = WedgedNetworkRemoval.bound

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/networks/{id}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let logger = req.logger
        guard let id = req.parameters.get("id") else {
            logger.warning("Missing network id parameter")
            throw Abort(.badRequest, reason: "Missing network id parameter")
        }
        let client = self.client
        let dnsManager = req.application.storage[NetworkDNSManagerKey.self]
        let broadcaster = req.application.storage[EventBroadcasterKey.self]

        do {
            let removed = try await WedgedNetworkRemoval.bounded(within: bound) { () -> (id: String, name: String, driver: String) in
                // Resolve the network before deletion: getNetwork matches an exact Id or Name and
                // returns the canonical Id, Name and Driver, so the request maps to the real network
                // for DNS cleanup and the destroy event (moby network events include {name, type}).
                let summary = try? await client.getNetwork(id: id, logger: logger)
                let resolvedId = summary?.Id ?? id

                // Remove the DNS forwarder sidecar BEFORE deleting the network —
                // the network can't be deleted while the DNS container is still attached.
                if let dnsManager {
                    await dnsManager.cleanupDNSContainer(networkId: resolvedId)
                }
                try await client.delete(id: resolvedId, logger: logger)
                return (resolvedId, summary?.Name ?? id, summary?.Driver ?? "nat")
            }

            if let broadcaster {
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "network", action: "destroy", actorID: removed.id,
                        attributes: ["name": removed.name, "type": removed.driver]))
            }
            return Response(status: .noContent)
        } catch is WedgedNetworkRemoval.TimedOut {
            logger.error("network removal did not return", metadata: ["network": "\(id)"])
            throw Abort(
                .internalServerError,
                reason: WedgedNetworkRemoval.message(network: id, observed: .noAnswerWithin(bound)))
        } catch {
            // `localizedDescription` on a plain Swift error is the runtime's own boilerplate — "The
            // operation couldn't be completed. (… error 1.)" — not the message the daemon wrote, so
            // matching against it never fired. `ContainerizationError` prints through
            // CustomStringConvertible instead, and its wording is the camel-cased case name:
            // measured, a missing network arrives here as `notFound: "no network for id app_default"`
            // and was answered 500 rather than 404 for exactly this reason.
            let described = String(describing: error)
            if described.contains("notFound") || described.localizedCaseInsensitiveContains("not found") {
                throw Abort(.notFound, reason: "network \(id) not found")
            }
            if WedgedNetworkRemoval.isPendingOperation(described) {
                throw Abort(
                    .internalServerError,
                    reason: WedgedNetworkRemoval.message(network: id, observed: .daemonReportedPendingOperation))
            }
            throw Abort(.internalServerError, reason: "Network deletion failed: \(error)")
        }
    }
}
