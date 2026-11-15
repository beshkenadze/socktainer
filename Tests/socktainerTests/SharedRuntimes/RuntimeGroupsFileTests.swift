import Foundation
import Testing

@testable import socktainer

@Suite struct RuntimeGroupsFileTests {
    private let directory: URL
    private var path: String { directory.appendingPathComponent("runtime-groups.json").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-groups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(_ json: String, modified: Date) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    private func cleanup() { try? FileManager.default.removeItem(at: directory) }

    private static let oneGroup = #"{"version":1,"groups":[{"name":"one","kind":"exec","idleMinutes":5,"enabled":true}],"rules":[]}"#
    private static let otherGroup = #"{"version":1,"groups":[{"name":"two","kind":"exec","idleMinutes":30,"enabled":true}],"rules":[]}"#

    @Test func missingFileMeansTheDefaults() async {
        defer { cleanup() }
        let state = await RuntimeGroupsFile(path: path).current()
        #expect(state == .active(.defaults))
    }

    @Test func malformedFileTurnsGroupingOffWithACause() async throws {
        defer { cleanup() }
        try write(#"{"version":1,"groups":[],"rules":[],"oops":1}"#, modified: Date(timeIntervalSince1970: 1_000))
        let state = await RuntimeGroupsFile(path: path).current()
        guard case .off(let cause) = state else {
            Issue.record("expected grouping off, got \(state)")
            return
        }
        #expect(cause.contains("runtime-groups.json"))
        #expect(cause.contains("oops"))
    }

    @Test func unknownVersionTurnsGroupingOffWithACause() async throws {
        defer { cleanup() }
        try write(#"{"version":2,"groups":[],"rules":[]}"#, modified: Date(timeIntervalSince1970: 1_000))
        let state = await RuntimeGroupsFile(path: path).current()
        #expect(state == .off(cause: "runtime-groups.json: unsupported version 2"))
    }

    @Test func fileIsReadAgainWhenItsModificationTimeChanges() async throws {
        defer { cleanup() }
        let file = RuntimeGroupsFile(path: path)
        try write(Self.oneGroup, modified: Date(timeIntervalSince1970: 1_000))
        #expect(await file.current().document?.groups.map(\.name) == ["one"])

        try write(Self.otherGroup, modified: Date(timeIntervalSince1970: 2_000))
        #expect(await file.current().document?.groups.map(\.name) == ["two"])
    }

    @Test func fileIsNotReadAgainWhileItsModificationTimeIsTheSame() async throws {
        defer { cleanup() }
        let file = RuntimeGroupsFile(path: path)
        try write(Self.oneGroup, modified: Date(timeIntervalSince1970: 1_000))
        #expect(await file.current().document?.groups.map(\.name) == ["one"])

        try write(Self.otherGroup, modified: Date(timeIntervalSince1970: 1_000))
        #expect(await file.current().document?.groups.map(\.name) == ["one"])
    }

    @Test func aChangeOfTheTargetOfASymlinkIsSeen() async throws {
        defer { cleanup() }
        let target = directory.appendingPathComponent("target.json").path
        try Data(Self.oneGroup.utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: target)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        let file = RuntimeGroupsFile(path: path)
        #expect(await file.current().document?.groups.map(\.name) == ["one"])

        try Data(Self.otherGroup.utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: target)
        #expect(await file.current().document?.groups.map(\.name) == ["two"])
    }

    @Test func removingTheFileReturnsToTheDefaultsAndAFixedFileTurnsGroupingOn() async throws {
        defer { cleanup() }
        let file = RuntimeGroupsFile(path: path)
        try write("{", modified: Date(timeIntervalSince1970: 1_000))
        #expect(await file.current().document == nil)

        try write(Self.oneGroup, modified: Date(timeIntervalSince1970: 2_000))
        #expect(await file.current().document?.groups.map(\.name) == ["one"])

        try FileManager.default.removeItem(atPath: path)
        #expect(await file.current() == .active(.defaults))
    }
}
