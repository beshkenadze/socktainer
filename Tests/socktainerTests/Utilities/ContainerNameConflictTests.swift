import ContainerizationError
import Foundation
import Testing
import Vapor

@testable import socktainer

/// A container name is in use when the data root's file system already has its directory.
@Suite struct ContainerNameConflictTests {
    private final class Root {
        let dir: URL
        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("name-conflict-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("web"), withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
    }

    private static func tempDirIsCaseInsensitive() -> Bool {
        let base = FileManager.default.temporaryDirectory
        let probe = base.appendingPathComponent("CaseProbe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else {
            return false
        }
        defer { try? FileManager.default.removeItem(at: probe) }
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(probe.lastPathComponent.lowercased()).path)
    }

    @Test(
        "a name that the file system folds onto an existing container is refused with 409 and the existing name",
        .enabled(if: tempDirIsCaseInsensitive(), "needs a case-insensitive temporary directory")
    )
    func foldedNameIsRefused() throws {
        let root = try Root()
        #expect(ContainerNameConflict.existingEntry(id: "WEB", containersDirectory: root.dir) == "web")
        let error = #expect(throws: Abort.self) {
            try ContainerNameConflict.guardCreate(name: "WEB", containersDirectory: root.dir)
        }
        #expect(error?.status == .conflict)
        #expect(error?.reason.contains("\"/WEB\" is already in use by container \"web\"") == true)
    }

    @Test("an unused name passes, the exact name of an existing container does not")
    func exactAndUnusedNames() throws {
        let root = try Root()
        #expect(ContainerNameConflict.existingEntry(id: "api", containersDirectory: root.dir) == nil)
        try ContainerNameConflict.guardCreate(name: "api", containersDirectory: root.dir)
        #expect(throws: Abort.self) {
            try ContainerNameConflict.guardCreate(name: "web", containersDirectory: root.dir)
        }
        try ContainerNameConflict.guardCreate(name: "web", containersDirectory: nil)
    }

    @Test("the runtime's refusal of a name in use becomes 409; other errors do not")
    func runtimeRefusalMapsTo409() throws {
        let root = try Root()
        let inUse = ContainerizationError(.exists, message: "container already exists: web")
        #expect(ContainerNameConflict.conflict(after: inUse, name: "web", containersDirectory: root.dir)?.status == .conflict)
        // .exists for another reason (a hostname): no directory under the name, no 409.
        let hostname = ContainerizationError(.exists, message: "hostname(s) already exist: [\"api\"]")
        #expect(ContainerNameConflict.conflict(after: hostname, name: "api", containersDirectory: root.dir) == nil)
        let other = ContainerizationError(.internalError, message: "boom")
        #expect(ContainerNameConflict.conflict(after: other, name: "web", containersDirectory: root.dir) == nil)
        #expect(ContainerNameConflict.conflict(after: inUse, name: "web", containersDirectory: nil) == nil)
    }
}
