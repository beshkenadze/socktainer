import Foundation

/// Deciding whether a string can name an image the way moby does, so routes
/// can split "malformed request" (400) from "well-formed name of nothing"
/// (404).
///
/// moby v28.5.2 runs every reference through
/// `reference.ParseAnyReference` (distribution/reference v0.6.0, the version
/// its go.mod pins) inside `daemon/images/image.go`'s `GetImage`: a parse
/// failure becomes `errdefs.InvalidParameter` — a 400 "invalid reference
/// format" — while a well-formed reference that names nothing becomes
/// `ErrImageDoesNotExist` — a 404 "No such image: …". `api/server/router/image/image_routes.go`
/// relies on the same classification for push/tag/create. Collapsing both
/// into 404 tells clients (and CI retry loops) that an absent image exists
/// under a garbage name.
///
/// Apple's `ContainerizationOCI.Reference.parse` cannot make this call: its
/// path pattern is matched unanchored (`NSRegularExpression.matches` finds a
/// substring), so "Ü\u{01}·x" "parses" and the rejection surfaces much later
/// as a 500 from the runtime (observed live on /images/{name}/push).
enum DockerReference {
    /// nil when `ref` is a well-formed image reference — a (possibly
    /// domain-qualified) name with optional tag/digest, a bare digest, or a
    /// bare 64-hex image ID. Otherwise the moby-style reason it cannot be one.
    static func invalidReason(for ref: String) -> String? {
        // ParseAnyReference tries a bare 64-hex identifier first and treats
        // it as a sha256 image ID.
        if wholeMatch(identifierRegex, in: ref) { return nil }

        // Then a bare digest — but only a registered algorithm with the exact
        // encoded length parses (go-digest v1.0.0 registers sha256/sha384/
        // sha512). Anything else falls through to the named grammar, exactly
        // like ParseAnyReference does on a digest.Parse error.
        if wholeMatch(bareDigestRegex, in: ref), let colon = ref.firstIndex(of: ":"),
            isRegisteredDigest(algorithm: String(ref[..<colon]), encoded: String(ref[ref.index(after: colon)...]))
        {
            return nil
        }

        guard let match = wholeMatchCapture(referenceRegex, in: ref) else {
            // Parse() reports the friendlier error when lowercasing would
            // have made the reference valid (reference.go ErrNameContainsUppercase).
            if wholeMatch(referenceRegex, in: ref.lowercased()) {
                return "repository name must be lowercase"
            }
            return "invalid reference format"
        }

        // RepositoryNameTotalLengthMax (reference.go) bounds the name part.
        let name = String(ref[Range(match.range(at: 1), in: ref)!])
        if name.count > 255 {
            return "repository name must not exceed 255 characters"
        }

        // Parse() re-validates the digest suffix with digest.Parse, which
        // rejects unregistered algorithms and wrong hex lengths.
        if match.range(at: 3).location != NSNotFound,
            let digestRange = Range(match.range(at: 3), in: ref)
        {
            let digest = String(ref[digestRange])
            guard let colon = digest.firstIndex(of: ":"),
                isRegisteredDigest(
                    algorithm: String(digest[..<colon]),
                    encoded: String(digest[digest.index(after: colon)...]))
            else {
                return "invalid checksum digest format"
            }
        }

        return nil
    }

    // MARK: - Grammar (distribution/reference v0.6.0 regexp.go, verbatim)

    private static let alphanumeric = "[a-z0-9]+"
    private static let separator = "(?:[._]|__|[-]+)"
    private static let pathComponent = alphanumeric + "(?:" + separator + alphanumeric + ")*"
    private static let remoteName = pathComponent + "(?:/" + pathComponent + ")*"
    private static let domainNameComponent = "(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])"
    private static let ipv6Address = "\\[(?:[a-fA-F0-9:]+)\\]"
    private static let host = "(?:" + domainNameComponent + "(?:\\." + domainNameComponent + ")*|" + ipv6Address + ")"
    private static let domainAndPort = host + "(?::[0-9]+)?"
    // Go's `[\w]` is ASCII; ICU's \w is Unicode-wide, so spell it out or a
    // tag like "Ü" would slip through.
    private static let tag = "[0-9A-Za-z_][0-9A-Za-z_.-]{0,127}"
    private static let digestAlgorithm = "[A-Za-z][A-Za-z0-9]*(?:[-_+.][A-Za-z][A-Za-z0-9]*)*"
    private static let digestHex = "[0-9a-fA-F]{32,}"

    /// `ReferenceRegexp`: name, optional tag, optional digest, anchored.
    private static let referenceRegex = regex(
        "^((?:" + domainAndPort + "/)?" + remoteName + ")(?::(" + tag + "))?(?:@(" + digestAlgorithm + ":" + digestHex + "))?$")
    private static let bareDigestRegex = regex("^" + digestAlgorithm + ":" + digestHex + "$")
    private static let identifierRegex = regex("^[a-f0-9]{64}$")

    /// go-digest v1.0.0's `Algorithm.Available()` set with the exact encoded
    /// hex length each one requires.
    private static let registeredDigestLengths: [String: Int] = ["sha256": 64, "sha384": 96, "sha512": 128]

    private static func isRegisteredDigest(algorithm: String, encoded: String) -> Bool {
        guard let length = registeredDigestLengths[algorithm] else { return false }
        // go-digest validates the encoded section as lowercase hex only.
        return encoded.count == length
            && encoded.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    // MARK: - Matching

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns above are compile-time constants; a malformed one is a
        // programmer error that must crash tests, not be smuggled to clients.
        try! NSRegularExpression(pattern: pattern)
    }

    /// True only when the pattern matches the *entire* subject. Anchors alone
    /// are not enough: ICU's `$` also matches in front of a trailing newline,
    /// and "alpine%0Agarbage" must not classify as "alpine".
    private static func wholeMatch(_ regex: NSRegularExpression, in subject: String) -> Bool {
        wholeMatchCapture(regex, in: subject) != nil
    }

    private static func wholeMatchCapture(
        _ regex: NSRegularExpression, in subject: String
    ) -> NSTextCheckingResult? {
        let full = NSRange(subject.startIndex..., in: subject)
        guard let match = regex.firstMatch(in: subject, range: full), match.range == full else {
            return nil
        }
        return match
    }
}
