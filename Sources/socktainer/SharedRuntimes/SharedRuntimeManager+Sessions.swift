import Foundation

/// Sessions (spec §3.4, F-005, F-006): `create` adds one and starts nothing; `start` joins the
/// container of its group and key and starts the launcher; when the program ends, the session is
/// removed and leaves its container.
extension SharedRuntimeManager {
    enum SessionError: Error, Equatable {
        case nameInUse(String)
        case notRunning(String)
        case running(String)
        case alreadyStarted
    }

    /// Adds a session. A name that another session has is refused.
    func addSession(_ spec: SharedSessionSpec) throws -> SharedSession {
        guard !sessions.values.contains(where: { $0.spec.name == spec.name }) else { throw SessionError.nameInUse(spec.name) }
        let session = SharedSession(spec: spec)
        sessions[spec.id] = session
        return session
    }

    /// A session by full ID, by name (with or without `/`), or by a unique ID prefix.
    func session(_ reference: String) -> SharedSession? {
        if let session = sessions[reference] { return session }
        let name = reference.hasPrefix("/") ? String(reference.dropFirst()) : reference
        if let session = sessions.values.first(where: { $0.spec.name == name }) { return session }
        let matches = sessions.values.filter { $0.spec.id.hasPrefix(reference) }
        return matches.count == 1 ? matches.first : nil
    }

    func allSessions() -> [SharedSession] { Array(sessions.values) }

    func isSessionName(_ name: String) -> Bool {
        sessions.values.contains { $0.spec.name == name }
    }

    // MARK: attach

    /// Called by `attach` before its 101 answer, so that a `start` that arrives before the stream
    /// is bound waits for it.
    func expectAttach(_ session: SharedSession) {
        session.attachExpected = true
    }

    func bindAttach(_ session: SharedSession, stream: SessionStream, stdin: DockerTCPHandler) async {
        guard session.io.bind(stream, stdin: stdin) else {
            await stream.finish()
            return
        }
        let waiting = session.attachWaiters
        session.attachWaiters = []
        waiting.forEach { $0.resume() }
    }

    /// The attach connection is gone: the session ends with all its processes. Before the start,
    /// the start sends the control signal as soon as the program runs.
    func attachDisconnected(_ session: SharedSession) async {
        switch session.phase {
        case .created: session.pendingSignals.append(SharedRuntimeSignal.endNow)
        case .running: try? await deliver(SharedRuntimeSignal.endNow, to: session)
        case .exited: return
        }
    }

    // MARK: start

    /// Starts the session. A container that turns out to be gone is evicted, and the start is
    /// tried once more in a new container.
    func start(_ session: SharedSession) async throws {
        guard session.phase == .created else { throw SessionError.alreadyStarted }
        session.phase = .running
        session.startedAt = Date()
        if session.attachExpected, !session.io.hasStream { await waitForAttach(session) }

        let launched: (container: SharedContainer, process: SharedRuntimeSessionProcess, pipes: StdioPipes)
        do {
            launched = try await launch(session)
        } catch {
            await finish(session, code: 125)
            throw error
        }
        session.container = launched.container
        await onEvent(sessionEvent(session, "start"))
        run(session, process: launched.process, pipes: launched.pipes, container: launched.container)
        let pending = session.pendingSignals
        session.pendingSignals = []
        for signal in pending { try? await deliver(signal, to: session) }
    }

    private func waitForAttach(_ session: SharedSession) async {
        let sleep = sessionSleep
        let timeout = attachTimeout
        let timer = Task {
            try? await sleep(timeout)
            await self.attachWaitExpired(session)
        }
        await withCheckedContinuation { session.attachWaiters.append($0) }
        timer.cancel()
    }

    private func attachWaitExpired(_ session: SharedSession) {
        let waiting = session.attachWaiters
        session.attachWaiters = []
        waiting.forEach { $0.resume() }
    }

