import Foundation
import Testing

@testable import socktainer

@Suite(.timeLimit(.minutes(1)))
struct SharedRuntimeKillSignalTests {
    @Test(
        arguments: [
            (nil, "9", "36"), ("", "9", "36"), ("SIGKILL", "9", "36"),
            ("USR1", "10", "USR1"), ("SIGUSR1", "10", "SIGUSR1"), ("usr1", "10", "usr1"),
            (" USR1 ", "10", "USR1"), ("USR2", "12", "USR2"),
            ("CONT", "18", "CONT"), ("TSTP", "20", "TSTP"), ("CHLD", "17", "CHLD"),
            ("10", "10", "10"), ("36", "36", "36"), ("09", "9", "36"),
            ("RTMIN+1", "35", "RTMIN+1"),
        ] as [(String?, String, String)])
    func eventUsesDockerSignal(signal: String?, expected: String, delivered: String) async throws {
        let client = FakeSharedRuntimeClient()
        let events = EventBroadcaster()
        let manager = SharedRuntimeManager(
            client: client, socketPath: SharedRuntimeManagerTests.socket,
            launcherDirectory: { URL(fileURLWithPath: "/tmp/launcher") },
            onEvent: { await events.broadcast($0) })
        // The kill event needs a running session, not a program or its I/O tasks.
        let session = SharedSession(spec: SharedRuntimeSessionTests.spec())
        session.phase = .running
        session.container = .init(
            nativeID: "shared-kill-test", dockerID: session.spec.id,
            group: session.spec.group.name, key: session.spec.key)
        try await manager.kill(session, signal: signal)
        #expect(await client.state.signals.map(\.signal) == [delivered])
        let history = await events.backlog(since: Date(timeIntervalSince1970: 0), until: nil)
        let kills = history.filter { $0.Action == "kill" }
        #expect(kills.count == 1)
        #expect(kills.first?.Actor.Attributes["signal"] == expected)
    }
}
