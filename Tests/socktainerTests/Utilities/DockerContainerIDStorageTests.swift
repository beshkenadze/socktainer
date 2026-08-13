import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

/// The Docker ID used to be derived from the container's name, which made identity a function of
/// mutable state: a rename recreates the container under a new name, so the ID changed with it and
/// every store keyed by it had to be migrated. It is stored on the container instead, so it rides
/// along in the configuration a recreate copies.
@Suite("DockerContainerID storage")
struct DockerContainerIDStorageTests {
    private static func snapshot(id: String, labels: [String: String]) -> ContainerSnapshot {
        let processConfig = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let imageDesc = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
        var config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
        config.labels = labels
        return ContainerSnapshot(configuration: config, status: .stopped, networks: [], startedDate: nil)
    }

    private static let storedId = String(repeating: "ab12", count: 16)

    @Test("A stored id is used verbatim")
    func storedIdWins() {
        let container = Self.snapshot(id: "web", labels: [DockerContainerID.idLabel: Self.storedId])
        #expect(DockerContainerID.hexId(for: container) == Self.storedId)
    }

    @Test("The id survives a rename, because it travels with the configuration")
    func idSurvivesRename() {
        let labels = [DockerContainerID.idLabel: Self.storedId]
        let before = Self.snapshot(id: "web", labels: labels)
        let afterRecreate = Self.snapshot(id: "web-old", labels: labels)

        #expect(DockerContainerID.hexId(for: before) == DockerContainerID.hexId(for: afterRecreate))
    }

    @Test("Without the label the id is derived from the name, so foreign containers still resolve")
    func fallsBackToDerivation() {
        let container = Self.snapshot(id: "web", labels: [:])
        let derived = DockerContainerID.hexId(nativeId: "web", createdAt: nil)

        #expect(DockerContainerID.hexId(for: container) == derived)
        #expect(DockerContainerID.hexId(for: container).count == 64)
    }

    @Test("A malformed stored id is ignored rather than handed to a client")
    func malformedStoredIdIsIgnored() {
        let derived = DockerContainerID.hexId(nativeId: "web", createdAt: nil)
        for bogus in ["", "not-hex", String(repeating: "a", count: 63), String(repeating: "A", count: 64)] {
            let container = Self.snapshot(id: "web", labels: [DockerContainerID.idLabel: bogus])
            #expect(DockerContainerID.hexId(for: container) == derived, "\(bogus.count) chars must not be trusted")
        }
    }

    @Test("Minted ids are Docker-shaped and distinct")
    func mintedIdsAreWellFormed() {
        let ids = (0..<50).map { _ in DockerContainerID.mint() }

        #expect(ids.allSatisfy { DockerContainerID.isWellFormed($0) })
        #expect(Set(ids).count == ids.count, "a repeated id would merge two containers")
    }

    @Test("The id label is socktainer's own: hidden from clients and refused on create")
    func idLabelIsInternal() {
        let restored = LabelNormalization.restore([
            DockerContainerID.idLabel: Self.storedId,
            "com.example.app": "demo"
        ])

        #expect(restored[DockerContainerID.idLabel] == nil, "Docker reports the id in Id, never as a label")
        #expect(restored["com.example.app"] == "demo")
        #expect(
            LabelNormalization.containsReservedKey([DockerContainerID.idLabel: Self.storedId]),
            "a client-supplied id would let it forge another container's identity"
        )
    }
}
