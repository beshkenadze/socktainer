import ContainerResource
import ContainerizationOCI
import Foundation

/// What a shared container is created from.
struct SharedContainerSpec: Sendable {
    /// The runtime ID, `cs-shared-<group>-<first 8 of the key>-<suffix>`.
    let name: String
    /// The Docker API ID, carried in `socktainer.docker-id`.
    let dockerID: String
    let image: ImageDescription
    let platform: Platform
    let labels: [String: String]
    /// The host directory that holds the launcher; mounted read-only at `/run/containerstack`.
    let launcherDirectory: URL

    static func make(
        group: String, key: SharingKey, socketPath: String, image: ImageDescription, platform: Platform,
        launcherDirectory: URL, suffix: String
    ) -> SharedContainerSpec {
        let dockerID = DockerContainerID.mint()
        return SharedContainerSpec(
            name: "cs-shared-\(group)-\(key.nameFragment)-\(suffix)",
            dockerID: dockerID,
            image: image,
            platform: platform,
            labels: [
                SharedRuntimeLabels.sharedGroup: group,
                SharedRuntimeLabels.sharedKey: key.labelValue,
                SharedRuntimeLabels.sharedSocket: socketPath,
                DockerContainerID.idLabel: dockerID,
            ],
            launcherDirectory: launcherDirectory)
    }
}

/// A container in the runtime, as cleanup at start sees it.
struct SharedRuntimeContainerRecord: Sendable, Equatable {
    let nativeID: String
    let labels: [String: String]
}

/// The runtime operations of shared runtime groups. Tests use a fake.
protocol SharedRuntimeClient: Sendable {
    /// Creates the container and starts its init process, `cs-session pause`.
    func createSharedContainer(_ spec: SharedContainerSpec) async throws
    /// Stops and deletes the container. A container that is already gone is not an error.
    func removeSharedContainer(nativeID: String) async throws
    func listContainers() async throws -> [SharedRuntimeContainerRecord]
    /// Sends `signal`, a Linux signal name or number, to one process of a container.
    func signalProcess(containerID: String, processID: String, signal: String) async throws
}
