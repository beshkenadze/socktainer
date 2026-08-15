import Vapor

// TODO: Sort out this file into logical sections

struct EmptyObject: Content {
    // Empty struct to represent {} in JSON
}

struct HealthcheckConfig: Content {
    let Test: [String]?
    let Interval: Int?
    let Timeout: Int?
    let Retries: Int?
    let StartPeriod: Int?
}

struct HealthLogEntry: Content {
    let Start: String
    let End: String
    let ExitCode: Int32
    let Output: String
}

struct ContainerHealth: Content {
    let Status: String
    let FailingStreak: Int
    let Log: [HealthLogEntry]
}

struct HostConfig: Content {
    let Binds: [String]?
    let BlkioWeight: Int?
    let BlkioWeightDevice: [BlkioWeightDevice]?
    let BlkioDeviceReadBps: [BlkioDeviceRate]?
    let BlkioDeviceWriteBps: [BlkioDeviceRate]?
    let BlkioDeviceReadIOps: [BlkioDeviceRate]?
    let BlkioDeviceWriteIOps: [BlkioDeviceRate]?
    let MemorySwappiness: Int?
    let NanoCpus: Int?
    let CapAdd: [String]?
    let CapDrop: [String]?
    let ContainerIDFile: String?
    let CpuPeriod: Int?
    let CpuRealtimePeriod: Int?
    let CpuRealtimeRuntime: Int?
    let CpuShares: Int?
    let CpuQuota: Int?
    let CpusetCpus: String?
    let CpusetMems: String?
    let Devices: [Device]?
    let DeviceCgroupRules: [String]?
    let DeviceRequests: [DeviceRequest]?
    let DiskQuota: Int?
    let Dns: [String]?
    let DnsOptions: [String]?
    let DnsSearch: [String]?
    let ExtraHosts: [String]?
    let GroupAdd: [String]?
    let IpcMode: String?
    let Cgroup: String?
    let Links: [String]?
    let LogConfig: LogConfig?
    let LxcConf: [String]?
    let Memory: Int?
    let MemorySwap: Int?
    let MemoryReservation: Int?
    let KernelMemory: Int?
    let NetworkMode: String?
    let OomKillDisable: Bool?
    let Init: Bool?
    let AutoRemove: Bool?
    let OomScoreAdj: Int?
    let PortBindings: [String: [PortBinding]]?
    let Privileged: Bool?
    let PublishAllPorts: Bool?
    let ReadonlyRootfs: Bool?
    let RestartPolicy: RestartPolicy?
    let Ulimits: [Ulimit]?
    let CpuCount: Int?
    let CpuPercent: Int?
    let IOMaximumIOps: Int?
    let IOMaximumBandwidth: Int?
    let VolumesFrom: [String]?
    let Mounts: [Mount]?
    let PidMode: String?
    let Isolation: String?
    let SecurityOpt: [String]?
    let StorageOpt: [String]?
    let CgroupParent: String?
    let VolumeDriver: String?
    let ShmSize: Int?
    let PidsLimit: Int?
    let Runtime: String?
    let Tmpfs: [String: String]?
    let UTSMode: String?
    let UsernsMode: String?
    let Sysctls: [String: String]?
    let ConsoleSize: [Int]?
    let MaskedPaths: [String]?
    let ReadonlyPaths: [String]?
    let CgroupnsMode: String?

