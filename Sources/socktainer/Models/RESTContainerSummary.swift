import Vapor

struct ContainerState: Content {
    let Status: String
    let Running: Bool
    let Paused: Bool
    let Restarting: Bool
    let OOMKilled: Bool
    let Dead: Bool
    let Pid: Int
    let ExitCode: Int
    let Error: String
    let StartedAt: String
    let FinishedAt: String
    let Health: ContainerHealth?
}

struct RESTContainerSummary: Content {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let ImageManifestDescriptor: ImageOCIDescriptor?
    let Command: String
    let Created: Int64
    let Ports: [ContainerPort]
    let SizeRw: Int64?
    let SizeRootFs: Int64?
    let Labels: [String: String]
    let State: String
    let Status: String
    let HostConfig: ContainerHostConfig
    let NetworkSettings: ContainerNetworkSummary
    let Mounts: [ContainerMountPoint]
    let Platform: String
}

struct RESTContainerInspect: Content {
    let Id: String
    let Created: String?
    let Path: String
    let Args: [String]
    let State: ContainerState
    let Image: String
    let ResolvConfPath: String
    let HostnamePath: String
    let HostsPath: String
    let LogPath: String?
    let Name: String
    let RestartCount: Int
    let Driver: String
    let Platform: String
    let ImageManifestDescriptor: ImageOCIDescriptor?
    let MountLabel: String
    let ProcessLabel: String
    let AppArmorProfile: String
    let ExecIDs: [String]?
    let HostConfig: HostConfig
    let GraphDriver: ContainerDriverData
    let SizeRw: Int64?
    let SizeRootFs: Int64?
    let Mounts: [ContainerMountPoint]
    let Config: ContainerConfig
    let NetworkSettings: ContainerNetworkSettings

    enum CodingKeys: String, CodingKey {
        case Id
        case Created
        case Path
        case Args
        case State
        case Image
        case ResolvConfPath
        case HostnamePath
        case HostsPath
        case LogPath
        case Name
        case RestartCount
        case Driver
        case Platform
        case ImageManifestDescriptor
        case MountLabel
        case ProcessLabel
        case AppArmorProfile
        case ExecIDs
        case HostConfig
        case GraphDriver
        case SizeRw
        case SizeRootFs
        case Mounts
        case Config
        case NetworkSettings
    }

    // moby's ContainerJSONBase types LogPath as a plain string and ExecIDs as
    // a nil-able []string, both without `omitempty`
    // (api/types/container/container.go): dockerd always emits the keys — ""
    // for a daemon that keeps no log file, `null` for a container with no
    // execs. The synthesized encoder dropped both nil optionals (issue #17);
    // everything else keeps the synthesized shape (`SizeRw`/`SizeRootFs`/
    // `ImageManifestDescriptor` are `omitempty` in moby and stay omittable).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Id, forKey: .Id)
        try container.encodeIfPresent(Created, forKey: .Created)
        try container.encode(Path, forKey: .Path)
        try container.encode(Args, forKey: .Args)
        try container.encode(State, forKey: .State)
        try container.encode(Image, forKey: .Image)
        try container.encode(ResolvConfPath, forKey: .ResolvConfPath)
        try container.encode(HostnamePath, forKey: .HostnamePath)
        try container.encode(HostsPath, forKey: .HostsPath)
        try container.encode(LogPath ?? "", forKey: .LogPath)
        try container.encode(Name, forKey: .Name)
        try container.encode(RestartCount, forKey: .RestartCount)
        try container.encode(Driver, forKey: .Driver)
        try container.encode(Platform, forKey: .Platform)
        try container.encodeIfPresent(ImageManifestDescriptor, forKey: .ImageManifestDescriptor)
        try container.encode(MountLabel, forKey: .MountLabel)
        try container.encode(ProcessLabel, forKey: .ProcessLabel)
        try container.encode(AppArmorProfile, forKey: .AppArmorProfile)
        try container.encodeNullable(ExecIDs, forKey: .ExecIDs)
        try container.encode(HostConfig, forKey: .HostConfig)
        try container.encode(GraphDriver, forKey: .GraphDriver)
        try container.encodeIfPresent(SizeRw, forKey: .SizeRw)
        try container.encodeIfPresent(SizeRootFs, forKey: .SizeRootFs)
        try container.encode(Mounts, forKey: .Mounts)
        try container.encode(Config, forKey: .Config)
        try container.encode(NetworkSettings, forKey: .NetworkSettings)
    }
}

struct RESTContainerListQuery: Content {
    let all: Bool?
}
