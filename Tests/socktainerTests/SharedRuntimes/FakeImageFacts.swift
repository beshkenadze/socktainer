import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

/// Image facts for tests: an image that is in the store, or none.
struct FakeImageFacts: SharedRuntimeImageFacts {
    var image: SharedRuntimeImage? = SharedRuntimeFixtures.image()
    var failure: Error?
    /// A test whose runs must be decided without the image.
    var mustNotBeCalled = false

    func facts(reference: String, platform: Platform) async throws -> SharedRuntimeImageFactsResult? {
        if mustNotBeCalled { Issue.record("the image was read for \(reference)") }
        if let failure { throw failure }
        return image.map { SharedRuntimeImageFactsResult(image: $0, description: SharedRuntimeManagerTests.image.description) }
    }
}
