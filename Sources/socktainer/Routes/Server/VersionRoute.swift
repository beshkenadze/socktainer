import Vapor

struct VersionRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/version", use: VersionRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        do {
            let apiVersion = getDockerEngineApiMaxVersion()
            let buildVersion = getBuildVersion()
            let version = VersionInfo(
                Platform: ServerPlatform(Name: "socktainer"),
                // NOTE: For the time being, we will report socktainer's version as a component
                //       https://github.com/socktainer/socktainer/pull/28#issuecomment-3318209340
                Components: [Component(Name: "socktainer", Version: buildVersion)],
                // The Engine release whose API this speaks, not the API version and not socktainer's
                // own — that one rides in `Components` above.
                //
                // moby documents this field as "the version of the daemon" (api/swagger.yaml,
                // example "27.0.1"), and clients gate on it: testcontainers-java refuses to run a
                // daemon whose Version compares below 1.6.0 (DockerClientFactory.checkDockerVersion,
                // Maven ComparableVersion). socktainer's own version is 0.x, so reporting it here
                // locks every Testcontainers user out; reporting the API version, as this did before
                // issue #9, told clients the daemon was "v1.51", which no version comparison
                // understands. Naming the emulated Engine release is the claim actually being made.
                Version: emulatedDockerEngineVersion,
                // moby api/swagger.yaml SystemVersion examples: "1.47" / "1.24" — bare
                // major.minor, no "v" prefix.
                ApiVersion: apiVersion,
                MinAPIVersion: getDockerEngineApiMinVersion(),
                GitCommit: getBuildGitCommit(),
                // Clients branch on Os to pick the platform of images they pull; containers
                // are Linux VMs on Apple Container whatever the host is, so this is "linux"
                // even though the daemon itself runs on macOS (dockerd behind Docker Desktop
                // for Mac reports "linux" the same way).
                Os: "linux",
                Arch: "arm64",
                KernelVersion: getKernel(),
                Experimental: true,
                BuildTime: getBuildTime(),
            )
            return try await version.encodeResponse(for: req)
        } catch {
            let response = Response(status: .internalServerError)
            response.headers.add(name: .contentType, value: "application/json")
            response.body = .init(string: "{\"message\": \"Failed to generate version information\"}\n")
            return response
        }
    }
}
