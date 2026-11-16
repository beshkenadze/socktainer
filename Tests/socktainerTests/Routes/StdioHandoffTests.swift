import ContainerizationError
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

extension StdioHandoffTests {
    @Test("bootstrap never replays adopted pipes, but can retry without stdio", arguments: [false, true])
    func bootstrapFailure(hasPipes: Bool) async throws {
        let pipes: StdioPipes? = hasPipes ? try #require(StdioPipes.make(.all)) : nil
        defer { pipes?.closeAll() }
        if let pipes {
            for handle in [pipes.stdin!.write, pipes.stdout!.write, pipes.stderr!.write] {
                try #require(fcntl(handle.fileDescriptor, F_GETNOSIGPIPE) == 1)
            }
        }
        let attempts = Counter()
        let generations = Counter()
        let client = ReconnectingContainerClient<Int>(makeClient: { generations.nextSync() })
        let operation: @Sendable (Int, [FileHandle?]) async throws -> Int = { generation, stdio in
            #expect(stdio.count == 3)
            #expect(stdio[0] === pipes?.stdin?.read)
            #expect(stdio[1] === pipes?.stdout?.write)
            #expect(stdio[2] === pipes?.stderr?.write)
            let attempt = attempts.nextSync()
            if hasPipes || attempt == 1 {
                throw ContainerizationError(.internalError, message: "bootstrap failed", cause: ContainerizationError(.interrupted, message: "reply lost"))
            }
            return generation
        }
        if let pipes {
            await #expect(throws: ContainerizationError.self) {
                try await client.withBootstrapStdio(pipes, operation)
            }
            #expect(attempts.countSync() == 1)
            for handle in pipes.stdioArray.compactMap({ $0 }) {
                let closed = isClosed(handle)
                #expect(!closed, "bootstrap owns the supplied end, even after a failure")
            }
            for handle in [pipes.stdin!.write, pipes.stdout!.read, pipes.stderr!.read] {
                let closed = isClosed(handle)
                #expect(closed, "the failed bootstrap must release bridge ends")
            }
        } else {
            let generation = try await client.withBootstrapStdio(nil, operation)
            #expect(generation == 2)
            #expect(attempts.countSync() == 2)
        }
        #expect(await client.reconnectCount == 1)
        let nextGeneration = try await client.withClient { $0 }
        #expect(nextGeneration == 2)
    }
}
