import Darwin
import Foundation
import Logging

/// Install before starting any worker threads. A peer closing its input must only fail a write.
func ignoreSIGPIPE() {
    signal(SIGPIPE, SIG_IGN)
}

/// Owns one stdin write end. Callers serialize writes and close (the TCP handler uses its queue).
/// A failed write closes only this input; output draining and process waiting stay independent.
final class StdinForwarder: @unchecked Sendable {
    private let writer: FileHandle
    private let logger: Logger
    private var closed = false
    private(set) var error: Error?

    init(_ writer: FileHandle, logger: Logger) {
        self.writer = writer
        self.logger = logger
        if fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
            fail(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        guard !closed else { return false }
        do {
            try writer.write(contentsOf: data)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ error: Error) {
        self.error = error
        close()
        logger.debug("stdin forwarding stopped: \(error)")
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? writer.close()
    }
}
