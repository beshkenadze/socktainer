import Foundation
import Testing

@testable import socktainer

/// `PUT /containers/{id}/archive` into a running container sends each file through the runtime's
/// `copyIn`, which writes below the container's rootfs as the VM sees it. A volume or bind mount
/// exists only in the container's own mount namespace, so a file sent there landed under the mount
/// point, out of the container's sight, and the request still answered 200. act copies every step
/// script into its `/var/run/act` volume this way, so each step failed with "No such file or
/// directory". Files below a mount now go through a shell in the container instead.
@Suite("ClientArchiveService — files below a mount")
struct ClientArchiveMountRoutingTests {

    @Test("a file inside a mounted directory goes through the container")
    func insideMount() {
        #expect(ClientArchiveService.liesUnderMount("/var/run/act/workflow/0", mountDestinations: ["/var/run/act"]))
        #expect(ClientArchiveService.liesUnderMount("/data/a/b.txt", mountDestinations: ["/etc/x", "/data"]))
    }

    /// A single-file bind mount is the mount itself, so a copy onto that path has to reach it too.
    @Test("the mount point itself counts as inside the mount")
    func mountPointItself() {
        #expect(ClientArchiveService.liesUnderMount("/etc/app.conf", mountDestinations: ["/etc/app.conf"]))
    }

    @Test("a sibling that only shares a name prefix stays on the rootfs path")
    func siblingPrefix() {
        #expect(!ClientArchiveService.liesUnderMount("/var/run/actual/0", mountDestinations: ["/var/run/act"]))
        #expect(!ClientArchiveService.liesUnderMount("/data2/x", mountDestinations: ["/data"]))
    }

    @Test("a trailing slash on the mount destination does not change the answer")
    func trailingSlash() {
        #expect(ClientArchiveService.liesUnderMount("/var/run/act/workflow/0", mountDestinations: ["/var/run/act/"]))
        #expect(!ClientArchiveService.liesUnderMount("/var/run/actual", mountDestinations: ["/var/run/act/"]))
    }

    /// The destination comes from the client as written, and `/./data` names the same directory as
    /// `/data`: a spelling must not send the file back under the mount point.
    @Test("another spelling of the same path is still inside the mount")
    func noncanonicalSpelling() {
        #expect(ClientArchiveService.liesUnderMount("/./data/x", mountDestinations: ["/data"]))
        #expect(ClientArchiveService.liesUnderMount("//data//x", mountDestinations: ["/data"]))
        #expect(ClientArchiveService.liesUnderMount("/data/sub/../x", mountDestinations: ["/data"]))
        #expect(ClientArchiveService.liesUnderMount("/var/run/act/0", mountDestinations: ["/var/run//act"]))
        #expect(!ClientArchiveService.liesUnderMount("/data/../tmp/x", mountDestinations: ["/data"]))
    }

    @Test("with no mounts, or outside all of them, the file stays on the rootfs path")
    func outsideMounts() {
        #expect(!ClientArchiveService.liesUnderMount("/tmp/probe", mountDestinations: []))
        #expect(!ClientArchiveService.liesUnderMount("/tmp/probe", mountDestinations: ["/var/run/act", "/data"]))
    }

    /// gitea-runner copies an action as `run/act/actions/<hash>/...` into the `/var/run/act` volume:
    /// `/var/run` links to `/run`, so both name the same place, and the text alone does not match.
    @Test("a file reached through a symlinked spelling of the mount goes through the container")
    func symlinkedSpellingOfMount() {
        let guestPath = "/run/act/actions/c3fe/dist/index.js"
        #expect(!ClientArchiveService.liesUnderMount(guestPath, mountDestinations: ["/var/run/act"]))

        let resolved = ClientArchiveService.ResolvedGuestPaths(
            parents: ["/run/act/actions/c3fe/dist": "/run/act/actions/c3fe/dist"],
            mounts: ["/run/act"]
        )
        #expect(ClientArchiveService.needsGuestShell(guestPath, mountDestinations: ["/var/run/act"], resolved: resolved))
    }

