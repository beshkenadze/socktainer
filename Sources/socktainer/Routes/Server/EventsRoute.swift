import Foundation
import NIOCore
import Vapor

struct EventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/events", use: EventsRoute.handler(client: client))
    }

}

extension EventsRoute {
    static func handler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else {
                throw Abort(.internalServerError, reason: "EventBroadcaster not configured")
            }

            // Bounded-event semantics follow moby's getEvents
            // (api/server/router/system/system_routes.go): `since`/`until` are parsed
            // first and a bad value is a 400; `until` before `since` is rejected;
            // `until` in the past means "return what matched and close"; `until` in
            // the future means "stream until that moment, then close"; `stream=false`
            // means never follow.
            let sinceRaw = req.query[String.self, at: "since"]
            let untilRaw = req.query[String.self, at: "until"]
            let since = try parseEventTimestamp(sinceRaw)
            let until = try parseEventTimestamp(untilRaw)

            if let since, let until, until < since {
                throw Abort(
                    .badRequest,
                    reason: "`since` time (\(sinceRaw ?? "")) cannot be after `until` time (\(untilRaw ?? ""))"
                )
            }

            let now = Date()
            // `req.query[Bool.self, at:]` answers `false` for a key that is not there, not nil, so
            // reading `stream` that way turned every plain `docker events` — which sends no such
            // parameter — into a history-only request that closed with an empty body, undoing the
            // streaming fix from #2. Read it as text and default to following, which is what
            // `/events` does: moby's getEvents has no `stream` parameter at all and always streams
            // until `until` (api/server/router/system/system_routes.go); the Podman-compatible
            // `stream=false` opt-out is the only reason to stop.
            let follow = req.query[String.self, at: "stream"].map { raw in MobyBool.parse(raw) ?? true } ?? true
            let onlyPastEvents = !follow || (until.map { $0 <= now } ?? false)

            if onlyPastEvents {
                // moby's getEvents writes the buffered events matching the window and
                // returns without ever subscribing live (api/server/router/system/
                // system_routes.go). The backlog now comes from the broadcaster's ring
                // buffer — the piece this bridge lacked, which made a window with
                // activity in it answer an empty body (issue #6). A window nothing
                // matches still closes promptly with an empty body, which a client can
                // proceed on.
                let backlog = await broadcaster.backlog(since: since, until: until)
                let response = Response(status: .ok)
                response.headers.add(name: .contentType, value: "application/json")
                var body = ByteBuffer()
                for event in backlog {
                    if let json = try? JSONEncoder().encode(event) {
                        body.writeBytes(json)
                        body.writeString("\n")
                    }
                }
                response.body = .init(buffer: body)
                return response
            }

            // Following: one atomic subscribe returns the backlog matching the window
            // and the live stream together — moby's SubscribeTopic takes both under one
            // mutex so an event broadcast in between is delivered exactly once, never
            // dropped or duplicated. The backlog is written first, then live events, in
            // moby's order. `until` is in the future here and still bounds the backlog:
            // measured against dockerd on the OrbStack socket (2026-08-15),
            // `?until=<future>` with no `since` replays the whole buffer, exactly what
            // loadBufferedEvents produces with a zero lower bound.
            let (backlog, live) = await broadcaster.subscribe(since: since, until: until)
            let deadline = until

            let response = Response(status: .ok)
            response.headers.add(name: .contentType, value: "application/json")

            response.body = .init(asyncStream: { writer in
                // Flush the head before waiting on the first event. A body stream sends nothing until
                // it produces, so on an idle daemon the client saw no status line at all: `docker
                // events` printed nothing and a `curl` against /events hung with zero bytes. Docker
                // answers immediately and only then streams, which is what `--until` and any client
                // that reads headers before events depends on.
                _ = try? await writer.write(.buffer(sharedAllocator.buffer(capacity: 0)))

                for event in backlog {
                    let clientStillThere = await writeJSONL(event, to: writer, logger: req.logger)
                    if !clientStillThere { break }
                }
                for await event in EventsRoute.deadlineBounded(live, until: deadline) {
                    let clientStillThere = await writeJSONL(event, to: writer, logger: req.logger)
                    if !clientStillThere { break }
                }
                _ = try? await writer.write(.end)
            })