    private func launch(_ session: SharedSession) async throws -> (SharedContainer, SharedRuntimeSessionProcess, StdioPipes) {
        let spec = session.spec
        var retried = false
        while true {
            let container = try await join(sessionID: spec.id, group: spec.group, key: spec.key, image: spec.image)
            guard let pipes = StdioPipes.make(.all) else {
                leave(sessionID: spec.id)
                throw SharedRuntimeLauncherError.noPipes
            }
            do {
                let process = try await sessionClient.startSession(
                    containerID: container.nativeID, sessionID: spec.id, process: spec.process,
                    tmpDirectory: spec.tmpDirectory, stdio: pipes.stdioArray)
                return (container, process, pipes)
            } catch {
                pipes.closeAfterHandoff()
                leave(sessionID: spec.id)
                if !retried, await !sessionClient.isRunning(nativeID: container.nativeID) {
                    retried = true
                    containerEnded(container.nativeID)
                    continue
                }
                throw error
            }
        }
    }

    /// After the program has exited, how long the session waits for the rest of its output before it
    /// asks the runtime whether the container still runs, and how long it waits at most.
    static let drainCheck = Duration.seconds(5)
    static let drainLimit = Duration.seconds(60)

    /// Pumps the output, then ends the session in this order: the output readers reach end of
    /// file, the stream is flushed and closed, waiters get the exit code, the session is removed
    /// and leaves its container.
    private func run(_ session: SharedSession, process: SharedRuntimeSessionProcess, pipes: StdioPipes, container: SharedContainer) {
        let io = session.io
        io.connectStdin(pipes.stdin?.write)
        // No stream is bound (no attach, or one that did not bind in time): stdin ends now.
        if !io.hasStream { io.closeStdinIfDetached() }
        let exit = session.exit
        let client = sessionClient
        let sessionID = session.spec.id
        Task.detached {
            let code: Int32
            do {
                code = try await process.wait()
            } catch {
                // The runtime cannot say when the program ends: the launcher ends it now, so no
                // process of the session stays after the session is removed.
                try? await client.signalProcess(containerID: container.nativeID, processID: sessionID, signal: SharedRuntimeSignal.endNow)
                code = 255
            }
            exit.resolve(code)
        }
        let readers = SessionLatch<Bool>()
        let stdout = pipes.stdout?.read
        let stderr = pipes.stderr?.read
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                if let stdout { group.addTask { await SessionOutputReader.read(stdout) { io.output(.stdout, $0) } } }
                if let stderr { group.addTask { await SessionOutputReader.read(stderr) { io.output(.stderr, $0) } } }
            }
            readers.resolve(true)
        }
        let sleep = sessionSleep
        let first = SessionLatch<Bool>()
        Task.detached {
            _ = await readers.wait()
            first.resolve(true)
        }
        Task.detached {
            _ = await exit.wait()
            first.resolve(true)
        }
        Task.detached {
            _ = await first.wait()
            // The program exited first: the launcher has ended its descendants, so the pipes reach
            // end of file and the output that is in them reaches the log and the stream. Only a
            // container that is gone can keep them open; a slow bridge must not lose the output.
            var waited = Duration.zero
            while readers.current == nil, await !self.isContainerGone(session) {
                if await Self.wait(for: readers, limit: Self.drainCheck, sleep: sleep) != nil { break }
                waited += Self.drainCheck
                if await !client.isRunning(nativeID: container.nativeID) {
                    await self.containerEnded(container.nativeID)
                    break
                }
                if waited >= Self.drainLimit { break }
            }
            // The output ended first: the exit code follows, unless the container is gone.
            var code = await Self.wait(for: exit, limit: .seconds(10), sleep: sleep)
            if code == nil {
                if await !client.isRunning(nativeID: container.nativeID) { await self.containerEnded(container.nativeID) }
                code = await exit.wait()
            }
            io.outputEnded(.stdout)
            io.outputEnded(.stderr)
            await self.finish(session, code: code ?? 255)
        }
    }

    private func isContainerGone(_ session: SharedSession) -> Bool { session.containerGone }

    /// The value of `latch`, or nil when `limit` passes first on `sleep`. The sleep is cancelled
    /// when the value comes first.
    nonisolated static func wait<Value: Sendable>(
        for latch: SessionLatch<Value>, limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async -> Value? {
        if let value = latch.current { return value }
        let outcome = SessionLatch<SessionWaitOutcome<Value>>()
        let timer = Task {
            do { try await sleep(limit) } catch { return }
            outcome.resolve(.timedOut)
        }
        Task {
            if let value = await latch.wait() { outcome.resolve(.value(value)) }
        }
        let result = await outcome.wait()
        timer.cancel()
        if case .value(let value) = result { return value }
        return nil
    }

    /// Ends a session: waiters get `code`, the session is removed and leaves its container.
    func finish(_ session: SharedSession, code: Int32) async {
        guard sessions[session.spec.id] === session else { return }
        let wasRunning = session.container != nil
        session.phase = .exited(code)
        session.finishedAt = Date()
        sessions[session.spec.id] = nil
        if wasRunning { leave(sessionID: session.spec.id) }
        await session.io.end()
        session.exit.resolve(code)
        session.ended.resolve(code)
        if wasRunning { await onEvent(sessionEvent(session, "die", ["exitCode": "\(code)"])) }
        await onEvent(sessionEvent(session, "destroy"))
    }

    /// A container ended outside the manager: its slot is evicted, and the sessions whose program
    /// runs in it end. A session that only joined it is still in its start, which tries again in a
    /// new container. The slot can be gone already, so the sessions are found by their container.
    func containerEnded(_ nativeID: String) {
        _ = evict(nativeID: nativeID)
        for session in sessions.values where session.container?.nativeID == nativeID {
            session.containerGone = true
            session.exit.resolve(255)
        }
    }

    // MARK: signals

    /// `kill`: Docker's default and SIGKILL become the control signal 36; SIGSTOP is refused.
    func kill(_ session: SharedSession, signal: String?) async throws {
        let launcherSignal = try SharedRuntimeSignal.launcherSignal(forDocker: signal)
        guard session.phase == .running else { throw SessionError.notRunning(session.spec.id) }
        try await deliver(launcherSignal, to: session)
        await onEvent(sessionEvent(session, "kill", ["signal": signal ?? "SIGKILL"]))
    }

    /// `stop`: the signal of the request or SIGTERM, then the control signal after `timeout`
    /// seconds. The launcher itself ends the program 5 s after the first SIGTERM (spec §3.3), so a
    /// longer `timeout` does not give the program more time. Returns false when not running.
    func stop(_ session: SharedSession, signal: String?, timeout: Int?) async throws -> Bool {
        let first = try SharedRuntimeSignal.launcherSignal(forDocker: signal ?? "SIGTERM")
        guard session.phase == .running else { return false }
        try await deliver(first, to: session)
        if await session.ended.wait(limit: .seconds(max(0, timeout ?? 10))) == nil {
            try await deliver(SharedRuntimeSignal.endNow, to: session)
            _ = await session.ended.wait(limit: .seconds(10))
        }
        return true
    }

    /// `rm`: a created session is removed; a running one needs `force` and ends first.
    func remove(_ session: SharedSession, force: Bool) async throws {
        switch session.phase {
        case .created:
            await finish(session, code: 0)
        case .running:
            guard force else { throw SessionError.running(session.spec.id) }
            try await deliver(SharedRuntimeSignal.endNow, to: session)
            _ = await session.ended.wait(limit: .seconds(10))
        case .exited:
            return
        }
    }

    /// Sends a signal to the launcher. A failure because the container is gone evicts it; a
    /// failure because the program has just exited is not an error.
    private func deliver(_ signal: String, to session: SharedSession) async throws {
        guard let container = session.container else {
            guard session.phase == .running else { throw SessionError.notRunning(session.spec.id) }
            // The start still launches the program: it sends the signal when the program runs.
            session.pendingSignals.append(signal)
            return
        }
        do {
            try await sessionClient.signalProcess(containerID: container.nativeID, processID: session.spec.id, signal: signal)
        } catch {
            if await !sessionClient.isRunning(nativeID: container.nativeID) {
                containerEnded(container.nativeID)
                return
            }
            if session.exit.current != nil || session.phase != .running { return }
            throw error
        }
    }

    func sessionEvent(_ session: SharedSession, _ action: String, _ extra: [String: String] = [:]) -> DockerEvent {
        DockerEvent.simpleEvent(
            id: session.spec.id, type: "container", status: action, image: session.spec.imageName,
            name: session.spec.name, labels: session.spec.labels, extraAttributes: extra)
    }
}

enum SharedRuntimeLauncherError: Error, CustomStringConvertible {
    case noPipes

    var description: String { "could not create the I/O pipes of the session" }
}

enum SessionWaitOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}
