import Testing

@testable import socktainer

@Suite("Docker Engine API version build info")
struct BuildInfoApiVersionTests {
    /// The Engine API reports these as bare `major.minor`. The `v` prefix this used to require is not
    /// cosmetic: moby compares versions with `versions.Compare`, which runs `strconv.Atoi` over each
    /// dot-separated part, so a leading `v` parses as 0 and every comparison against a real daemon
    /// version silently answers "older". A client negotiating the API version would downgrade to the
    /// minimum, or refuse to talk at all.

    @Test("min API version is bare major.minor, even without Makefile env vars")
    func minApiVersionIsAlwaysValid() {
        #expect(getDockerEngineApiMinVersion().wholeMatch(of: /\d+\.\d+/) != nil)
    }

    @Test("max API version is bare major.minor, even without Makefile env vars")
    func maxApiVersionIsAlwaysValid() {
        #expect(getDockerEngineApiMaxVersion().wholeMatch(of: /\d+\.\d+/) != nil)
    }

    @Test("the build version is bare too, whatever shape the tag had")
    func buildVersionIsBare() {
        // Build constants come from `git describe`, which yields "v1.2.1"; the daemon version field
        // carries no prefix in Docker's own output.
        #expect(getBuildVersion().hasPrefix("v") == false)
    }
}
