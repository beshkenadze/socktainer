import Testing

@testable import socktainer

private let testControlSocketPath = "/Users/test/.containerstack/docker.sock"

@Suite("DockerSocketRelay.detect")
struct DockerSocketRelayDetectionTests {

    @Test("A bind mounting the canonical docker.sock path is detected")
    func detectsCanonicalDockerSocketBind() {
        let candidates = [(source: "/var/run/docker.sock", target: "/var/run/docker.sock")]
        #expect(
            DockerSocketRelay.detect(candidates: candidates, controlSocketPath: testControlSocketPath)
                == DockerSocketRelay.Match(guestPath: "/var/run/docker.sock", sourcePath: testControlSocketPath)
        )
    }

    @Test("An arbitrary host source is still detected as long as the guest destination is canonical")
    func detectsRegardlessOfHostSource() {
        // e.g. supabase-cli binds the active docker context's own socket as the source.
        let candidates = [(source: "/Users/test/.socktainer/container.sock", target: "/var/run/docker.sock")]
        #expect(
            DockerSocketRelay.detect(candidates: candidates, controlSocketPath: testControlSocketPath)
                == DockerSocketRelay.Match(guestPath: "/var/run/docker.sock", sourcePath: testControlSocketPath)
        )
    }

    @Test("A configured control socket becomes the relay source for the canonical guest docker.sock")
    func detectsConfiguredControlSocketSource() {
        let candidates = [(source: "/Users/test/.containerstack/docker.sock", target: "/var/run/docker.sock")]
        #expect(
            DockerSocketRelay.detect(
                candidates: candidates,
                controlSocketPath: testControlSocketPath
            )
                == DockerSocketRelay.Match(
                    guestPath: "/var/run/docker.sock",
                    sourcePath: testControlSocketPath
                )
        )
    }

    @Test("A non-canonical guest destination is not detected, even with the canonical host source")
    func ignoresNonCanonicalDestination() {
        let candidates = [(source: "/var/run/docker.sock", target: "/tmp/docker.sock")]
        #expect(DockerSocketRelay.detect(candidates: candidates, controlSocketPath: testControlSocketPath) == nil)
    }

    @Test("Unrelated socket binds are not detected")
    func ignoresUnrelatedSockets() {
        let candidates = [(source: "/tmp/ssh-agent.sock", target: "/ssh-agent")]
        #expect(DockerSocketRelay.detect(candidates: candidates, controlSocketPath: testControlSocketPath) == nil)
    }

    @Test("No candidates yields no match")
    func noCandidatesNoMatch() {
        #expect(DockerSocketRelay.detect(candidates: [], controlSocketPath: testControlSocketPath) == nil)
    }

    @Test("A docker.sock bind among unrelated binds is still found")
    func findsAmongOtherBinds() {
        let candidates = [
            (source: "/host/data", target: "/data"),
            (source: "/var/run/docker.sock", target: "/var/run/docker.sock"),
        ]
        #expect(
            DockerSocketRelay.detect(candidates: candidates, controlSocketPath: testControlSocketPath)
                == DockerSocketRelay.Match(guestPath: "/var/run/docker.sock", sourcePath: testControlSocketPath)
        )
    }

    @Test("A differently-cased guest destination is not detected — the guest Linux filesystem is case-sensitive")
    func ignoresDifferentlyCasedDestination() {
        let candidates = [(source: "/var/run/docker.sock", target: "/VAR/RUN/Docker.Sock")]
        #expect(DockerSocketRelay.detect(candidates: candidates, controlSocketPath: testControlSocketPath) == nil)
    }
}

@Suite("DockerSocketRelay.bindComponents")
struct DockerSocketRelayBindComponentsTests {

    @Test("Splits a source:target bind")
    func splitsSourceAndTarget() {
        let result = DockerSocketRelay.bindComponents("/var/run/docker.sock:/var/run/docker.sock")
        #expect(result?.source == "/var/run/docker.sock")
        #expect(result?.target == "/var/run/docker.sock")
    }

    @Test("Ignores a trailing mode like :ro")
    func ignoresTrailingMode() {
        let result = DockerSocketRelay.bindComponents("/var/run/docker.sock:/var/run/docker.sock:ro")
        #expect(result?.source == "/var/run/docker.sock")
        #expect(result?.target == "/var/run/docker.sock")
    }

    @Test("Returns nil for a bind with no target")
    func nilForMissingTarget() {
        #expect(DockerSocketRelay.bindComponents("/var/run/docker.sock") == nil)
    }
}
