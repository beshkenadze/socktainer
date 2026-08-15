import BuildInfo

// Get values from C functions and convert to Swift String

public func getBuildVersion() -> String {
    // Engine API version fields are bare "major.minor[.patch]" — moby's
    // /version examples ("27.0.1", "1.47") carry no "v" prefix, and clients
    // compare these strings numerically (moby api/types/versions/compare.go
    // does strconv.Atoi per dot-part, so "v1.51" degrades to 0). Build
    // constants may be tag-derived ("v1.2.1"), so normalize here.
    getBareVersion(String(cString: get_build_version()))
}

public func getBuildGitCommit() -> String {
    String(cString: get_build_git_commit())
}

public func getBuildTime() -> String {
    String(cString: get_build_time())
}

public func getDockerEngineApiMinVersion() -> String {
    getBareVersion(String(cString: get_docker_engine_api_min_version()))
}

public func getDockerEngineApiMaxVersion() -> String {
    getBareVersion(String(cString: get_docker_engine_api_max_version()))
}

private func getBareVersion(_ value: String) -> String {
    value.hasPrefix("v") ? String(value.dropFirst()) : value
}

public func getAppleContainerVersion() -> String {
    String(cString: get_apple_container_version())
}

/// The Docker Engine release whose API surface socktainer targets, reported as `Version` by
/// `GET /version`. API 1.51 is Engine 28.x; keep this in step with
/// `DOCKER_ENGINE_API_MAX_VERSION` in the Makefile whenever the API version moves.
///
/// It is a compatibility claim, not a boast of feature parity: the API *dialect* is 28.x, while what
/// is implemented behind it is socktainer's own version, reported in `Components`.
public let emulatedDockerEngineVersion = "28.5.2"
