import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// F-009 and F-010 through the routes.
@Suite(.timeLimit(.minutes(1))) struct SessionRoutesTests {
    typealias H = SessionRouteHarness

    private func call(_ app: Application, _ method: HTTPMethod, _ path: String) async throws -> (HTTPStatus, ByteBuffer) {
        var answer: (HTTPStatus, ByteBuffer) = (.ok, ByteBuffer())
        try await app.testing().test(method, path) { res in answer = (res.status, res.body) }
        return answer
    }

    private func started(_ app: Application, _ client: FakeSharedRuntimeClient) async throws -> (String, FakeSharedRuntimeClient.Program) {
        let id = try await H.createSession(app, name: "srv")
        #expect(try await call(app, .POST, "/containers/\(id)/start").0 == .noContent)
        return (id, await client.waitForProgram(id))
    }

    @Test func inspectShowsTheSessionWithoutEnvironmentValues() async throws {
        try await H.withApp { app, _ in
            let id = try await H.createSession(app, name: "srv") { $0["Env"] = ["TOKEN=s3cr3t-value"] }
            let (status, body) = try await call(app, .GET, "/containers/srv/json")
            #expect(status == .ok)
            let text = String(buffer: body)
            #expect(!text.contains("s3cr3t-value"))
            let inspect = try JSONDecoder().decode(RESTContainerInspect.self, from: Data(buffer: body))
            #expect(inspect.Id == id)
            #expect(inspect.Name == "/srv")
            #expect(inspect.State.Status == "created")
            #expect(inspect.Config.Labels?[SharedRuntimeLabels.sessionGroup] == "mcp-catalog")
            #expect(text.contains(#""AutoRemove":true"#), "a session is removed when it ends")
        }
    }

    @Test func listShowsTheSessionWithItsLabels() async throws {
        let client = FakeSharedRuntimeClient()
        try await H.withApp(client: client) { app, _ in
            let (id, _) = try await started(app, client)
            let (_, body) = try await call(app, .GET, "/containers/json?filters=%7B%22label%22%3A%5B%22containerstack.session.group%3Dmcp-catalog%22%5D%7D")
            let list = try JSONDecoder().decode([RESTContainerSummary].self, from: Data(buffer: body))
            #expect(list.map(\.Id) == [id])
            #expect(list.first?.State == "running")
            let container = try #require(await client.state.created.first)
            #expect(list.first?.Labels[SharedRuntimeLabels.sessionContainer] == container.dockerID)
        }
    }

    @Test func routesOutsideTheListAnswer409AndOtherIDsGoToMain() async throws {
        try await H.withApp { app, _ in
            let id = try await H.createSession(app, name: "srv")
            let exec = try await call(app, .POST, "/containers/\(id)/exec")
            #expect(exec.0 == .conflict && String(buffer: exec.1).contains("not supported for a session of a shared group"))
            let archive = try await call(app, .GET, "/containers/srv/archive?path=/")
            #expect(archive.0 == .conflict)
            let other = try await call(app, .GET, "/containers/somebody-else/archive?path=/")
            #expect(String(buffer: other.1) == "archive of main")
        }
    }

    @Test func aReferenceThatOnlyPrefixesASessionIDGoesToADedicatedContainerOfThatName() async throws {
        let dedicated = H.DedicatedNames()
        try await H.withApp(containers: dedicated) { app, _ in
            let id = try await H.createSession(app, name: "srv")
            let prefix = String(id.prefix(4))
            await dedicated.add(prefix)
            await dedicated.add(id)
            await dedicated.add("srv")
            #expect(String(buffer: try await call(app, .GET, "/containers/\(prefix)/archive?path=/").1) == "archive of main")
            #expect(try await call(app, .GET, "/containers/\(id)/archive?path=/").0 == .conflict, "a full session ID stays the session")
            #expect(try await call(app, .GET, "/containers/srv/archive?path=/").0 == .conflict, "a session name stays the session")
        }
    }

    @Test func networkConnectAndDisconnectOfASessionAnswer409() async throws {
        try await H.withApp { app, _ in
            let id = try await H.createSession(app, name: "srv")
            for action in ["connect", "disconnect"] {
                for (container, expected) in [(id, HTTPStatus.conflict), ("srv", .conflict), ("somebody-else", .ok)] {
                    try await app.testing().test(
                        .POST, "/networks/default/\(action)",
                        beforeRequest: { req in
                            req.headers.contentType = .json
                            req.body = ByteBuffer(string: #"{"Container":"\#(container)"}"#)
                        }, afterResponse: { res in #expect(res.status == expected, "\(action) \(container)") })
                }
            }
        }
    }

    @Test func aPrefixThatIsAmbiguousAmongDedicatedContainersDoesNotReachTheSession() async throws {
        let dedicated = H.DedicatedNames()
        let client = FakeSharedRuntimeClient()
        try await H.withApp(client: client, containers: dedicated) { app, _ in
            let (id, _) = try await started(app, client)
            let prefix = String(id.prefix(4))
            await dedicated.addAmbiguous(prefix)
            let (status, _) = try await call(app, .POST, "/containers/\(prefix)/kill")
            #expect(status != .noContent, "the ambiguity is the answer")
            #expect(await client.state.signals.isEmpty, "the session got no signal")
        }
    }

    @Test func aDedicatedContainerCannotTakeTheNameOfASession() async throws {
        let dedicated = H.DedicatedNames()
        try await H.withApp(containers: dedicated) { app, _ in
            _ = try await H.createSession(app, name: "taken")
            await dedicated.add("ordinary")
            for name in ["taken", "/taken"] {
                let (status, body) = try await call(app, .POST, "/containers/ordinary/rename?name=\(name)")
                #expect(status == .conflict && String(buffer: body).contains("already in use"), "\(name)")
            }
        }
    }

    @Test func aCreatedSessionWhoseClientLeftStaysCreatedHoldsNothingAndIsRemoved() async throws {
        let client = FakeSharedRuntimeClient()
        try await H.withApp(client: client) { app, service in
            let manager = await try #require(service).manager
            let id = try await H.createSession(app, name: "left")
            let session = try #require(await manager.session(id))
            await manager.expectAttach(session)
            let pair = try await SessionTestChannel.make()
            let stream = SessionStream(channel: pair.server, probeInterval: .milliseconds(50)) {
                Task { await manager.attachDisconnected(session) }
            }
            await manager.bindAttach(session, stream: stream, stdin: DockerTCPHandler(execId: "x", ttyEnabled: false))
            await pair.close()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while session.pendingSignals.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

            #expect(!pair.server.isActive, "the hijacked connection is closed")
            #expect(await client.state.created.isEmpty, "no shared container, so no VM")
            let (_, body) = try await call(app, .GET, "/containers/json?all=1")
            let list = try JSONDecoder().decode([RESTContainerSummary].self, from: Data(buffer: body))
            #expect(list.first { $0.Id == id }?.State == "created")
            #expect(try await call(app, .DELETE, "/containers/left").0 == .noContent)
            #expect(await manager.session(id) == nil)
        }
    }

    @Test func killStopAndRemove() async throws {
        let client = FakeSharedRuntimeClient()
        try await H.withApp(client: client) { app, _ in
            let created = try await H.createSession(app, name: "idle")
            #expect(try await call(app, .POST, "/containers/\(created)/kill").0 == .conflict)
            #expect(try await call(app, .POST, "/containers/\(created)/stop").0 == .notModified)
            #expect(try await call(app, .DELETE, "/containers/idle").0 == .noContent)
            #expect(try await call(app, .GET, "/containers/idle/json").0 == .notFound)

            let (id, program) = try await started(app, client)
            #expect(try await call(app, .POST, "/containers/\(id)/kill?signal=SIGSTOP").0 == .badRequest)
            #expect(try await call(app, .POST, "/containers/\(id)/kill?signal=SIGUSR1").0 == .noContent)
            #expect(try await call(app, .DELETE, "/containers/\(id)").0 == .conflict)
            Task {
                await client.waitUntil { $0.signals.last?.signal == "36" }
                program.exit(137)
            }
            #expect(try await call(app, .DELETE, "/containers/\(id)?force=1").0 == .noContent)
            #expect(await client.state.signals.map(\.signal) == ["SIGUSR1", "36"])
        }
    }

    @Test func logsKeepWholeRecordsWithTheirStreams() async throws {
        let client = FakeSharedRuntimeClient()
        try await H.withApp(client: client) { app, service in
            let (id, program) = try await started(app, client)
            let line = String(repeating: "x", count: 1023) + "\n"
            for index in 0..<300 {
                if index.isMultiple(of: 2) { program.write(stdout: line) } else { program.write(stderr: line) }
            }
            program.write(stdout: "end-out\n")
            program.write(stderr: "end-err\n")
            let session = try #require(await service?.manager.session(id))
            let markers = [Data("end-out\n".utf8), Data("end-err\n".utf8)]
            while !markers.allSatisfy({ marker in session.io.logRecords(stdout: true, stderr: true, tail: nil).contains { $0.data == marker } }) {
                await Task.yield()
            }

            let buffered = session.io.logRecords(stdout: true, stderr: true, tail: nil)
            #expect(buffered.reduce(0) { $0 + $1.data.count } <= SessionLogBuffer.capacity)
            let both = RawSocketClient.frames(Array(buffer: try await call(app, .GET, "/containers/\(id)/logs?stdout=1&stderr=1").1))
            #expect(both.map { Data($0.1) } == buffered.map(\.data), "every record whole and in order")
            #expect(both.map(\.0) == buffered.map(\.stream.rawValue))
            #expect(Set(both.map(\.0)) == [1, 2])
            let errors = RawSocketClient.frames(Array(buffer: try await call(app, .GET, "/containers/\(id)/logs?stderr=1").1))
            #expect(errors.allSatisfy { $0.0 == 2 })
            #expect(errors.count == buffered.filter { $0.stream == .stderr }.count)
            let tail = RawSocketClient.frames(Array(buffer: try await call(app, .GET, "/containers/\(id)/logs?stdout=1&tail=3").1))
            #expect(tail.count == 3 && tail.allSatisfy { $0.0 == 1 })
            #expect(try await call(app, .GET, "/containers/\(id)/logs").0 == .badRequest)
        }
    }
}
