import Foundation

/// How one Apple Container image reference becomes the names Docker reports, and what makes an image
/// dangling. Both the image list and prune read these: prune deletes, so the two must agree on which
/// images have no name.
///
/// Apple Container stores one record per reference and names an image it has no tag for
/// `untagged@sha256:…` — the counterpart of moby's internal `moby-dangling@sha256:…`, which moby never
/// reports and treats as the definition of dangling (`isDanglingImage`, daemon/containerd).
enum ImageReferenceNames {
    /// The marker Apple Container uses for an image with no tag left.
    private static let untaggedPrefix = "untagged@"

    /// An image nothing names: moby leaves both name arrays empty for it, `docker images` renders the
    /// `<none>` row itself, and `--filter dangling=true` selects exactly these.
    static func isUnnamed(_ reference: String) -> Bool {
        reference.isEmpty || reference.hasPrefix(untaggedPrefix)
    }

    /// `alpine@sha256:…` carries a digest and no tag, so moby files it under `RepoDigests` alone.
    /// The colon that matters is the one in the last path component: `localhost:5000/app@sha256:…` is
    /// a digest reference on a registry with a port, not a tag.
    static func isDigestOnly(_ reference: String) -> Bool {
        guard let digestSeparator = reference.firstIndex(of: "@") else { return false }
        let name = reference[reference.startIndex..<digestSeparator]
        let lastComponent = name.split(separator: "/").last ?? name[...]
        return !lastComponent.contains(":")
    }

    static func repoTags(for reference: String) -> [String] {
        isUnnamed(reference) || isDigestOnly(reference) ? [] : [reference]
    }

    /// A digest-only reference is the image's sole name, so it is always reported; the legacy `digests`
    /// query flag governs only a reference that also carries a tag.
    static func repoDigests(for reference: String, includeDigests: Bool) -> [String] {
        if isUnnamed(reference) {
            return []
        }
        if isDigestOnly(reference) {
            return [reference]
        }
        return includeDigests && reference.contains("@sha256:") ? [reference] : []
    }

    /// A digest reference is a name, so an image carrying one is not dangling even with no tag.
    static func isDangling(repoTags: [String], repoDigests: [String]) -> Bool {
        repoTags.isEmpty && repoDigests.isEmpty
    }
}
