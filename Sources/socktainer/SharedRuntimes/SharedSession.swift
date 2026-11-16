import Foundation
import NIOCore

/// What `create` decided for a session; it does not change.
struct SharedSessionSpec: Sendable {
    let id: String
    let name: String
    let group: RuntimeGroup
    let key: SharingKey
    let process: SharedRuntimeProcess
    let image: SharedRuntimeManager.Image
    /// The image ID, the config digest that `docker image inspect` reports as `Id`.
    let imageID: String
    /// The image as the client wrote it.
    let imageName: String
    let labels: [String: String]
    let created: Date

    /// The `TMPDIR` of the session (F-013); the launcher creates it and removes it.
    var tmpDirectory: String { "/tmp/cs-session-\(id.prefix(12))" }
}

/// A session: a process in a shared container that the client sees as a container of its own.
/// The manager actor changes its state; its I/O has a lock of its own.
final class SharedSession: @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case created
        case running
        case exited(Int32)
    }

    let spec: SharedSessionSpec
    let io = SharedSessionIO()

    // Changed by SharedRuntimeManager only.
    var phase = Phase.created
    var container: SharedRuntimeManager.SharedContainer?
    var startedAt: Date?
    var finishedAt: Date?
    /// The exit code of the program; 255 when the runtime cannot say it.
    let exit = SessionLatch<Int32>()
    /// Set when the session has ended and was removed.
    let ended = SessionLatch<Int32>()
    var attachExpected = false
    var attachWaiters: [CheckedContinuation<Void, Never>] = []
    var removeWhenCreated = false
    /// Set when its container ended outside the manager: no output can come any more.
    var containerGone = false
    /// Signals that arrived while the start launched the program; the start sends them after.
    var pendingSignals: [String] = []

    init(spec: SharedSessionSpec) {
        self.spec = spec
    }
}

/// The pipes, the attached stream and the log buffer of a session.
final class SharedSessionIO: @unchecked Sendable {
    private let lock = NSLock()
    private var logs = SessionLogBuffer()
    private var stream: SessionStream?
    private var stdinHandler: DockerTCPHandler?
    private var stdinWriter: FileHandle?
    private var followers: [UUID: AsyncStream<SessionLogBuffer.Record>.Continuation] = [:]
    private var ended = false

    var hasStream: Bool { lock.withLock { stream != nil } }

    /// Binds the attach connection. Its stdin reaches the program once the session runs.
    /// A session has one attach connection. Returns false when the session has ended or has its
    /// connection already: the caller closes the stream.
    func bind(_ stream: SessionStream, stdin handler: DockerTCPHandler) -> Bool {
        let (bound, writer): (Bool, FileHandle?) = lock.withLock {
            guard !ended, self.stream == nil else { return (false, nil) }
            self.stream = stream
            stdinHandler = handler
            defer { stdinWriter = nil }
            return (true, stdinWriter)
        }
        if let writer { handler.setStdinWriter(writer) }
        return bound
    }

    /// Gives the write end of stdin to the attached connection, or closes it when no client
    /// is attached: the program then reads end of file.
    func connectStdin(_ writer: FileHandle?) {
        guard let writer else { return }
        let handler: DockerTCPHandler? = lock.withLock {
            if stdinHandler == nil { stdinWriter = writer }
            return stdinHandler
        }
        if let handler { handler.setStdinWriter(writer) }
    }

    /// Closes stdin when no client attached before the start.
    func closeStdinIfDetached() {
        let writer: FileHandle? = lock.withLock {
            defer { stdinWriter = nil }
            return stdinWriter
        }
        try? writer?.close()
    }

    func output(_ kind: DockerStreamFrame.StreamType, _ data: Data) {
        let (target, records, listeners) = lock.withLock {
            (stream, logs.append(kind, data), Array(followers.values))
        }
        target?.send(kind, data)
        for record in records { listeners.forEach { $0.yield(record) } }
    }

    func outputEnded(_ kind: DockerStreamFrame.StreamType) {
        let (record, listeners) = lock.withLock { (logs.finish(kind), Array(followers.values)) }
        if let record { listeners.forEach { $0.yield(record) } }
    }

    func logRecords(stdout: Bool, stderr: Bool, tail: Int?) -> [SessionLogBuffer.Record] {
        lock.withLock { logs.select(stdout: stdout, stderr: stderr, tail: tail) }
    }

    /// The selected records, and with `follow` the records written after them until the session
    /// ends. Both are taken under one lock, so no record is lost or repeated between them.
    func logRecords(stdout: Bool, stderr: Bool, tail: Int?, follow: Bool) -> ([SessionLogBuffer.Record], AsyncStream<SessionLogBuffer.Record>?) {
        guard follow else { return (logRecords(stdout: stdout, stderr: stderr, tail: tail), nil) }
        let (stream, continuation) = AsyncStream<SessionLogBuffer.Record>.makeStream()
        let id = UUID()
        let (records, alreadyEnded): ([SessionLogBuffer.Record], Bool) = lock.withLock {
            if !ended { followers[id] = continuation }
            return (logs.select(stdout: stdout, stderr: stderr, tail: tail), ended)
        }
        if alreadyEnded { continuation.finish() }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.followers.removeValue(forKey: id) }
        }
        return (records, stream)
    }

    /// Flushes and closes the attached stream, and ends the followers.
    func end() async {
        let (target, listeners) = lock.withLock {
            ended = true
            defer { followers = [:] }
            return (stream, Array(followers.values))
        }
        listeners.forEach { $0.finish() }
        await target?.finish()
    }
}

/// Reads a pipe to its end without holding a thread of the cooperative pool.
enum SessionOutputReader {
    static func read(_ handle: FileHandle, _ onChunk: @escaping @Sendable (Data) -> Void) async {
        let queue = DispatchQueue.global(qos: .userInitiated)
        let io = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
        }
        io.setLimit(lowWater: 1)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            io.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
                if let data, !data.isEmpty { onChunk(Data(data)) }
                if done || error != 0 {
                    io.close()
                    continuation.resume()
                }
            }
        }
    }
}
