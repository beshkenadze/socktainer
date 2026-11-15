import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

enum SharedRuntimeFixtures {
    static func resource(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil))
        return try Data(contentsOf: url)
    }

    /// `runtime-groups.v1.json`: the document of the spec, byte for byte.
    static func groupsFile() throws -> Data { try resource("runtime-groups.v1.json") }

    /// The body that Docker CLI 28.5.2 sent for `docker run -i --rm busybox:1.37-musl true`.
    static func recordedRunBody() throws -> Data { try resource("docker-cli-28.5.2-run-i-rm.json") }

    /// The recorded body with `edit` applied to its JSON object, re-encoded.
    static func body(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: recordedRunBody()) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func request(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> SharedRuntimeCreateRequest {
        try SharedRuntimeCreateRequest(data: body(edit))
    }

    static func setHostConfig(_ key: String, _ value: Any) -> (inout [String: Any]) -> Void {
        { object in
            var host = object["HostConfig"] as? [String: Any] ?? [:]
            host[key] = value
            object["HostConfig"] = host
        }
    }

    static func image(
        id: String = "sha256:" + String(repeating: "a", count: 64),
        entrypoint: [String]? = ["/server"],
        cmd: [String]? = ["--stdio"],
        env: [String]? = ["PATH=/usr/bin"],
        user: String? = nil,
        workingDir: String? = "/app",
        volumes: [String: [String: String]]? = nil
    ) -> SharedRuntimeImage {
        SharedRuntimeImage(
            id: id,
            config: ContainerizationOCI.ImageConfig(user: user, env: env, entrypoint: entrypoint, cmd: cmd, workingDir: workingDir),
            volumes: volumes)
    }

    static func defaults() throws -> RuntimeGroupsDocument { try RuntimeGroupsDocument.decode(groupsFile()) }

    /// The fixture with the given groups turned on.
    static func enabling(mcpCatalog: Bool, stdioSessions: Bool) throws -> RuntimeGroupsDocument {
        try RuntimeGroupsDocument.decode(
            Data(
                """
                {"version":1,
                 "groups":[{"name":"mcp-catalog","kind":"exec","idleMinutes":10,"enabled":\(mcpCatalog)},
                           {"name":"stdio-sessions","kind":"exec","idleMinutes":10,"enabled":\(stdioSessions)}],
                 "rules":[{"group":"mcp-catalog","image":"mcp/*"},{"group":"stdio-sessions","stdioSession":true}]}
                """.utf8))
    }

    static func mcpEnabled() throws -> RuntimeGroupsDocument { try enabling(mcpCatalog: true, stdioSessions: false) }
    static func bothEnabled() throws -> RuntimeGroupsDocument { try enabling(mcpCatalog: true, stdioSessions: true) }
}
