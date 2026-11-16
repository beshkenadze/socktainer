import Darwin
import Foundation
import Testing

@testable import socktainer

@Suite struct StdioHandoffTests {
    enum Failure: Error { case preparation, submission }

    @Test("a failed handoff closes bridge ends and leaves adopted ends alone", arguments: UInt8(0)...UInt8(7))
    func submissionFailure(mask: UInt8) async throws {
        let pipes = try #require(StdioPipes.make(.init(rawValue: mask)))
        defer { pipes.closeAll() }
        let adopted = pipes.stdioArray.compactMap { $0 }
        let retained = [pipes.stdin?.write, pipes.stdout?.read, pipes.stderr?.read].compactMap { $0 }
        for handle in [pipes.stdin?.write, pipes.stdout?.write, pipes.stderr?.write].compactMap({ $0 }) {
            try #require(fcntl(handle.fileDescriptor, F_GETNOSIGPIPE) == 1)
        }
        var attempts = 0
        await #expect(throws: Failure.self) {
            let _: Int = try await pipes.withHandoff(preparing: {}) { stdio in
                attempts += 1
                #expect(stdio.count == 3)
                // The fake callee adopts these handles without raw close/reuse, so
                // a bad cleanup cannot close an fd recycled by another parallel test.
                #expect(stdio[0] === pipes.stdin?.read)
                #expect(stdio[1] === pipes.stdout?.write)
                #expect(stdio[2] === pipes.stderr?.write)
                throw Failure.submission
            }
        }
        #expect(attempts == 1)
        for handle in adopted { #expect(!isClosed(handle), "the callee owns this end after submission") }
        for handle in retained { #expect(isClosed(handle), "the bridge must release its end on error") }
    }

    @Test("failure before handoff closes every end and never calls the operation")
    func preparationFailure() async throws {
        let pipes = try #require(StdioPipes.make(.all))
        defer { pipes.closeAll() }
        let all = pipes.stdioArray.compactMap { $0 } + [pipes.stdin!.write, pipes.stdout!.read, pipes.stderr!.read]
        var attempted = false
        await #expect(throws: Failure.self) {
            let _: Int = try await pipes.withHandoff(preparing: { throw Failure.preparation }) { _ in
                attempted = true
                return 0
            }
        }
        #expect(!attempted)
        for handle in all { #expect(isClosed(handle)) }
    }

    @Test("successful creation leaves bridge ends available for I/O and wait")
    func successfulHandoff() async throws {
        let pipes = try #require(StdioPipes.make(.all))
        defer { pipes.closeAll() }
        let result = try await pipes.withHandoff(preparing: {}) { _ in 42 }
        #expect(result == 42)
        for handle in [pipes.stdin!.write, pipes.stdout!.read, pipes.stderr!.read] {
            #expect(!isClosed(handle))
        }
    }

    // The throwing FileHandle API checks its own closed state before writing.
    // An open pipe read end reports POSIX EBADF; an open protected write end
    // whose reader was released reports EPIPE. Neither is a closed FileHandle.
    private func isClosed(_ handle: FileHandle) -> Bool {
        do {
            try handle.write(contentsOf: Data([0]))
            return false
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && error.code == NSFileWriteUnknownError
                && error.userInfo[NSUnderlyingErrorKey] == nil
        }
    }
}