    /// The route fills what the runtime actually knows (issue #17); every other
    /// field stays nil and the encoder emits moby's zero for it, so the wire
    /// shape always matches dockerd's.
    public init(
        restartPolicy: RestartPolicy? = nil,
        binds: [String]? = nil,
        portBindings: [String: [PortBinding]]? = nil,
        memory: Int? = nil,
        nanoCpus: Int? = nil,
        shmSize: Int? = nil,
        capAdd: [String]? = nil,
        capDrop: [String]? = nil,
        readonlyRootfs: Bool? = nil,
        networkMode: String? = nil,
        runtime: String? = nil,
        dnsSearch: [String]? = nil,
        dnsOptions: [String]? = nil,
        maskedPaths: [String]? = nil,
        readonlyPaths: [String]? = nil
    ) {
        self.Binds = binds
        self.BlkioWeight = nil
        self.BlkioWeightDevice = nil
        self.BlkioDeviceReadBps = nil
        self.BlkioDeviceWriteBps = nil
        self.BlkioDeviceReadIOps = nil
        self.BlkioDeviceWriteIOps = nil
        self.MemorySwappiness = nil
        self.NanoCpus = nanoCpus
        self.CapAdd = capAdd
        self.CapDrop = capDrop
        self.ContainerIDFile = nil
        self.CpuPeriod = nil
        self.CpuRealtimePeriod = nil
        self.CpuRealtimeRuntime = nil
        self.CpuShares = nil
        self.CpuQuota = nil
        self.CpusetCpus = nil
        self.CpusetMems = nil
        self.Devices = nil
        self.DeviceCgroupRules = nil
        self.DeviceRequests = nil
        self.DiskQuota = nil
        self.Dns = nil
        self.DnsOptions = dnsOptions
        self.DnsSearch = dnsSearch
        self.ExtraHosts = nil
        self.GroupAdd = nil
        self.IpcMode = nil
        self.Cgroup = nil
        self.Links = nil
        self.LogConfig = nil
        self.LxcConf = nil
        self.Memory = memory
        self.MemorySwap = nil
        self.MemoryReservation = nil
        self.KernelMemory = nil
        self.NetworkMode = networkMode
        self.OomKillDisable = nil
        self.Init = nil
        self.AutoRemove = nil
        self.OomScoreAdj = nil
        self.PortBindings = portBindings
        self.Privileged = nil
        self.PublishAllPorts = nil
        self.ReadonlyRootfs = readonlyRootfs
        self.RestartPolicy = restartPolicy
        self.Ulimits = nil
        self.CpuCount = nil
        self.CpuPercent = nil
        self.IOMaximumIOps = nil
        self.IOMaximumBandwidth = nil
        self.VolumesFrom = nil
        self.Mounts = nil
        self.PidMode = nil
        self.Isolation = nil
        self.SecurityOpt = nil
        self.StorageOpt = nil
        self.CgroupParent = nil
        self.VolumeDriver = nil
        self.ShmSize = shmSize
        self.PidsLimit = nil
        self.Runtime = runtime
        self.Tmpfs = nil
        self.UTSMode = nil
        self.UsernsMode = nil
        self.Sysctls = nil
        self.ConsoleSize = nil
        self.CgroupnsMode = nil
        self.MaskedPaths = maskedPaths
        self.ReadonlyPaths = readonlyPaths
    }
    enum CodingKeys: String, CodingKey {
        case Binds
        case BlkioWeight
        case BlkioWeightDevice
        case BlkioDeviceReadBps
        case BlkioDeviceWriteBps
        case BlkioDeviceReadIOps
        case BlkioDeviceWriteIOps
        case MemorySwappiness
        case NanoCpus
        case CapAdd
        case CapDrop
        case ContainerIDFile
        case CpuPeriod
        case CpuRealtimePeriod
        case CpuRealtimeRuntime
        case CpuShares
        case CpuQuota
        case CpusetCpus
        case CpusetMems
        case Devices
        case DeviceCgroupRules
        case DeviceRequests
        case DiskQuota
        case Dns
        case DnsOptions
        case DnsSearch
        case ExtraHosts
        case GroupAdd
        case IpcMode
        case Cgroup
        case Links
        case LogConfig
        case LxcConf
        case Memory
        case MemorySwap
        case MemoryReservation
        case KernelMemory
        case NetworkMode
        case OomKillDisable
        case Init
        case AutoRemove
        case OomScoreAdj
        case PortBindings
        case Privileged
        case PublishAllPorts
        case ReadonlyRootfs
        case RestartPolicy
        case Ulimits
        case CpuCount
        case CpuPercent
        case IOMaximumIOps
        case IOMaximumBandwidth
        case VolumesFrom
        case Mounts
        case PidMode
        case Isolation
        case SecurityOpt
        case StorageOpt
        case CgroupParent
        case VolumeDriver
        case ShmSize
        case PidsLimit
        case Runtime
        case Tmpfs
        case UTSMode
        case UsernsMode
        case Sysctls
        case ConsoleSize
        case CgroupnsMode
        case MaskedPaths
        case ReadonlyPaths
    }

