import ContainerAPIClient
import ContainerResource
import ContainerXPC
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite struct SharedRuntimeSignalTests {
    @Test func dockerDefaultAndSIGKILLBecomeTheControlSignal36() throws {
        for signal in [nil, "", "KILL", "SIGKILL", "sigkill", "9"] {
            #expect(try SharedRuntimeSignal.launcherSignal(forDocker: signal) == "36", "\(signal ?? "nil")")
        }
    }

    @Test func sigstopIsRefused() {
        for signal in ["STOP", "SIGSTOP", "stop", "19"] {
            #expect(throws: SharedRuntimeSignal.Failure.unsupported(signal)) {
                try SharedRuntimeSignal.launcherSignal(forDocker: signal)
            }
        }
        #expect(
            SharedRuntimeSignal.Failure.unsupported("SIGSTOP").description
                == "signal SIGSTOP is not supported for a session of a shared group")
    }

    @Test func numbersAreComparedAndSentInOneForm() throws {
        for signal in ["09", "+9", "SIG09", "0009"] {
            #expect(try SharedRuntimeSignal.launcherSignal(forDocker: signal) == "36", "\(signal)")
        }
        for signal in ["019", "+19"] {
            #expect(throws: SharedRuntimeSignal.Failure.self) { try SharedRuntimeSignal.launcherSignal(forDocker: signal) }
        }
        #expect(try SharedRuntimeSignal.launcherSignal(forDocker: "010") == "10")
    }

    @Test func otherSignalsGoUnchanged() throws {
        for signal in ["SIGTERM", "TERM", "15", "SIGUSR1", "10", "SIGRTMIN+3"] {
            #expect(try SharedRuntimeSignal.launcherSignal(forDocker: signal) == signal)
        }
    }

    @Test func killRequestTargetsOneProcessWithTheSignalAsAString() {
        let request = SharedRuntimeSignal.killRequest(containerID: "cs-shared-g-0123abcd-1", processID: "session-1", signal: "36")
        #expect(request.string(key: XPCMessage.routeKey) == XPCRoute.containerKill.rawValue)
        #expect(request.string(key: XPCKeys.id.rawValue) == "cs-shared-g-0123abcd-1")
        #expect(request.string(key: XPCKeys.processIdentifier.rawValue) == "session-1")
        #expect(request.string(key: XPCKeys.signal.rawValue) == "36")
    }
}

@Suite struct SharedContainerSpecTests {
    @Test func nameAndLabelsFollowTheContract() throws {
        let key = SharingKey(
            imageID: "sha256:abc",
            process: SharedRuntimeProcess(
                executable: "/server", arguments: [], environment: [], workingDirectory: "/", user: .id(uid: 0, gid: 0)))
        let image = ImageDescription(
            reference: "docker.io/mcp/time:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 1))
        let spec = SharedContainerSpec.make(
            group: "mcp-catalog", key: key, socketPath: "/tmp/bridge.sock", image: image, platform: .current,
            launcherDirectory: URL(fileURLWithPath: "/tmp/launcher"), suffix: "1a2b3c4d")

        #expect(spec.name == "cs-shared-mcp-catalog-\(key.nameFragment)-1a2b3c4d")
        #expect(spec.name.count <= 64)
        #expect(spec.labels[SharedRuntimeLabels.sharedGroup] == "mcp-catalog")
        #expect(spec.labels[SharedRuntimeLabels.sharedKey] == key.labelValue)
        #expect(spec.labels[SharedRuntimeLabels.sharedSocket] == "/tmp/bridge.sock")
        #expect(spec.labels[DockerContainerID.idLabel] == spec.dockerID)
        #expect(DockerContainerID.isWellFormed(spec.dockerID))
    }
}
