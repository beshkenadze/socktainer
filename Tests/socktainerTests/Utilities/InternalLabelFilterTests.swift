import Foundation
import Testing

@testable import socktainer

/// socktainer stores its own bookkeeping on containers as labels, and strips them from the labels a
/// client sees. A filter reads the *stored* labels, so without the same exclusion
/// `docker ps --filter label=socktainer.docker-id` would match every container socktainer created —
/// and the identical filter drives `prune`, which would then select containers the client never
/// labelled.
@Suite("Internal labels are invisible to filters")
struct InternalLabelFilterTests {
    private static let stored = [
        DockerContainerID.idLabel: String(repeating: "ab12", count: 16),
        LabelNormalization.mappingKey: "{\"com.example.app\":\"com.example.App\"}",
        "com.example.app": "demo"
    ]

    @Test("A key-only filter never matches an internal label")
    func keyOnlyFilterSkipsInternalLabels() {
        #expect(LabelNormalization.filterContainsKey(DockerContainerID.idLabel, in: Self.stored) == false)
        #expect(LabelNormalization.filterContainsKey(LabelNormalization.mappingKey, in: Self.stored) == false)
        #expect(LabelNormalization.filterContainsKey("com.example.app", in: Self.stored))
    }

    @Test("A key=value filter cannot read an internal label's value")
    func valueFilterSkipsInternalLabels() {
        #expect(LabelNormalization.filterValue(in: Self.stored, forKey: DockerContainerID.idLabel) == nil)
        #expect(LabelNormalization.filterValue(in: Self.stored, forKey: LabelNormalization.mappingKey) == nil)
        #expect(LabelNormalization.filterValue(in: Self.stored, forKey: "com.example.app") == "demo")
    }

    @Test("The exclusion follows key normalization, so an underscore spelling cannot slip past")
    func normalizedSpellingIsAlsoExcluded() {
        // Apple Container rejects some characters, so keys are normalized before storage; a filter
        // spelled the other way must not become a back door to the same label.
        let normalized = LabelNormalization.sanitizeKey(DockerContainerID.idLabel)
        #expect(LabelNormalization.filterContainsKey(normalized, in: Self.stored) == false)
        #expect(LabelNormalization.filterValue(in: Self.stored, forKey: normalized) == nil)
    }
}