    // moby's HostConfig carries no `omitempty` on nearly every field
    // (api/types/container/hostconfig.go), so dockerd always emits them —
    // `0` for ints, `""` for strings, `false` for bools, `null` for nil
    // slices/pointers — whether or not the runtime honours the knob. A typed
    // client fails on the *absent key*, not the value (issue #17), so every
    // field the issue lists encodes unconditionally with moby's exact zero
    // when the route has no real value. Fields moby marks `omitempty`
    // (`KernelMemory`, `Init`, `Mounts`, `StorageOpt`, `Tmpfs`, `Sysctls`)
    // and fields moby removed (`DiskQuota`, `LxcConf`) keep the
    // encodeIfPresent behaviour so we never emit a key dockerd would not.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let binds = Binds {
            try container.encode(binds, forKey: .Binds)
        } else {
            try container.encodeNil(forKey: .Binds)
        }
        try container.encode(PortBindings ?? [:], forKey: .PortBindings)
        try container.encode(BlkioWeight ?? 0, forKey: .BlkioWeight)
        try container.encodeNullable(BlkioWeightDevice, forKey: .BlkioWeightDevice)
        try container.encodeNullable(BlkioDeviceReadBps, forKey: .BlkioDeviceReadBps)
        try container.encodeNullable(BlkioDeviceWriteBps, forKey: .BlkioDeviceWriteBps)
        try container.encodeNullable(BlkioDeviceReadIOps, forKey: .BlkioDeviceReadIOps)
        try container.encodeNullable(BlkioDeviceWriteIOps, forKey: .BlkioDeviceWriteIOps)
        try container.encodeNullable(MemorySwappiness, forKey: .MemorySwappiness)
        try container.encode(NanoCpus ?? 0, forKey: .NanoCpus)
        try container.encodeNullable(CapAdd, forKey: .CapAdd)
        try container.encodeNullable(CapDrop, forKey: .CapDrop)
        try container.encode(ContainerIDFile ?? "", forKey: .ContainerIDFile)
        try container.encode(CpuPeriod ?? 0, forKey: .CpuPeriod)
        try container.encode(CpuRealtimePeriod ?? 0, forKey: .CpuRealtimePeriod)
        try container.encode(CpuRealtimeRuntime ?? 0, forKey: .CpuRealtimeRuntime)
        try container.encode(CpuShares ?? 0, forKey: .CpuShares)
        try container.encode(CpuQuota ?? 0, forKey: .CpuQuota)
        try container.encode(CpusetCpus ?? "", forKey: .CpusetCpus)
        try container.encode(CpusetMems ?? "", forKey: .CpusetMems)
        try container.encodeNullable(Devices, forKey: .Devices)
        try container.encodeNullable(DeviceCgroupRules, forKey: .DeviceCgroupRules)
        try container.encodeNullable(DeviceRequests, forKey: .DeviceRequests)
        try container.encodeIfPresent(DiskQuota, forKey: .DiskQuota)
        try container.encodeNullable(Dns, forKey: .Dns)
        try container.encodeNullable(DnsOptions, forKey: .DnsOptions)
        try container.encodeNullable(DnsSearch, forKey: .DnsSearch)
        try container.encodeNullable(ExtraHosts, forKey: .ExtraHosts)
        try container.encodeNullable(GroupAdd, forKey: .GroupAdd)
        try container.encode(IpcMode ?? "", forKey: .IpcMode)
        try container.encode(Cgroup ?? "", forKey: .Cgroup)
        try container.encodeNullable(Links, forKey: .Links)
        try container.encode(LogConfig ?? socktainer.LogConfig(Type: "", Config: nil), forKey: .LogConfig)
        try container.encodeIfPresent(LxcConf, forKey: .LxcConf)
        try container.encode(Memory ?? 0, forKey: .Memory)
        try container.encode(MemorySwap ?? 0, forKey: .MemorySwap)
        try container.encode(MemoryReservation ?? 0, forKey: .MemoryReservation)
        try container.encodeIfPresent(KernelMemory, forKey: .KernelMemory)
        try container.encode(NetworkMode ?? "", forKey: .NetworkMode)
        try container.encodeNullable(OomKillDisable, forKey: .OomKillDisable)
        try container.encodeIfPresent(Init, forKey: .Init)
        try container.encode(AutoRemove ?? false, forKey: .AutoRemove)
        try container.encode(OomScoreAdj ?? 0, forKey: .OomScoreAdj)
        try container.encode(Privileged ?? false, forKey: .Privileged)
        try container.encode(PublishAllPorts ?? false, forKey: .PublishAllPorts)
        try container.encode(ReadonlyRootfs ?? false, forKey: .ReadonlyRootfs)
        try container.encode(RestartPolicy ?? socktainer.RestartPolicy(Name: "", MaximumRetryCount: nil), forKey: .RestartPolicy)
        try container.encodeNullable(Ulimits, forKey: .Ulimits)
        try container.encode(CpuCount ?? 0, forKey: .CpuCount)
        try container.encode(CpuPercent ?? 0, forKey: .CpuPercent)
        try container.encode(IOMaximumIOps ?? 0, forKey: .IOMaximumIOps)
        try container.encode(IOMaximumBandwidth ?? 0, forKey: .IOMaximumBandwidth)
        try container.encodeNullable(VolumesFrom, forKey: .VolumesFrom)
        try container.encodeIfPresent(Mounts, forKey: .Mounts)
        try container.encode(PidMode ?? "", forKey: .PidMode)
        try container.encode(Isolation ?? "", forKey: .Isolation)
        try container.encodeNullable(SecurityOpt, forKey: .SecurityOpt)
        try container.encodeIfPresent(StorageOpt, forKey: .StorageOpt)
        try container.encode(CgroupParent ?? "", forKey: .CgroupParent)
        try container.encode(VolumeDriver ?? "", forKey: .VolumeDriver)
        try container.encode(ShmSize ?? 0, forKey: .ShmSize)
        try container.encodeNullable(PidsLimit, forKey: .PidsLimit)
        try container.encode(Runtime ?? "", forKey: .Runtime)
        try container.encodeIfPresent(Tmpfs, forKey: .Tmpfs)
        try container.encode(UTSMode ?? "", forKey: .UTSMode)
        try container.encode(UsernsMode ?? "", forKey: .UsernsMode)
        try container.encodeIfPresent(Sysctls, forKey: .Sysctls)
        try container.encode(ConsoleSize ?? [0, 0], forKey: .ConsoleSize)
        try container.encode(CgroupnsMode ?? "", forKey: .CgroupnsMode)
        try container.encodeNullable(MaskedPaths, forKey: .MaskedPaths)
        try container.encodeNullable(ReadonlyPaths, forKey: .ReadonlyPaths)
    }
}

