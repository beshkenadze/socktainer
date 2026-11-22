import ContainerResource
import Foundation

/// Whether the bridge can show that a container has nothing that a rename would lose.
///
/// The runtime has no rename, so the bridge renames by deleting the container and creating it
/// again from its configuration. A container that has run would lose its writable file system,
/// its logs and its start history. A rename goes on only when every check below shows that the
/// container never ran; any doubt refuses.
///
/// This is a check before the delete, not part of it: a start through the native `container` CLI
/// between this check and the delete is not seen. Only a rename in the runtime closes that.
enum RenameSafety {
    /// The only file in the state directory of a container that was created and never started.
    static let createdOnlyLayout = ["runtime-configuration.json"]

    /// Nil when every check shows that `container` never ran; otherwise the first reason to doubt
    /// it. `appRoot` is the runtime's app root as the runtime reports it.
    static func reasonToRefuse(_ container: ContainerSnapshot, hasExitRecord: Bool, hasRunHistory: Bool, appRoot: URL) -> String? {
        guard container.status == .stopped else {
            return "it is \(container.status.rawValue)"
        }
        if container.startedDate != nil {
            return "it has a start time"
        }
        if hasExitRecord {
            return "the bridge has its exit record"
        }
        if hasRunHistory {
            return "the bridge has its run history"
        }
        let directory = appRoot.appendingPathComponent("containers").appendingPathComponent(container.id)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            return "its directory \(directory.path) cannot be found (\(String(cString: strerror(errno))))"
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return "\(directory.path) is not a directory"
        }
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            return "its directory \(directory.path) cannot be read (\(error))"
        }
        guard entries == createdOnlyLayout else {
            return "its directory \(directory.path) holds \(entries.isEmpty ? "nothing" : entries.joined(separator: ", ")), not only runtime-configuration.json"
        }
        var file = stat()
        guard lstat(directory.appendingPathComponent(createdOnlyLayout[0]).path, &file) == 0, file.st_mode & S_IFMT == S_IFREG else {
            return "its runtime-configuration.json is not a regular file"
        }
        return nil
    }

    static func refusal(id: String, reason: String) -> String {
        "Cannot rename container \(id): this container runtime has no rename, so a rename deletes the container and creates it again, "
            + "and a container that has run would lose its files and logs. The bridge cannot show that \(id) never ran: \(reason). "
            + "Instead, create a new container under the new name from the same image; copy data out of \(id) first with `docker cp`."
    }
}
