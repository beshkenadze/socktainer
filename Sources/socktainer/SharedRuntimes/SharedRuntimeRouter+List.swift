import Foundation

/// Sessions in `GET /containers/json` (F-009).
extension SharedRuntimeRouter {
    /// Filters that a session can match; with any other filter, sessions are not listed.
    static let sessionFilters: Set<String> = ["id", "name", "label", "status"]

    /// Adds the sessions to the summaries of the containers, newest first, and applies `limit`.
    static func listing(
        _ containers: [RESTContainerSummary], sessions: [SharedSession], showAll: Bool, filters: [String: [String]], limit: Int
    ) -> [RESTContainerSummary] {
        guard Set(filters.keys).isSubset(of: sessionFilters) else { return containers }
        let added = sessions.filter { matches($0, showAll: showAll, filters: filters) }.map(summary)
        var all = (containers + added).sorted { $0.Created > $1.Created }
        if limit > 0 { all = Array(all.prefix(limit)) }
        return all
    }

    static func matches(_ session: SharedSession, showAll: Bool, filters: [String: [String]]) -> Bool {
        let running = session.phase == .running
        guard showAll || running else { return false }
        let labels = labels(of: session)
        for (key, values) in filters where !values.isEmpty {
            let ok: Bool
            switch key {
            case "id": ok = values.contains { session.spec.id.hasPrefix($0) }
            case "name": ok = values.contains { session.spec.name.contains($0.hasPrefix("/") ? String($0.dropFirst()) : $0) }
            case "status": ok = values.contains(running ? "running" : "created")
            case "label":
                ok = values.allSatisfy { filter in
                    let parts = filter.split(separator: "=", maxSplits: 1).map(String.init)
                    return parts.count == 2 ? labels[parts[0]] == parts[1] : labels[parts[0]] != nil
                }
            default: ok = false
            }
            if !ok { return false }
        }
        return true
    }

    static func summary(_ session: SharedSession) -> RESTContainerSummary {
        let spec = session.spec
        let running = session.phase == .running
        return RESTContainerSummary(
            Id: spec.id, Names: ["/" + spec.name], Image: spec.imageName, ImageID: spec.imageID, ImageManifestDescriptor: nil,
            Command: ([spec.process.executable] + spec.process.arguments).joined(separator: " "),
            Created: Int64(spec.created.timeIntervalSince1970), Ports: [], SizeRw: nil, SizeRootFs: nil,
            Labels: labels(of: session), State: running ? "running" : "created",
            Status: running ? "Up \(uptime(since: session.startedAt ?? spec.created))" : "Created",
            HostConfig: ContainerHostConfig(NetworkMode: "default", Annotations: nil),
            NetworkSettings: ContainerNetworkSummary(Networks: nil), Mounts: [], Platform: "linux")
    }

    static func uptime(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds) seconds"
        case ..<3600: return "\(seconds / 60) minutes"
        default: return "\(seconds / 3600) hours"
        }
    }
}
