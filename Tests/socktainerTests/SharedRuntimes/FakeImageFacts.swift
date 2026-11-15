import ContainerResource
import ContainerizationOCI
import Foundation

@testable import socktainer

/// Image facts for tests: an image that is in the store, or none.
struct FakeImageFacts: SharedRuntimeImageFacts {
    var image: SharedRuntimeImage? = SharedRuntimeFixtures.image()
    var failure: Error?

    func facts(reference: String, platform: Platform) async throws -> SharedRuntimeImageFactsResult? {
        if let failure { throw failure }
        return image.map { SharedRuntimeImageFactsResult(image: $0, description: SharedRuntimeManagerTests.image.description) }
    }
}
