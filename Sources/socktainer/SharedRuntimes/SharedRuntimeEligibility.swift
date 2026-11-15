import Foundation

/// A create request body, decoded both as the route decodes it and as raw JSON.
///
/// The typed model drops keys it does not declare; the raw form lets the eligibility allowlist
/// see them.
struct SharedRuntimeCreateRequest: Sendable {
    let body: CreateContainerRequest
    let raw: [String: SharedRuntimeJSON]

    init(data: Data) throws {
        body = try JSONDecoder().decode(CreateContainerRequest.self, from: data)
        guard let raw = try SharedRuntimeJSON.parse(data).objectValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "create body is not a JSON object"))
        }
        self.raw = raw
    }
}

/// Whether a run can be a session (F-002). An allowlist: each field outside the conditions
/// below and the fields of the sharing key must be at its default, where a missing, null and
/// empty value are the same default.
enum SharedRuntimeEligibility {
    /// Fields that can have any value: the sharing key fields and a few that do not matter.
    static let anyValueKeys: Set<String> = [
        "Image", "Entrypoint", "Cmd", "Env", "User", "WorkingDir", "Labels", "AttachStderr", "StdinOnce",
    ]
    static let mountKeys: Set<String> = ["Binds", "Mounts", "VolumesFrom", "Tmpfs"]
    static let portKeys: Set<String> = ["PortBindings", "PublishAllPorts"]
    static let limitKeys: Set<String> = [
        "Memory", "MemorySwap", "MemoryReservation", "MemorySwappiness", "KernelMemory",
        "NanoCpus", "CpuShares", "CpuPeriod", "CpuQuota", "CpuRealtimePeriod", "CpuRealtimeRuntime",
        "CpusetCpus", "CpusetMems", "CpuCount", "CpuPercent",
    ]
    static let defaultNetworkNames: Set<String> = ["", "default", "bridge"]
    private static let endpointKeys: Set<String> = ["EndpointsConfig", "Networks"]

    /// The keys that the request types declare; a key outside them is at its default only when
    /// its value is null, false, 0, "", [] or {}.
    static let requestKeys = declaredKeys(of: CreateContainerRequest.self, decodedFrom: #"{"Image":""}"#)
    static let hostConfigKeys = declaredKeys(of: HostConfig.self, decodedFrom: "{}")
    static let networkingConfigKeys = declaredKeys(of: ContainerNetworkSettings.self, decodedFrom: "{}")

    /// The reason from the request alone, when no image can change it. The image adds only
    /// volumes, which give `mount`; a reason that comes before `mount` in the order, or is `mount`,
    /// is final. Nil when the image must be read.
    static func finalReason(for request: SharedRuntimeCreateRequest) -> SharedRuntimeReason? {
        guard let reason = reason(for: request, imageVolumes: nil) else { return nil }
        return [.noStdin, .noAutoremove, .tty, .mount].contains(reason) ? reason : nil
    }

    /// Nil when the run is eligible, else the first reason in the order of the contract.
    static func reason(for request: SharedRuntimeCreateRequest, imageVolumes: [String: [String: String]]?) -> SharedRuntimeReason? {
        let top = request.raw
        let host = top["HostConfig"]?.objectValue ?? [:]
        let networking = top["NetworkingConfig"]?.objectValue ?? [:]

        guard ["OpenStdin", "AttachStdin", "AttachStdout"].allSatisfy({ top[$0] == .bool(true) }) else { return .noStdin }
        guard host["AutoRemove"] == .bool(true) else { return .noAutoremove }
        if !isDefault(top["Tty"]) { return .tty }
        if !isDefault(top["Volumes"]) || mountKeys.contains(where: { !isDefault(host[$0]) }) || !(imageVolumes ?? [:]).isEmpty {
            return .mount
        }
        if portKeys.contains(where: { !isDefault(host[$0]) }) { return .port }
        if !isDefaultNetwork(top: top, host: host, networking: networking) { return .network }
        if limitKeys.contains(where: { !isDefaultLimit($0, host[$0]) }) { return .limits }

        let checkedTop = anyValueKeys.union(["OpenStdin", "AttachStdin", "AttachStdout", "Tty", "Volumes", "NetworkDisabled", "HostConfig", "NetworkingConfig"])
        let checkedHost = mountKeys.union(portKeys).union(limitKeys).union(["AutoRemove", "NetworkMode"])
        let sections: [(fields: [String: SharedRuntimeJSON], checked: Set<String>, declared: Set<String>)] = [
            (top, checkedTop, requestKeys),
            (host, checkedHost, hostConfigKeys),
            (networking, endpointKeys, networkingConfigKeys),
        ]
        for section in sections {
            for key in section.fields.keys.sorted() where !section.checked.contains(key) {
                let value = section.fields[key]
                let isAtDefault = section.declared.contains(key) ? isDeclaredDefault(key, value) : (value?.isEmptyDefault ?? true)
                if !isAtDefault { return .option(key) }
            }
        }
        return nil
    }

    private static func isDefault(_ value: SharedRuntimeJSON?) -> Bool {
        value?.isEmptyDefault ?? true
    }

    /// A struct value whose every field is at its default, such as `{"Type":"","Config":{}}`.
    private static func hasOnlyDefaultFields(_ value: SharedRuntimeJSON?) -> Bool {
        guard let fields = value?.objectValue else { return isDefault(value) }
        return fields.values.allSatisfy(\.isEmptyDefault)
    }

    /// The defaults that Docker clients spell as a value rather than as an empty one.
    private static func isDeclaredDefault(_ key: String, _ value: SharedRuntimeJSON?) -> Bool {
        switch key {
        case "RestartPolicy":
            guard var policy = value?.objectValue else { return isDefault(value) }
            if policy["Name"] == .string("no") { policy["Name"] = nil }
            return hasOnlyDefaultFields(.object(policy))
        case "LogConfig":
            return hasOnlyDefaultFields(value)
        case "ConsoleSize":
            guard case .array(let size) = value else { return isDefault(value) }
            return size.allSatisfy(\.isEmptyDefault)
        default:
            return isDefault(value)
        }
    }

    private static func isDefaultLimit(_ key: String, _ value: SharedRuntimeJSON?) -> Bool {
        // -1 is Docker's "unset" for swappiness; 0 is a real value.
        if key == "MemorySwappiness" { return value == nil || value == .null || value == .integer(-1) }
        return isDefault(value)
    }

    private static func isDefaultNetwork(
        top: [String: SharedRuntimeJSON], host: [String: SharedRuntimeJSON], networking: [String: SharedRuntimeJSON]
    ) -> Bool {
        guard isDefault(top["NetworkDisabled"]) else { return false }
        switch host["NetworkMode"] {
        case nil, .null: break
        case .string(let mode) where defaultNetworkNames.contains(mode): break
        default: return false
        }
        for key in endpointKeys {
            switch networking[key] {
            case nil, .null: continue
            case .object(let endpoints):
                guard endpoints.allSatisfy({ defaultNetworkNames.contains($0.key) && hasOnlyDefaultFields($0.value) }) else { return false }
            default: return false
            }
        }
        return true
    }

    private static func declaredKeys<T: Decodable>(of type: T.Type, decodedFrom json: String) -> Set<String> {
        guard let value = try? JSONDecoder().decode(T.self, from: Data(json.utf8)) else { return [] }
        return Set(Mirror(reflecting: value).children.compactMap(\.label))
    }
}
