import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import socktainer

/// The cleanup of a deleted network and the replacement of a stale sidecar act only on the DNS
/// sidecar of the network. They look the name up again before each stop and each delete, so a
/// container that takes the name in between, for example a cluster node, is not changed.
@Suite("DNS sidecar removal")
struct DNSSidecarRemovalTests {
    private static let network = "dev"
    private static let name = "socktainer-dns-dev"

    private static func sidecar(_ status: RuntimeStatus) throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: name, ip: "192.168.70.2", network: network,
            labels: [NetworkDNSManager.roleLabel: NetworkDNSManager.dnsRole, NetworkDNSManager.networkLabel: network], status: status)
    }

    private static func node(_ status: RuntimeStatus) throws -> ContainerSnapshot {
        try makeContainerSnapshot(
            nativeId: name, ip: "192.168.70.3", network: network,
            labels: [ResourceLabelKeys.plugin: ResourcePluginValues.cluster], status: status)
    }

    private static func cleanup(_ runtime: FakeSidecarRuntime) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = NetworkDNSManager(appSupportURL: directory, containerSystemConfig: ContainerSystemConfig())
        await manager.cleanupDNSContainer(networkId: network, runtime: runtime.closures)
    }

    @Test("cleanup leaves a node with the sidecar name alone", arguments: [RuntimeStatus.running, .stopped])
    func cleanupForeign(status: RuntimeStatus) async throws {
        let runtime = FakeSidecarRuntime(try Self.node(status))
        try await Self.cleanup(runtime)
        #expect(await runtime.mutations.isEmpty)
    }

    @Test("cleanup stops and deletes the sidecar of the network")
    func cleanupOwn() async throws {
        let runtime = FakeSidecarRuntime(try Self.sidecar(.running))
        try await Self.cleanup(runtime)
        #expect(await runtime.mutations == ["stop", "delete"])
    }

    @Test("cleanup does not delete a node that takes the name while the sidecar stops")
    func cleanupReplacedAtStop() async throws {
        let runtime = FakeSidecarRuntime(try Self.sidecar(.running), afterStop: try Self.node(.stopped))
        try await Self.cleanup(runtime)
        #expect(await runtime.mutations == ["stop"])
    }

    @Test("cleanup does not delete a node that takes the name between two delete attempts")
    func cleanupReplacedBetweenAttempts() async throws {
        let runtime = FakeSidecarRuntime(try Self.sidecar(.stopped), failedDeletes: 1, afterPause: try Self.node(.stopped))
        try await Self.cleanup(runtime)
        #expect(await runtime.mutations == ["delete (failed)"])
    }

    @Test("replacement refuses a node with the sidecar name and does not change it", arguments: [RuntimeStatus.running, .stopped])
    func replaceForeign(status: RuntimeStatus) async throws {
        let runtime = FakeSidecarRuntime(try Self.node(status))
        await #expect(throws: NetworkDNSManager.NotSidecar.self) {
            try await NetworkDNSManager.clearSidecarName(containerId: Self.name, networkId: Self.network, runtime: runtime.closures)
        }
        #expect(await runtime.mutations.isEmpty)
    }

    @Test("replacement deletes a stale sidecar of the network")
    func replaceOwn() async throws {
        let runtime = FakeSidecarRuntime(try Self.sidecar(.stopped))
        try await NetworkDNSManager.clearSidecarName(containerId: Self.name, networkId: Self.network, runtime: runtime.closures)
        #expect(await runtime.mutations == ["delete"])
    }
}

/// One container under the sidecar name. A stop or a pause can put another container in its place.
private actor FakeSidecarRuntime {
    private var occupant: ContainerSnapshot?
    private let afterStop: ContainerSnapshot?
    private let afterPause: ContainerSnapshot?
    private var failedDeletes: Int
    private(set) var mutations: [String] = []

    init(_ occupant: ContainerSnapshot, afterStop: ContainerSnapshot? = nil, failedDeletes: Int = 0, afterPause: ContainerSnapshot? = nil) {
        self.occupant = occupant
        self.afterStop = afterStop
        self.failedDeletes = failedDeletes
        self.afterPause = afterPause
    }

    func get(_ id: String) throws -> ContainerSnapshot {
        guard let occupant, occupant.id == id else { throw ContainerizationError(.notFound, message: "no container \(id)") }
        return occupant
    }

    func stop(_ id: String) {
        mutations.append("stop")
        if let afterStop { occupant = afterStop }
    }

    func delete(_ id: String) throws {
        if failedDeletes > 0 {
            failedDeletes -= 1
            mutations.append("delete (failed)")
            throw ContainerizationError(.internalError, message: "busy")
        }
        mutations.append("delete")
        occupant = nil
    }

    func pause() {
        if let afterPause { occupant = afterPause }
    }

    nonisolated var closures: NetworkDNSManager.SidecarRuntime {
        NetworkDNSManager.SidecarRuntime(
            get: { try await self.get($0) },
            stop: { await self.stop($0) },
            delete: { try await self.delete($0) },
            pause: { await self.pause() })
    }
}
