import ContainerResource
import Vapor

struct EventBroadcasterKey: StorageKey {
    typealias Value = EventBroadcaster
}

struct DockerActor: Codable {
    let ID: String
    let Attributes: [String: String]
}

struct DockerEvent: Codable {
    let status: String
    let id: String
    let from: String
    let `Type`: String
    let Action: String
    let Actor: DockerActor
    let scope: String
    let time: Int
    let timeNano: UInt64
}

extension DockerEvent {
    /// The one nanosecond stamp every event timestamp passes through — constructors and
    /// history-window comparisons alike — so a boundary Date converts to the same
    /// UInt64 an event carries and equality at `since`/`until` is decided on a single
    /// representation instead of two that drift by a rounding step. Rounded, not
    /// truncated: truncating the product shaves a fraction of a nanosecond and flips
    /// an equality-at-boundary query exclusive by one step (caught by the boundary
    /// tests in EventBroadcasterHistoryTests). The remaining floor is Date itself —
    /// measured on Darwin, constructing and reading back 2000000.001 s wobbles
    /// +46.8ns — still finer than any timestamp the Docker CLI sends.
    static func timeNano(from date: Date) -> UInt64 {
        UInt64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }

    /// General constructor mirroring moby's `EventsService.Log(action, type, Actor{ID, Attributes})`.
    /// The deprecated top-level fields are derived exactly as moby does for backward compatibility:
    /// `id` = Actor.ID, `status` = action, `from` = Attributes["image"] (empty when absent).
    /// Use this for image/network/volume/prune events, whose attribute sets differ from containers
    /// (e.g. no forced `image`/`name` keys).
    static func make(
        type: String,
        action: String,
        actorID: String,
        attributes: [String: String]
    ) -> DockerEvent {
        let now = Date()
        let timeSeconds = Int(now.timeIntervalSince1970)
        let timeNano = timeNano(from: now)

        return DockerEvent(
            status: action,
            id: actorID,
            from: attributes["image"] ?? "",
            Type: type,
            Action: action,
            Actor: DockerActor(ID: actorID, Attributes: attributes),
            scope: "local",
            time: timeSeconds,
            timeNano: timeNano
        )
    }

    /// Container-shaped event: moby's `LogContainerEventWithAttributes` always injects
    /// `image` and `name` attributes alongside the container labels. Keep using this for
    /// `Type: "container"` events only. `extraAttributes` carries action-specific keys moby
    /// adds on top (e.g. `signal` on `kill`, `exitCode` on `die`/`exec_die`); they override
    /// any same-named label.
    static func simpleEvent(
        id: String,
        type: String,
        status: String,
        image: String = "",
        name: String = "",
        labels: [String: String] = [:],
        extraAttributes: [String: String] = [:]
    ) -> DockerEvent {
        var attributes = labels
        attributes["image"] = image
        attributes["name"] = name.isEmpty ? id : name
        for (key, value) in extraAttributes { attributes[key] = value }
        return make(type: type, action: status, actorID: id, attributes: attributes)
    }

    /// Container-shaped event derived from a snapshot: canonical 64-char Docker id,
    /// image reference, native name, and restored labels — the fields every
    /// container lifecycle event site otherwise re-derives by hand.
    static func containerEvent(
        _ action: String,
        container: ContainerSnapshot,
        extraAttributes: [String: String] = [:]
    ) -> DockerEvent {
        simpleEvent(
            id: DockerContainerID.hexId(for: container),
            type: "container",
            status: action,
            image: container.configuration.image.reference,
            name: container.id,
            labels: LabelNormalization.restore(container.configuration.labels),
            extraAttributes: extraAttributes
        )
    }
}

actor EventBroadcaster {
    /// moby retains the last `eventsLimit = 256` events precisely so a client can ask
    /// for what it missed (daemon/events/events.go) — the buffer this bridge lacked,
    /// which made `GET /events?since=…&until=…` answer `[]` even for a window with
    /// activity in it (issue #6). 256 is moby's number, not a tuned one: it caps the
    /// ring's memory while covering any realistic "what just happened" query. Like
    /// moby's in-process slice, the ring is memory-only — a restarted bridge answers
    /// history queries from an empty buffer, never from disk.
    static let historyLimit = 256

    private var history: [DockerEvent] = []
    private var continuations: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]

    func stream() -> AsyncStream<DockerEvent> {
        // Live-only view of the atomic subscribe: nil/nil bounds select no backlog
        // (moby's loadBufferedEvents returns nothing when both bounds are zero), so
        // this degrades to pure registration — the behaviour every pre-history caller
        // relied on.
        subscribe(since: nil, until: nil).live
    }

    /// moby's SubscribeTopic: the matching backlog snapshot and the live registration
    /// happen in one critical section — under one mutex in Go, inside one
    /// actor-isolated call here. Splitting them reopens the class of race `stream()`
    /// documents being fixed once already: read the buffer first and an event
    /// broadcast before registering is lost to this listener; register first and an
    /// event broadcast after the read arrives on both arms at once. Actor isolation
    /// serializes `broadcast` against this whole method, so every event lands in
    /// exactly one arm — never neither, never both.
    func subscribe(since: Date?, until: Date?) -> (backlog: [DockerEvent], live: AsyncStream<DockerEvent>) {
        let backlog = loadBufferedEvents(since: since, until: until)
        let id = UUID()
        let (live, continuation) = AsyncStream.makeStream(of: DockerEvent.self)
        continuations[id] = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await self.removeContinuation(id: id) }
        }
        return (backlog, live)
    }

    /// History read for requests that will not follow (`stream=false`, or `until`
    /// already past). No live continuation is registered because none would ever be
    /// consumed — moby's getEvents subscribes on this path too only to unsubscribe
    /// immediately after; skipping the detour is the same observable behaviour.
    func backlog(since: Date?, until: Date?) -> [DockerEvent] {
        loadBufferedEvents(since: since, until: until)
    }

    func broadcast(_ event: DockerEvent) {
        // Ring eviction as in moby's PublishMessage: at capacity the oldest entry is
        // dropped (Go shifts the slice with copy; removeFirst() is the same O(n)
        // trade at n = 256).
        if history.count == Self.historyLimit {
            history.removeFirst()
        }
        history.append(event)
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// moby's loadBufferedEvents: newest-to-oldest scan that stops at the first event
    /// older than `since`, skips events newer than `until`, and prepends so the result
    /// comes back chronological. Both bounds are inclusive — measured against dockerd
    /// 29.4.0 on the OrbStack socket (2026-08-15): a `create` with timeNano
    /// 1786819544696782212 was replayed with `since` set to exactly that value and
    /// dropped at since+1ns; it was replayed with `until` set to exactly that value
    /// and dropped at until-1ns. Go compares UnixNano integers; this compares the same
    /// nanosecond stamp the constructors write, so equality at the boundary survives
    /// the Date round trip.
    private func loadBufferedEvents(since: Date?, until: Date?) -> [DockerEvent] {
        guard since != nil || until != nil else { return [] }
        let sinceNano = since.map { DockerEvent.timeNano(from: $0) }
        let untilNano = until.map { DockerEvent.timeNano(from: $0) }
        var buffered: [DockerEvent] = []
        for event in history.reversed() {
            if let sinceNano, event.timeNano < sinceNano {
                break
            }
            if let untilNano, event.timeNano > untilNano {
                continue
            }
            buffered.insert(event, at: 0)
        }
        return buffered
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
