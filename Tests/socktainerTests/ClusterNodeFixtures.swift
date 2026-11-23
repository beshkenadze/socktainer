import ContainerAPIClient
import ContainerResource
import Foundation
import NIOCore

@testable import socktainer

/// Fixtures for the cluster node guard tests: nodes of a `container cluster`, ordinary containers,
/// and a fake runtime that records every change that a route asks for.
enum ClusterNodeFixtures {
    static func node(_ name: String, status: RuntimeStatus = .running) throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: name, ip: "192.168.64.3", network: "kind",
            labels: [ResourceLabelKeys.plugin: ResourcePluginValues.cluster, ResourceLabelKeys.role: "control-plane"],
            status: status)
    }

    static func ordinary(_ name: String, status: RuntimeStatus = .stopped) throws -> ContainerSnapshot {
        try makeContainerSnapshot(nativeId: name, ip: "192.168.64.4", network: "default", labels: [:], status: status)
    }

    /// A name that no other test uses: the stores that the routes write are process-wide.
    static func uniqueName(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The body of the 409 for the node `name` (spec F-101).
    static func refusal(_ name: String) -> String {
        "\(name) is a node of a Kubernetes cluster. Use 'container cluster' or ContainerStack to start, stop or delete it."
    }

    /// The `message` of a Docker error body.
    static func message(_ body: ByteBuffer) -> String? {
        let data = Data(buffer: body)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }
}

/// A runtime of fixed containers. Lookups resolve like the real client: native name, then the
/// Docker ID or a prefix of it, then a retired ID of a renamed container. The Docker listing hides
/// plugin containers, as the real one does. Each change is recorded and has no other effect.
actor RecordingNodeRuntime: ClientContainerProtocol {
    let containers: [ContainerSnapshot]
    private(set) var calls: [String] = []

    init(_ containers: [ContainerSnapshot]) {
        self.containers = containers
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        ClientContainerService.listing(containers, showAll: showAll, filters: filters)
    }

    func listEveryRuntimeContainer() async throws -> [ContainerSnapshot] { containers }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        if let exact = containers.first(where: { $0.id == id }) { return exact }
        let entries = containers.map { (nativeId: $0.id, hexId: DockerContainerID.hexId(for: $0)) }
        switch DockerContainerID.resolve(reference: id, entries: entries) {
        case .match(let nativeId):
            return containers.first { $0.id == nativeId }
        case .ambiguous(let matches):
            throw ClientContainerError.ambiguousId(reference: id, matches: matches)
        case .none:
            guard let renamed = await ContainerRenameMap.shared.nativeId(forRetiredHexId: id) else { return nil }
            return containers.first { $0.id == renamed }
        }
    }

    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {
        guard container.status == .running else { throw ClientContainerError.notRunning(id: container.id) }
    }

    func prepareForStart(container: ContainerSnapshot) async throws { calls.append("prepareForStart \(container.id)") }
    func start(id: String, detachKeys: String?) async throws { calls.append("start \(id)") }
    func stop(id: String, signal: String?, timeout: Int?) async throws { calls.append("stop \(id)") }
    func restart(id: String, signal: String?, timeout: Int?) async throws { calls.append("restart \(id)") }
    func kill(id: String, signal: String?) async throws { calls.append("kill \(id)") }
    func delete(id: String) async throws { calls.append("delete \(id)") }
    func rename(id: String, newName: String) async throws { calls.append("rename \(id) \(newName)") }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        calls.append("prune")
        return ([], 0)
    }
}
