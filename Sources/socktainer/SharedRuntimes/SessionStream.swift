import Foundation
import NIOCore

/// The hijacked `attach` connection of a session.
///
/// A client that ends its stdin half-closes the connection and still reads the answer; a client
/// that is gone closes it. Both arrive as end of input, because the connection allows a remote
/// half-close. So while the session runs, the stream writes an empty stdout frame at an interval:
/// Docker's stream demultiplexer skips it, and on a closed connection the write fails and closes
/// the channel. `onDisconnect` runs when the channel closes before the session closed it.
final class SessionStream: @unchecked Sendable {
    static let probeInterval = TimeAmount.seconds(1)

    private let channel: Channel
    private let lock = NSLock()
    private var closing = false
    private var probe: RepeatedTask?

    init(channel: Channel, probeInterval: TimeAmount = SessionStream.probeInterval, onDisconnect: @escaping @Sendable () -> Void) {
        self.channel = channel
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            let byClient: Bool = self.lock.withLock {
                self.probe?.cancel()
                return !self.closing
            }
            if byClient { onDisconnect() }
        }
        let probe = channel.eventLoop.scheduleRepeatedTask(initialDelay: probeInterval, delay: probeInterval) { [weak self] _ in
            self?.send(.stdout, Data())
        }
        lock.withLock { self.probe = probe }
    }

    var isActive: Bool { channel.isActive }

    /// The bytes that may wait for a client that reads slowly. Past this, the connection closes and
    /// the session ends as for a disconnect: one slow client cannot fill the memory of the bridge.
    static let queueLimit = 8 * 1024 * 1024
    /// Changed on the event loop only.
    private var queued = 0

    /// Writes one Docker frame; an empty `data` writes an empty frame.
    func send(_ stream: DockerStreamFrame.StreamType, _ data: Data) {
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: data.count + 8)
            buffer.writeDockerFrame(streamType: stream, data: data, ttyMode: false)
            let size = buffer.readableBytes
            guard self.queued + size <= Self.queueLimit else {
                channel.close(promise: nil)
                return
            }
            self.queued += size
            let written = channel.eventLoop.makePromise(of: Void.self)
            written.futureResult.whenComplete { _ in self.queued -= size }
            channel.writeAndFlush(buffer, promise: written)
        }
    }

    static let flushLimit = TimeAmount.seconds(5)

    /// Writes what is queued, then closes the connection. A client that does not read keeps the
    /// writes queued: after `flushLimit` the connection closes and the rest is dropped.
    func finish() async {
        lock.withLock {
            closing = true
            probe?.cancel()
        }
        let channel = self.channel
        let deadline = channel.eventLoop.scheduleTask(in: Self.flushLimit) { channel.close(promise: nil) }
        let barrier = channel.eventLoop.flatSubmit {
            channel.writeAndFlush(channel.allocator.buffer(capacity: 0))
        }
        try? await barrier.get()
        deadline.cancel()
        try? await channel.close().get()
    }
}
