import ContainerAPIClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging

/// `SharedRuntimeClient` over Apple Container.
struct ContainerSharedRuntimeClient: SharedRuntimeClient {
    static let launcherGuestDirectory = "/run/containerstack"
    static let launcherGuestPath = "/run/containerstack/cs-session"

    let logger: Logger

    func createSharedContainer(_ spec: SharedContainerSpec) async throws {
        let process = ProcessConfiguration(
            executable: Self.launcherGuestPath,
            arguments: ["pause"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0))
        var configuration = ContainerConfiguration(id: spec.name, image: spec.image, process: process)
        configuration.platform = spec.platform
        configuration.rosetta = Platform.current.architecture == "arm64" && spec.platform.architecture == "amd64"
        configuration.labels = spec.labels
        configuration.networks = [
            AttachmentConfiguration(network: "default", options: AttachmentOptions(hostname: spec.name))
        ]
        // As the create route does for a run with no DNS options on the default network.
        configuration.dns = ContainerConfiguration.DNSConfiguration(nameservers: [], domain: nil, searchDomains: [], options: [])
        configuration.mounts = [
            Filesystem.virtiofs(source: spec.launcherDirectory.path, destination: Self.launcherGuestDirectory, options: ["ro"])
        ]
        let defaults = await ContainerResourceDefaults.shared.current(logger: logger)
        if let memory = ContainerResourceResolution.memoryInBytes(requested: nil, configured: defaults) {
            configuration.resources.memoryInBytes = memory
        }
        if let cpus = ContainerResourceResolution.cpus(requestedNanoCpus: nil, configured: defaults) {
            configuration.resources.cpus = cpus
        }

        let finalConfiguration = configuration
        try await VMLifecycleAdmission.shared.withSlot {
            let client = ContainerClient()
            let kernel = try await ClientKernel.getDefaultKernel(for: .current)
            try await client.create(configuration: finalConfiguration, options: .default, kernel: kernel)
            let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
            defer { try? io.close() }
            do {
                let initProcess = try await client.bootstrap(id: spec.name, stdio: io.stdio)
                try await initProcess.start()
                try io.closeAfterStart()
            } catch {
                try? await client.stop(id: spec.name)
                try? await client.delete(id: spec.name)
                throw error
            }
        }
    }

    func removeSharedContainer(nativeID: String) async throws {
        let client = ContainerClient()
        do {
            if try await client.get(id: nativeID).status == .running {
                try await client.stop(id: nativeID)
            }
            try await client.delete(id: nativeID)
        } catch let error as ContainerizationError where error.code == .notFound {
            return
        }
    }

    func listContainers() async throws -> [SharedRuntimeContainerRecord] {
        try await ContainerClient().list().map { SharedRuntimeContainerRecord(nativeID: $0.id, labels: $0.configuration.labels) }
    }

    func signalProcess(containerID: String, processID: String, signal: String) async throws {
        try await SharedRuntimeSignal.send(containerID: containerID, processID: processID, signal: signal)
    }
}
