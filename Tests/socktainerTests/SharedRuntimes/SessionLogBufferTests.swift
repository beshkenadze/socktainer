import Foundation
import Testing

@testable import socktainer

@Suite struct SessionLogBufferTests {
    @Test func linesAreRecordsAndAPartialLineWaitsForItsNewline() {
        var buffer = SessionLogBuffer()
        buffer.append(.stdout, Data("one\ntw".utf8))
        #expect(buffer.records.map(\.data) == [Data("one\n".utf8)])
        buffer.append(.stdout, Data("o\nthree".utf8))
        buffer.finish(.stdout)
        #expect(buffer.records.map(\.data) == ["one\n", "two\n", "three"].map { Data($0.utf8) })
    }

    @Test func eachStreamKeepsItsOwnPartialLine() {
        var buffer = SessionLogBuffer()
        buffer.append(.stdout, Data("out-".utf8))
        buffer.append(.stderr, Data("err\n".utf8))
        buffer.append(.stdout, Data("line\n".utf8))
        #expect(buffer.records.map(\.stream) == [.stderr, .stdout])
        #expect(buffer.records.map(\.data) == [Data("err\n".utf8), Data("out-line\n".utf8)])
    }

    @Test func evictionRemovesWholeRecordsAndKeepsTheNewest() {
        var buffer = SessionLogBuffer()
        let line = String(repeating: "x", count: 1023) + "\n"
        for index in 0..<300 {
            buffer.append(index.isMultiple(of: 2) ? .stdout : .stderr, Data(line.utf8))
        }
        #expect(buffer.payloadBytes <= SessionLogBuffer.capacity)
        #expect(buffer.records.count == 256)
        #expect(buffer.records.allSatisfy { $0.data.count == 1024 })
        #expect(buffer.records.first?.stream == .stdout)
    }

    @Test func outputWithoutNewlinesStaysWithinTheCapacity() {
        var buffer = SessionLogBuffer()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 60 * 1024)
        for _ in 0..<10 { buffer.append(.stdout, chunk) }
        #expect(buffer.pendingBytes < SessionLogBuffer.capacity)
        #expect(buffer.payloadBytes <= SessionLogBuffer.capacity)
        #expect(buffer.records.allSatisfy { $0.data.count <= SessionLogBuffer.capacity })

        var long = SessionLogBuffer()
        long.append(.stderr, Data(repeating: UInt8(ascii: "y"), count: 300 * 1024) + Data("\n".utf8))
        #expect(long.payloadBytes <= SessionLogBuffer.capacity)
        #expect(long.records.allSatisfy { $0.data.count <= SessionLogBuffer.capacity })
    }

    @Test func selectFiltersStreamsAndTails() {
        var buffer = SessionLogBuffer()
        for index in 0..<6 {
            buffer.append(index.isMultiple(of: 2) ? .stdout : .stderr, Data("\(index)\n".utf8))
        }
        #expect(buffer.select(stdout: true, stderr: false, tail: nil).map(\.data) == ["0\n", "2\n", "4\n"].map { Data($0.utf8) })
        #expect(buffer.select(stdout: false, stderr: true, tail: 1).map(\.data) == [Data("5\n".utf8)])
        #expect(buffer.select(stdout: true, stderr: true, tail: 0).isEmpty)
    }
}
