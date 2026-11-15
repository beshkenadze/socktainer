import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import CryptoKit
import Foundation

/// The image facts that a decision needs.
struct SharedRuntimeImage: Sendable {
    /// The image ID (config digest) behind the reference the client wrote.
    let id: String
    let config: ContainerizationOCI.ImageConfig?
    /// The image's declared `VOLUME`s, as `ImageVolumeConfiguration.read` returns them.
    let volumes: [String: [String: String]]?
}

/// The effective process configuration of a run (F-003), resolved with the merge rules of the
/// create route. A session is started with exactly this configuration.
///
/// Its descriptions name the environment variables but never print their values.
struct SharedRuntimeProcess: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    /// Sorted: the merge keeps one entry per name, so the order carries no meaning.
    let environment: [String]
    let workingDirectory: String
    let user: ProcessConfiguration.User

    static func resolve(body: CreateContainerRequest, image: ContainerizationOCI.ImageConfig?) throws -> SharedRuntimeProcess {
        let commandLine = try ContainerCreateRoute.resolveCommandLine(
            requestEntrypoint: body.Entrypoint, requestCmd: body.Cmd,
            imageEntrypoint: image?.entrypoint, imageCmd: image?.cmd)
        // The create route also rewrites the environment, but only for named networks, which an
        // eligible run does not use.
        let environment = try Parser.allEnv(imageEnvs: image?.env ?? [], envFiles: [], envs: body.Env ?? [])
        return SharedRuntimeProcess(
            executable: commandLine.executable,
            arguments: commandLine.arguments,
            environment: environment.sorted(),
            workingDirectory: ContainerCreateRoute.resolveWorkingDirectory(
                requestWorkingDir: body.WorkingDir, imageWorkingDir: image?.workingDir),
            user: ContainerCreateRoute.resolveUser(requestUser: body.User, imageUser: image?.user))
    }

    var environmentNames: [String] {
        // Split on the byte: a value that starts with a combining mark joins `=` into one Character.
        environment.map { entry in
            let bytes = entry.utf8
            return String(decoding: bytes[..<(bytes.firstIndex(of: UInt8(ascii: "=")) ?? bytes.endIndex)], as: UTF8.self)
        }
    }
}

extension SharedRuntimeProcess: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "SharedRuntimeProcess(executable: \(executable), arguments: \(arguments.count), "
            + "environment: \(environmentNames), workingDirectory: \(workingDirectory), user: \(user))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "executable": executable, "arguments": arguments.count, "environment": environmentNames,
                "workingDirectory": workingDirectory, "user": user.description,
            ])
    }
}

/// SHA-256 of a canonical encoding of the image ID and the effective process configuration.
struct SharingKey: Hashable, Sendable, CustomStringConvertible {
    let hex: String

    init(imageID: String, process: SharedRuntimeProcess) {
        let user: String
        switch process.user {
        case .raw(let userString): user = "raw:\(userString)"
        case .id(let uid, let gid): user = "id:\(uid):\(gid)"
        }
        let canonical = Canonical(
            imageID: imageID, executable: process.executable, arguments: process.arguments,
            environment: process.environment, workingDirectory: process.workingDirectory, user: user)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(canonical)
        } catch {
            preconditionFailure("encoding strings cannot fail: \(error)")
        }
        hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The value of `containerstack.shared.key`.
    var labelValue: String { String(hex.prefix(16)) }
    /// The key part of a shared container name, `cs-shared-<group>-<first 8>-<suffix>`.
    var nameFragment: String { String(hex.prefix(8)) }
    var description: String { labelValue }

    private struct Canonical: Encodable {
        let imageID: String
        let executable: String
        let arguments: [String]
        let environment: [String]
        let workingDirectory: String
        let user: String
    }
}
