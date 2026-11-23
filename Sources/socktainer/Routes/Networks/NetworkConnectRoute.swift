import Foundation
import Vapor

struct NetworkConnectRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id}/connect", use: NetworkConnectRoute.handler(client: client))
    }

    // Apple Container uses a single global hostname namespace, so all containers
    // can already reach each other without explicit network attachment.
    // Returning 200 lets Docker Compose proceed; inter-service DNS is handled
    // by the Socktainer DNS server via com.docker.compose.service label registration.
    // A node of a Kubernetes cluster is refused. Disconnect uses the same handler.
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            if let reference = try await container(req) {
                try ClusterNodeGuard.refuse(try? await client.getContainer(id: reference))
            }
            return Response(status: .ok)
        }
    }

    private struct Body: Decodable {
        let Container: String
    }

    /// The container of a network connect or disconnect, from the request body.
    static func container(_ req: Request) async throws -> String? {
        guard let body = try await req.body.collect(max: req.application.routes.defaultMaxBodySize.value).get() else { return nil }
        return try? JSONDecoder().decode(Body.self, from: body).Container
    }
}
