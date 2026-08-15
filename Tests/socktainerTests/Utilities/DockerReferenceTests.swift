import Foundation
import Testing

@testable import socktainer

/// Splitting "this cannot name an image" (400) from "nothing is named that" (404), the way moby does
/// before any store lookup: `reference.ParseAnyReference` failing is `errdefs.InvalidParameter`,
/// while a parse that succeeds and finds nothing is `ErrImageDoesNotExist`.
///
/// Collapsing the two told a client its garbage name was a perfectly good name for an image that
/// merely happens to be absent — so CI retry loops retried it, and `docker pull` of an unparseable
/// name surfaced as `500 "Something went wrong."`, which reads as "the daemon is broken".
@Suite("Docker reference validation")
struct DockerReferenceTests {
    @Test(
        "Names Docker accepts",
        arguments: [
            "alpine",
            "alpine:3.20",
            "docker.io/library/alpine:latest",
            "localhost:5000/team/app:1.2",
            "localhost:5000/team/app@sha256:0000000000000000000000000000000000000000000000000000000000000000",
            "alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000",
            // A bare hex identifier: what `docker inspect` gets after `docker ps -q`.
            "9f5f5b2b0d6a",
            "0000000000000000000000000000000000000000000000000000000000000000"
        ])
    func acceptsValidReferences(reference: String) {
        #expect(DockerReference.invalidReason(for: reference) == nil, "rejected a valid reference: \(reference)")
    }

    @Test(
        "Names Docker rejects",
        arguments: [
            // The Schemathesis finding behind issue #3.
            "Ü\u{01}·x",
            "",
            "ALPINE",  // uppercase is not a legal repository path
            "alpine:",
            "alpine::3.20",
            "alpine@sha256:short",  // digest length is part of the grammar
            "alpine@notadigest",
            "-alpine",
            "alpine:-tag"
        ])
    func rejectsMalformedReferences(reference: String) {
        #expect(DockerReference.invalidReason(for: reference) != nil, "accepted a malformed reference: \(reference)")
    }

    @Test("The rejection reason is the message Docker sends")
    func reasonMatchesDocker() {
        // moby answers "invalid reference format" — clients match on it, and it says what is wrong.
        #expect(DockerReference.invalidReason(for: "Ü\u{01}·x") == "invalid reference format")
    }

    /// Apple Container's own `Reference.parse` is unanchored, so it accepts trailing garbage; that is
    /// why the routes cannot just lean on it.
    @Test("Validation is anchored: trailing garbage does not sneak through")
    func validationIsAnchored() {
        #expect(DockerReference.invalidReason(for: "alpine:3.20 rm -rf /") != nil)
        #expect(DockerReference.invalidReason(for: "alpine\n") != nil)
        #expect(DockerReference.invalidReason(for: " alpine") != nil)
    }
}
