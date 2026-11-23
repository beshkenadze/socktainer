import Vapor

struct NetworkConnectRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id}/connect", use: NetworkConnectRoute.handler)
    }

    // Apple Container uses a single global hostname namespace, so all containers
    // can already reach each other without explicit network attachment.
    // Returning 200 lets Docker Compose proceed; inter-service DNS is handled
    // by the Socktainer DNS server via com.docker.compose.service label registration.
    // This route changes no container. When it gets an effect on a container, it must
    // refuse a cluster node first (ClusterNodeGuard).
    static func handler(_ req: Request) async throws -> Response {
        Response(status: .ok)
    }
}
