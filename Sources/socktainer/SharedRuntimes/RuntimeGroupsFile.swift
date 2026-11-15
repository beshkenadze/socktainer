import Foundation

/// Reads `runtime-groups.json` and reads it again when its modification time changes.
actor RuntimeGroupsFile {
    enum State: Equatable, Sendable {
        /// Grouping is on with this document (the defaults when the file is missing).
        case active(RuntimeGroupsDocument)
        /// The file does not parse or has an unknown version; grouping is off.
        case off(cause: String)

        var document: RuntimeGroupsDocument? {
            if case .active(let document) = self { return document }
            return nil
        }
    }

    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".containerstack/runtime-groups.json").path
    }

    private enum Stamp: Equatable {
        case missing
        /// The file that a symlink resolves to, and its modification time.
        case modified(String, Date)
    }

    let path: String
    private var cached: (stamp: Stamp, state: State)?

    init(path: String = RuntimeGroupsFile.defaultPath) {
        self.path = path
    }

    /// The state to use for a `create`.
    func current() -> State {
        let stamp = Self.stamp(of: path)
        if let cached, cached.stamp == stamp { return cached.state }
        let state = Self.read(path: path, stamp: stamp)
        cached = (stamp, state)
        return state
    }

    private static func stamp(of path: String) -> Stamp {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        return .modified(resolved, attributes?[.modificationDate] as? Date ?? .distantPast)
    }

    private static func read(path: String, stamp: Stamp) -> State {
        guard stamp != .missing else { return .active(.defaults) }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return .active(try RuntimeGroupsDocument.decode(data))
        } catch let error as RuntimeGroupsDocumentError {
            return .off(cause: error.description)
        } catch {
            return .off(cause: "runtime-groups.json cannot be read: \(error.localizedDescription)")
        }
    }
}
