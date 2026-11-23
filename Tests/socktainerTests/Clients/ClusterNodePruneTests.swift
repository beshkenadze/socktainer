import ContainerResource
import Foundation
import Testing

@testable import socktainer

/// Spec F-101: prune never deletes a node of a Kubernetes cluster and goes on with the others.
@Suite("Cluster node guard — prune")
struct ClusterNodePruneTests {
    private typealias Fixtures = ClusterNodeFixtures

    @Test(
        "a node is never a prune candidate, also with a label filter on the plugin label",
        arguments: [
            [:],
            ["label": [ResourceLabelKeys.plugin]],
            ["label": ["\(ResourceLabelKeys.plugin)=\(ResourcePluginValues.cluster)"]],
            ["label": ["\(ResourceLabelKeys.plugin)!=\(ResourcePluginValues.machine)"]],
        ] as [[String: [String]]])
    func candidates(filters: [String: [String]]) throws {
        let listed = [
            try Fixtures.node("kind-control-plane", status: .stopped),
            try Fixtures.node("kind-worker", status: .stopped),
            try Fixtures.ordinary("old-job"),
        ]

        let candidates = ClientContainerService.pruneCandidates(listed, filters: filters).map(\.id)

        #expect(!candidates.contains("kind-control-plane"))
        #expect(!candidates.contains("kind-worker"))
    }

    @Test("a candidate that is a node when its delete starts is skipped, and the prune goes on")
    func replacedByNode() async throws {
        let deletes = DeleteLog()

        let deleted = await ClientContainerService.deleteCandidates(
            [try Fixtures.ordinary("replaced"), try Fixtures.ordinary("old-job")],
            current: { id in id == "replaced" ? try Fixtures.node(id, status: .stopped) : try Fixtures.ordinary(id) },
            delete: { container in await deletes.add(container.id) })

        #expect(deleted == ["old-job"], "the node is not in ContainersDeleted")
        #expect(await deletes.ids == ["old-job"], "the node is not deleted")
    }

    @Test("a candidate whose delete fails is left out, and the prune goes on")
    func failedDelete() async throws {
        let deleted = await ClientContainerService.deleteCandidates(
            [try Fixtures.ordinary("busy"), try Fixtures.ordinary("old-job")],
            current: { id in try Fixtures.ordinary(id) },
            delete: { container in
                if container.id == "busy" { throw ClientContainerError.notFound(id: container.id) }
            })

        #expect(deleted == ["old-job"])
    }
}

private actor DeleteLog {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}
