import Vapor

struct NetworkDisconnectRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/{id}/disconnect", use: NetworkConnectRoute.handler(client: client))
    }
}
