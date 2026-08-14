import Foundation
import Testing

@testable import socktainer

/// One reference, three questions: which names Docker reports for it, and whether anything names it at
/// all. The image list answers a filter with this; `docker image prune` deletes with it.
@Suite("Image reference names")
struct ImageReferenceNamesTests {
    @Test("A tagged reference is a tag; the digests flag governs one that also carries a digest")
    func taggedReference() {
        #expect(ImageReferenceNames.repoTags(for: "docker.io/library/alpine:3.20") == ["docker.io/library/alpine:3.20"])
        #expect(ImageReferenceNames.repoDigests(for: "docker.io/library/alpine:3.20", includeDigests: true).isEmpty)

        let both = "docker.io/library/alpine:3.20@sha256:abc"
        #expect(ImageReferenceNames.repoTags(for: both) == [both])
        #expect(ImageReferenceNames.repoDigests(for: both, includeDigests: true) == [both])
        #expect(ImageReferenceNames.repoDigests(for: both, includeDigests: false).isEmpty)
    }

    @Test("A digest-only reference is a digest, not a tag, whatever the digests flag says")
    func digestOnlyReference() {
        let digested = "docker.io/library/alpine@sha256:abc"
        #expect(ImageReferenceNames.repoTags(for: digested).isEmpty)
        #expect(ImageReferenceNames.repoDigests(for: digested, includeDigests: false) == [digested])
        #expect(ImageReferenceNames.repoDigests(for: digested, includeDigests: true) == [digested])
    }

    @Test("A registry port is not a tag")
    func registryPortIsNotATag() {
        // The colon that decides is the one in the last path component. Reading the first colon put
        // `localhost:5000/team/app@sha256:…` in RepoTags and dropped its digest whenever digests=false.
        let ported = "localhost:5000/team/app@sha256:abc"
        #expect(ImageReferenceNames.isDigestOnly(ported))
        #expect(ImageReferenceNames.repoTags(for: ported).isEmpty)
        #expect(ImageReferenceNames.repoDigests(for: ported, includeDigests: false) == [ported])

        let portedAndTagged = "localhost:5000/team/app:1.2"
        #expect(ImageReferenceNames.isDigestOnly(portedAndTagged) == false)
        #expect(ImageReferenceNames.repoTags(for: portedAndTagged) == [portedAndTagged])
    }

    @Test("Apple Container's untagged marker names nothing")
    func untaggedMarkerNamesNothing() {
        for reference in ["untagged@sha256:5545c07ac9ab", ""] {
            #expect(ImageReferenceNames.isUnnamed(reference), "reference: \(reference)")
            #expect(ImageReferenceNames.repoTags(for: reference).isEmpty)
            #expect(ImageReferenceNames.repoDigests(for: reference, includeDigests: true).isEmpty)
        }
    }

    /// `docker image prune` with no filter deletes every image this calls unnamed, so a reference that
    /// still names something must not be one. It used to read any `@sha256:` as dangling, which put
    /// `alpine@sha256:…` — an image a client can still pull by that digest — on the delete list.
    @Test("A digest reference is a name, so prune cannot treat it as dangling")
    func digestReferenceIsNotDangling() {
        let digested = "docker.io/library/alpine@sha256:abc"
        #expect(ImageReferenceNames.isUnnamed(digested) == false)
        #expect(
            ImageReferenceNames.isDangling(
                repoTags: ImageReferenceNames.repoTags(for: digested),
                repoDigests: ImageReferenceNames.repoDigests(for: digested, includeDigests: false)
            ) == false)

        #expect(
            ImageReferenceNames.isDangling(
                repoTags: ImageReferenceNames.repoTags(for: "untagged@sha256:abc"),
                repoDigests: ImageReferenceNames.repoDigests(for: "untagged@sha256:abc", includeDigests: true)
            ))
    }
}
