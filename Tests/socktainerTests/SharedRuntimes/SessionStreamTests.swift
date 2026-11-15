import Foundation
import NIOCore
import NIOPosix
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// F-006 on a real Unix socket: a half-close of the client is not a disconnect; a closed client is.
@Suite(.timeLimit(.minutes(1))) struct SessionStreamTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var stream: SessionStream?
        private var disconnects = 0
        private var observers: [CheckedContinuation<Void, Never>] = []
        private var changes = 0

        func bound(_ stream: SessionStream) {
            lock.withLock { self.stream = stream }
            notify()
        }

        func disconnected() {
            lock.withLock { disconnects += 1 }
            notify()
        }

        var current: SessionStream? { lock.withLock { stream } }
        var disconnectCount: Int { lock.withLock { disconnects } }

        func waitUntil(seconds: Double = 10, _ condition: @escaping @Sendable (Events) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while true {
                let seen = lock.withLock { changes }
                if condition(self) { return true }
                if ContinuousClock.now >= deadline { return false }
                // Wakes the wait at least every 100 ms, so a deadline ends it.
                let wake = Task.detached { [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.wakeAll()
                }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let unchanged: Bool = lock.withLock {
                        guard changes == seen else { return false }
                        observers.append(continuation)
                        return true
                    }
                    if !unchanged { continuation.resume() }
                }
                wake.cancel()
            }
        }

        func wakeAll() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                changes += 1
                defer { observers = [] }
                return observers
            }
            waiting.forEach { $0.resume() }
        }

        private func notify() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                changes += 1
                defer { observers = [] }
                return observers
            }
            waiting.forEach { $0.resume() }
        }
    }

    private func withUpgradeServer(_ test: (String, Application, Events) async throws -> Void) async throws {
        let events = Events()
        try await withApp(configure: { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            try app.regexRouter.register(.POST, pattern: "/probe") { _ in
                Response.dockerTCPUpgrade(execId: "probe", ttyEnabled: false) { channel, _ in
                    events.bound(SessionStream(channel: channel, probeInterval: .milliseconds(100)) { events.disconnected() })
                }
            }
        }) { app in
            let path = "/tmp/session-stream-\(UUID().uuidString.prefix(8)).sock"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try await app.server.start(address: .unixDomainSocket(path: path))
            try await test(path, app, events)
            await app.server.shutdown()
        }
    }

    private func connect(_ path: String, _ app: Application, _ events: Events) async throws -> RawSocketClient {
        let client = try await RawSocketClient.connect(path: path, group: app.eventLoopGroup)
        try await client.send(RawSocketClient.upgradeRequest(path: "/probe"))
        let bound = await events.waitUntil { $0.current != nil }
        #expect(bound, "no upgrade; the client got: \(String(decoding: client.received, as: UTF8.self))")
        return client
    }

    @Test func aHalfCloseIsNotADisconnectAndTheAnswerStillArrives() async throws {
        try await withUpgradeServer { path, app, events in
            let client = try await connect(path, app, events)
            try await client.halfClose()
            // Several probe intervals pass with the client still reading.
            #expect(await client.waitUntil { RawSocketClient.frames($0.stream).count >= 3 })
            #expect(events.disconnectCount == 0)

            let stream = try #require(events.current)
            stream.send(.stdout, Data("answer".utf8))
            #expect(await client.waitUntil { RawSocketClient.frames($0.stream).contains { $0.1 == Array("answer".utf8) } })
            await stream.finish()
            #expect(await client.waitUntil { $0.isClosed })
            #expect(events.disconnectCount == 0)
            #expect(RawSocketClient.frames(client.stream).allSatisfy { $0.0 == 1 })
        }
    }

    @Test func aClosedClientIsADisconnect() async throws {
        try await withUpgradeServer { path, app, events in
            let client = try await connect(path, app, events)
            try await client.close()
            #expect(await events.waitUntil { $0.disconnectCount == 1 })
        }
    }

    @Test func finishingIsNotADisconnect() async throws {
        try await withUpgradeServer { path, app, events in
            let client = try await connect(path, app, events)
            await events.current?.finish()
            #expect(await client.waitUntil { $0.isClosed })
            #expect(events.disconnectCount == 0)
        }
    }

    @Test func finishEndsAlsoWhenTheClientDoesNotRead() async throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // The client end is a plain descriptor that nobody reads.
        let server = try await NIOPipeBootstrap(group: group).takingOwnershipOfDescriptor(inputOutput: fds[0]).get()
        let stream = SessionStream(channel: server) {}
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
        for _ in 0..<64 { stream.send(.stdout, chunk) }
        let done = SessionLatch<Bool>()
        Task {
            await stream.finish()
            done.resolve(true)
        }
        #expect(await done.wait(limit: .seconds(15)) == true, "a client that does not read cannot keep the session from its end")
        close(fds[1])
        try await group.shutdownGracefully()
    }

    @Test func aClientThatDoesNotReadIsDisconnectedWhenTheQueuePassesItsLimit() async throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await NIOPipeBootstrap(group: group).takingOwnershipOfDescriptor(inputOutput: fds[0]).get()
        let disconnected = SessionLatch<Bool>()
        let stream = SessionStream(channel: server) { disconnected.resolve(true) }
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
        for _ in 0..<160 { stream.send(.stdout, chunk) }
        #expect(await disconnected.wait(limit: .seconds(10)) == true, "10 MiB that nobody reads end the session as a disconnect")
        close(fds[1])
        try await group.shutdownGracefully()
    }
}
