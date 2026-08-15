import Foundation
import Testing

@testable import socktainer

/// The history ring and its window filter mirror moby's events buffer
/// (daemon/events/events.go). Every boundary expectation here was first measured
/// against dockerd 29.4.0 on the OrbStack socket (2026-08-15); the boundary test
/// records the exact numbers.
@Suite("EventBroadcaster — history ring")
struct EventBroadcasterHistoryTests {

    @Test("replay returns events inside the window, chronologically")
    func replayWindow() async throws {
        let broadcaster = EventBroadcaster()
        let base = EventHistoryFixture.base
        await broadcaster.broadcast(EventHistoryFixture.event("create", at: base - 1_000_000_000))
        await broadcaster.broadcast(EventHistoryFixture.event("start", at: base + 500_000_000))
        await broadcaster.broadcast(EventHistoryFixture.event("die", at: base + 1_000_000_000))
        await broadcaster.broadcast(EventHistoryFixture.event("destroy", at: base + 2_000_000_000))

        let replayed = await broadcaster.backlog(
            since: EventHistoryFixture.date(base),
            until: EventHistoryFixture.date(base + 2_000_000_000)
        )

        #expect(replayed.map(\.Action) == ["start", "die", "destroy"])
    }

    /// event's exact timeNano (integer UnixNano on the daemon's side, ±1ns probes):
    /// 1786819544696782212 replayed for an equal bound and dropped one nanosecond
    /// beyond it — both bounds inclusive, what moby's loadBufferedEvents implements
    /// (`TimeNano < since` breaks, `TimeNano > until` skips). This bridge's bounds
    /// travel as Date, which wobbles tens of nanoseconds on Darwin, so equality is
    /// asserted on a half-second boundary (exactly representable, verified to
    /// round-trip) and exclusivity at ±1ms — the finest offsets that decide
    /// deterministically through a Date.
    @Test("since and until bounds are inclusive, matching measured dockerd")
    func boundarySemantics() async throws {
        let broadcaster = EventBroadcaster()
        let base = EventHistoryFixture.base
        let boundary = base + 500_000_000
        await broadcaster.broadcast(EventHistoryFixture.event("create", at: base))
        await broadcaster.broadcast(EventHistoryFixture.event("start", at: boundary))

        let sinceHit = await broadcaster.backlog(since: EventHistoryFixture.date(boundary), until: nil)
        #expect(sinceHit.map(\.Action) == ["start"], "the event with timeNano == since replays; older ones break off")

        let sinceMiss = await broadcaster.backlog(since: EventHistoryFixture.date(boundary + 1_000_000), until: nil)
        #expect(sinceMiss.isEmpty, "an event one nanosecond — here one millisecond — before since must not replay")

        let untilHit = await broadcaster.backlog(since: EventHistoryFixture.date(base), until: EventHistoryFixture.date(boundary))
        #expect(untilHit.map(\.Action) == ["create", "start"], "the event with timeNano == until replays")

        let untilMiss = await broadcaster.backlog(since: EventHistoryFixture.date(base), until: EventHistoryFixture.date(boundary - 1_000_000))
        #expect(untilMiss.map(\.Action) == ["create"], "an event one nanosecond — here one millisecond — past until must not replay")
    }

    /// moby's PublishMessage discards the oldest entry once the ring holds
    /// `eventsLimit` events, so the buffer answers "the last 256", not "everything
    /// since the process started".
    @Test("ring evicts the oldest events past moby's 256 capacity")
    func ringEvictsOldest() async throws {
        let broadcaster = EventBroadcaster()
        let base = EventHistoryFixture.base
        let overflow = 10
        let total = EventBroadcaster.historyLimit + overflow
        for i in 0..<total {
            await broadcaster.broadcast(EventHistoryFixture.event("tick-\(i)", at: base + UInt64(i)))
        }

        let replayed = await broadcaster.backlog(since: EventHistoryFixture.date(base), until: nil)

        #expect(replayed.count == EventBroadcaster.historyLimit)
        #expect(EventBroadcaster.historyLimit == 256, "moby's eventsLimit (daemon/events/events.go)")
        #expect(replayed.first?.Action == "tick-\(overflow)", "oldest \(overflow) evicted")
        #expect(replayed.last?.Action == "tick-\(total - 1)")
    }