    @Test("a mount configured at the resolved path catches the symlinked spelling of a file")
    func symlinkedSpellingOfFile() {
        let resolved = ClientArchiveService.ResolvedGuestPaths(
            parents: ["/var/run/act/workflow": "/run/act/workflow"],
            mounts: ["/run/act"]
        )
        #expect(
            ClientArchiveService.needsGuestShell(
                "/var/run/act/workflow/0", mountDestinations: ["/run/act"], resolved: resolved))
    }

    @Test("a file on the rootfs keeps the runtime's copy")
    func rootfsFileWithResolvedPaths() {
        let resolved = ClientArchiveService.ResolvedGuestPaths(parents: ["/tmp": "/tmp"], mounts: ["/run/act"])
        #expect(!ClientArchiveService.needsGuestShell("/tmp/probe", mountDestinations: ["/var/run/act"], resolved: resolved))
    }

    /// The shell writes where the container sees the path, so it is never wrong, only slower.
    @Test("when the guest did not report where things are, every file goes through the container")
    func unresolved() {
        #expect(ClientArchiveService.needsGuestShell("/tmp/probe", mountDestinations: [], resolved: nil))
    }

    @Test("the report pairs each line with the path it was asked for")
    func parseReport() {
        let resolved = ClientArchiveService.parseResolvedGuestPaths(
            "P /run/act/actions\nP /tmp\nM /run/act\n",
            parents: ["/var/run/act/actions", "/tmp"],
            mountDestinations: ["/var/run/act"]
        )
        #expect(
            resolved
                == ClientArchiveService.ResolvedGuestPaths(
                    parents: ["/var/run/act/actions": "/run/act/actions", "/tmp": "/tmp"],
                    mounts: ["/run/act"]
                ))
    }

    @Test("a report that does not line up is not trusted")
    func parseMismatchedReport() {
        #expect(
            ClientArchiveService.parseResolvedGuestPaths(
                "P /tmp\n", parents: ["/tmp", "/data"], mountDestinations: []) == nil)
        #expect(
            ClientArchiveService.parseResolvedGuestPaths(
                "noise\nP /tmp\n", parents: ["/tmp"], mountDestinations: []) == nil)
        // A path that ends in a newline leaves an empty line behind; skipping it would accept the
        // rest of the path as the whole one.
        #expect(
            ClientArchiveService.parseResolvedGuestPaths(
                "P /run\nM /run/app.conf\n\n", parents: ["/run"], mountDestinations: ["/var/run/app.conf\n"]) == nil)
    }

    /// Runs the generated script with the host's `/bin/sh` on a tree where `var/run` links to `run`,
    /// as in Debian and Ubuntu images, so the report is what a real shell prints.
    @Test("the preparation script reports where the guest resolves parents and mounts")
    func scriptReportsResolvedPaths() throws {
        let created = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archive-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created.appendingPathComponent("run/act"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: created) }
        // `realpath`, as `pwd -P` sees it: `resolvingSymlinksInPath` drops the `/private` of `/private/var`.
        let resolvedRoot = try #require(realpath(created.path, nil))
        defer { free(resolvedRoot) }
        let root = URL(fileURLWithPath: String(cString: resolvedRoot))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("var"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("var/run"), withDestinationURL: root.appendingPathComponent("run"))

        let file = ClientArchiveService.ArchiveEntryPlan(
            relativePath: "run/act/actions/h/dist/index.js",
            guestPath: root.path + "/run/act/actions/h/dist/index.js",
            kind: .file,
            mode: 0o644
        )
        let mount = root.path + "/var/run/act"
        let service = ClientArchiveService(appSupportPath: FileManager.default.temporaryDirectory)
        let script = service.buildPreparationScript(
            entries: [file], noOverwriteDirNonDir: false, mountDestinations: [mount])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", root.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let resolved = ClientArchiveService.parseResolvedGuestPaths(
            report,
            parents: ClientArchiveService.implicitParents(of: [file]),
            mountDestinations: [mount]
        )
        #expect(resolved?.mounts == [root.path + "/run/act"])
        #expect(ClientArchiveService.needsGuestShell(file.guestPath, mountDestinations: [mount], resolved: resolved))
    }

    /// `cd` cannot enter a file, so a bind of one file, such as `/var/run/docker.sock`, is resolved
    /// through its directory.
    @Test("a single-file mount is resolved through its directory")
    func scriptResolvesFileMountThroughParent() throws {
        let created = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archive-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created.appendingPathComponent("run"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: created) }
        let resolvedRoot = try #require(realpath(created.path, nil))
        defer { free(resolvedRoot) }
        let root = URL(fileURLWithPath: String(cString: resolvedRoot))
        try Data("old".utf8).write(to: root.appendingPathComponent("run/app.conf"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("var"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("var/run"), withDestinationURL: root.appendingPathComponent("run"))

        let file = ClientArchiveService.ArchiveEntryPlan(
            relativePath: "run/app.conf", guestPath: root.path + "/run/app.conf", kind: .file, mode: 0o644)
        let mount = root.path + "/var/run/app.conf"
        let service = ClientArchiveService(appSupportPath: FileManager.default.temporaryDirectory)
        let script = service.buildPreparationScript(entries: [file], noOverwriteDirNonDir: false, mountDestinations: [mount])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", root.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let resolved = ClientArchiveService.parseResolvedGuestPaths(
            report, parents: ClientArchiveService.implicitParents(of: [file]), mountDestinations: [mount])
        #expect(resolved?.mounts == [root.path + "/run/app.conf"])
        #expect(ClientArchiveService.needsGuestShell(file.guestPath, mountDestinations: [mount], resolved: resolved))
    }
}
