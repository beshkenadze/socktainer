import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct MockHealthCheckClient: ClientHealthCheckProtocol {
    func ping() async throws {}
}

/// Issue #10 — the bounded forms of GET /events must terminate like moby's getEvents
/// (api/server/router/system/system_routes.go). A bounded query against an empty
/// window legitimately returns an empty body — what a client can never tolerate is a
/// hang. The in-memory tester collects the whole response body, so a request that
/// never closes would stall the suite; the bounded tests therefore race the request
/// against a timeout and fail (rather than hang) on regression. History replay for
/// non-empty windows is covered by EventsHistoryRouteTests.
@Suite("GET /events — bounded forms terminate")
struct EventsRouteTests {

    private func withRoute(
        _ test: @escaping (Application, EventBroadcaster) async throws -> Void
    ) async throws {
        try await withApp(configure: { app in
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
        }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: EventsRoute(client: MockHealthCheckClient()))
            try await test(app, app.storage[EventBroadcasterKey.self]!)
        }
    }

    /// Performs a GET and fails (nil) instead of hanging when the route never closes
    /// the response — the observable symptom of issue #10.
    private func responseWithin(
        _ app: Application, _ path: String, timeout: TimeInterval = 5
    ) async throws -> TestingHTTPResponse? {
        let request = Task<TestingHTTPResponse?, Never> {
            try? await app.testing().sendRequest(.GET, path)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            request.cancel()
        }
        defer { timeoutTask.cancel() }
        return await request.value
    }

    // MARK: - Bounded shapes

    @Test("stream=false returns immediately with an empty body instead of following")
    func streamFalseTerminates() async throws {
        let past = Int(Date().timeIntervalSince1970) - 60
        try await withRoute { app, _ in
            let res = try await responseWithin(app, "/events?stream=false&since=\(past)")
            #expect(res != nil, "response never completed — stream=false must not follow")
            #expect(res?.status == .ok)
            #expect(res?.headers.first(name: "Content-Type")?.hasPrefix("application/json") == true)
            #expect(res?.body.string.isEmpty == true, "nothing matched the window, body must be empty")
        }
    }

    @Test("until in the past returns immediately with an empty body")
    func untilPastTerminates() async throws {
        let past = Int(Date().timeIntervalSince1970) - 60
        try await withRoute { app, _ in
            let res = try await responseWithin(app, "/events?since=\(past)&until=\(past + 30)")
            #expect(res != nil, "response never completed — a past until must close")
            #expect(res?.status == .ok)
            #expect(res?.body.string.isEmpty == true)
        }
    }

    @Test("until in the future streams until the deadline, then closes")
    func untilFutureClosesAtDeadline() async throws {
        try await withRoute { app, _ in
            let until = Date().timeIntervalSince1970 + 1.5
            let startedAt = Date()
            let res = try await responseWithin(app, "/events?until=\(until)", timeout: 10)
            let elapsed = Date().timeIntervalSince(startedAt)
            #expect(res != nil, "response never completed — a future until must close at its deadline")
            #expect(res?.status == .ok)
            // Closing early (the onlyPastEvents shortcut) would mean future bounds are
            // treated as past ones; closing only after the deadline proves the timer raced.
            #expect(elapsed >= 1.0, "closed after \(elapsed)s, deadline was 1.5s")
        }
    }

    // MARK: - Parameter validation

    @Test("since after until is rejected like moby's getEvents")
    func sinceAfterUntilRejected() async throws {
        try await withRoute { app, _ in
            let res = try await responseWithin(app, "/events?since=2000000000&until=1000000000")
            #expect(res?.status == .badRequest)
            #expect(
                res?.body.string.contains("cannot be after `until` time") == true,
                "moby's message identifies the offending pair, got: \(res?.body.string ?? "")"
            )
        }
    }

    @Test("a malformed timestamp is a 400, not a hang or a stream")
    func malformedTimestampRejected() async throws {
        try await withRoute { app, _ in
            let res = try await responseWithin(app, "/events?since=not-a-timestamp")
            #expect(res?.status == .badRequest)
        }
    }

    @Test("unix seconds, seconds.nanoseconds, and RFC3339 are all accepted")
    func acceptsAllTimestampFormats() async throws {
        try await withRoute { app, _ in
            let formats: [(String, String)] = [
                ("unix seconds", "1755427200"),
                ("seconds.nanoseconds", "1755427200.123456789"),
                ("RFC3339 Z", "2025-08-15T00:00:00Z"),
                ("RFC3339 offset", "2025-08-15T00:00:00%2B01:00"),
            ]
            for (name, since) in formats {
                let res = try await responseWithin(app, "/events?stream=false&since=\(since)")
                #expect(res?.status == .ok, "\(name) was rejected: \(res?.status ?? .none)")
            }
        }
    }

    @Test("fractional unix timestamps resolve sub-second precision")
    func fractionalUnixTimestampPrecision() async throws {
        let base: TimeInterval = 1_755_427_200
        #expect(
            try EventsRoute.parseEventTimestamp("1755427200.5")?.timeIntervalSince1970
                == base + 0.5
        )
        #expect(
            try EventsRoute.parseEventTimestamp("1755427200.000000001")?.timeIntervalSince1970
                == base + 1e-9
        )
        #expect(try EventsRoute.parseEventTimestamp(nil) == nil)
        #expect(try EventsRoute.parseEventTimestamp("") == nil)
    }

    // MARK: - Unbounded streaming still works (issue #2 regression guard)

    /// A raw TCP client with a read deadline: the in-memory tester cannot prove that
    /// headers arrive *before* the first event, because it only surfaces the fully
    /// collected body.
    private final class RawHTTPClient: @unchecked Sendable {
        private let fd: Int32

        init(port: Int) throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Abort(.internalServerError, reason: "socket() failed") }

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                close(fd)
                throw Abort(.internalServerError, reason: "connect() failed: \(errno)")
            }
        }

        func get(_ path: String) {
            let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
            _ = request.withCString { pointer in
                send(fd, pointer, strlen(pointer), 0)
            }
        }

        /// Reads once with a deadline. Empty data means EOF (server closed), nil means
        /// the deadline elapsed with nothing to read.
        func read(deadline: TimeInterval) -> Data? {
            var tv = timeval(tv_sec: Int(deadline), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let received = recv(fd, &buffer, buffer.count, 0)
            if received == 0 { return Data() }
            guard received > 0 else { return nil }
            return Data(buffer.prefix(received))
        }

        deinit { close(fd) }
    }

    private func withLiveServer(
        _ test: @escaping (Application, EventBroadcaster, Int) async throws -> Void
    ) async throws {
        try await withRoute { app, broadcaster in
            let port = 28_000 + Int.random(in: 0..<2_000)
            try await app.server.start(address: .hostname("127.0.0.1", port: port))
            try await test(app, broadcaster, port)
            await app.server.shutdown()
        }
    }

    @Test("unbounded /events flushes the head immediately, then streams live events")
    func unboundedStreamsAfterImmediateHeadFlush() async throws {
        try await withLiveServer { _, broadcaster, port in
            let client = try RawHTTPClient(port: port)
            client.get("/events?since=\(Int(Date().timeIntervalSince1970) - 60)")

            // No event has been broadcast and none is coming yet: bytes here can only
            // be the flushed head (status line + headers) — the behaviour #2 added and
            // this bounded rework must preserve.
            let head = client.read(deadline: 3)
            #expect(head != nil, "head was not flushed within 3s of an idle stream")
            #expect(
                String(data: head ?? Data(), encoding: .utf8)?.contains("200 OK") == true,
                "expected the HTTP head, got: \(String(data: head ?? Data(), encoding: .utf8) ?? "")"
            )

            await broadcaster.broadcast(
                DockerEvent.simpleEvent(id: "live-ctr", type: "container", status: "start"))

            let event = client.read(deadline: 3)
            let eventText = String(data: event ?? Data(), encoding: .utf8) ?? ""
            #expect(
                eventText.contains("\"Action\":\"start\"") && eventText.contains("live-ctr"),
                "live event was not streamed, got: \(eventText)"
            )
        }
    }

    @Test("a future until closes the real connection at the deadline")
    func untilFutureClosesLiveConnection() async throws {
        try await withLiveServer { _, _, port in
            let client = try RawHTTPClient(port: port)
            let deadline = 1.0
            let startedAt = Date()
            client.get("/events?until=\(Date().timeIntervalSince1970 + deadline)")

            let head = client.read(deadline: 3)
            #expect(head != nil && !(head ?? Data()).isEmpty, "head was not flushed")

            // Drain to EOF. The chunked terminator arrives as a read of its own, so "the next read
            // is empty" fails against a stream that closes correctly; EOF is the empty read that
            // ends the drain. Closing at once would mean a future bound was treated as a past one,
            // never closing is the bug being fixed — the deadline has to be both reached and kept.
            while let chunk = client.read(deadline: 3), !chunk.isEmpty {}
            let elapsed = Date().timeIntervalSince(startedAt)
            #expect(elapsed >= deadline, "closed after \(elapsed)s, deadline was \(deadline)s")
            #expect(elapsed < 3, "connection did not close at the deadline")
        }
    }
}
