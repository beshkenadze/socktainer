import Foundation
import Testing
import Vapor

@testable import socktainer

/// Docker's `ErrorResponse` has exactly one property, `message`, and its text names the object that
/// was not found (issue #18). Two separate promises:
///
/// - `error` and `reason` were Vapor's, not Docker's. A client round-tripping the body through a
///   strict decoder rejects the unknown keys.
/// - `Container not found` tells whoever reads the log nothing. `No such container: c2ada9df5af8`
///   tells them which one — the only detail that makes the message actionable.
@Suite("Docker error bodies")
struct DockerErrorBodyTests {
    private static func body(of response: Response) throws -> [String: Any] {
        let data = try #require(response.body.data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("an error body carries message and nothing else")
    func onlyMessage() throws {
        let response = DockerErrorMiddleware.makeDockerError(
            status: .notFound, message: "No such container: c2ada9df5af8")

        let json = try Self.body(of: response)
        #expect(json.keys.sorted() == ["message"])
        #expect(json["message"] as? String == "No such container: c2ada9df5af8")
        #expect(response.headers.first(name: .contentType) == "application/json")
    }

    @Test("Vapor's own keys are stripped from a rendered error")
    func stripsVaporKeys() throws {
        let rendered = Response(status: .badRequest)
        rendered.headers.replaceOrAdd(name: .contentType, value: "application/json")
        rendered.body = .init(
            data: try JSONSerialization.data(withJSONObject: [
                "error": true, "reason": "invalid filter 'notjson'", "message": "invalid filter 'notjson'",
            ]))

        let json = try Self.body(of: DockerErrorMiddleware.ensureMessageField(in: rendered))
        #expect(json.keys.sorted() == ["message"])
        #expect(json["message"] as? String == "invalid filter 'notjson'")
    }

    @Test("a body with only Vapor's keys still yields the message")
    func promotesReason() throws {
        let rendered = Response(status: .conflict)
        rendered.headers.replaceOrAdd(name: .contentType, value: "application/json")
        rendered.body = .init(
            data: try JSONSerialization.data(withJSONObject: ["error": true, "reason": "name already in use"]))

        let json = try Self.body(of: DockerErrorMiddleware.ensureMessageField(in: rendered))
        #expect(json.keys.sorted() == ["message"])
        #expect(json["message"] as? String == "name already in use")
    }

    @Test("a request that matches no route reads as page not found, as Docker says it")
    func unroutedRequest() throws {
        // Vapor's router raises a bare Abort(.notFound) whose reason is the HTTP status text. Docker
        // answers `page not found` (api/server/server.go), and every route that means "this object is
        // missing" now names the object, so nothing else lands on this text.
        let thrown = DockerErrorMiddleware.makeDockerError(status: .notFound, message: "Not Found")
        #expect(try Self.body(of: thrown)["message"] as? String == "page not found")

        let rendered = Response(status: .notFound)
        rendered.headers.replaceOrAdd(name: .contentType, value: "application/json")
        rendered.body = .init(
            data: try JSONSerialization.data(withJSONObject: ["error": true, "reason": "Not Found", "message": "Not Found"]))
        #expect(try Self.body(of: DockerErrorMiddleware.ensureMessageField(in: rendered))["message"] as? String == "page not found")
    }

    @Test("a named object keeps its name through the middleware")
    func keepsObjectName() throws {
        for message in ["No such container: c2ada9df5af8", "network br0 not found", "get data: no such volume"] {
            let json = try Self.body(of: DockerErrorMiddleware.makeDockerError(status: .notFound, message: message))
            #expect(json["message"] as? String == message)
        }
    }
}
