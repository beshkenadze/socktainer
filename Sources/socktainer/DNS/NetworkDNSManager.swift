import ContainerAPIClient
import ContainerNetworkClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import Foundation
import Logging
import Vapor

struct NetworkDNSManagerKey: StorageKey {
    typealias Value = NetworkDNSManager
}

/// Manages one DNS forwarder sidecar container per user-created network.
///
/// Each forwarder is the embedded `socktainer-dns` binary (static Rust, ~388 KB,
/// bundled as a Swift Package resource). It proxies DNS queries from containers
/// to SocktainerDNSServer on the macOS host via the network gateway, without
/// pulling anything from the internet at runtime.
///
/// DNS containers are identified by the label `socktainer.role=dns` and
/// named `socktainer-dns-{networkId}`.
actor NetworkDNSManager {
    static let dnsRole = "dns"
    static let roleLabel = "socktainer.role"
    static let networkLabel = "socktainer.network"
    static let containerPrefix = "socktainer-dns-"
    static let dnsPort = 2054
    static let sidecarCPUs = 1
    // Virtualization.framework rejects anything below 200 MiB.
    static let sidecarMemoryInBytes: UInt64 = 256.mib()

    private let appSupportURL: URL
    private let dnsPort: Int
    private let containerSystemConfig: ContainerSystemConfig
    private var pendingCreation: [String: Task<String, Error>] = [:]
    private var log = Logger(label: "socktainer.dns.manager")

    init(appSupportURL: URL, dnsPort: Int = 2054, containerSystemConfig: ContainerSystemConfig) {
        self.appSupportURL = appSupportURL
        self.dnsPort = dnsPort
        self.containerSystemConfig = containerSystemConfig
    }

    // MARK: - Public API

    func ensureDNSContainer(networkId: String) async throws -> String {
        if let pending = pendingCreation[networkId] {
            log.info("[dns-manager] waiting for in-flight DNS forwarder creation for network \(networkId)")
            return try await pending.value
        }

        log.info("[dns-manager] ensuring DNS forwarder container for network \(networkId)")
        let appSupportURL = self.appSupportURL
        let dnsPort = self.dnsPort
        let containerSystemConfig = self.containerSystemConfig
        let task = Task<String, Error> {
            try await Self.createDNSContainerWork(networkId: networkId, appSupportURL: appSupportURL, dnsPort: dnsPort, containerSystemConfig: containerSystemConfig)
        }
        pendingCreation[networkId] = task

        do {
            let ip = try await task.value
            pendingCreation.removeValue(forKey: networkId)
            log.info("[dns-manager] DNS forwarder running at \(ip) for network \(networkId)")
            return ip
        } catch {
            pendingCreation.removeValue(forKey: networkId)
            throw error
        }
    }

    /// The native calls that remove a DNS sidecar. Injected for tests.
    struct SidecarRuntime: Sendable {
        var get: @Sendable (String) async throws -> ContainerSnapshot
        var stop: @Sendable (String) async throws -> Void
        var delete: @Sendable (String) async throws -> Void
        /// The gap between two delete attempts.
        var pause: @Sendable () async -> Void

        static let native = SidecarRuntime(
            get: { try await ContainerClient().get(id: $0) },
            stop: { try await ContainerClient().stop(id: $0) },
            delete: { try await ContainerClient().delete(id: $0) },
            pause: { try? await Task.sleep(for: .milliseconds(300)) })
    }

    /// Another container holds the name of the sidecar. It is left alone.
    struct NotSidecar: Error, CustomStringConvertible {
        let holder: String
        let networkId: String
        var description: String {
            "container \(holder) holds the name of the DNS sidecar of network \(networkId) but is not that sidecar; it was left alone"
        }
    }

    /// Removes the DNS forwarder container for `networkId`.
    /// Called when a user network is deleted.
    func cleanupDNSContainer(networkId: String, runtime: SidecarRuntime = .native) async {
        let containerId = ContainerNameUtility.sanitize(Self.containerPrefix + networkId)
        do {
            // Retry deletion: Apple Container may need a moment to fully release
            // the container from the network after stop. Retry up to 3 times with
            // short gaps rather than a fixed 1s sleep so we stay fast.
            guard try await Self.removeSidecar(containerId: containerId, networkId: networkId, deleteAttempts: 3, runtime: runtime) else {
                return  // container already gone
            }
            log.info("[dns-manager] removed DNS container for network \(networkId)")
            let corefileDir = appSupportURL.appendingPathComponent("dns/\(networkId)")
            try? FileManager.default.removeItem(at: corefileDir)
        } catch let error as NotSidecar {
            log.warning("[dns-manager] did not remove \(containerId): \(error)")
        } catch {
            log.warning("[dns-manager] could not remove DNS container \(containerId): \(error)")
        }
    }

    /// Removes a stale sidecar before a new one is made under its name. A delete that fails is not
    /// an error here: the create that follows reports it. Throws `NotSidecar` for another container.
    static func clearSidecarName(containerId: String, networkId: String, runtime: SidecarRuntime) async throws {
        do {
            _ = try await removeSidecar(containerId: containerId, networkId: networkId, deleteAttempts: 1, runtime: runtime)
        } catch let error as NotSidecar {
            throw error
        } catch {}
    }

    /// Stops and deletes the sidecar of `networkId` under `containerId`. Returns false when no
    /// container has the name. Throws `NotSidecar` when another container has it, else the error
    /// of the last delete attempt.
    static func removeSidecar(containerId: String, networkId: String, deleteAttempts: Int, runtime: SidecarRuntime) async throws -> Bool {
        func sidecar() async throws -> ContainerSnapshot? {
            guard let snapshot = try? await runtime.get(containerId) else { return nil }
            if case .foreign(let holder) = occupant(snapshot, networkId: networkId) {
                throw NotSidecar(holder: holder, networkId: networkId)
            }
            return snapshot
        }
        guard let snapshot = try await sidecar() else { return false }
        if snapshot.status == .running { try? await runtime.stop(containerId) }
        for attempt in 1...deleteAttempts {
            // Another container can take the name during the stop or the pause.
            guard try await sidecar() != nil else { return false }
            do {
                try await runtime.delete(containerId)
                return true
            } catch {
                guard attempt < deleteAttempts else { throw error }
                await runtime.pause()
            }
        }
        return false
    }

    // A recreated sidecar never gets its old IP back (upstream allocates rotating,
    // never reusing freed addresses), while existing containers keep that IP baked
    // in resolv.conf — so healthy sidecars must be adopted, never recreated.
    func adoptOrRemoveSidecarsFromPreviousRun() async {
        let client = ContainerClient()
        guard let containers = try? await client.list() else { return }
        for container in containers {
            guard ClientContainerService.isDNSSidecar(container) else { continue }
            if Self.shouldAdoptSidecar(status: container.status, networkExists: await networkStillExists(for: container)) {
                log.info("[dns-manager] adopting running DNS container: \(container.id)")
                continue
            }
            log.info("[dns-manager] removing stale DNS container: \(container.id)")
            if container.status == .running { try? await client.stop(id: container.id) }
            try? await client.delete(id: container.id)
        }
    }

    static func shouldAdoptSidecar(status: RuntimeStatus, networkExists: Bool) -> Bool {
        status == .running && networkExists
    }

    private func networkStillExists(for container: ContainerSnapshot) async -> Bool {
        guard let networkId = container.configuration.labels[Self.networkLabel] else { return false }
        return (try? await NetworkClient().get(id: networkId)) != nil
    }

    /// What holds the name of the DNS sidecar of a network.
    enum SidecarOccupant: Equatable {
        case none
        /// The running sidecar, with its address on the network.
        case reuse(ip: String)
        /// A sidecar of the network that must be made again.
        case replace
        /// A container that is not the sidecar of the network: a cluster node, an ordinary
        /// container, or the sidecar of another network. It is left alone.
        case foreign(String)
    }

    static func occupant(_ snapshot: ContainerSnapshot?, networkId: String) -> SidecarOccupant {
        guard let snapshot else { return .none }
        let labels = snapshot.configuration.labels
        guard labels[roleLabel] == dnsRole, labels[networkLabel] == networkId else { return .foreign(snapshot.id) }
        if snapshot.status == .running, let attachment = snapshot.networks.first(where: { $0.network == networkId }) {
            return .reuse(ip: attachment.ipv4Address.address.description)
        }
        return .replace
    }

    // MARK: - Private implementation

    /// Runs outside the actor's executor to avoid deadlock with the Task created in ensureDNSContainer.
    private static func createDNSContainerWork(networkId: String, appSupportURL: URL, dnsPort: Int, containerSystemConfig: ContainerSystemConfig) async throws -> String {
        let containerClient = ContainerClient()
        // Sanitize to respect Apple Container's 64-char container ID limit
        let containerId = ContainerNameUtility.sanitize(containerPrefix + networkId)

        // Reuse if already running
        switch occupant(try? await containerClient.get(id: containerId), networkId: networkId) {
        case .reuse(let ip): return ip
        case .foreign(let holder): throw NotSidecar(holder: holder, networkId: networkId)
        case .none, .replace: break
        }

        // Get the network's gateway IP — passed to the forwarder as DNS_UPSTREAM
        let networkResource = try await NetworkClient().get(id: networkId)
        let gatewayIP = networkResource.status.ipv4Gateway.description

        let image = try await EmbeddedDNSImage.ensure(
            containerSystemConfig: containerSystemConfig,
            appSupportURL: appSupportURL
        )

        let platform = Platform.current
        _ = try await image.getCreateSnapshot(platform: platform)

        let processConfig = ProcessConfiguration(
            executable: "/dns-forwarder",
            arguments: [],
            environment: ["DNS_UPSTREAM=\(gatewayIP):\(dnsPort)"],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: containerId, image: image.description, process: processConfig)
        config.resources.cpus = sidecarCPUs
        config.resources.memoryInBytes = sidecarMemoryInBytes
        config.labels = [
            roleLabel: dnsRole,
            networkLabel: networkId,
        ]
        config.networks = [
            AttachmentConfiguration(
                network: networkId,
                options: AttachmentOptions(hostname: ContainerNameUtility.sanitize(containerPrefix + networkId))
            )
        ]
        // Point DNS forwarder to the vmnet gateway for upstream resolution
        config.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: [gatewayIP],
            domain: nil,
            searchDomains: [],
            options: []
        )

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        // Remove any stale sidecar first; any other container under the name is left alone.
        try await clearSidecarName(containerId: containerId, networkId: networkId, runtime: .native)

        try await containerClient.create(configuration: config, options: .default, kernel: kernel)
        try await startDNSContainer(id: containerId, client: containerClient)

        let snapshot = try await containerClient.get(id: containerId)
        guard let attachment = snapshot.networks.first(where: { $0.network == networkId }) else {
            throw ContainerizationError(.invalidState, message: "DNS container for \(networkId) has no network attachment")
        }
        return attachment.ipv4Address.address.description
    }

    private static func startDNSContainer(id: String, client: ContainerClient) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        do {
            let process = try await client.bootstrap(id: id, stdio: io.stdio)
            try await process.start()
            try io.closeAfterStart()
        } catch {
            try? await client.stop(id: id)
            try? await client.delete(id: id)
            throw ContainerizationError(.internalError, message: "failed to start DNS container: \(error)")
        }
    }
}
