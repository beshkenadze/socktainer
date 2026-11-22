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

    @Test("the 409 carries Docker's message with the holder's full Docker ID")
    func conflictNamesTheHolderID() async throws {
        let holder = try makeContainerSnapshot(nativeId: "web", networks: [], labels: [:])
        let client = StaticSnapshotClientMock(snapshot: holder)

        let abort = try #require(
            await ContainerNameConflict.conflict(after: ContainerizationError(.exists, message: Self.folded), name: "WEB", client: client))
        #expect(abort.status == .conflict)
        #expect(
            abort.reason
                == "Conflict. The container name \"/WEB\" is already in use by container \"\(DockerContainerID.hexId(for: holder))\". You have to remove (or rename) that container to be able to reuse that name."
        )
    }

    @Test("without the holder in the runtime, the 409 names it; any other error is not mapped")
    func conflictWithoutTheHolder() async throws {
        let client = StaticSnapshotClientMock(snapshot: try makeContainerSnapshot(nativeId: "web", networks: [], labels: [:]))
        await client.removeSnapshot()

        let abort = await ContainerNameConflict.conflict(
            after: ContainerizationError(.exists, message: "container already exists: web"), name: "web", client: client)
        #expect(abort?.reason.contains("is already in use by container \"web\"") == true)
        #expect(await ContainerNameConflict.conflict(after: CancellationError(), name: "web", client: client) == nil)
    }
}
