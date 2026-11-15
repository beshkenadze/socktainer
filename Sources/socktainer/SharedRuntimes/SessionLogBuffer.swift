import Foundation

/// The newest output of a session (F-010): whole records of up to 256 KiB of payload, each with
/// its stream. A record is one line; a line without its newline waits until the newline or the
/// end of the stream arrives. Eviction removes whole records, oldest first.
struct SessionLogBuffer: Sendable {
    struct Record: Sendable, Equatable {
        let stream: DockerStreamFrame.StreamType
        let time: Date
        let data: Data
    }

    static let capacity = 256 * 1024

    private(set) var records: [Record] = []
    private(set) var payloadBytes = 0
    private var partial: [DockerStreamFrame.StreamType: Data] = [:]
    let capacity: Int

    init(capacity: Int = SessionLogBuffer.capacity) {
        self.capacity = capacity
    }

    /// Adds output and returns the records that it completed.
    @discardableResult
    mutating func append(_ stream: DockerStreamFrame.StreamType, _ data: Data, time: Date = Date()) -> [Record] {
        var pending = (partial[stream] ?? Data()) + data
        var added: [Record] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex...newline]
            added.append(contentsOf: Self.cut(Data(line), stream: stream, time: time, capacity: capacity))
            pending = Data(pending[(newline + 1)...])
        }
        // A line without a newline must not grow without limit: its full parts become records.
        while pending.count >= capacity {
            added.append(Record(stream: stream, time: time, data: Data(pending.prefix(capacity))))
            pending = Data(pending.dropFirst(capacity))
        }
        partial[stream] = pending.isEmpty ? nil : pending
        for record in added { store(record) }
        return added
    }

    /// Keeps the rest of a stream that ended without a newline, and returns it.
    @discardableResult
    mutating func finish(_ stream: DockerStreamFrame.StreamType, time: Date = Date()) -> Record? {
        guard let rest = partial.removeValue(forKey: stream) else { return nil }
        let record = Record(stream: stream, time: time, data: rest)
        store(record)
        return record
    }

    /// The records of the requested streams, the last `tail` of them when `tail` is set.
    func select(stdout: Bool, stderr: Bool, tail: Int?) -> [Record] {
        let matching = records.filter { ($0.stream == .stdout && stdout) || ($0.stream == .stderr && stderr) }
        guard let tail else { return matching }
        return Array(matching.suffix(max(0, tail)))
    }

    var pendingBytes: Int { partial.values.reduce(0) { $0 + $1.count } }

    /// No record is larger than the capacity, so the buffer never holds more than it.
    private mutating func store(_ record: Record) {
        records.append(record)
        payloadBytes += record.data.count
        while payloadBytes > capacity {
            payloadBytes -= records.removeFirst().data.count
        }
    }

    private static func cut(_ line: Data, stream: DockerStreamFrame.StreamType, time: Date, capacity: Int) -> [Record] {
        stride(from: 0, to: line.count, by: capacity).map {
            Record(stream: stream, time: time, data: line.subdata(in: $0..<min($0 + capacity, line.count)))
        }
    }
}