    /// moby's loadBufferedEvents returns nothing when both bounds are zero: a plain
    /// `docker events` (no since/until) must not replay history, only follow live.
    @Test("nil since and nil until select no backlog — plain docker events never replays")
    func bothBoundsNilSelectNothing() async throws {
        let broadcaster = EventBroadcaster()
        await broadcaster.broadcast(EventHistoryFixture.event("create", at: EventHistoryFixture.base))

        let empty = await broadcaster.backlog(since: nil, until: nil)
        #expect(empty.isEmpty)

        let (backlog, _) = await broadcaster.subscribe(since: nil, until: nil)
        #expect(backlog.isEmpty)
    }

    /// Measured against dockerd (OrbStack socket, 2026-08-15): `?until=<future>` with
    /// no `since` replayed the whole buffer — a zero lower bound bounds nothing, and a
    /// set `until` is enough to make loadBufferedEvents run.
    @Test("until alone replays the whole buffer up to until")
    func untilAloneReplaysWholeBuffer() async throws {
        let broadcaster = EventBroadcaster()
        let base = EventHistoryFixture.base
        await broadcaster.broadcast(EventHistoryFixture.event("create", at: base))
        await broadcaster.broadcast(EventHistoryFixture.event("start", at: base + 1_000_000))
        await broadcaster.broadcast(EventHistoryFixture.event("die", at: base + 2_000_000))

        let replayed = await broadcaster.backlog(since: nil, until: EventHistoryFixture.date(base + 5_000_000))
        #expect(replayed.map(\.Action) == ["create", "start", "die"])

        let clipped = await broadcaster.backlog(since: nil, until: EventHistoryFixture.date(base + 1_000_000))
        #expect(clipped.map(\.Action) == ["create", "start"])
    }

    /// The subscribe contract: an event broadcast after subscribe returns — the exact
    /// moment a split (snapshot-then-register, or register-then-snapshot) would lose
    /// or duplicate it — arrives exactly once, through the live arm, never in the
    /// backlog too.
    @Test("subscribe hands back backlog and live atomically — no gap, no duplicate")
    func atomicSubscribeExactlyOnce() async throws {
        let broadcaster = EventBroadcaster()
        let base = EventHistoryFixture.base
        await broadcaster.broadcast(EventHistoryFixture.event("create", at: base))

        let (backlog, live) = await broadcaster.subscribe(
            since: EventHistoryFixture.date(base - 1_000_000_000), until: nil
        )
        await broadcaster.broadcast(EventHistoryFixture.event("start", at: base + 1_000_000_000))

        #expect(backlog.map(\.Action) == ["create"], "snapshot was taken before the second broadcast")

        let collect = Task<[DockerEvent], Never> {
            var seen: [DockerEvent] = []
            for await event in live {
                seen.append(event)
                if seen.count == 1 { break }
            }
            return seen
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            collect.cancel()
        }
        let liveEvents = await collect.value
        timeout.cancel()

        #expect(liveEvents.map(\.Action) == ["start"], "post-subscribe broadcast arrives live, exactly once")
    }

    /// The pre-history contract every existing caller depends on: `stream()` follows
    /// live events only — nothing broadcast before the call is replayed to it.
    @Test("stream() stays live-only — no replay of pre-existing history")
    func streamRemainsLiveOnly() async throws {
        let broadcaster = EventBroadcaster()
        let base = EventHistoryFixture.base
        await broadcaster.broadcast(EventHistoryFixture.event("before", at: base))

        let live = await broadcaster.stream()
        await broadcaster.broadcast(EventHistoryFixture.event("after", at: base + 1_000_000_000))

        let collect = Task<[String], Never> {
            var seen: [String] = []
            for await event in live {
                seen.append(event.Action)
                if seen.count == 2 { break }
            }
            return seen
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            collect.cancel()
        }
        let seen = await collect.value
        timeout.cancel()

        #expect(seen == ["after"], "stream() delivers only post-subscription events, got \(seen)")
    }
}
