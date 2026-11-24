import ContainerAPIClient
import ContainerResource
import Testing

@testable import socktainer

/// The DNS sidecar of a network is found by its name, `socktainer-dns-<network>`. Another container
/// can hold that name, for example a cluster node. Only the sidecar of the network is reused,
/// stopped, deleted or replaced; any other occupant is left alone.
@Suite("DNS sidecar occupant")
struct DNSSidecarOccupantTests {
    private static let name = "socktainer-dns-dev"
    private static let ownLabels = [NetworkDNSManager.roleLabel: NetworkDNSManager.dnsRole, NetworkDNSManager.networkLabel: "dev"]

    @Test("the running sidecar of the network is reused")
    func runningSidecar() throws {
        let sidecar = try makeContainerSnapshot(nativeId: Self.name, ip: "192.168.70.2", network: "dev", labels: Self.ownLabels, status: .running)
        #expect(NetworkDNSManager.occupant(sidecar, networkId: "dev") == .reuse(ip: "192.168.70.2"))
    }

    @Test("a stopped sidecar of the network is replaced")
    func stoppedSidecar() throws {
        let sidecar = try makeContainerSnapshot(nativeId: Self.name, ip: "192.168.70.2", network: "dev", labels: Self.ownLabels, status: .stopped)
        #expect(NetworkDNSManager.occupant(sidecar, networkId: "dev") == .replace)
    }

    @Test("no container holds the name")
    func noOccupant() {
        #expect(NetworkDNSManager.occupant(nil, networkId: "dev") == NetworkDNSManager.SidecarOccupant.none)
    }

    @Test(
        "a container that is not the sidecar of the network is left alone",
        arguments: [
            [ResourceLabelKeys.plugin: ResourcePluginValues.cluster],
            [:],
            [NetworkDNSManager.roleLabel: NetworkDNSManager.dnsRole, NetworkDNSManager.networkLabel: "prod"],
        ] as [[String: String]],
        [RuntimeStatus.running, .stopped])
    func foreignOccupant(labels: [String: String], status: RuntimeStatus) throws {
        let occupant = try makeContainerSnapshot(nativeId: Self.name, ip: "192.168.70.3", network: "dev", labels: labels, status: status)
        #expect(NetworkDNSManager.occupant(occupant, networkId: "dev") == .foreign(Self.name))
    }
}
