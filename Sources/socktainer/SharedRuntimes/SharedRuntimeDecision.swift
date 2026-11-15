import Foundation

/// Group selection (F-001): the `containerstack.group` label, else the rules in order.
enum SharedRuntimeSelection {
    /// The image name as the client wrote it, with no digest, no tag and no `docker.io/` prefix.
    static func imageName(_ reference: String) -> String {
        var name = reference
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") { name = String(name[..<colon]) }
        if name.hasPrefix("docker.io/") { name.removeFirst("docker.io/".count) }
        return name
    }

    /// `*` matches any run of characters except `/`; every other character matches itself.
    static func imageMatches(pattern: String, image: String) -> Bool {
        glob(Array(pattern), Array(imageName(image)))
    }

    private static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        guard let first = pattern.first else { return text.isEmpty }
        let rest = Array(pattern.dropFirst())
        if first == "*" {
            var index = 0
            while true {
                if glob(rest, Array(text[index...])) { return true }
                guard index < text.count, text[index] != "/" else { return false }
                index += 1
            }
        }
        guard let head = text.first, head == first else { return false }
        return glob(rest, Array(text.dropFirst()))
    }
}

/// What to do with a create request (F-001, F-002, F-003, F-008).
enum SharedRuntimeDecision: Equatable, Sendable {
    /// No group selected: a dedicated container, as without grouping.
    case dedicated
    /// A session in `group`; sessions share a container only when their keys are equal.
    case session(group: String, key: SharingKey, process: SharedRuntimeProcess)
    /// A rule selected `group` but the run cannot be a session: a dedicated container with
    /// the label `containerstack.group.skipped=<group>:<reason>`.
    case skipped(group: String, reason: SharedRuntimeReason)
    /// The label selected `group` but the run cannot be a session: `create` fails with 400.
    case rejected(group: String, reason: SharedRuntimeReason)

    /// Decides for a request while grouping is on. Throws the create route's 400 when the run
    /// has no executable.
    static func decide(
        request: SharedRuntimeCreateRequest, image: SharedRuntimeImage, groups: RuntimeGroupsDocument
    ) throws -> SharedRuntimeDecision {
        lazy var ineligibility = SharedRuntimeEligibility.reason(for: request, imageVolumes: image.volumes)

        func session(_ group: String) throws -> SharedRuntimeDecision {
            let process = try SharedRuntimeProcess.resolve(body: request.body, image: image.config)
            return .session(group: group, key: SharingKey(imageID: image.id, process: process), process: process)
        }

        if let label = request.body.Labels?[SharedRuntimeLabels.group] {
            if label == SharedRuntimeLabels.noGroup { return .dedicated }
            guard let group = groups.group(named: label) else { return .rejected(group: label, reason: .unknownGroup) }
            guard group.isActive else { return .rejected(group: label, reason: .disabledGroup) }
            if let reason = ineligibility { return .rejected(group: label, reason: reason) }
            return try session(label)
        }

        for rule in groups.rules where groups.group(named: rule.group)?.isActive == true {
            switch rule {
            case .image(let group, let pattern):
                guard SharedRuntimeSelection.imageMatches(pattern: pattern, image: request.body.Image) else { continue }
                if let reason = ineligibility { return .skipped(group: group, reason: reason) }
                return try session(group)
            case .stdioSession(let group):
                guard ineligibility == nil else { continue }
                return try session(group)
            }
        }
        return .dedicated
    }

    /// The value of `containerstack.group.skipped` for a skipped run.
    var skippedLabelValue: String? {
        guard case .skipped(let group, let reason) = self else { return nil }
        return "\(group):\(reason.code)"
    }

    /// The 400 message for a rejected run. It names the group and the reason only.
    var rejectionMessage: String? {
        guard case .rejected(let group, let reason) = self else { return nil }
        return "cannot run in shared runtime group \"\(group)\": \(reason.code)"
    }
}