            return response

        }
    }

    /// One event as one JSONL frame, shared by the backlog and live paths so replayed
    /// history is byte-identical to what the live stream sends. False when the client
    /// is gone (broken pipe, closed channel): the caller stops queueing frames nobody
    /// will read. A bad encode or a transient write error is logged and skipped — the
    /// tolerance the live path already had, now applied to the backlog too.
    private static func writeJSONL(
        _ event: DockerEvent,
        to writer: AsyncBodyStreamWriter,
        logger: Logger
    ) async -> Bool {
        guard let json = try? JSONEncoder().encode(event) else {
            logger.warning("\(event) could not be encoded")
            return true
        }
        var buffer = ByteBuffer()
        buffer.writeBytes(json)
        buffer.writeString("\n")
        do {
            try await writer.write(.buffer(buffer))
            return true
        } catch is IOError {
            logger.debug("Client disconnected (broken pipe)")
            return false
        } catch let error as ChannelError where error == .ioOnClosedChannel {
            logger.debug("Client disconnected (closed channel)")
            return false
        } catch {
            logger.warning("\(event) raised '\(error)'")
            return true
        }
    }

    /// Races the live event stream against the `until` deadline, the way moby's
    /// getEvents select-loop closes its `timeout` channel at the deadline even when
    /// no event ever arrives (api/server/router/system/system_routes.go). A plain
    /// `for await` would only ever check the clock when an event happens to be
    /// delivered, so `?until=<future>` never terminated on an idle daemon.
    private static func deadlineBounded(
        _ stream: AsyncStream<DockerEvent>, until deadline: Date?
    ) -> AsyncStream<DockerEvent> {
        AsyncStream { (continuation: AsyncStream<DockerEvent>.Continuation) in
            let producer = Task {
                for await event in stream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            let timer = deadlineTimer(deadline, continuation: continuation)
            continuation.onTermination = { _ in
                producer.cancel()
                timer?.cancel()
            }
        }
    }

    /// The `timeout` arm of moby's getEvents select loop: a task that finishes the
    /// consumer's continuation when the `until` deadline passes, independent of event
    /// traffic. Nil when the stream is unbounded.
    private static func deadlineTimer(
        _ deadline: Date?,
        continuation: AsyncStream<DockerEvent>.Continuation
    ) -> Task<Void, Never>? {
        guard let deadline else { return nil }
        let deadlineInstant = ContinuousClock.now + .seconds(deadline.timeIntervalSinceNow)
        return Task {
            try? await Task.sleep(until: deadlineInstant, clock: .continuous)
            continuation.finish()
        }
    }

    /// Parses an event `since`/`until` parameter like moby's `timetypes.ParseTimestamps`
    /// (api/types/time/timestamp.go): Unix seconds, `seconds.nanoseconds` (the fractional
    /// part is scaled to 9 digits — `0.5` means half a second), and RFC3339. Absent or
    /// empty means unbounded (nil); anything else is a client error (400), as in moby's
    /// `eventTime` helper.
    static func parseEventTimestamp(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        if let date = parseUnixTimestamp(raw) {
            return date
        }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) {
            return date
        }

        throw Abort(
            .badRequest,
            reason: "invalid value for timestamp: \"\(raw)\""
        )
    }

    /// `seconds` or `seconds.nanoseconds` — nil when `raw` is not that shape.
    private static func parseUnixTimestamp(_ raw: String) -> Date? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let seconds = Int64(parts[0]), parts[0].allSatisfy(\.isNumber) else {
            return nil
        }

        var nanoseconds = 0
        if parts.count == 2 {
            let fraction = parts[1]
            guard fraction.allSatisfy(\.isNumber), !fraction.isEmpty else { return nil }
            // Scale the fraction to nanoseconds: "5" → 0.5s, "123456789" → 123456789ns.
            let digits = min(fraction.count, 9)
            let value = Int64(fraction.prefix(digits)) ?? 0
            nanoseconds = Int(value * Int64(pow(10, Double(9 - digits))))
        }

        return Date(timeIntervalSince1970: TimeInterval(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}
