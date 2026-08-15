import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Regression tests for issue #17: dockerd always serialises ~75 more keys on
/// `GET /containers/{id}/json` than socktainer did — 60 HostConfig knobs,
/// `Config.Domainname`/`Config.Volumes`, `ExecIDs`/`LogPath`, and the ten
/// top-level NetworkSettings fields. Docker emits these as zero/null defaults
/// whether or not the runtime can honour them, and typed clients fail on the
/// *absent key*, not the value. These assert raw JSON key presence and the
/// exact zero shape (0 / "" / false / null) taken from moby v28.5.2's
/// `api/types/container/hostconfig.go`, `config.go`, `container.go` and
/// `network_settings.go`, so a dropped field fails the suite again.
@Suite("ContainerInspectRoute moby field shape")
struct ContainerInspectMobyShapeTests {

    // MARK: - Fixtures

    private static func makeSnapshot(
        id: String,
        status: RuntimeStatus = .stopped,
        liveNetworks: [ContainerResource.Attachment] = [],
        configure: (inout ContainerConfiguration) -> Void = { _ in }
    ) -> ContainerSnapshot {
        let processConfig = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
        let imageDesc = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
        )
        var config = ContainerConfiguration(id: id, image: imageDesc, process: processConfig)
        configure(&config)
        return ContainerSnapshot(
            configuration: config,
            status: status,
            networks: liveNetworks,
            startedDate: status == .running ? Date(timeIntervalSinceNow: -30) : nil
        )
    }

    private func withRoute(
        snapshot: ContainerSnapshot,
        test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: ContainerInspectRoute(client: MobyShapeMock(snapshot: snapshot)))
            try await test(app)
        }
    }

    private func inspectJSON(_ body: ByteBuffer) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any])
    }

    /// Every field from the issue's HostConfig list must be present in the
    /// payload. `isSubset` (rather than equality) so the omitempty keys moby
    /// legitimately drops, plus Binds/PortBindings/RestartPolicy from #11,
    /// don't make this test brittle.
    private static let issueHostConfigKeys: Set<String> = [
        "AutoRemove", "BlkioDeviceReadBps", "BlkioDeviceReadIOps", "BlkioDeviceWriteBps",
        "BlkioDeviceWriteIOps", "BlkioWeight", "BlkioWeightDevice", "CapAdd", "CapDrop",
        "Cgroup", "CgroupParent", "CgroupnsMode", "ConsoleSize", "ContainerIDFile", "CpuCount",
        "CpuPercent", "CpuPeriod", "CpuQuota", "CpuRealtimePeriod", "CpuRealtimeRuntime",
        "CpuShares", "CpusetCpus", "CpusetMems", "DeviceCgroupRules", "DeviceRequests",
        "Devices", "Dns", "DnsOptions", "DnsSearch", "ExtraHosts", "GroupAdd",
        "IOMaximumBandwidth", "IOMaximumIOps", "IpcMode", "Isolation", "Links", "LogConfig",
        "MaskedPaths", "Memory", "MemoryReservation", "MemorySwap", "MemorySwappiness",
        "NanoCpus", "NetworkMode", "OomKillDisable", "OomScoreAdj", "PidMode", "PidsLimit",
        "Privileged", "PublishAllPorts", "ReadonlyPaths", "ReadonlyRootfs", "Runtime",
        "SecurityOpt", "ShmSize", "UTSMode", "Ulimits", "UsernsMode", "VolumeDriver",
        "VolumesFrom",
    ]

    private static let issueNetworkSettingsKeys: Set<String> = [
        "EndpointID", "Gateway", "GlobalIPv6Address", "GlobalIPv6PrefixLen", "IPAddress",
        "IPPrefixLen", "IPv6Gateway", "MacAddress", "SandboxID", "SandboxKey",
    ]

    /// Asserts `expected` against the raw JSON object: ints, strings, bools by
    /// value, anything else as JSON null.
    private func expectValues(_ expected: [String: Any], in object: [String: Any], _ what: String) {
        for (key, value) in expected {
            let actual = object[key]
            switch value {
            case let number as Int: #expect(actual as? Int == number, "\(what).\(key)")
            case let string as String: #expect(actual as? String == string, "\(what).\(key)")
            case let bool as Bool: #expect(actual as? Bool == bool, "\(what).\(key)")
            case let ints as [Int]: #expect(actual as? [Int] == ints, "\(what).\(key)")
            case let strings as [String]: #expect(actual as? [String] == strings, "\(what).\(key)")
            default: #expect(actual is NSNull, "\(what).\(key)")
            }
        }
    }

    // MARK: - HostConfig

    @Test("HostConfig carries all 60 issue-listed keys with moby's zero shapes")
    func hostConfigEmitsMobyZeroes() async throws {
        // Default fixture: Apple Container's own resource defaults (4 vCPU,
        // 1 GiB) are what the runtime enforces, so they are the *real* values
        // here — everything else must appear as moby's zero.
        try await withRoute(snapshot: Self.makeSnapshot(id: "moby-zero")) { app in
            try await app.testing().test(.GET, "/v1.51/containers/moby-zero/json") { res async throws in
                let json = try inspectJSON(res.body)
                let hostConfig = try #require(json["HostConfig"] as? [String: Any])

                let missing = Self.issueHostConfigKeys.subtracting(hostConfig.keys)
                #expect(missing.isEmpty, "HostConfig dropped: \(missing.sorted())")

                expectValues(
                    [
                        "AutoRemove": false,
                        "BlkioDeviceReadBps": NSNull(),
                        "BlkioDeviceReadIOps": NSNull(),
                        "BlkioDeviceWriteBps": NSNull(),
                        "BlkioDeviceWriteIOps": NSNull(),
                        "BlkioWeight": 0,
                        "BlkioWeightDevice": NSNull(),
                        "CapAdd": NSNull(),
                        "CapDrop": NSNull(),
                        "Cgroup": "",
                        "CgroupParent": "",
                        "CgroupnsMode": "",
                        "ConsoleSize": [0, 0],
                        "ContainerIDFile": "",
                        "CpuCount": 0,
                        "CpuPercent": 0,
                        "CpuPeriod": 0,
                        "CpuQuota": 0,
                        "CpuRealtimePeriod": 0,
                        "CpuRealtimeRuntime": 0,
                        "CpuShares": 0,
                        "CpusetCpus": "",
                        "CpusetMems": "",
                        "DeviceCgroupRules": NSNull(),
                        "DeviceRequests": NSNull(),
                        "Devices": NSNull(),
                        "Dns": NSNull(),
                        "DnsOptions": NSNull(),
                        "DnsSearch": NSNull(),
                        "ExtraHosts": NSNull(),
                        "GroupAdd": NSNull(),
                        "IOMaximumBandwidth": 0,
                        "IOMaximumIOps": 0,
                        "IpcMode": "",
                        "Isolation": "",
                        "Links": NSNull(),
                        "MaskedPaths": NSNull(),
                        "Memory": 1_073_741_824,  // Apple Container default: 1 GiB, enforced
                        "MemoryReservation": 0,
                        "MemorySwap": 0,
                        "MemorySwappiness": NSNull(),
                        "NanoCpus": 4_000_000_000,  // 4 default vCPUs, enforced
                        "NetworkMode": "none",  // fixture has no networks at all
                        "OomKillDisable": NSNull(),
                        "OomScoreAdj": 0,
                        "PidMode": "",
                        "PidsLimit": NSNull(),
                        "Privileged": false,
                        "PublishAllPorts": false,
                        "ReadonlyPaths": NSNull(),
                        "ReadonlyRootfs": false,
                        "Runtime": "container-runtime-linux",
                        "SecurityOpt": NSNull(),
                        "ShmSize": 0,  // fixture never set one; create defaults only on the create path
                        "UTSMode": "",
                        "Ulimits": NSNull(),
                        "UsernsMode": "",
                        "VolumeDriver": "",
                        "VolumesFrom": NSNull(),
                    ],
                    in: hostConfig,
                    "HostConfig"
                )

                // LogConfig is a nested object with no omitempty in moby.
                let logConfig = try #require(hostConfig["LogConfig"] as? [String: Any])
                #expect((logConfig["Type"] as? String) == "")
                #expect(logConfig["Config"] is NSNull)
            }
        }
    }

    @Test("HostConfig reports the values the runtime actually knows")
    func hostConfigReportsRealValues() async throws {
        let attachment = try ContainerResource.Attachment(
            network: "mynet",
            hostname: "c1",
            ipv4Address: CIDRv4("192.168.64.5/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: CIDRv6("fd00::1/64"),
            macAddress: MACAddress("aa:bb:cc:dd:ee:ff")
        )
        let snapshot = Self.makeSnapshot(id: "moby-real", status: .running, liveNetworks: [attachment]) { config in
            config.resources.cpus = 2
            config.resources.memoryInBytes = 536_870_912
            config.shmSize = 67_108_864
            config.capAdd = ["NET_ADMIN"]
            config.capDrop = ["CHOWN"]
            config.readOnly = true
            config.runtimeHandler = "container-runtime-linux"
            config.dns = ContainerConfiguration.DNSConfiguration(
                nameservers: ["192.168.64.1"],
                domain: "example.com",
                searchDomains: ["example.com"],
                options: ["ndots:2"]
            )
            config.maskedPaths = ["/proc/keys"]
            config.readonlyPaths = ["/proc/sys"]
        }
        try await withRoute(snapshot: snapshot) { app in
            try await app.testing().test(.GET, "/v1.51/containers/moby-real/json") { res async throws in
                let json = try inspectJSON(res.body)
                expectValues(
                    [
                        "Memory": 536_870_912,
                        "NanoCpus": 2_000_000_000,
                        "ShmSize": 67_108_864,
                        "CapAdd": ["NET_ADMIN"],
                        "CapDrop": ["CHOWN"],
                        "ReadonlyRootfs": true,
                        "NetworkMode": "mynet",
                        "Runtime": "container-runtime-linux",
                        "DnsSearch": ["example.com"],
                        "DnsOptions": ["ndots:2"],
                        "MaskedPaths": ["/proc/keys"],
                        "ReadonlyPaths": ["/proc/sys"],
                    ],
                    in: try #require(json["HostConfig"] as? [String: Any]),
                    "HostConfig"
                )

                // The mirrored DefaultNetworkSettings block carries the live endpoint.
                let networkSettings = try #require(json["NetworkSettings"] as? [String: Any])
                expectValues(
                    [
                        "IPAddress": "192.168.64.5",
                        "IPPrefixLen": 24,
                        "Gateway": "192.168.64.1",
                        "GlobalIPv6Address": "fd00::1",
                        "GlobalIPv6PrefixLen": 64,
                        "MacAddress": "aa:bb:cc:dd:ee:ff",
                    ],
                    in: networkSettings,
                    "NetworkSettings"
                )
                // And so does the per-network endpoint.
                let endpoint = try #require(networkSettings["Networks"] as? [String: Any])["mynet"]
                #expect(((endpoint as? [String: Any])?["MacAddress"] as? String) == "aa:bb:cc:dd:ee:ff")
            }
        }
    }

    // MARK: - Config, container level

    @Test("Config.Domainname is an empty string and Config.Volumes is JSON null")
    func configDomainnameAndVolumes() async throws {
        try await withRoute(snapshot: Self.makeSnapshot(id: "moby-config")) { app in
            try await app.testing().test(.GET, "/v1.51/containers/moby-config/json") { res async throws in
                let json = try inspectJSON(res.body)
                let config = try #require(json["Config"] as? [String: Any])
                #expect((config["Domainname"] as? String) == "")
                #expect(config["Volumes"] is NSNull)
            }
        }
    }

    @Test("ExecIDs is JSON null, LogPath is an empty string, State.Pid is 0")
    func containerLevelFields() async throws {
        try await withRoute(snapshot: Self.makeSnapshot(id: "moby-toplevel")) { app in
            try await app.testing().test(.GET, "/v1.51/containers/moby-toplevel/json") { res async throws in
                let json = try inspectJSON(res.body)
                #expect(json["ExecIDs"] is NSNull)
                #expect((json["LogPath"] as? String) == "")
                let state = try #require(json["State"] as? [String: Any])
                #expect((state["Pid"] as? Int) == 0)
            }
        }
    }

    // MARK: - NetworkSettings

    @Test("NetworkSettings emits the ten top-level keys, empty for a stopped container")
    func networkSettingsTopLevelEmpties() async throws {
        let snapshot = Self.makeSnapshot(id: "moby-net-stopped") { config in
            config.networks = [AttachmentConfiguration(network: "mynet", options: AttachmentOptions(hostname: "c1"))]
        }
        try await withRoute(snapshot: snapshot) { app in
            try await app.testing().test(.GET, "/v1.51/containers/moby-net-stopped/json") { res async throws in
                let json = try inspectJSON(res.body)
                let networkSettings = try #require(json["NetworkSettings"] as? [String: Any])
                let missing = Self.issueNetworkSettingsKeys.subtracting(networkSettings.keys)
                #expect(missing.isEmpty, "NetworkSettings dropped: \(missing.sorted())")
                expectValues(
                    [
                        "Bridge": "",
                        "EndpointID": "",
                        "Gateway": "",
                        "GlobalIPv6Address": "",
                        "GlobalIPv6PrefixLen": 0,
                        "IPAddress": "",
                        "IPPrefixLen": 0,
                        "IPv6Gateway": "",
                        "MacAddress": "",
                        "SandboxID": "",
                        "SandboxKey": "",
                    ],
                    in: networkSettings,
                    "NetworkSettings"
                )
            }
        }
    }
}

private struct MobyShapeMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
