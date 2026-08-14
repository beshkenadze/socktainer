import Foundation
import Vapor

struct RESTNetworksListQuery: Content {
    let filters: String?
}

extension Response {
    /// Docker serves JSON bodies with `Content-Type: application/json`; clients
    /// and proxies that sniff the content type cannot treat a bare `Response`
    /// as JSON. All routes returning a JSON payload build it through this.
    static func json(_ data: Data, status: HTTPResponseStatus = .ok) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}

struct NetworkListRoute: RouteCollection {
    let client: ClientNetworkProtocol

    init(client: ClientNetworkProtocol = ClientNetworkService()) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/networks", use: handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let query = try req.query.decode(RESTNetworksListQuery.self)
        let filtersParam = query.filters

        let parsedFilters = try DockerNetworkFilterUtility.parseNetworkFilters(filtersParam: filtersParam, defaultDangling: false, logger: req.logger)

        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)

        do {
            let networks = try await client.list(filters: filtersJSONString, logger: req.logger)
            return .json(try JSONEncoder().encode(networks))
        } catch {
            throw Abort(.internalServerError, reason: "Failed to list networks: \(error)")
        }
    }
}
