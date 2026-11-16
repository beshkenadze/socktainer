import Foundation
import Vapor

/// `inspect` of a session. It returns the fields that a Docker client reads for a container
/// that it ran with `docker run -i --rm`: ID, name, state, exit code, image, command, user,
/// working directory, labels and `AutoRemove`. `Config.Env` is empty: environment values are not
/// shown for a session (F-003).
extension SharedRuntimeRouter {
    static func labels(of session: SharedSession) -> [String: String] {
        var labels = session.spec.labels
        labels[SharedRuntimeLabels.sessionGroup] = session.spec.group.name
        if let container = session.container { labels[SharedRuntimeLabels.sessionContainer] = container.dockerID }
        return labels
    }

    static func inspect(_ req: Request, _ session: SharedSession) async throws -> Response {
        let spec = session.spec
        let zeroTime = "0001-01-01T00:00:00Z"
        let running = session.phase == .running
        let state = ContainerState(
            Status: running ? "running" : "created", Running: running, Paused: false, Restarting: false,
            OOMKilled: false, Dead: false, Pid: 0, ExitCode: 0, Error: "",
            StartedAt: session.startedAt.map { AppleContainerTimestampResolver.iso8601Timestamp($0) } ?? zeroTime,
            FinishedAt: zeroTime, Health: nil)
        let config = ContainerConfig(
            Hostname: session.container?.nativeID, Domainname: nil, User: spec.process.user.description,
            AttachStdin: true, AttachStdout: true, AttachStderr: true, ExposedPorts: nil, Tty: false,
            OpenStdin: true, StdinOnce: true, Env: nil, Cmd: spec.process.arguments, Healthcheck: nil,
            ArgsEscaped: false, Image: spec.imageName, Volumes: nil, WorkingDir: spec.process.workingDirectory,
            Entrypoint: [spec.process.executable], NetworkDisabled: false, MacAddress: nil, OnBuild: nil,
            Labels: labels(of: session), StopSignal: nil, StopTimeout: nil, Shell: nil)
        let inspect = RESTContainerInspect(
            Id: spec.id, Created: AppleContainerTimestampResolver.iso8601Timestamp(spec.created),
            Path: spec.process.executable, Args: spec.process.arguments, State: state, Image: spec.imageID,
            ResolvConfPath: "", HostnamePath: "", HostsPath: "", LogPath: nil, Name: "/" + spec.name,
            RestartCount: 0, Driver: "overlayfs", Platform: "linux", ImageManifestDescriptor: nil,
            MountLabel: "", ProcessLabel: "", AppArmorProfile: "", ExecIDs: nil,
            HostConfig: HostConfig(networkMode: "default", autoRemove: true),
            GraphDriver: ContainerDriverData(Name: "overlayfs", Data: [:]), SizeRw: nil, SizeRootFs: nil,
            Mounts: [], Config: config, NetworkSettings: ContainerNetworkSettings.empty)
        return try await inspect.encodeResponse(for: req)
    }
}

extension ContainerNetworkSettings {
    static let empty = ContainerNetworkSettings(
        Bridge: nil, SandboxID: nil, Ports: nil, SandboxKey: nil, EndpointID: nil, Gateway: nil,
        GlobalIPv6Address: nil, GlobalIPv6PrefixLen: nil, IPAddress: nil, IPPrefixLen: nil, IPv6Gateway: nil,
        MacAddress: nil, Networks: nil, EndpointsConfig: nil)
}