struct BlkioWeightDevice: Content {
    let Path: String
    let Weight: Int
}

struct BlkioDeviceRate: Content {
    let Path: String
    let Rate: Int
}

struct Device: Content {
    let PathOnHost: String
    let PathInContainer: String
    let CgroupPermissions: String
}

struct DeviceRequest: Content {
    let Driver: String?
    let Count: Int?
    let DeviceIDs: [String]?
    let Capabilities: [[String]]?
    let Options: [String: String]?
}

struct LogConfig: Content {
    let `Type`: String
    let Config: [String: String]?

    enum CodingKeys: String, CodingKey {
        case `Type` = "Type"
        case Config
    }

    // moby's LogConfig has no `omitempty` on either field, so an unconfigured
    // container gets `{"Type":"","Config":null}` — never an omitted key and
    // never an omitted Config.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(`Type`, forKey: .Type)
        try container.encodeNullable(Config, forKey: .Config)
    }
}

struct PortBinding: Content {
    let HostIp: String?
    let HostPort: String?
}

struct RestartPolicy: Content {
    let Name: String
    let MaximumRetryCount: Int?

    enum CodingKeys: String, CodingKey {
        case Name
        case MaximumRetryCount
    }

    // moby types RestartPolicy.MaximumRetryCount as a plain int with no `omitempty`
    // (api/types/container/hostconfig.go), so dockerd always emits the key — 0 for
    // policies without a retry limit. Omitting it (Swift's synthesized encodeIfPresent)
    // made generated clients nil-deref where dockerd never would. Decoding keeps the
    // optional: `docker run --restart on-failure` sends no MaximumRetryCount at all.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Name, forKey: .Name)
        try container.encode(MaximumRetryCount ?? 0, forKey: .MaximumRetryCount)
    }
}

