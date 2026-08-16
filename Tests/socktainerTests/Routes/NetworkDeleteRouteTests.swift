import ContainerResource
import ContainerizationExtras
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `DELETE /networks/{id}` against a runtime whose vmnet helper has died.
///
/// Measured on a disposable runtime (ContainerStack `scripts/verify-stage0-remedies.sh pending`): the
/// removal does not fail, it stops answering — two attempts, 120s of client patience each, nothing
/// back. The bridge still served `_ping` and `ps` throughout, so the request does reach this route; it
/// is this one operation that never returns. Restarting the runtime made the same network deletable
/// at once, which is the remedy the answer has to carry.
@Suite("NetworkDeleteRoute — a removal that cannot finish")
struct NetworkDeleteRouteTests {

    @Test("a removal that never returns is answered, with the remedy in the body")
    func boundedRemovalAnswers() async throws {
        let client = HangingNetworkClient()
        try await withDeleteRouteApp(client: client, bound: .milliseconds(200)) { app in
            try await app.testing().test(.DELETE, "/v1.51/networks/app_default") { res async in
                #expect(res.status == .internalServerError)
                let body = res.body.string
                #expect(body.contains("app_default"))
                #expect(body.contains("did not answer within"))
                #expect(body.contains("restart the runtime"))
            }
        }
    }

    @Test("Apple's own busy-network refusal is explained rather than passed through raw")
    func pendingOperationIsExplained() async throws {
        let client = PendingOperationNetworkClient()
        try await withDeleteRouteApp(client: client) { app in
            try await app.testing().test(.DELETE, "/v1.51/networks/app_default") { res async in
                #expect(res.status == .internalServerError)
                let body = res.body.string
                #expect(body.contains("unfinished operation"))
                #expect(body.contains("restart the runtime"))
                #expect(!body.contains("has a pending operation"), "the raw wording carries no way out")
            }
        }
    }

    @Test("a healthy removal still returns 204 and is not slowed down")
    func healthyRemovalIsUntouched() async throws {
        let client = WorkingNetworkClient()
        try await withDeleteRouteApp(client: client) { app in
            try await app.testing().test(.DELETE, "/v1.51/networks/app_default") { res async in
                #expect(res.status == .noContent)
            }
        }
        #expect(client.deleted == ["app_default"])
    }

    @Test("a network that is not there is still a 404, not a diagnosis")
    func missingNetworkStaysNotFound() async throws {
        let client = NotFoundNetworkClient()
        try await withDeleteRouteApp(client: client) { app in
            try await app.testing().test(.DELETE, "/v1.51/networks/app_default") { res async in
                #expect(res.status == .notFound)
                #expect(!res.body.string.contains("restart the runtime"))
            }
        }
    }
}

private func withDeleteRouteApp(
    client: ClientNetworkProtocol,
    bound: Duration = WedgedNetworkRemoval.bound,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: NetworkDeleteRoute(client: client, bound: bound))
        try await test(app)
    }
}

private struct PendingOperation: Error, CustomStringConvertible {
    var description: String { "network app_default has a pending operation" }
}

private struct NoSuchNetwork: Error, CustomStringConvertible {
    var description: String { "no network for id app_default: not found" }
}

/// The measured shape: the call is accepted and never comes back.
private final class HangingNetworkClient: ClientNetworkProtocol, @unchecked Sendable {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? { nil }
    func delete(id: String, logger: Logger) async throws {
        try await Task.sleep(for: .seconds(600))
    }
    func create(
        name: String,
        labels: [String: String],
        ipv4Subnet: String?,
        logger: Logger
    ) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}

private final class PendingOperationNetworkClient: ClientNetworkProtocol, @unchecked Sendable {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? { nil }
    func delete(id: String, logger: Logger) async throws { throw PendingOperation() }
    func create(
        name: String,
        labels: [String: String],
        ipv4Subnet: String?,
        logger: Logger
    ) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}

private final class NotFoundNetworkClient: ClientNetworkProtocol, @unchecked Sendable {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? { nil }
    func delete(id: String, logger: Logger) async throws { throw NoSuchNetwork() }
    func create(
        name: String,
        labels: [String: String],
        ipv4Subnet: String?,
        logger: Logger
    ) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}

private final class WorkingNetworkClient: ClientNetworkProtocol, @unchecked Sendable {
    private(set) var deleted: [String] = []
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? { nil }
    func delete(id: String, logger: Logger) async throws { deleted.append(id) }
    func create(
        name: String,
        labels: [String: String],
        ipv4Subnet: String?,
        logger: Logger
    ) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}
