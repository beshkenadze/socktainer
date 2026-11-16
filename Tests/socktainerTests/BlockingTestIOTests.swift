import Foundation
import Testing

@testable import socktainer

@Suite("Blocking fixture I/O")
struct BlockingTestIOTests {
    @Test("a blocked fixture leaves the cooperative pool free to release it")
    func fixtureDoesNotOccupyThePool() async throws {
        let entered = SessionLatch<Bool>()
        let release = DispatchSemaphore(value: 0)
        let worker = Task {
            try await blockingTestIO {
                entered.resolve(true)
                return release.wait(timeout: .now() + .seconds(30))
            }
        }
        let started = await entered.wait(limit: .seconds(5))
        release.signal()
        #expect(started == true)
        #expect(try await worker.value == .success)
    }
}