struct Ulimit: Content {
    let Name: String
    let Soft: Int
    let Hard: Int
}

struct Mount: Content {
    let Target: String
    let Source: String
    let MountType: String
    let ReadOnly: Bool?
    let Consistency: String?
    let BindOptions: BindOptions?
    let VolumeOptions: VolumeOptions?
    let TmpfsOptions: TmpfsOptions?

    enum CodingKeys: String, CodingKey {
        case Target
        case Source
        case MountType = "Type"
        case ReadOnly
        case Consistency
        case BindOptions
        case VolumeOptions
        case TmpfsOptions
    }
}

struct BindOptions: Content {
    let Propagation: String?
}

struct VolumeOptions: Content {
    let NoCopy: Bool?
    let Labels: [String: String]?
    let DriverConfig: VolumeDriverConfig?
}

struct VolumeDriverConfig: Content {
    let Name: String?
    let Options: [String: String]?
}

struct TmpfsOptions: Content {
    let SizeBytes: Int?
    let Mode: Int?
}

struct ContainerNetworkSettings: Content {
    let Bridge: String?
    let SandboxID: String?
    let Ports: [String: [PortBinding]]?
    let SandboxKey: String?
    // The deprecated-but-always-serialised DefaultNetworkSettings block
    // (moby api/types/container/network_settings.go): dockerd mirrors the
    // endpoint of the container's first network here. Nil means "not running
    // or unknown" and encodes as ""/0, matching a stopped container in dockerd.
    let EndpointID: String?
    let Gateway: String?
    let GlobalIPv6Address: String?
    let GlobalIPv6PrefixLen: Int?
    let IPAddress: String?
    let IPPrefixLen: Int?
    let IPv6Gateway: String?
    let MacAddress: String?
    let Networks: [String: ContainerEndpointSettings]?
    let EndpointsConfig: [String: ContainerEndpointSettings]?

    enum CodingKeys: String, CodingKey {
        case Bridge
        case SandboxID
        case Ports
        case SandboxKey
        case EndpointID
        case Gateway
        case GlobalIPv6Address
        case GlobalIPv6PrefixLen
        case IPAddress
        case IPPrefixLen
        case IPv6Gateway
        case MacAddress
        case Networks
        case EndpointsConfig
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Bridge ?? "", forKey: .Bridge)
        try container.encode(SandboxID ?? "", forKey: .SandboxID)
        try container.encode(Ports ?? [:], forKey: .Ports)
        try container.encode(SandboxKey ?? "", forKey: .SandboxKey)
        try container.encode(EndpointID ?? "", forKey: .EndpointID)
        try container.encode(Gateway ?? "", forKey: .Gateway)
        try container.encode(GlobalIPv6Address ?? "", forKey: .GlobalIPv6Address)
        try container.encode(GlobalIPv6PrefixLen ?? 0, forKey: .GlobalIPv6PrefixLen)
        try container.encode(IPAddress ?? "", forKey: .IPAddress)
        try container.encode(IPPrefixLen ?? 0, forKey: .IPPrefixLen)
        try container.encode(IPv6Gateway ?? "", forKey: .IPv6Gateway)
        try container.encode(MacAddress ?? "", forKey: .MacAddress)
        try container.encode(Networks ?? [:], forKey: .Networks)
        try container.encodeIfPresent(EndpointsConfig, forKey: .EndpointsConfig)
    }
}

