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
}
