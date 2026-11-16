import Darwin
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite struct StdinForwarderTests {
    @Test func closedReaderStopsForwardingWithEPIPE() throws {
        // Foundation Pipe has no per-fd protection: the forwarder must install it itself.
        let pipe = Pipe()
        let fd = pipe.fileHandleForWriting.fileDescriptor
        let forwarder = StdinForwarder(pipe.fileHandleForWriting, logger: Logger(label: "test.stdin"))
        defer { forwarder.close() }
        // Require before closing the reader: removing the fd guard fails safely, without SIGPIPE.
        try #require(fcntl(fd, F_GETNOSIGPIPE) == 1)
        try pipe.fileHandleForReading.close()
        #expect(!forwarder.write(Data([1])))
        let error = try #require(forwarder.error) as NSError
        let posixCode = error.domain == NSPOSIXErrorDomain ? error.code : (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        #expect(posixCode == Int(EPIPE))
        #expect(stdinHandleIsClosed(pipe.fileHandleForWriting))
        // Later input is dropped without another write or replacing the original error.
        #expect(!forwarder.write(Data([2])))
        #expect((forwarder.error as NSError?) == error)
    }

    @Test func processPipesSuppressSIGPIPE() throws {
        let pipe = try #require(ProcessPipe.make())
        defer {
            try? pipe.read.close()
            try? pipe.write.close()
        }
        #expect(fcntl(pipe.write.fileDescriptor, F_GETNOSIGPIPE) == 1)
    }

    @Test func startupIgnoresSIGPIPE() throws {
        var previous = sigaction()
        try #require(sigaction(SIGPIPE, nil, &previous) == 0)
        defer { sigaction(SIGPIPE, &previous, nil) }
        signal(SIGPIPE, SIG_DFL)
        ignoreSIGPIPE()
        var current = sigaction()
        try #require(sigaction(SIGPIPE, nil, &current) == 0)
        #expect(unsafeBitCast(current.__sigaction_u.__sa_handler, to: UInt.self) == unsafeBitCast(SIG_IGN, to: UInt.self))
    }
}

/// Only for a protected writer whose reader is already closed. An open handle reports
/// EPIPE with an underlying POSIX error; Foundation reports a closed handle without one.
/// Checking the saved fd with fcntl would race other tests recycling that fd number.
func stdinHandleIsClosed(_ writer: FileHandle) -> Bool {
    do {
        try writer.write(contentsOf: Data([0]))
        return false
    } catch {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileWriteUnknownError
            && error.userInfo[NSUnderlyingErrorKey] == nil
    }
}
