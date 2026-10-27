import Testing

@testable import socktainer

/// `PUT /containers/{id}/archive` before the first start holds each file and mounts it into place
/// at start. buildx's docker-container driver does this in GitHub Actions jobs: it creates the
/// buildkit container, sends `buildkit/provenance.d/github_actions_context.json` into `/etc` with
/// both directories as entries, and only then starts the container.
@Suite("ClientArchiveService — copy before the first start")
struct ClientArchivePreStartTests {

    private func entry(_ guestPath: String, _ kind: ClientArchiveService.ArchiveEntryPlan.Kind) -> ClientArchiveService.ArchiveEntryPlan {
        ClientArchiveService.ArchiveEntryPlan(relativePath: guestPath, guestPath: guestPath, kind: kind, mode: 0o755)
    }

    @Test("directories that hold a staged file are accepted")
    func directoriesAroundAFile() {
        let plan = [
            entry("/etc/buildkit", .directory),
            entry("/etc/buildkit/provenance.d", .directory),
            entry("/etc/buildkit/provenance.d/github_actions_context.json", .file),
        ]
        #expect(ClientArchiveService.entryRefusedBeforeStart(plan) == nil)
    }

    /// Nothing would be mounted to create it, so the copy is refused while it can still be retried
    /// after start.
    @Test("a directory with no staged file below it is refused")
    func emptyDirectory() {
        let plan = [entry("/etc/buildkit", .directory), entry("/etc/other/file", .file)]
        #expect(ClientArchiveService.entryRefusedBeforeStart(plan) == "a directory")
    }

    @Test("a directory whose name only starts like the file's directory is refused")
    func siblingPrefix() {
        let plan = [entry("/etc/build", .directory), entry("/etc/buildkit/file", .file)]
        #expect(ClientArchiveService.entryRefusedBeforeStart(plan) == "a directory")
    }

    /// The mount creates missing directories as 0755, so another mode could not be reproduced.
    @Test("a directory whose mode the mount would not reproduce is refused")
    func directoryMode() {
        var directory = entry("/srv/uploads", .directory)
        directory = ClientArchiveService.ArchiveEntryPlan(
            relativePath: directory.relativePath, guestPath: directory.guestPath, kind: .directory, mode: 0o777)
        #expect(ClientArchiveService.entryRefusedBeforeStart([directory, entry("/srv/uploads/seed", .file)]) == "a directory")
    }

    @Test("a symlink is refused")
    func symlink() {
        #expect(ClientArchiveService.entryRefusedBeforeStart([entry("/etc/link", .symlink(target: "/x"))]) == "a symlink")
    }
}
