import Vapor

struct NetworkDisconnectRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id}/disconnect", use: NetworkDisconnectRoute.handler)
    }

    // This route changes no container. When it gets an effect on a container, it must
    // refuse a cluster node first (ClusterNodeGuard).
    static func handler(_ req: Request) async throws -> Response {
        Response(status: .ok)
    }
}
