import ContainerAPIClient
import ContainerizationError
import Foundation
import Vapor

/// Docker's 409 for a container create that the runtime refused because the name is in use.
///
/// The runtime refuses with `.exists` in two texts: "container already exists: <name>" for the
/// exact name, and (a runtime that reserves state directories) "container '<name>' cannot be created: on this file system
/// its name is the same as that of the existing container '<holder>'" for a name that the
/// case-insensitive data root folds onto another container's. Other `.exists` refusals (a
/// hostname or alias in use, a left-over directory) are not name conflicts and are not mapped.
enum ContainerNameConflict {
    /// The container that holds `name`, as the runtime's refusal names it; nil when `error` is not
    /// a refusal of `name` because it is in use.
    static func holder(of name: String, in error: Error) -> String? {
        guard let error = error as? ContainerizationError, error.code == .exists else {
            return nil
        }
        if error.message == "container already exists: \(name)" {
            return name
        }
        let prefix = "container '\(name)' cannot be created: on this file system its name is the same as that of the existing container '"
        guard error.message.hasPrefix(prefix), error.message.hasSuffix("'"), error.message.count > prefix.count + 1 else {
            return nil
        }
        return String(error.message.dropFirst(prefix.count).dropLast())
    }

    static func abort(name: String, holderID: String) -> Abort {
        Abort(
            .conflict,
            reason:
                "Conflict. The container name \"/\(name)\" is already in use by container \"\(holderID)\". You have to remove (or rename) that container to be able to reuse that name."
        )
    }

    /// The 409 for `error` when it is the runtime's refusal of `name`, with the holder's full
    /// Docker ID when the holder can be found (its name otherwise); nil for any other error.
    static func conflict(after error: Error, name: String, client: ClientContainerProtocol) async -> Abort? {
        guard let holder = holder(of: name, in: error) else {
            return nil
        }
        let holderID = (try? await client.getContainer(id: holder)).flatMap { $0 }.map(DockerContainerID.hexId(for:)) ?? holder
        return abort(name: name, holderID: holderID)
    }
}
