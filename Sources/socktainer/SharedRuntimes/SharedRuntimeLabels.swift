/// Label names of shared runtime groups (frozen contract).
enum SharedRuntimeLabels {
    /// On a create request: the group to run in, or `none` for no group.
    static let group = "containerstack.group"
    static let noGroup = "none"

    /// On a shared container.
    static let sharedGroup = "containerstack.shared.group"
    static let sharedKey = "containerstack.shared.key"
    static let sharedSocket = "containerstack.shared.socket"

    /// On a session.
    static let sessionGroup = "containerstack.session.group"
    static let sessionContainer = "containerstack.session.container"

    /// On a dedicated run that a rule selected for a group: `<group>:<reason>`.
    static let groupSkipped = "containerstack.group.skipped"
}

/// Why a run is not a session (frozen contract).
enum SharedRuntimeReason: Hashable, Sendable, CustomStringConvertible {
    case noStdin
    case noAutoremove
    case tty
    case mount
    case port
    case network
    case limits
    case option(String)
    case unknownGroup
    case disabledGroup

    var code: String {
        switch self {
        case .noStdin: "no-stdin"
        case .noAutoremove: "no-autoremove"
        case .tty: "tty"
        case .mount: "mount"
        case .port: "port"
        case .network: "network"
        case .limits: "limits"
        case .option(let field): "option:\(field)"
        case .unknownGroup: "unknown-group"
        case .disabledGroup: "disabled-group"
        }
    }

    var description: String { code }
}
