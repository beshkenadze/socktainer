import ContainerAPIClient
import ContainerXPC
import Foundation

/// Signals for the launcher of a session (spec §3.3).
enum SharedRuntimeSignal {
    /// "End now": the launcher sends SIGKILL to the program and then cleans up. The launcher is
    /// a musl binary, where `SIGRTMIN` is 35, so this is `SIGRTMIN+1` there. Sent as a number,
    /// never as a name that the host or the runtime resolves.
    static let endNow = "36"

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupported(String)

        var description: String {
            switch self {
            case .unsupported(let signal): "signal \(signal) is not supported for a session of a shared group"
            }
        }
    }

    /// The signal string to send to the launcher for a Docker signal (`kill -s`, `StopSignal`).
    /// Docker's default and SIGKILL become the control signal; SIGSTOP is refused, because the
    /// launcher cannot catch it and would stop instead of the program. Other values go
    /// unchanged; the runtime parses them with the Linux signal table.
    static func launcherSignal(forDocker signal: String?) throws -> String {
        let trimmed = (signal ?? "").trimmingCharacters(in: .whitespaces)
        var name = trimmed.uppercased()
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        // The runtime reads "09" or "+9" as 9: compare and send numbers in one form.
        if let number = Int32(name) { name = String(number) }
        switch name {
        case "", "KILL", "9": return endNow
        case "STOP", "19": throw Failure.unsupported(trimmed)
        default: return Int32(name) == nil ? trimmed : name
        }
    }

    static let apiServerService = "com.apple.container.apiserver"

    /// The `containerKill` request for one process of a container. `ClientProcess.kill` takes a
    /// host signal number and maps it through the host's table, which has no real-time signals,
    /// so the request is built here with the signal as a string.
    static func killRequest(containerID: String, processID: String, signal: String) -> XPCMessage {
        let request = XPCMessage(route: XPCRoute.containerKill.rawValue)
        request.set(key: XPCKeys.id.rawValue, value: containerID)
        request.set(key: XPCKeys.processIdentifier.rawValue, value: processID)
        request.set(key: XPCKeys.signal.rawValue, value: signal)
        return request
    }

    static func send(containerID: String, processID: String, signal: String) async throws {
        let client = XPCClient(service: apiServerService)
        _ = try await client.send(killRequest(containerID: containerID, processID: processID, signal: signal))
    }
}
