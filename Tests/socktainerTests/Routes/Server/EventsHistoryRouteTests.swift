import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct MockHealthCheckClient: ClientHealthCheckProtocol {
    func ping() async throws {}
}

/// Issue #6 — `GET /events?since=…&until=…` must return the events that happened in
/// the window, from the broadcaster's 256-entry ring, the way moby's getEvents writes
/// its buffered events before deciding whether to follow. The in-memory tester
/// collects the whole response body, so every test here proves both content and
/// termination: a request that never closes would stall the suite.
@Suite("GET /events — history replay")
struct EventsHistoryRouteTests {

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

    /// Decodes a JSONL /events body back through the real codables.
    private func events(from body: String) -> [DockerEvent] {
        body.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(DockerEvent.self, from: Data($0.utf8))
        }
    }

    // MARK: - History-only requests close with the matching window

    @Test("history-only replay returns the window's events in order and closes")
    func historyOnlyReplaysWindow() async throws {
        let base = EventHistoryFixture.base
        try await withRoute { app, broadcaster in
            let sequence = ["create", "start", "die", "destroy"]
            for (i, action) in sequence.enumerated() {
                await broadcaster.broadcast(EventHistoryFixture.event(action, at: base + UInt64(i) * 1_000_000))
            }

            let path =
                "/events?stream=false"
                + "&since=\(EventHistoryFixture.timestamp(base))"
                + "&until=\(EventHistoryFixture.timestamp(base + 10_000_000))"

            let res = try await app.testing().sendRequest(.GET, path)

            #expect(res.status == .ok)
            #expect(res.headers.first(name: "Content-Type")?.hasPrefix("application/json") == true)
            let replayed = events(from: res.body.string)
            #expect(replayed.map(\.Action) == sequence)
            let expectedIDs = (0..<sequence.count).map { "ctr-\(base + UInt64($0) * 1_000_000)" }
            #expect(replayed.map(\.id) == expectedIDs, "ids survive the replay")
        }
    }

    @Test("history-only replay excludes events outside the window")
    func historyOnlyExcludesOutside() async throws {
        let base = EventHistoryFixture.base
        try await withRoute { app, broadcaster in
            for (i, action) in ["create", "start", "die", "destroy"].enumerated() {
                await broadcaster.broadcast(EventHistoryFixture.event(action, at: base + UInt64(i) * 1_000_000))
            }

            let path =
                "/events?stream=false"
                + "&since=\(EventHistoryFixture.timestamp(base + 1_500_000))"
                + "&until=\(EventHistoryFixture.timestamp(base + 2_500_000))"

            let res = try await app.testing().sendRequest(.GET, path)
            let replayed = events(from: res.body.string)

            #expect(replayed.map(\.Action) == ["die"], "only the event inside [1.5ms, 2.5ms]")
        }
    }
    /// The boundary measured against dockerd 29.4.0 on the OrbStack socket
    /// (2026-08-15), with `since`/`until` set to an event's exact timeNano: the event
    /// at the boundary replayed for an equal bound and dropped one nanosecond beyond
    /// it — both bounds inclusive. The half-second boundary is exactly representable
    /// as a Date (verified to round-trip); the ±1ms probes stay on the exclusive
    /// side deterministically, since a Date wobbles only tens of nanoseconds on
    /// Darwin. The buffer persists across the three requests, so each sees the same
    /// two events.
    @Test("route honours the measured inclusive since/until boundaries")
    func routeHonoursMeasuredBoundaries() async throws {
        let base = EventHistoryFixture.base
        let boundary = base + 500_000_000
        try await withRoute { app, broadcaster in
            await broadcaster.broadcast(EventHistoryFixture.event("create", at: base))
            await broadcaster.broadcast(EventHistoryFixture.event("start", at: boundary))

            let equal = try await app.testing().sendRequest(
                .GET,
                "/events?stream=false&since=\(EventHistoryFixture.timestamp(boundary))"
                    + "&until=\(EventHistoryFixture.timestamp(boundary))"
            )
            #expect(events(from: equal.body.string).map(\.Action) == ["start"], "== since and == until both replay")

            let sinceBeyond = try await app.testing().sendRequest(
                .GET,
                "/events?stream=false&since=\(EventHistoryFixture.timestamp(boundary + 1_000_000))"
                    + "&until=\(EventHistoryFixture.timestamp(base + 1_000_000_000))"
            )
            #expect(sinceBeyond.body.string.isEmpty, "a bound past the boundary event drops it")

            let untilBefore = try await app.testing().sendRequest(
                .GET,
                "/events?stream=false&since=\(EventHistoryFixture.timestamp(base))"
                    + "&until=\(EventHistoryFixture.timestamp(boundary - 1_000_000))"
            )
            #expect(events(from: untilBefore.body.string).map(\.Action) == ["create"], "a bound before the boundary event drops it")
        }
    }

    // MARK: - Following requests: backlog then live, atomically

    /// A following request must deliver the backlog and the live stream as one
    /// continuous sequence. The third event is broadcast while the request is in
    /// flight — inside the window a split subscribe would either lose it (snapshot
    /// taken, registration pending) or duplicate it (registered first, snapshot
    /// retaken after). Whichever arm it lands in, the response must carry it exactly
    /// once, after the backlog, and the `until` deadline must still close the stream.
    @Test("following request gets backlog then live with no gap and no duplicate")
    func followingGetsBacklogThenLive() async throws {
        let base = EventHistoryFixture.base
        try await withRoute { app, broadcaster in
            await broadcaster.broadcast(EventHistoryFixture.event("create", at: base))
            await broadcaster.broadcast(EventHistoryFixture.event("start", at: base + 1_000_000))

            let until = Date().timeIntervalSince1970 + 1.2
            let startedAt = Date()
            let request = Task<TestingHTTPResponse?, Never> {
                try? await app.testing().sendRequest(
                    .GET,
                    "/events?since=\(EventHistoryFixture.timestamp(base))&until=\(until)"
                )
            }
            // The route is now between subscribe and its first body read — the moment
            // the third event must survive exactly once.
            try? await Task.sleep(nanoseconds: 150_000_000)
            await broadcaster.broadcast(
                DockerEvent.simpleEvent(id: "live-ctr", type: "container", status: "die"))

            let res = await request.value
            let elapsed = Date().timeIntervalSince(startedAt)

            #expect(res != nil, "response never completed — the until deadline must close it")
            #expect(elapsed >= 1.0, "closed after \(elapsed)s, deadline was 1.2s — backlog must not shortcut the follow")
            let replayed = events(from: res?.body.string ?? "")
            #expect(replayed.map(\.Action) == ["create", "start", "die"], "backlog then live, each exactly once")
            #expect(replayed.filter { $0.Action == "die" }.count == 1, "the in-flight event arrived exactly once")
        }
    }

    // MARK: - Shape fidelity against a captured dockerd event

    /// Key set and types captured from dockerd 29.4.0 on the OrbStack socket
    /// (2026-08-15) with an explicit /v1.51 negotiation, for
    /// `docker run --rm alpine:3.20 true`: keys Action, Actor{ID, Attributes},
    /// Type, from, id, scope, status, time, timeNano — with the deprecated trio
    /// derived as moby's Log derives it (status = action, id = Actor.ID,
    /// from = Attributes["image"]). An unversioned request against the same daemon
    /// omits status/id/from; the bridge targets v1.51, where they are present.
    @Test("replayed event shape matches a captured dockerd event")
    func replayedEventShapeMatchesDockerd() async throws {
        let containerID = String(repeating: "ab", count: 32)
        try await withRoute { app, broadcaster in
            await broadcaster.broadcast(
                DockerEvent.simpleEvent(
                    id: containerID,
                    type: "container",
                    status: "start",
                    image: "alpine:3.20",
                    name: "probe",
                    labels: ["org.example.probe": "1"]
                ))

            let since = Date().timeIntervalSince1970 - 60
            let res = try await app.testing().sendRequest(.GET, "/events?stream=false&since=\(since)")
            let lines = res.body.string.split(separator: "\n")
            guard let first = lines.first else {
                Issue.record("no event replayed for a window with one broadcast event")
                return
            }
            #expect(lines.count == 1, "exactly the one broadcast event, got \(lines.count)")
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(first.utf8)),
                let dict = object as? [String: Any]
            else {
                Issue.record("replayed event is not a JSON object: \(first)")
                return
            }

            #expect(
                Set(dict.keys) == [
                    "Action", "Actor", "Type", "from", "id", "scope", "status", "time", "timeNano",
                ], "captured dockerd key set, got \(Set(dict.keys).sorted())")

            let actor = dict["Actor"] as? [String: Any]
            #expect(actor?["ID"] as? String == containerID)
            #expect((actor?["ID"] as? String)?.count == 64, "full 64-char container id")
            let attributes = actor?["Attributes"] as? [String: String]
            #expect(attributes?["image"] == "alpine:3.20")
            #expect(attributes?["name"] == "probe")
            #expect(attributes?["org.example.probe"] == "1")

            #expect(dict["status"] as? String == "start", "status derived from the action")
            #expect(dict["id"] as? String == containerID, "id derived from Actor.ID")
            #expect(dict["from"] as? String == "alpine:3.20", "from derived from the image attribute")
            #expect(dict["Type"] as? String == "container")
            #expect(dict["Action"] as? String == "start")
            #expect(dict["scope"] as? String == "local")

            let timeNano = (dict["timeNano"] as? NSNumber)?.uint64Value
            #expect(timeNano != nil && timeNano! > 1_700_000_000_000_000_000)
            #expect((dict["time"] as? NSNumber)?.int64Value == Int64(timeNano! / 1_000_000_000))
        }
    }
}
