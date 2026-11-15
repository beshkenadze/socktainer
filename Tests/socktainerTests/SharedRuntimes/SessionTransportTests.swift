import Foundation
import Testing
import Vapor

@testable import socktainer

/// F-005 over the real HTTP transport on a Unix socket, in the order that the Docker CLI uses:
/// create, attach, wait?condition=removed, start.
@Suite(.timeLimit(.minutes(1))) struct SessionTransportTests {
    typealias H = SessionRouteHarness

    private func request(_ method: String, _ path: String, body: Data = Data()) -> [UInt8] {
        Array("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + Array(body)
    }

    private func text(_ client: RawSocketClient) -> String { String(decoding: client.received, as: UTF8.self) }

    @Test func theFourCallsInTheTracedOrderGiveTheExitCodeAndTheBytesBothWays() async throws {
        let client = FakeSharedRuntimeClient()
        try await H.withApp(client: client) { app, _ in
            let path = "/tmp/session-transport-\(UUID().uuidString.prefix(8)).sock"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try await app.server.start(address: .unixDomainSocket(path: path))

            let create = try await RawSocketClient.connect(path: path, group: app.eventLoopGroup)
            try await create.send(request("POST", "/v1.51/containers/create", body: try SharedRuntimeFixtures.body { $0["Image"] = SharedRuntimeFixtures.absentImage }))
            #expect(await create.waitUntil { String(decoding: $0.received, as: UTF8.self).contains("\"Id\"") })
            let created = try JSONDecoder().decode(RESTContainerCreate.self, from: Data(create.stream))
            #expect(text(create).hasPrefix("HTTP/1.1 201"))
            let id = created.Id

            let attach = try await RawSocketClient.connect(path: path, group: app.eventLoopGroup)
            try await attach.send(RawSocketClient.upgradeRequest(path: "/v1.51/containers/\(id)/attach?stream=1&stdin=1&stdout=1&stderr=1"))
            #expect(await attach.waitUntil { String(decoding: $0.received, as: UTF8.self).contains("\r\n\r\n") })
            #expect(text(attach).hasPrefix("HTTP/1.1 101"))

            let wait = try await RawSocketClient.connect(path: path, group: app.eventLoopGroup)
            try await wait.send(request("POST", "/v1.51/containers/\(id)/wait?condition=removed"))
            #expect(await wait.waitUntil { String(decoding: $0.received, as: UTF8.self).contains("\r\n\r\n") }, "the wait head arrives before start")
            #expect(text(wait).hasPrefix("HTTP/1.1 200"))

            let start = try await RawSocketClient.connect(path: path, group: app.eventLoopGroup)
            try await start.send(request("POST", "/v1.51/containers/\(id)/start"))
            #expect(await start.waitUntil { String(decoding: $0.received, as: UTF8.self).contains("\r\n\r\n") })
            #expect(text(start).hasPrefix("HTTP/1.1 204"))

            let program = await client.waitForProgram(id)
            try await attach.send(Array("hello".utf8))
            try await attach.halfClose()
            #expect(await program.readStdin() == Data("hello".utf8), "stdin reaches the program, then end of file")
            program.write(stdout: "answer\n")
            program.write(stderr: "warning\n")
            // The output is read before the exit, as a program writes before it exits.
            #expect(await attach.waitUntil { RawSocketClient.frames($0.stream).filter { !$0.1.isEmpty }.count == 2 })
            program.exit(7)

            #expect(await attach.waitUntil { $0.isClosed })
            // Each stream keeps its own order; there is no order between stdout and stderr.
            let frames = RawSocketClient.frames(attach.stream).filter { !$0.1.isEmpty }
            let text: (UInt8) -> String = { kind in frames.filter { $0.0 == kind }.map { String(decoding: $0.1, as: UTF8.self) }.joined() }
            #expect(text(1) == "answer\n")
            #expect(text(2) == "warning\n")
            #expect(await wait.waitUntil { String(decoding: $0.received, as: UTF8.self).contains("\"StatusCode\":7") })
            for connection in [create, attach, wait, start] { try? await connection.close() }
            await app.server.shutdown()
        }
    }

    @Test func aStartWithoutAttachEndsCleanly() async throws {
        let client = FakeSharedRuntimeClient()
        try await H.withApp(client: client) { app, service in
            let id = try await H.createSession(app)
            try await app.testing().test(.POST, "/containers/\(id)/start") { res in #expect(res.status == .noContent) }
            let program = await client.waitForProgram(id)
            #expect(await program.readStdin().isEmpty)
            let session = await service?.manager.session(id)
            program.exit(0)
            #expect(await session?.ended.wait() == 0)
            try await app.testing().test(.GET, "/containers/\(id)/json") { res in #expect(res.status == .notFound) }
        }
    }
}
