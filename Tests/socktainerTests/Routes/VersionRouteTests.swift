import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `GET /version` contract, measured against dockerd (issue #9).
///
/// - `Version` names the Docker Engine release whose API is spoken, never the API version and never
///   socktainer's own — that one is reported in `Components`. Clients gate on this field:
///   testcontainers-java refuses any daemon whose `Version` compares below 1.6.0, which socktainer's
///   0.x version can never satisfy, and "v1.51" is not a version any comparison understands.
/// - `ApiVersion` / `MinAPIVersion` are bare "major.minor": moby's examples are
///   "1.47" / "1.24", and clients compare these strings numerically — moby's
///   `api/types/versions/compare.go` runs `strconv.Atoi` on each dot-separated
///   part, so a "v1.51" prefix degrades the whole comparison to 0 and API
///   version negotiation never matches.
/// - `Os` describes where containers run, not where the daemon runs: containers
///   are Linux VMs on Apple Container whatever the host is, and clients branch
///   on this field (e.g. to pick image platform). dockerd behind Docker Desktop
///   for Mac reports "linux" for the same reason.
@Suite("VersionRoute — /version contract")
struct VersionRouteTests {

    @Test("ApiVersion and MinAPIVersion are bare major.minor, no v prefix")
    func apiVersionsAreBare() async throws {
        try await withVersionRouteApp { app in
            try await app.testing().test(.GET, "/version") { res async throws in
                #expect(res.status == .ok)
                let info = try res.content.decode(VersionInfo.self)
                // The Engine API format is bare major.minor (moby example "1.47");
                // clients' numeric comparison chokes on a "v" prefix.
                #expect(info.ApiVersion.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil)
                #expect(info.MinAPIVersion.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil)
            }
        }
    }

    @Test("Version names the emulated engine, not the API version, and clears client version floors")
    func versionIsEmulatedEngineVersion() async throws {
        try await withVersionRouteApp { app in
            try await app.testing().test(.GET, "/version") { res async throws in
                #expect(res.status == .ok)
                let info = try res.content.decode(VersionInfo.self)
                // A daemon that echoes its ApiVersion as Version makes clients believe the daemon
                // itself is at that version (issue #9).
                #expect(info.Version != info.ApiVersion)
                #expect(info.Version == emulatedDockerEngineVersion)
                // testcontainers-java's DockerClientFactory.checkDockerVersion throws below 1.6.0,
                // and Maven's ComparableVersion ranks a non-numeric leading token under every
                // number — so both "0.0.0-dev" and "v1.51" lock those clients out.
                let parts = info.Version.split(separator: ".").compactMap { Int($0) }
                #expect(parts.count >= 2)
                #expect(parts[0] > 1 || (parts[0] == 1 && parts[1] >= 6))
                // socktainer's own version stays reported, where dockerd puts its daemon component.
                #expect(info.Components.first?.Version == getBuildVersion())
            }
        }
    }

    @Test("Os reports where containers run: linux")
    func osIsLinux() async throws {
        try await withVersionRouteApp { app in
            try await app.testing().test(.GET, "/version") { res async throws in
                #expect(res.status == .ok)
                let info = try res.content.decode(VersionInfo.self)
                #expect(info.Os == "linux")
            }
        }
    }

    @Test("versioned path /v1.51/version serves the same contract")
    func versionedPathServesVersionInfo() async throws {
        try await withVersionRouteApp { app in
            try await app.testing().test(.GET, "/v1.51/version") { res async throws in
                #expect(res.status == .ok)
                let info = try res.content.decode(VersionInfo.self)
                #expect(info.ApiVersion.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil)
                #expect(info.Os == "linux")
            }
        }
    }
}

// MARK: - Helpers

private func withVersionRouteApp(
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: VersionRoute())
        try await test(app)
    }
}
