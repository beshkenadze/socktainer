import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("NotImplementedStatus")
struct NotImplementedStatusTests {

    @Test("NotImplemented.respond returns 501 with a JSON message")
    func helperPinned() throws {
        let res = NotImplemented.respond("/x", "POST")
        #expect(res.status == .notImplemented)
        #expect(res.headers[.contentType].first == "application/json")
        let text = try #require(res.body.string)
        let body = try JSONDecoder().decode(ErrorMessage.self, from: Data(text.utf8))
        #expect(!body.message.isEmpty)
    }

    @Test("AppleContainerNotSupported.respond returns 501 with a JSON message")
    func capabilityHelperPinned() throws {
        let res = AppleContainerNotSupported.respond("Pausing container")
        #expect(res.status == .notImplemented)
        #expect(res.headers[.contentType].first == "application/json")
        let text = try #require(res.body.string)
        let body = try JSONDecoder().decode(ErrorMessage.self, from: Data(text.utf8))
        #expect(!body.message.isEmpty)
    }

    @Test("POST /containers/{id}/unpause returns 501 with a JSON message")
    func unpause() async throws {
        try await withNotImplementedApp { app in
            try await app.testing().test(.POST, "/v1.51/containers/web/unpause") { res async throws in
                #expect(res.status == .notImplemented)
                #expect(res.headers[.contentType].first == "application/json")
                let body = try JSONDecoder().decode(ErrorMessage.self, from: Data(buffer: res.body))
                #expect(!body.message.isEmpty)
            }
        }
    }

    @Test("POST /containers/{id}/pause returns 501 with a JSON message")
    func pause() async throws {
        try await withNotImplementedApp { app in
            try await app.testing().test(.POST, "/v1.51/containers/web/pause") { res async throws in
                #expect(res.status == .notImplemented)
                #expect(res.headers[.contentType].first == "application/json")
                let body = try JSONDecoder().decode(ErrorMessage.self, from: Data(buffer: res.body))
                #expect(!body.message.isEmpty)
            }
        }
    }
}

private func withNotImplementedApp(
    _ test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: ContainerPauseRoute())
        try app.register(collection: ContainerUnpauseRoute())
        try await test(app)
    }
}

private struct ErrorMessage: Decodable {
    let message: String
}
