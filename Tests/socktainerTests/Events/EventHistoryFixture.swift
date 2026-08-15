import Foundation

@testable import socktainer

/// Fixtures for the events-history suites: events stamped with exact nanoseconds and
/// the Date conversion the route performs on `since`/`until`. The base sits below 2^53
/// nanoseconds, where every integer nanosecond is exactly representable as a Double —
/// so a boundary Date converts back to the same UInt64 its event carries, and equality
/// at `since`/`until` is decided by the window filter, not by floating-point rounding.
enum EventHistoryFixture {
    static let base: UInt64 = 2_000_000_000_000_000

    static func event(_ action: String, at timeNano: UInt64) -> DockerEvent {
        DockerEvent(
            status: action,
            id: "ctr-\(timeNano)",
            from: "alpine:3.20",
            Type: "container",
            Action: action,
            Actor: DockerActor(ID: "ctr-\(timeNano)", Attributes: ["image": "alpine:3.20"]),
            scope: "local",
            time: Int(timeNano / 1_000_000_000),
            timeNano: timeNano
        )
    }

    static func date(_ timeNano: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(timeNano) / 1_000_000_000)
    }

    /// `seconds.nanoseconds`, the exact form dockerd's timetypes parses and the form
    /// the boundary probes against the real daemon used.
    static func timestamp(_ timeNano: UInt64) -> String {
        let fraction = String(timeNano % 1_000_000_000)
        let padded = String(repeating: "0", count: 9 - fraction.count) + fraction
        return "\(timeNano / 1_000_000_000).\(padded)"
    }
}
