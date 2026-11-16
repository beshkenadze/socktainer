import Foundation
import NIOCore
import NIOPosix
import Vapor

/// A raw client on a Unix socket: it writes bytes as given and collects every byte it receives,
/// so a test sees an HTTP upgrade and the hijacked stream after it as the Docker CLI does.
final class RawSocketClient: @unchecked Sendable {
    private final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let client: RawSocketClient
        init(_ client: RawSocketClient) { self.client = client }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { client.append(bytes) }
        }

        func channelInactive(context: ChannelHandlerContext) {
            client.markClosed()
        }

        /// The server ended the stream; with half-closure allowed that is end of input.
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case ChannelEvent.inputClosed = event { client.markClosed() }
            context.fireUserInboundEventTriggered(event)
        }
    }

    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var closed = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var changes = 0
    private(set) var channel: Channel!

    static func connect(path: String, group: EventLoopGroup) async throws -> RawSocketClient {
        let client = RawSocketClient()
        client.channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { $0.pipeline.addHandler(Collector(client)) }
            .connect(unixDomainSocketPath: path).get()
        return client
    }

    func send(_ text: String) async throws {
        try await send(Array(text.utf8))
    }

    func send(_ data: [UInt8]) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    /// Ends the stdin of the session: the client still reads.
    func halfClose() async throws {
        try await channel.close(mode: .output).get()
    }

    func close() async throws {
        try await channel.close().get()
    }

    var received: [UInt8] { lock.withLock { bytes } }
    var isClosed: Bool { lock.withLock { closed } }

    /// The bytes after the HTTP head of the 101 answer.
    var stream: [UInt8] {
        let all = received
        let marker: [UInt8] = Array("\r\n\r\n".utf8)
        guard let end = (0...max(0, all.count - marker.count)).first(where: { all.count >= marker.count && Array(all[$0..<$0 + marker.count]) == marker }) else { return [] }
        return Array(all[(end + marker.count)...])
    }

    /// Suspends until `condition` holds.
    func waitUntil(seconds: Double = 10, _ condition: @escaping @Sendable (RawSocketClient) -> Bool) async -> Bool {
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

    private func append(_ data: [UInt8]) {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            bytes.append(contentsOf: data)
            changes += 1
            defer { observers = [] }
            return observers
        }
        waiting.forEach { $0.resume() }
    }

    private func markClosed() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            closed = true
            changes += 1
            defer { observers = [] }
            return observers
        }
        waiting.forEach { $0.resume() }
    }

    static func upgradeRequest(path: String) -> String {
        "POST \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n"
    }

    /// Docker frames of a multiplexed stream, as (stream type, payload).
    static func frames(_ bytes: [UInt8]) -> [(UInt8, [UInt8])] {
        var frames: [(UInt8, [UInt8])] = []
        var index = 0
        while index + 8 <= bytes.count {
            let size = Int(bytes[index + 4]) << 24 | Int(bytes[index + 5]) << 16 | Int(bytes[index + 6]) << 8 | Int(bytes[index + 7])
            guard index + 8 + size <= bytes.count else { break }
            frames.append((bytes[index], Array(bytes[(index + 8)..<(index + 8 + size)])))
            index += 8 + size
        }
        return frames
    }
}
