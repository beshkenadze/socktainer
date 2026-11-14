import ContainerAPIClient
import ContainerResource
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("Container wait fallback load")
struct ContainerWaitLoadTests {
    @Test("an already recorded exit returns without a fallback poll", arguments: [ContainerWaitCondition.notRunning, .nextExit, .removed])
    func recordedExitReturnsImmediately(condition: ContainerWaitCondition) async throws {
        let id = UUID().uuidString
        await ContainerExitCodeStore.shared.set(id: id, code: 7)
        let base = StaticSnapshotClientMock(snapshot: try makeContainerSnapshot(nativeId: id, networks: [], labels: [:]))
        await base.removeSnapshot()
        let result = try await ClientContainerService.waitForExit(id: id, condition: condition) { try await base.getContainer(id: $0) }
        #expect(result.StatusCode == 7)
        #expect(await base.getCalls == (condition == .removed ? 1 : 0))
        await ContainerExitCodeStore.shared.remove(id: id)
    }

    @Test("unbounded exit and removal polling obeys the one-second interval", arguments: [ContainerWaitCondition.notRunning, .nextExit, .removed])
    func boundedLookups(condition: ContainerWaitCondition) async throws {
        let id = UUID().uuidString
        let snapshot = try makeContainerSnapshot(nativeId: id, networks: [], labels: [:], status: .running)
        let client = StaticSnapshotClientMock(snapshot: snapshot)
        // A recorded exit puts removed directly in its second, unbounded loop.
        if condition == .removed { await ContainerExitCodeStore.shared.set(id: id, code: 7) }
        let task = Task {
            try await ClientContainerService.waitForExit(id: id, condition: condition) {
                try await client.getContainer(id: $0)
            }
        }
        defer { task.cancel() }
        for _ in 0..<3000 {
            if await client.getCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let initialCalls = await client.getCalls
        try #require(initialCalls > 0)
        let started = ContinuousClock.now
        // Suspend the test task; never block a cooperative pool thread.
        try await Task.sleep(for: .milliseconds(1250))
        let elapsedSeconds = started.duration(to: .now).components.seconds
        task.cancel()
        let result = await task.result
        let calls = await client.getCalls

        #expect(calls - initialCalls <= elapsedSeconds + 1, "made \(calls - initialCalls) additional lookups in \(elapsedSeconds) whole seconds plus the fractional remainder")
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("wait must propagate cancellation")
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await client.getCalls == calls)
        await ContainerExitCodeStore.shared.remove(id: id)
    }
}

private actor WaitCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

private struct ChannelWaitWriter: AsyncBodyStreamWriter {
    let channel: NIOAsyncTestingChannel

    func write(_ result: BodyStreamResult) async throws {
        if case .buffer(let buffer) = result {
            try await channel.writeAndFlush(buffer).get()
        }
    }
}

extension ContainerWaitLoadTests {
    @Test("closing the HTTP transport ends the wait and stops client calls", arguments: [ContainerWaitCondition.notRunning, .nextExit, .removed])
    func disconnectStopsWait(condition: ContainerWaitCondition) async throws {
        let id = UUID().uuidString
        let client = StaticSnapshotClientMock(
            snapshot: try makeContainerSnapshot(nativeId: id, networks: [], labels: [:], status: .running)
        )
        let channel = NIOAsyncTestingChannel()
        let writer = ChannelWaitWriter(channel: channel)
        let completion = WaitCompletion()
        let (events, continuation) = AsyncStream.makeStream(of: DockerEvent.self)
        defer { continuation.finish() }
        let task = Task {
            do {
                _ = try await ContainerWaitRoute.withDisconnectCancellation(writer: writer) {
                    if condition == .removed {
                        return try await ClientContainerService.waitForExit(id: id, condition: condition) {
                            try await client.getContainer(id: $0)
                        }
                    }
                    return await ContainerWaitRoute.resolveNotRunning(
                        containerId: id,
                        client: WaitingClient(base: client),
                        condition: condition,
                        events: events
                    )
                }
            } catch {}
            await completion.finish()
        }
        // Ensure the wait has started before closing its transport.
        for _ in 0..<100 {
            if await client.getCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.getCalls > 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await completion.finished == false, "a connected wait must stay pending")
        try await channel.close().get()
        try await Task.sleep(for: .milliseconds(1250))
        #expect(await completion.finished, "disconnect must end the streaming wait task")
        let calls = await client.getCalls
        try await Task.sleep(for: .milliseconds(1150))
        #expect(await client.getCalls == calls, "no polling may survive a disconnected client")
        task.cancel()
        await task.value
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }
}

/// Keep the real service fallback in the route's source race, without a runtime connection.
private struct WaitingClient: ClientContainerProtocol {
    let base: StaticSnapshotClientMock
    let completion: WaitCompletion?

    init(base: StaticSnapshotClientMock, completion: WaitCompletion? = nil) {
        self.base = base
        self.completion = completion
    }
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { try await base.getContainer(id: id) }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        do {
            let result = try await ClientContainerService.waitForExit(id: id, condition: condition) {
                try await base.getContainer(id: $0)
            }
            await completion?.finish()
            return result
        } catch {
            await completion?.finish()
            throw error
        }
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}

private final class WaitHeadReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let receivedHead: EventLoopPromise<Void>
    init(_ receivedHead: EventLoopPromise<Void>) { self.receivedHead = receivedHead }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            #expect(head.status == .ok)
            receivedHead.succeed(())
        }
    }
}

