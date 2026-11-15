import Foundation

@testable import socktainer

/// A `SharedRuntimeClient` that records calls. `create` and `remove` can be held: a held call
/// suspends until the test releases it. Tests wait for a state with `waitUntil`, which
/// suspends and never blocks a thread.
actor FakeSharedRuntimeClient: SharedRuntimeClient {
    struct State: Sendable {
        var created: [SharedContainerSpec] = []
        var removed: [String] = []
        var createsInFlight = 0
        var removesInFlight = 0
        var removeAttempts = 0
        var listCalls = 0
        var signals: [(containerID: String, processID: String, signal: String)] = []
    }

    enum Failure: Error { case injected }

    private(set) var state = State()
    var records: [SharedRuntimeContainerRecord] = []
    var holdCreates = false
    var holdRemoves = false
    var failCreates = false
    var failList = false
    /// The number of next removals that fail.
    var failRemoves = 0
    /// When set, `listContainers` never returns.
    var listNeverReturns = false

    private var heldCreates: [CheckedContinuation<Void, Never>] = []
    private var heldRemoves: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func configure(_ change: @Sendable (isolated FakeSharedRuntimeClient) -> Void) { change(self) }

    func createSharedContainer(_ spec: SharedContainerSpec) async throws {
        state.created.append(spec)
        state.createsInFlight += 1
        changed()
        if holdCreates { await withCheckedContinuation { heldCreates.append($0) } }
        state.createsInFlight -= 1
        changed()
        if failCreates { throw Failure.injected }
    }

    func removeSharedContainer(nativeID: String) async throws {
        state.removesInFlight += 1
        changed()
        if holdRemoves { await withCheckedContinuation { heldRemoves.append($0) } }
        state.removesInFlight -= 1
        state.removeAttempts += 1
        if failRemoves > 0 {
            failRemoves -= 1
            changed()
            throw Failure.injected
        }
        state.removed.append(nativeID)
        records.removeAll { $0.nativeID == nativeID }
        changed()
    }

    func listContainers() async throws -> [SharedRuntimeContainerRecord] {
        state.listCalls += 1
        changed()
        if listNeverReturns {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        if failList { throw Failure.injected }
        return records
    }

    func signalProcess(containerID: String, processID: String, signal: String) async throws {
        state.signals.append((containerID, processID, signal))
        changed()
        if failSignals { throw Failure.injected }
    }

    /// A session program that the test drives through the handles that the runtime got.
    final class Program: SharedRuntimeSessionProcess, @unchecked Sendable {
        let sessionID: String
        let containerID: String
        let process: SharedRuntimeProcess
        let tmpDirectory: String
        let stdin: FileHandle?
        let stdout: FileHandle?
        let stderr: FileHandle?
        private let lock = NSLock()
        private var code: Int32?
        private var waiters: [CheckedContinuation<Int32, Error>] = []
        private var waitFailed = false

        init(sessionID: String, containerID: String, process: SharedRuntimeProcess, tmpDirectory: String, stdio: [FileHandle?]) {
            self.sessionID = sessionID
            self.containerID = containerID
            self.process = process
            self.tmpDirectory = tmpDirectory
            stdin = stdio.count > 0 ? stdio[0] : nil
            stdout = stdio.count > 1 ? stdio[1] : nil
            stderr = stdio.count > 2 ? stdio[2] : nil
        }

        func write(stdout text: String) { try? stdout?.write(contentsOf: Data(text.utf8)) }
        func write(stderr text: String) { try? stderr?.write(contentsOf: Data(text.utf8)) }

        /// Reads stdin until end of file, off the cooperative pool.
        func readStdin() async -> Data {
            guard let stdin else { return Data() }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: (try? stdin.readToEnd()) ?? Data()) }
            }
        }

        /// Stdin until end of file, or nil when it does not end within `seconds`.
        func readStdin(limit seconds: Double) async -> Data? {
            let result = SessionLatch<Data>()
            if let stdin {
                DispatchQueue.global().async { result.resolve((try? stdin.readToEnd()) ?? Data()) }
            } else {
                result.resolve(Data())
            }
            return await result.wait(limit: .seconds(seconds))
        }

        /// The program exits: the runtime closes its handles, then `wait` returns `code`.
        func exit(_ code: Int32) {
            try? stdin?.close()
            try? stdout?.close()
            try? stderr?.close()
            let waiting: [CheckedContinuation<Int32, Error>] = lock.withLock {
                guard self.code == nil else { return [] }
                self.code = code
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume(returning: code) }
        }

        /// The program exits, but its output stays open: something still holds the pipes.
        func exitKeepingOutput(_ code: Int32) {
            try? stdin?.close()
            let waiting: [CheckedContinuation<Int32, Error>] = lock.withLock {
                guard self.code == nil else { return [] }
                self.code = code
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume(returning: code) }
        }

        func closeOutput() {
            try? stdout?.close()
            try? stderr?.close()
        }

        /// The runtime loses the program: `wait` fails, and the program still runs.
        func failWait() {
            let waiting: [CheckedContinuation<Int32, Error>] = lock.withLock {
                waitFailed = true
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume(throwing: Failure.injected) }
        }

        var hasExited: Bool { lock.withLock { code != nil } }

        func wait() async throws -> Int32 {
            try await withCheckedThrowingContinuation { continuation in
                let (done, failed): (Int32?, Bool) = lock.withLock {
                    if let code { return (code, false) }
                    if waitFailed { return (nil, true) }
                    waiters.append(continuation)
                    return (nil, false)
                }
                if let done { continuation.resume(returning: done) }
                if failed { continuation.resume(throwing: Failure.injected) }
            }
        }
    }

    private(set) var programs: [Program] = []
    /// Native IDs that `isRunning` reports as gone.
    var goneContainers: Set<String> = []
    /// The number of next session starts that fail; the runtime still closes their handles.
    var failSessionStarts = 0
    /// Signals that fail.
    var failSignals = false

    func startSession(
        containerID: String, sessionID: String, process: SharedRuntimeProcess, tmpDirectory: String, stdio: [FileHandle?]
    ) async throws -> SharedRuntimeSessionProcess {
        if failSessionStarts > 0 {
            failSessionStarts -= 1
            stdio.forEach { try? $0?.close() }
            changed()
            throw Failure.injected
        }
        let program = Program(sessionID: sessionID, containerID: containerID, process: process, tmpDirectory: tmpDirectory, stdio: stdio)
        programs.append(program)
        changed()
        return program
    }

    func isRunning(nativeID: String) async -> Bool {
        state.created.contains { $0.name == nativeID } && !goneContainers.contains(nativeID) && !state.removed.contains(nativeID)
    }

    func program(_ sessionID: String) -> Program? { programs.last { $0.sessionID == sessionID } }

    /// Suspends until the program of `sessionID` has started.
    func waitForProgram(_ sessionID: String) async -> Program {
        while true {
            if let program = program(sessionID) { return program }
            await withCheckedContinuation { observers.append($0) }
        }
    }

    func releaseCreates() {
        holdCreates = false
        heldCreates.forEach { $0.resume() }
        heldCreates = []
    }

    func releaseRemoves() {
        holdRemoves = false
        heldRemoves.forEach { $0.resume() }
        heldRemoves = []
    }

    /// Suspends until `condition` holds for the recorded state.
    /// False when `condition` is still false after `seconds`.
    func waitUntil(seconds: Double, _ condition: @Sendable (State) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(state) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func waitUntil(_ condition: @Sendable (State) -> Bool) async {
        while !condition(state) {
            await withCheckedContinuation { observers.append($0) }
        }
    }

    private func changed() {
        let waiting = observers
        observers = []
        waiting.forEach { $0.resume() }
    }
}
