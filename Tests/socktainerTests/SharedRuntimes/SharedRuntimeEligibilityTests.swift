import Foundation
import Testing

@testable import socktainer

@Suite struct SharedRuntimeEligibilityTests {
    private typealias F = SharedRuntimeFixtures

    private func reason(
        imageVolumes: [String: [String: String]]? = nil,
        _ edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> SharedRuntimeReason? {
        SharedRuntimeEligibility.reason(for: try F.request(edit), imageVolumes: imageVolumes)
    }

    private func host(_ key: String, _ value: Any) throws -> SharedRuntimeReason? {
        try reason(F.setHostConfig(key, value))
    }

    // MARK: The recorded Docker CLI body

    @Test func recordedDockerCLIBodyIsEligible() throws {
        #expect(try reason() == nil)
    }

    @Test func recordedDockerCLIBodyWithAGroupLabelIsEligible() throws {
        #expect(try reason { $0["Labels"] = ["containerstack.group": "mcp-catalog"] } == nil)
    }

    @Test func recordedDockerCLIBodyHasOnlyDeclaredKeys() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: F.recordedRunBody()) as? [String: Any])
        let hostConfig = try #require(object["HostConfig"] as? [String: Any])
        let networking = try #require(object["NetworkingConfig"] as? [String: Any])
        #expect(Set(object.keys).subtracting(SharedRuntimeEligibility.requestKeys).isEmpty)
        #expect(Set(hostConfig.keys).subtracting(SharedRuntimeEligibility.hostConfigKeys).isEmpty)
        #expect(Set(networking.keys).subtracting(SharedRuntimeEligibility.networkingConfigKeys).isEmpty)
    }

    @Test func declaredKeySetsComeFromTheRequestTypes() {
        #expect(SharedRuntimeEligibility.requestKeys.isSuperset(of: ["Image", "OpenStdin", "HostConfig", "Shell"]))
        #expect(SharedRuntimeEligibility.hostConfigKeys.isSuperset(of: ["AutoRemove", "Privileged", "CgroupnsMode"]))
        #expect(SharedRuntimeEligibility.networkingConfigKeys.isSuperset(of: ["EndpointsConfig", "Networks"]))
        #expect(!SharedRuntimeEligibility.hostConfigKeys.contains("Annotations"))
    }

    // MARK: Required stdin attachment and auto-remove

    @Test func openStdinIsRequired() throws {
        #expect(try reason { $0["OpenStdin"] = false } == .noStdin)
        #expect(try reason { $0.removeValue(forKey: "OpenStdin") } == .noStdin)
    }

    @Test func attachStdinIsRequired() throws {
        #expect(try reason { $0["AttachStdin"] = false } == .noStdin)
    }

    @Test func attachStdoutIsRequired() throws {
        #expect(try reason { $0["AttachStdout"] = false } == .noStdin)
    }

    @Test func autoRemoveIsRequired() throws {
        #expect(try host("AutoRemove", false) == .noAutoremove)
        #expect(try reason { $0.removeValue(forKey: "HostConfig") } == .noAutoremove)
    }

    @Test func ttyIsNotAllowed() throws {
        #expect(try reason { $0["Tty"] = true } == .tty)
    }

    @Test func nonTtyRunWithConsoleSizeIsEligible() throws {
        #expect(
            try reason {
                $0["Tty"] = false
                F.setHostConfig("ConsoleSize", [24, 80])(&$0)
            } == nil)
    }

    @Test func ttyRunWithConsoleSizeKeepsTheTtyReason() throws {
        #expect(
            try reason {
                $0["Tty"] = true
                F.setHostConfig("ConsoleSize", [24, 80])(&$0)
            } == .tty)
    }

    // MARK: Mounts, ports, network, limits

    @Test func bindsAreAMount() throws {
        #expect(try host("Binds", ["/host:/guest"]) == .mount)
    }

    @Test func mountsAreAMount() throws {
        #expect(try host("Mounts", [["Type": "volume", "Target": "/data"]]) == .mount)
    }

    @Test func requestVolumesAreAMount() throws {
        #expect(try reason { $0["Volumes"] = ["/data": [String: Any]()] } == .mount)
    }

    @Test func volumesFromAndTmpfsAreAMount() throws {
        #expect(try host("VolumesFrom", ["other"]) == .mount)
        #expect(try host("Tmpfs", ["/run": ""]) == .mount)
    }

    @Test func imageWithADeclaredVolumeIsAMount() throws {
        #expect(try reason(imageVolumes: ["/var/lib/data": [:]]) == .mount)
        #expect(try reason(imageVolumes: [:]) == nil)
    }

    @Test func portBindingsAreAPort() throws {
        #expect(try host("PortBindings", ["80/tcp": [["HostPort": "8080"]]]) == .port)
        #expect(try host("PublishAllPorts", true) == .port)
    }

    @Test func aNamedNetworkIsNotTheDefaultNetwork() throws {
        #expect(try host("NetworkMode", "mynet") == .network)
        #expect(try host("NetworkMode", "host") == .network)
        #expect(try host("NetworkMode", "none") == .network)
        #expect(try reason { $0["NetworkingConfig"] = ["EndpointsConfig": ["mynet": [String: Any]()]] } == .network)
        #expect(
            try reason { $0["NetworkingConfig"] = ["EndpointsConfig": ["default": ["Aliases": ["db"]]]] } == .network)
        #expect(try reason { $0["NetworkDisabled"] = true } == .network)
    }

    @Test func theDefaultNetworkInAnySpellingIsAllowed() throws {
        for mode in ["default", "bridge", ""] {
            #expect(try host("NetworkMode", mode) == nil)
        }
        #expect(try reason { $0.removeValue(forKey: "NetworkingConfig") } == nil)
        #expect(try reason { $0["NetworkingConfig"] = ["EndpointsConfig": ["bridge": [String: Any]()]] } == nil)
    }

    @Test func memoryAndCPULimitsAreLimits() throws {
        #expect(try host("Memory", 512 * 1024 * 1024) == .limits)
        #expect(try host("NanoCpus", 1_000_000_000) == .limits)
        #expect(try host("CpuShares", 512) == .limits)
        #expect(try host("CpusetCpus", "0-1") == .limits)
        #expect(try host("MemorySwappiness", 0) == .limits)
    }

    // MARK: The allowlist

    @Test func privilegedIsAnOption() throws {
        #expect(try host("Privileged", true) == .option("Privileged"))
    }

    @Test func otherDeclaredFieldsMustBeAtTheirDefault() throws {
        #expect(try host("RestartPolicy", ["Name": "always", "MaximumRetryCount": 0]) == .option("RestartPolicy"))
        #expect(try host("CapAdd", ["NET_ADMIN"]) == .option("CapAdd"))
        #expect(try reason { $0["Hostname"] = "box" } == .option("Hostname"))
        #expect(try reason { $0["Healthcheck"] = ["Test": ["CMD", "true"]] } == .option("Healthcheck"))
    }

    @Test func aMapWithEmptyValuesIsNotEmpty() throws {
        #expect(try reason { $0["ExposedPorts"] = ["80/tcp": [String: Any]()] } == .option("ExposedPorts"))
        #expect(try host("Sysctls", ["net.ipv4.ip_forward": ""]) == .option("Sysctls"))
        #expect(try host("PortBindings", ["80/tcp": [Any]()]) == .port)
        #expect(try reason { $0["NetworkingConfig"] = ["EndpointsConfig": ["default": ["DriverOpts": ["k": ""]]]] } == .network)
    }

    @Test func clientSpelledDefaultsAreDefaultsAndOtherValuesAreNot() throws {
        #expect(try host("ConsoleSize", [0, 0]) == nil)
        #expect(try host("LogConfig", ["Type": "", "Config": [String: Any]()]) == nil)
        #expect(try host("LogConfig", ["Type": "json-file"]) == .option("LogConfig"))
        #expect(try host("RestartPolicy", ["Name": "no", "MaximumRetryCount": 3]) == .option("RestartPolicy"))
    }

    @Test func missingNullAndEmptyAreTheSameDefault() throws {
        let minimal: [String: Any] = [
            "Image": "busybox", "OpenStdin": true, "AttachStdin": true, "AttachStdout": true,
            "HostConfig": ["AutoRemove": true],
        ]
        #expect(try reason { $0 = minimal } == nil)
        #expect(
            try reason {
                $0["Hostname"] = NSNull()
                $0["OnBuild"] = [String]()
                $0["Volumes"] = NSNull()
            } == nil)
        #expect(try host("RestartPolicy", ["Name": "", "MaximumRetryCount": 0]) == nil)
        #expect(try host("RestartPolicy", NSNull()) == nil)
    }

    @Test func fieldsThatCanHaveAnyValue() throws {
        let edited = try reason {
            $0["Labels"] = ["a": "b"]
            $0["AttachStderr"] = false
            $0["StdinOnce"] = false
            $0["Env"] = ["TOKEN=x"]
            $0["Cmd"] = ["serve"]
            $0["Entrypoint"] = ["/bin/app"]
            $0["User"] = "1000"
            $0["WorkingDir"] = "/srv"
            $0["Image"] = "mcp/time"
        }
        #expect(edited == nil)
    }

    // MARK: Keys the request types do not declare

    @Test func unknownKeyWithADefaultLikeValueStaysEligible() throws {
        let edited = try reason {
            $0["FutureNull"] = NSNull()
            $0["FutureFalse"] = false
            $0["FutureZero"] = 0
            $0["FutureString"] = ""
            $0["FutureArray"] = [Any]()
            $0["FutureObject"] = [String: Any]()
            var host = $0["HostConfig"] as! [String: Any]
            host["Annotations"] = [String: Any]()
            $0["HostConfig"] = host
        }
        #expect(edited == nil)
    }

    @Test func hostConfigAnnotationsWithAnEntryIsNotEligible() throws {
        #expect(try host("Annotations", ["io.example": "1"]) == .option("Annotations"))
    }

    @Test func unknownKeyWithAValueIsNotEligible() throws {
        #expect(try reason { $0["Future"] = 1 } == .option("Future"))
        #expect(try reason { $0["Future"] = ["a": 0] } == .option("Future"))
        #expect(try reason { $0["privileged"] = true } == .option("privileged"))
        #expect(try reason { $0["NetworkingConfig"] = ["Future": "x"] } == .option("Future"))
    }
}
