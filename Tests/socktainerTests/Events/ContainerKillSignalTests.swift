import ContainerAPIClient
import ContainerResource
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("Kill event Linux signal numbers")
struct ContainerKillSignalTests {
    @Test(arguments: [
        ("USR1", "10"), ("SIGUSR1", "10"), ("usr1", "10"),
        ("USR2", "12"), ("STOP", "19"), ("CONT", "18"),
        ("TSTP", "20"), ("CHLD", "17"), ("10", "10"),
        ("19", "19"), ("30", "30"), ("SIG10", "10"), ("SIGKILL", "9"),
        ("RTMIN", "34"), ("RTMIN+1", "35"), ("SIGRTMIN+29", "63"), ("rtmax", "64"),
        ("BUS", "7"), ("URG", "23"), ("IO", "29"), ("SYS", "31"),
    ])
    func eventSignal(signal: String, expected: String) async throws {
        try await check(signal: signal, expected: expected)
    }

    @Test func defaultSignal() async throws {
        try await check(signal: nil, expected: "9")
    }

    @Test func unknownSignalKeepsRuntimeError() async throws {
        let client = KillSignalMock(expectedSignal: "UNKNOWN", fails: true)
        let broadcaster = EventBroadcaster()
        try await withApp(configure: { _ in }) { app in
            try configure(app, client: client, broadcaster: broadcaster)
            try await app.testing().test(.POST, "/v1.51/containers/test/kill?signal=UNKNOWN") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string == "Failed to kill container: invalid signal: UNKNOWN")
            }
        }
        let events = await broadcaster.backlog(since: Date(timeIntervalSince1970: 0), until: nil)
        #expect(events.isEmpty)
    }

    private func check(signal: String?, expected: String) async throws {
        let client = KillSignalMock(expectedSignal: signal)
        let broadcaster = EventBroadcaster()
        try await withApp(configure: { _ in }) { app in
            try configure(app, client: client, broadcaster: broadcaster)
            let query = signal.map { "?signal=\($0.replacingOccurrences(of: "+", with: "%2B"))" } ?? ""
            try await app.testing().test(.POST, "/v1.51/containers/test/kill\(query)") { res async in
                #expect(res.status == .noContent)
            }
        }
        let events = await broadcaster.backlog(since: Date(timeIntervalSince1970: 0), until: nil)
        #expect(events.count == 1)
        #expect(events.first?.Action == "kill")
        #expect(events.first?.Actor.Attributes["signal"] == expected)
    }

    private func configure(_ app: Application, client: KillSignalMock, broadcaster: EventBroadcaster) throws {
        let router = app.regexRouter(with: app.logger)
        app.setRegexRouter(router)
        router.installMiddleware(on: app)
        app.storage[EventBroadcasterKey.self] = broadcaster
        try app.register(collection: ContainerKillRoute(client: client))
    }
}

private struct InvalidKillSignal: Error, CustomStringConvertible {
    var description: String { "invalid signal: UNKNOWN" }
}

private struct KillSignalMock: ClientContainerProtocol {
    let expectedSignal: String?
    var fails = false
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {
        #expect(signal == expectedSignal)
        if fails { throw InvalidKillSignal() }
    }
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
