import Foundation
import NIOCore
import Vapor

/// `logs` of a session (F-010), from its log buffer.
extension SharedRuntimeRouter {
    static func logs(_ req: Request, _ session: SharedSession) throws -> Response {
        let stdout = req.query[Bool.self, at: "stdout"] ?? false
        let stderr = req.query[Bool.self, at: "stderr"] ?? false
        guard stdout || stderr else { throw Abort(.badRequest, reason: "You must choose at least one stream") }
        let tail = req.query[String.self, at: "tail"].flatMap { $0 == "all" ? nil : Int($0) }
        let timestamps = req.query[Bool.self, at: "timestamps"] ?? false
        let follow = req.query[Bool.self, at: "follow"] ?? false
        let (records, more) = session.io.logRecords(stdout: stdout, stderr: stderr, tail: tail, follow: follow)
        let wanted: @Sendable (SessionLogBuffer.Record) -> Bool = { ($0.stream == .stdout && stdout) || ($0.stream == .stderr && stderr) }
        let body = Response.Body(managedAsyncStream: { writer in
            for record in records { try await writer.write(.buffer(frame(record, timestamps: timestamps))) }
            guard let more else { return }
            for await record in more where wanted(record) {
                try await writer.write(.buffer(frame(record, timestamps: timestamps)))
            }
        })
        return Response(status: .ok, headers: ["Content-Type": "application/vnd.docker.multiplexed-stream"], body: body)
    }

    static func frame(_ record: SessionLogBuffer.Record, timestamps: Bool) -> ByteBuffer {
        var data = record.data
        if timestamps {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            data = Data((formatter.string(from: record.time) + " ").utf8) + data
        }
        var buffer = ByteBuffer()
        buffer.writeDockerFrame(streamType: record.stream, data: data, ttyMode: false)
        return buffer
    }
}
