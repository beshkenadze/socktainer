import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import socktainer

@Suite(.timeLimit(.minutes(1))) struct SharedRuntimeSessionTests {
    typealias M = SharedRuntimeManagerTests

    static func spec(_ id: String = String(repeating: "a", count: 64), name: String = "s1", env: String = "A=1") -> SharedSessionSpec {
        let process = SharedRuntimeProcess(
            executable: "/server", arguments: ["--stdio"], environment: [env], workingDirectory: "/", user: .id(uid: 0, gid: 0))
        return SharedSessionSpec(
            id: id, name: name, group: M.group, key: SharingKey(imageID: "sha256:abc", process: process), process: process,
            image: M.image, imageID: "sha256:abc", imageName: "mcp/time", labels: ["a": "b"], created: Date())
    }

    static func id(_ n: Int) -> String { String(format: "%064x", n) }

    // MARK: F-005

    @Test func startWithoutAttachRunsTheLauncherAndEndsCleanly() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        try await manager.start(session)
        let program = await client.waitForProgram(session.spec.id)
        #expect(program.process.arguments == ["--stdio"])
        #expect(program.tmpDirectory == "/tmp/cs-session-aaaaaaaaaaaa")
        #expect(await program.readStdin().isEmpty, "a detached session reads end of file")
        program.write(stdout: "hello\n")
        program.exit(3)
        #expect(await session.ended.wait() == 3)
        #expect(await manager.session(session.spec.id) == nil)
        #expect(session.io.logRecords(stdout: true, stderr: true, tail: nil).map(\.data) == [Data("hello\n".utf8)])
    }

    @Test func outputThatArrivesAfterTheDrainLimitIsKeptWhileTheContainerRuns() async throws {
        let client = FakeSharedRuntimeClient()
        let sleeper = ManualSleeper()
        let manager = M.manager(client, sleeper: sleeper)
        let session = try await manager.addSession(Self.spec())
        try await manager.start(session)
        let program = await client.waitForProgram(session.spec.id)
        program.write(stdout: "early\n")
        program.exitKeepingOutput(0)

        func drainWaitPending() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(7))
            while !sleeper.snapshot.pending.contains(SharedRuntimeManager.drainCheck), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return sleeper.snapshot.pending.contains(SharedRuntimeManager.drainCheck)
        }
        #expect(await drainWaitPending(), "the drain limit runs on the injected clock")
        sleeper.fireAll()
        #expect(await drainWaitPending(), "the container runs, so the session waits again")
        #expect(session.ended.current == nil)

        program.write(stdout: "late\n")
        program.closeOutput()
        #expect(await session.ended.wait(limit: .seconds(10)) == 0)
        #expect(session.io.logRecords(stdout: true, stderr: true, tail: nil).map(\.data) == ["early\n", "late\n"].map { Data($0.utf8) })
    }

    @Test func aStartBeforeTheAttachIsBoundWaitsForIt() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        await manager.expectAttach(session)
        let start = Task { try await manager.start(session) }
        while await manager.joinsInProgress > 0 || session.attachWaiters.isEmpty { await Task.yield() }
        #expect(await client.programs.isEmpty, "nothing starts before the stream is bound")
        let pair = try await SessionTestChannel.make()
        await manager.bindAttach(session, stream: SessionStream(channel: pair.server) {}, stdin: DockerTCPHandler(execId: "x", ttyEnabled: false))
        try await start.value
        _ = await client.waitForProgram(session.spec.id)
        await pair.close()
    }

    @Test func aStartWhoseAttachNeverBindsGoesOnAfterTheLimit() async throws {
        let client = FakeSharedRuntimeClient()
        let sleeper = ManualSleeper()
        let manager = M.manager(client, sleeper: sleeper)
        let session = try await manager.addSession(Self.spec())
        await manager.expectAttach(session)
        let start = Task { try await manager.start(session) }
        await sleeper.waitUntil { $0.pending == [.seconds(10)] }
        sleeper.fireAll()
        try await start.value
        let program = await client.waitForProgram(session.spec.id)
        #expect(await program.readStdin(limit: 5) == Data(), "with no attached client the program reads end of file")
        program.exit(0)
    }

    // MARK: point 1: a shared container that is gone

    @Test func aStartInAContainerThatIsGoneEvictsItAndRetriesOnceInANewOne() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let first = try await manager.addSession(Self.spec(Self.id(1), name: "one"))
        try await manager.start(first)
        let dead = try #require(first.container)
        await client.configure {
            $0.goneContainers.insert(dead.nativeID)
            $0.failSessionStarts = 1
        }
        let second = try await manager.addSession(Self.spec(Self.id(2), name: "two"))
        try await manager.start(second)
        #expect(second.container?.nativeID != dead.nativeID)
        #expect(await client.state.created.count == 2)
        #expect(await first.ended.wait() == 255, "the sessions of the gone container end with an error")
        #expect(await manager.runningContainers().map(\.nativeID) == [second.container?.nativeID])
    }

    @Test func aSecondFailedStartFailsTheSession() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let seed = try await manager.addSession(Self.spec(Self.id(1), name: "seed"))
        try await manager.start(seed)
        await client.configure {
            $0.goneContainers.insert(seed.container!.nativeID)
            $0.failSessionStarts = 2
        }
        let session = try await manager.addSession(Self.spec(Self.id(2), name: "two"))
        await #expect(throws: FakeSharedRuntimeClient.Failure.self) { try await manager.start(session) }
        #expect(await session.ended.wait() == 125)
        #expect(await client.state.created.count == 2, "the second try ran in a new container")
        for container in await manager.runningContainers() {
            #expect(await manager.sessionCount(of: container.nativeID) == 0)
        }
    }

    @Test func anEvictionEndsOnlyTheSessionsThatRunInTheContainer() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let running = try await manager.addSession(Self.spec(Self.id(1), name: "running"))
        try await manager.start(running)
        let dead = try #require(running.container)
        // A session that joined the container and is still in its start.
        let starting = try await manager.addSession(Self.spec(Self.id(2), name: "starting"))
        let spec = starting.spec
        _ = try await manager.join(sessionID: spec.id, group: spec.group, key: spec.key, image: spec.image)
        await manager.containerEnded(dead.nativeID)
        #expect(await running.ended.wait(limit: .seconds(10)) == 255)
        #expect(starting.exit.current == nil, "a start that retries in a new container keeps its exit code open")
    }

    @Test func aSessionInAContainerThatWasAlreadyEvictedStillEnds() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        try await manager.start(session)
        let dead = try #require(session.container)
        _ = await manager.evict(nativeID: dead.nativeID)
        await manager.containerEnded(dead.nativeID)
        #expect(await session.ended.wait(limit: .seconds(10)) == 255)
    }

    @Test func aSignalToAGoneContainerEvictsOnlyThatContainer() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        try await manager.start(session)
        let dead = try #require(session.container)
        await client.configure {
            $0.failSignals = true
            $0.goneContainers.insert(dead.nativeID)
        }
        try await manager.kill(session, signal: nil)
        #expect(await session.ended.wait() == 255)
        #expect(await manager.runningContainers().isEmpty)

        await client.configure { $0.failSignals = false }
        let next = try await manager.addSession(Self.spec(Self.id(2), name: "next"))
        try await manager.start(next)
        #expect(next.container?.nativeID != dead.nativeID)
    }

    @Test func aKillThatRacesTheExitDoesNotEvictARunningContainer() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let other = try await manager.addSession(Self.spec(Self.id(1), name: "other"))
        try await manager.start(other)
        let session = try await manager.addSession(Self.spec(Self.id(2), name: "racing"))
        try await manager.start(session)
        let program = await client.waitForProgram(session.spec.id)
        program.exit(0)
        _ = await session.exit.wait()
        await client.configure { $0.failSignals = true }
        try? await manager.kill(session, signal: "SIGTERM")
        #expect(await manager.runningContainers().count == 1)
        #expect(other.phase == .running)
    }

    // MARK: point 2: every end of a session leaves its container

    enum End: String, CaseIterable, Sendable {
        case exited, stop, kill, removeForce, disconnect, startFailed
    }

    @Test(arguments: End.allCases)
    func everyEndLeavesTheContainer(end: End) async throws {
        let client = FakeSharedRuntimeClient()
        let sleeper = ManualSleeper()
        let manager = M.manager(client, sleeper: sleeper)
        let session = try await manager.addSession(Self.spec())
        switch end {
        case .startFailed:
            await client.configure { $0.failSessionStarts = 1 }
            try? await manager.start(session)
        case .disconnect:
            await manager.expectAttach(session)
            let pair = try await SessionTestChannel.make()
            let stream = SessionStream(channel: pair.server, probeInterval: .milliseconds(50)) {
                Task { await manager.attachDisconnected(session) }
            }
            await manager.bindAttach(session, stream: stream, stdin: DockerTCPHandler(execId: "x", ttyEnabled: false))
            try await manager.start(session)
            let program = await client.waitForProgram(session.spec.id)
            await pair.close()
            await client.waitUntil { $0.signals.contains { $0.signal == "36" } }
            program.exit(137)
        default:
            try await manager.start(session)
            let program = await client.waitForProgram(session.spec.id)
            switch end {
            case .exited:
                program.exit(0)
            case .stop:
                Task {
                    await client.waitUntil { $0.signals.contains { $0.signal == "SIGTERM" } }
                    program.exit(143)
                }
                _ = try await manager.stop(session, signal: nil, timeout: 5)
            case .kill:
                try await manager.kill(session, signal: nil)
                await client.waitUntil { $0.signals.last?.signal == "36" }
                program.exit(137)
            case .removeForce:
                Task {
                    await client.waitUntil { $0.signals.last?.signal == "36" }
                    program.exit(137)
                }
                try await manager.remove(session, force: true)
            default:
                break
            }
        }
        _ = await session.ended.wait()
        for container in await client.state.created {
            #expect(await manager.sessionCount(of: container.name) == 0, "\(end)")
        }
        await sleeper.waitUntil { $0.pending == [.seconds(600)] }
    }

    @Test func anAttachThatBindsAfterTheSessionEndedIsClosed() async throws {
        let manager = M.manager(FakeSharedRuntimeClient())
        let session = try await manager.addSession(Self.spec())
        await manager.expectAttach(session)
        try await manager.remove(session, force: false)
        let pair = try await SessionTestChannel.make()
        await manager.bindAttach(session, stream: SessionStream(channel: pair.server) {}, stdin: DockerTCPHandler(execId: "x", ttyEnabled: false))
        let closed = SessionLatch<Bool>()
        pair.server.closeFuture.whenComplete { _ in closed.resolve(true) }
        #expect(await closed.wait(limit: .seconds(5)) == true, "the connection of an ended session is closed")
        await pair.close()
    }

    @Test func aDisconnectBeforeTheStartEndsTheProgramWhenItRuns() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        await manager.expectAttach(session)
        let pair = try await SessionTestChannel.make()
        let stream = SessionStream(channel: pair.server, probeInterval: .milliseconds(50)) {
            Task { await manager.attachDisconnected(session) }
        }
        await manager.bindAttach(session, stream: stream, stdin: DockerTCPHandler(execId: "x", ttyEnabled: false))
        await pair.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.pendingSignals.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

        try await manager.start(session)
        let program = await client.waitForProgram(session.spec.id)
        let ended = await client.waitUntil(seconds: 10) { $0.signals.contains { $0.signal == SharedRuntimeSignal.endNow } }
        #expect(ended, "the client is gone, so the program ends")
        program.exit(137)
        #expect(await session.ended.wait(limit: .seconds(10)) == 137)
    }

    @Test func aSecondAttachIsClosedAndTheFirstKeepsTheSession() async throws {
        let manager = M.manager(FakeSharedRuntimeClient())
        let session = try await manager.addSession(Self.spec())
        await manager.expectAttach(session)
        let first = try await SessionTestChannel.make()
        let second = try await SessionTestChannel.make()
        await manager.bindAttach(session, stream: SessionStream(channel: first.server) {}, stdin: DockerTCPHandler(execId: "a", ttyEnabled: false))
        await manager.bindAttach(session, stream: SessionStream(channel: second.server) {}, stdin: DockerTCPHandler(execId: "b", ttyEnabled: false))
        let closed = SessionLatch<Bool>()
        second.server.closeFuture.whenComplete { _ in closed.resolve(true) }
        #expect(await closed.wait(limit: .seconds(5)) == true, "the second attach is closed")
        #expect(first.server.isActive, "the first attach stays")
        await first.close()
        await second.close()
    }

    @Test func aFailedWaitEndsTheProgramThroughTheLauncher() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        try await manager.start(session)
        let program = await client.waitForProgram(session.spec.id)
        program.failWait()
        let sent = await client.waitUntil(seconds: 10) { $0.signals.contains { $0.signal == SharedRuntimeSignal.endNow } }
        #expect(sent, "the program does not stay without its session")
        program.closeOutput()  // the launcher has ended the program
        #expect(await session.ended.wait(limit: .seconds(15)) == 255)
        program.exit(137)
    }

    // MARK: an end that arrives while the start launches

    enum EarlyEnd: String, CaseIterable, Sendable { case disconnect, kill, stop, removeForce }

    @Test(arguments: EarlyEnd.allCases)
    func anEndDuringTheLaunchIsSentWhenTheProgramRuns(end: EarlyEnd) async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        var pair: SessionTestChannel?
        if end == .disconnect {
            await manager.expectAttach(session)
            let channels = try await SessionTestChannel.make()
            let stream = SessionStream(channel: channels.server, probeInterval: .milliseconds(50)) {
                Task { await manager.attachDisconnected(session) }
            }
            await manager.bindAttach(session, stream: stream, stdin: DockerTCPHandler(execId: "x", ttyEnabled: false))
            pair = channels
        }
        await client.configure { $0.holdCreates = true }
        let start = Task { try await manager.start(session) }
        await client.waitUntil { $0.createsInFlight == 1 }

        let request: Task<Void, Never>
        switch end {
        case .disconnect:
            await pair?.close()
            request = Task {}
        case .kill:
            request = Task { try? await manager.kill(session, signal: nil) }
        case .stop:
            request = Task { _ = try? await manager.stop(session, signal: nil, timeout: 1) }
        case .removeForce:
            request = Task { try? await manager.remove(session, force: true) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.pendingSignals.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }

        await client.releaseCreates()
        try await start.value
        let program = await client.waitForProgram(session.spec.id)
        let sent = await client.waitUntil(seconds: 10) { $0.signals.contains { $0.processID == session.spec.id } }
        #expect(sent, "\(end): the end reaches the program after the launch")
        program.exit(137)
        #expect(await session.ended.wait(limit: .seconds(10)) == 137)
        _ = await request.value
        if let pair { await pair.close() }
    }

    // MARK: signals by route (point 3)

    @Test func stopSendsTERMThenTheControlSignalAfterTheTimeout() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        try await manager.start(session)
        let program = await client.waitForProgram(session.spec.id)
        Task {
            await client.waitUntil { $0.signals.last?.signal == "36" }
            program.exit(137)
        }
        #expect(try await manager.stop(session, signal: nil, timeout: 1))
        #expect(await client.state.signals.map(\.signal) == ["SIGTERM", "36"])
        #expect(await client.state.signals.allSatisfy { $0.processID == session.spec.id })
    }

    @Test func killWithoutASignalIsTheControlSignalAndSTOPIsRefused() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = M.manager(client)
        let session = try await manager.addSession(Self.spec())
        try await manager.start(session)
        await #expect(throws: SharedRuntimeSignal.Failure.self) { try await manager.kill(session, signal: "SIGSTOP") }
        try await manager.kill(session, signal: "SIGUSR1")
        #expect(session.phase == .running, "a handled signal does not end the session")
        try await manager.kill(session, signal: nil)
        #expect(await client.state.signals.map(\.signal) == ["SIGUSR1", "36"])
    }

    @Test func aKillOfASessionThatDidNotStartIsRefused() async throws {
        let manager = M.manager(FakeSharedRuntimeClient())
        let session = try await manager.addSession(Self.spec())
        await #expect(throws: SharedRuntimeManager.SessionError.notRunning(session.spec.id)) { try await manager.kill(session, signal: nil) }
    }

    @Test func removeOfARunningSessionNeedsForce() async throws {
        let manager = M.manager(FakeSharedRuntimeClient())
        let session = try await manager.addSession(Self.spec())
        try await manager.start(session)
        await #expect(throws: SharedRuntimeManager.SessionError.running(session.spec.id)) { try await manager.remove(session, force: false) }
    }

    @Test func namesAndReferences() async throws {
        let manager = M.manager(FakeSharedRuntimeClient())
        let session = try await manager.addSession(Self.spec(Self.id(0xabc), name: "fancy"))
        await #expect(throws: SharedRuntimeManager.SessionError.nameInUse("fancy")) { try await manager.addSession(Self.spec(Self.id(1), name: "fancy")) }
        #expect(await manager.session("fancy") === session)
        #expect(await manager.session("/fancy") === session)
        #expect(await manager.session(Self.id(0xabc)) === session)
        #expect(await manager.session(String(Self.id(0xabc).prefix(62))) === session)
    }
}

/// A connected pair of channels on a socket pair, for a stream that a test closes.
struct SessionTestChannel {
    let server: Channel
    let client: Channel
    let group: MultiThreadedEventLoopGroup

    static func make() async throws -> SessionTestChannel {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let server = try await NIOPipeBootstrap(group: group).takingOwnershipOfDescriptor(inputOutput: fds[0]).get()
        let client = try await NIOPipeBootstrap(group: group).takingOwnershipOfDescriptor(inputOutput: fds[1]).get()
        return SessionTestChannel(server: server, client: client, group: group)
    }

    /// Closes the client side; the group stays up for the session that still uses the server side.
    func close() async {
        try? await client.close().get()
    }
}