/// Address type for SecondaryIPAddresses and SecondaryIPv6Addresses
struct Address: Content {
    let Addr: String?
    let PrefixLen: Int?
}

struct ContainerEndpointSettings: Content {
    let IPAMConfig: ContainerIPAMConfig?
    let Links: [String]?
    let Aliases: [String]?
    let NetworkID: String?
    let EndpointID: String?
    let Gateway: String?
    let IPAddress: String?
    let IPPrefixLen: Int?
    let IPv6Gateway: String?
    let GlobalIPv6Address: String?
    let GlobalIPv6PrefixLen: Int?
    let MacAddress: String?
    let DriverOpts: [String: String]?
}

struct ContainerIPAMConfig: Content {
    let IPv4Address: String?
    let IPv6Address: String?
    let LinkLocalIPs: [String]?
}

struct ContainerConfig: Content {
    let Hostname: String?
    let Domainname: String?
    let User: String?
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let ExposedPorts: [String: EmptyObject]?
    let Tty: Bool?
    let OpenStdin: Bool?
    let StdinOnce: Bool?
    let Env: [String]?
    let Cmd: [String]?
    let Healthcheck: HealthcheckConfig?
    let ArgsEscaped: Bool?
    let Image: String
    let Volumes: [String: EmptyObject]?
    let WorkingDir: String?
    let Entrypoint: [String]?
    let NetworkDisabled: Bool?
    let MacAddress: String?
    let OnBuild: [String]?
    let Labels: [String: String]?
    let StopSignal: String?
    let StopTimeout: Int?
    let Shell: [String]?

    enum CodingKeys: String, CodingKey {
        case Hostname
        case Domainname
        case User
        case AttachStdin
        case AttachStdout
        case AttachStderr
        case ExposedPorts
        case Tty
        case OpenStdin
        case StdinOnce
        case Env
        case Cmd
        case Healthcheck
        case ArgsEscaped
        case Image
        case Volumes
        case WorkingDir
        case Entrypoint
        case NetworkDisabled
        case MacAddress
        case OnBuild
        case Labels
        case StopSignal
        case StopTimeout
        case Shell
    }

    // moby's container Config has no `omitempty` on Labels, Domainname or
    // Volumes (api/types/container/config.go). dockerd emits `{}` for an
    // unlabeled container, `""` for a domain-less one and JSON `null` for a
    // volume-less one — the synthesized encoder omitted all three keys, so a
    // client doing `.Config.Labels["com.docker.compose.project"]` or reading
    // `.Config.Volumes` nil-deref'd / keyed-absent instead (issues #11, #17).
    // Everything else keeps the synthesized behaviour.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(Hostname, forKey: .Hostname)
        try container.encode(Domainname ?? "", forKey: .Domainname)
        try container.encodeIfPresent(User, forKey: .User)
        try container.encodeIfPresent(AttachStdin, forKey: .AttachStdin)
        try container.encodeIfPresent(AttachStdout, forKey: .AttachStdout)
        try container.encodeIfPresent(AttachStderr, forKey: .AttachStderr)
        try container.encodeIfPresent(ExposedPorts, forKey: .ExposedPorts)
        try container.encodeIfPresent(Tty, forKey: .Tty)
        try container.encodeIfPresent(OpenStdin, forKey: .OpenStdin)
        try container.encodeIfPresent(StdinOnce, forKey: .StdinOnce)
        try container.encodeIfPresent(Env, forKey: .Env)
        try container.encodeIfPresent(Cmd, forKey: .Cmd)
        try container.encodeIfPresent(Healthcheck, forKey: .Healthcheck)
        try container.encodeIfPresent(ArgsEscaped, forKey: .ArgsEscaped)
        try container.encode(Image, forKey: .Image)
        try container.encodeNullable(Volumes, forKey: .Volumes)
        try container.encodeIfPresent(WorkingDir, forKey: .WorkingDir)
        try container.encodeIfPresent(Entrypoint, forKey: .Entrypoint)
        try container.encodeIfPresent(NetworkDisabled, forKey: .NetworkDisabled)
        try container.encodeIfPresent(MacAddress, forKey: .MacAddress)
        try container.encodeIfPresent(OnBuild, forKey: .OnBuild)
        try container.encode(Labels ?? [:], forKey: .Labels)
        try container.encodeIfPresent(StopSignal, forKey: .StopSignal)
        try container.encodeIfPresent(StopTimeout, forKey: .StopTimeout)
        try container.encodeIfPresent(Shell, forKey: .Shell)
    }
}