extension ContainerWaitLoadTests {
    @Test("the real HTTP wait stream stops polling after its peer closes", arguments: [ContainerWaitCondition.notRunning, .nextExit, .removed], [false, true])
    func routeDisconnect(condition: ContainerWaitCondition, unixSocket: Bool) async throws {
        let id = UUID().uuidString
        let base = StaticSnapshotClientMock(
            snapshot: try makeContainerSnapshot(nativeId: id, networks: [], labels: [:], status: .running)
        )
        let completion = WaitCompletion()
        try await withApp(configure: { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerWaitRoute(client: WaitingClient(base: base, completion: completion)))
        }) { app in
            let socketPath = "/tmp/wait-\(UUID().uuidString).sock"
            defer { if unixSocket { try? FileManager.default.removeItem(atPath: socketPath) } }
            let address: BindAddress = unixSocket ? .unixDomainSocket(path: socketPath) : .hostname("127.0.0.1", port: 0)
            try await app.server.start(address: address)
            let head = app.eventLoopGroup.next().makePromise(of: Void.self)
            let deadline = head.futureResult.eventLoop.scheduleTask(in: .seconds(5)) {
                head.fail(Abort(.requestTimeout))
            }
            defer { deadline.cancel() }
            let bootstrap = ClientBootstrap(group: app.eventLoopGroup)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers().flatMap {
                        channel.pipeline.addHandler(WaitHeadReader(head))
                    }
                }
            let channel: any Channel
            if unixSocket {
                channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()
            } else {
                let port = try #require(app.http.server.shared.localAddress?.port)
                channel = try await bootstrap.connect(host: "127.0.0.1", port: port).get()
            }
            do {
                let request = HTTPRequestHead(
                    version: .http1_1, method: .POST,
                    uri: "/containers/\(id)/wait?condition=\(condition.rawValue)",
                    headers: ["Host": "localhost", "Content-Length": "0"]
                )
                try await channel.writeAndFlush(HTTPClientRequestPart.head(request)).get()
                try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
                try await head.futureResult.get()
                deadline.cancel()
                try await Task.sleep(for: .milliseconds(150))
                #expect(await completion.finished == false)
                try await channel.close().get()
                // The first data probe can succeed before TCP's reset is observed;
                // the following probe must detect it.
                try await Task.sleep(for: .milliseconds(2500))
                #expect(await completion.finished, "the real route must cancel its native wait on disconnect")
                let calls = await base.getCalls
                try await Task.sleep(for: .milliseconds(1150))
                #expect(await base.getCalls == calls, "the route must leave no polling children behind")
            } catch {
                try? await channel.close().get()
                await base.removeSnapshot()
                await ContainerExitCodeStore.shared.set(id: id, code: 7)
                await app.server.shutdown()
                await ContainerExitCodeStore.shared.remove(id: id)
                throw error
            }
            // Also lets the original, leaking implementation terminate on a red run.
            await base.removeSnapshot()
            await ContainerExitCodeStore.shared.set(id: id, code: 7)
            await app.server.shutdown()
            await ContainerExitCodeStore.shared.remove(id: id)
        }
    }
}

extension ContainerWaitLoadTests {
    @Test("a connected client decodes the normal exit after a liveness probe")
    func connectedClientStillGetsExit() async throws {
        let id = UUID().uuidString
        let base = StaticSnapshotClientMock(
            snapshot: try makeContainerSnapshot(nativeId: id, networks: [], labels: [:], status: .running)
        )
        try await withApp(configure: { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            try app.register(collection: ContainerWaitRoute(client: WaitingClient(base: base)))
        }) { app in
            let recorder = Task {
                try await Task.sleep(for: .milliseconds(1250))
                await ContainerExitCodeStore.shared.set(id: id, code: 7)
            }
            let response = try await app.testing().sendRequest(.POST, "/containers/\(id)/wait")
            try await recorder.value
            #expect(response.status == .ok)
            let result = try JSONDecoder().decode(RESTContainerWait.self, from: Data(response.body.readableBytesView))
            #expect(result.StatusCode == 7)
            await ContainerExitCodeStore.shared.remove(id: id)
        }
    }
}

extension ContainerWaitLoadTests {
    @Test("an exit recorded during wait wakes promptly, including auto-remove", arguments: [ContainerWaitCondition.notRunning, .nextExit, .removed])
    func midWaitExitIsPrompt(condition: ContainerWaitCondition) async throws {
        let id = UUID().uuidString
        let base = StaticSnapshotClientMock(
            snapshot: try makeContainerSnapshot(nativeId: id, networks: [], labels: [:], status: .running)
        )
        let task = Task {
            try await ClientContainerService.waitForExit(id: id, condition: condition, pollIntervalNs: 60_000_000_000) {
                try await base.getContainer(id: $0)
            }
        }
        for _ in 0..<3000 {
            if await base.getCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await base.getCalls > 0)
        try await Task.sleep(for: .milliseconds(125))
        await base.removeSnapshot()
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            task.cancel()
        }
        defer {
            timeout.cancel()
            task.cancel()
        }
        await ContainerExitCodeStore.shared.set(id: id, code: 7)
        let result = try await task.value
        #expect(result.StatusCode == 7)
        // A notification must finish this wait before the 60-second fallback wakes.
        // Without it the deadline cancels the task and task.value throws above.
        await ContainerExitCodeStore.shared.remove(id: id)
    }
}
