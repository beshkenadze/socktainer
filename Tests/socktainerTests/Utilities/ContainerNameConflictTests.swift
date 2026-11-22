import ContainerizationError
import Foundation
import Testing
import Vapor

@testable import socktainer

/// The runtime's refusal of a create because the name is in use becomes Docker's 409.
@Suite struct ContainerNameConflictTests {
    private static let folded =
        "container 'WEB' cannot be created: on this file system its name is the same as that of the existing container 'web'"

    @Test("the runtime's refusals of a name in use name their holder; other refusals are not name conflicts")
    func holder() {
        #expect(ContainerNameConflict.holder(of: "web", in: ContainerizationError(.exists, message: "container already exists: web")) == "web")
        #expect(ContainerNameConflict.holder(of: "WEB", in: ContainerizationError(.exists, message: Self.folded)) == "web")

        let notNameConflicts: [Error] = [
            ContainerizationError(.exists, message: "hostname(s) already exist: [\"web\"]"),
            ContainerizationError(.exists, message: "alias(es) already exist: [\"db\"]"),
            ContainerizationError(
                .exists,
                message:
                    "container 'web' cannot be created: /x/containers/web already exists, holds files and belongs to no container. An earlier create that stopped before it finished leaves such a directory"
            ),
            ContainerizationError(.internalError, message: "container already exists: web"),
            ContainerizationError(.exists, message: "container already exists: other"),
            CancellationError(),
        ]
        for error in notNameConflicts {
            #expect(ContainerNameConflict.holder(of: "web", in: error) == nil, "\(error)")
        }
    }

    @Test("the 409 carries Docker's message with the holder's stored Docker ID")
    func conflictNamesTheHolderID() async throws {
        let id = DockerContainerID.mint()
        let holder = try makeContainerSnapshot(nativeId: "web", networks: [], labels: [DockerContainerID.idLabel: id])
        let client = StaticSnapshotClientMock(snapshot: holder)

        let abort = try #require(
            await ContainerNameConflict.conflict(after: ContainerizationError(.exists, message: Self.folded), name: "WEB", client: client))
        #expect(abort.status == .conflict)
        #expect(
            abort.reason
                == "Conflict. The container name \"/WEB\" is already in use by container \"\(id)\". You have to remove (or rename) that container to be able to reuse that name."
        )
        #expect(await client.getCalls == 0, "no lookup that can match by ID prefix")
    }

    @Test("a holder without a stored Docker ID, or not in the list, is named, never another container")
    func conflictWithoutAStoredID() async throws {
        let refusal = ContainerizationError(.exists, message: "container already exists: ab")
        // No stored ID: the name, not an ID derived from the creation date on disk.
        var client = StaticSnapshotClientMock(snapshot: try makeContainerSnapshot(nativeId: "ab", networks: [], labels: [:]))
        var abort = await ContainerNameConflict.conflict(after: refusal, name: "ab", client: client)
        #expect(abort?.reason.contains("is already in use by container \"ab\"") == true)

        // The holder is gone; another container whose Docker ID starts with "ab" is not named.
        let other = try makeContainerSnapshot(nativeId: "next", networks: [], labels: [DockerContainerID.idLabel: "ab" + String(repeating: "0", count: 62)])
        client = StaticSnapshotClientMock(snapshot: other)
        abort = await ContainerNameConflict.conflict(after: refusal, name: "ab", client: client)
        #expect(abort?.reason.contains("is already in use by container \"ab\"") == true)

        #expect(await ContainerNameConflict.conflict(after: CancellationError(), name: "ab", client: client) == nil)
    }
}