// `/networks` related
public struct NetworkConfigReference: Codable, Sendable {
    public let Network: String
}

public struct NetworkContainer: Codable, Sendable {
    public let Name: String
    public let EndpointID: String?
    public let MacAddress: String?
    public let IPv4Address: String
    public let IPv6Address: String?
}

public struct NetworkLabel: Codable {
    public let Name: String
}

public struct NetworkIPAMConfig: Codable, Sendable {
    public let Subnet: String?
    public let IPRange: String?
    public let Gateway: String?
    public let AuxiliaryAddresses: [String: String]?
}

public struct NetworkIPAM: Codable, Sendable {
    public let Driver: String
    public let Config: [NetworkIPAMConfig]
}

// `/volumes` related

struct VolumeRequest: Content {
    let Name: String?
    let Driver: String?
    let DriverOpts: [String: String]?
    let Labels: [String: String]?
    let ClusterVolumeSpec: EmptyObject?
}

struct VolumeUsageData: Content {
    let Size: Int64
    let RefCount: Int64
    init(Size: Int64, RefCount: Int64) {
        self.Size = Size
        self.RefCount = RefCount
    }
    init() {
        self.Size = -1  // will return -1, we have no option to calculate the actual usage of volume
        self.RefCount = -1  // will return -1, we don't map attached containers to volumes
    }
}

struct Volume: Content {
    let Name: String
    let Driver: String
    let Mountpoint: String
    let CreatedAt: String?
    let Status: [String: String]?
    let Labels: [String: String]?
    let Scope: String
    let ClusterVolume: EmptyObject?  // unused, only part of swarm
    let Options: [String: String]
    let UsageData: VolumeUsageData?
}

struct VolumeInfo: Content {
    let CreatedAt: String
    let Driver: String
    let Labels: [String: String]?
    let Mountpoint: String
    let Name: String
    let Options: [String: String]
    let Scope: String
    let Status: [String: String]?  // we do not report any status from the underlying driver at the moment
    let UsageData: VolumeUsageData?
}

// image related

struct ImageOCIDescriptor: Content {
    let mediaType: String
    let digest: String
    let size: Int64
    let urls: [String]?
    let annotations: [String: String]?
    let platform: ImageOCIPlatform?
}

struct ImageOCIPlatform: Content {
    let architecture: String
    let os: String
    let osVersion: String?
    let osFeatures: [String]?
    let variant: String?
}

// container related

struct ContainerDriverData: Content {
    let Name: String
    let Data: [String: String]
}

struct ContainerMountPoint: Content {
    let type: String
    let name: String?
    let source: String
    let destination: String
    let driver: String?
    let mode: String
    let rw: Bool
    let propagation: String

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case name = "Name"
        case source = "Source"
        case destination = "Destination"
        case driver = "Driver"
        case mode = "Mode"
        case rw = "RW"
        case propagation = "Propagation"
    }
}

struct ContainerPort: Content {
    let IP: String?
    let PrivatePort: Int
    let PublicPort: Int?
    let type: String

    enum CodingKeys: String, CodingKey {
        case IP
        case PrivatePort
        case PublicPort
        case type = "Type"
    }
}

struct ContainerHostConfig: Content {
    let NetworkMode: String
    let Annotations: [String: String]?
}

struct ContainerNetworkSummary: Content {
    let Networks: [String: ContainerEndpointSettings]?
}

public struct ContainerWaitExitError: Codable, Sendable {
    public let Message: String?
}

// auth related

struct AuthConfig: Content {
    let username: String?
    let password: String?
    let email: String?
    let serveraddress: String?
}
