import ContainerResource
import Foundation
import Testing

@testable import socktainer

/// A rename deletes and re-creates: it goes on only when the bridge can show the container never ran.
@Suite struct RenameSafetyTests {
    private final class Root {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rename-safety-\(UUID().uuidString)")
        func directory(_ id: String, files: [String]) throws {
            let directory = url.appendingPathComponent("containers").appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in files {
                try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private func snapshot(_ id: String, status: RuntimeStatus = .stopped, started: Date? = nil) throws -> ContainerSnapshot {
        var snapshot = try makeContainerSnapshot(nativeId: id, networks: [], labels: [:])
        snapshot.status = status
        snapshot.startedDate = started
        return snapshot
    }

    @Test("a container created and never started passes")
    func createdOnlyPasses() throws {
        let root = Root()
        try root.directory("web", files: ["runtime-configuration.json"])
        #expect(RenameSafety.reasonToRefuse(try snapshot("web"), hasExitRecord: false, hasRunHistory: false, appRoot: root.url) == nil)
    }

    @Test("each sign of a run, and each doubt, refuses")
    func everyDoubtRefuses() throws {
        let root = Root()
        try root.directory("web", files: ["runtime-configuration.json"])
        let web = try snapshot("web")
        let cases: [(String, String?)] = [
            ("running", RenameSafety.reasonToRefuse(try snapshot("web", status: .running), hasExitRecord: false, hasRunHistory: false, appRoot: root.url)),
            ("stopping", RenameSafety.reasonToRefuse(try snapshot("web", status: .stopping), hasExitRecord: false, hasRunHistory: false, appRoot: root.url)),
            ("unknown", RenameSafety.reasonToRefuse(try snapshot("web", status: .unknown), hasExitRecord: false, hasRunHistory: false, appRoot: root.url)),
            ("started", RenameSafety.reasonToRefuse(try snapshot("web", started: Date()), hasExitRecord: false, hasRunHistory: false, appRoot: root.url)),
            ("exit record", RenameSafety.reasonToRefuse(web, hasExitRecord: true, hasRunHistory: false, appRoot: root.url)),
            ("run history", RenameSafety.reasonToRefuse(web, hasExitRecord: false, hasRunHistory: true, appRoot: root.url)),
            ("no directory", RenameSafety.reasonToRefuse(try snapshot("gone"), hasExitRecord: false, hasRunHistory: false, appRoot: root.url)),
            ("wrong root", RenameSafety.reasonToRefuse(web, hasExitRecord: false, hasRunHistory: false, appRoot: root.url.appendingPathComponent("x"))),
        ]
        for (name, reason) in cases {
            #expect(reason != nil, "\(name)")
        }
        for files in [
            ["config.json", "runtime-configuration.json"], ["rootfs.ext4", "runtime-configuration.json"], ["runtime-configuration.json", "vminitd.log"], [],
            ["runtime-configuration.json", "stdio.log"],
        ] {
            let id = "c\(files.count)\(files.first?.prefix(3) ?? "none")"
            try root.directory(id, files: files)
            #expect(RenameSafety.reasonToRefuse(try snapshot(id), hasExitRecord: false, hasRunHistory: false, appRoot: root.url) != nil, "\(files)")
        }
    }

    @Test("a directory or a link in place of the file, or of the directory, refuses")
    func shapesRefuse() throws {
        let root = Root()
        let containers = root.url.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containers.appendingPathComponent("dir/runtime-configuration.json"), withIntermediateDirectories: true)
        #expect(RenameSafety.reasonToRefuse(try snapshot("dir"), hasExitRecord: false, hasRunHistory: false, appRoot: root.url) != nil)

        try root.directory("real", files: ["runtime-configuration.json"])
        try FileManager.default.createSymbolicLink(at: containers.appendingPathComponent("link"), withDestinationURL: containers.appendingPathComponent("real"))
        #expect(RenameSafety.reasonToRefuse(try snapshot("link"), hasExitRecord: false, hasRunHistory: false, appRoot: root.url) != nil)
    }
}
