import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Every route that takes an image name must decide the same way moby does: a name that cannot be a
/// reference is a 400 before any lookup, not a 404 saying the image is absent and not a 500 saying
/// the daemon broke (issue #3).
///
/// The validator has its own tests; these prove each route actually calls it, which is the part that
/// silently rots when a new route is added.
@Suite("Malformed image references are 400 at every route")
struct MalformedReferenceRouteTests {
    /// The name Schemathesis found: not UTF-8 garbage in transit, a genuinely unparseable reference.
    private static let malformed = "Ü\u{01}·x"

    private static func withImageRoutes(_ test: (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            let client = NeverCalledImageClient()
            try app.register(collection: ImageDeleteRoute(client: client))
            try app.register(collection: ImageCreateRoute(client: client))
            try app.register(collection: ImagePushRoute(client: client))
            try await test(app)
            let calls = await client.calls
            #expect(calls.isEmpty, "a malformed name reached the client: \(calls)")
        }
    }

    @Test("DELETE /images/{name}")
    func deleteRejects() async throws {
        try await Self.withImageRoutes { app in
            try await app.testing().test(.DELETE, "/v1.51/images/\(Self.malformed)") { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("invalid reference format"))
            }
        }
    }

    @Test("POST /images/create — the pull that used to answer 500")
    func createRejects() async throws {
        try await Self.withImageRoutes { app in
            try await app.testing().test(.POST, "/v1.51/images/create?fromImage=\(Self.malformed)") { res async throws in
                // Before: 500 "Something went wrong." — the malformed name reached the puller.
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("invalid reference format"))
            }
        }
    }

    @Test("POST /images/{name}/push")
    func pushRejects() async throws {
        try await Self.withImageRoutes { app in
            try await app.testing().test(.POST, "/v1.51/images/\(Self.malformed)/push") { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("invalid reference format"))
            }
        }
    }

    @Test("A well-formed name that names nothing is still a 404, not a 400")
    func validNameStillReaches404() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ImageDeleteRoute(client: NotFoundImageClient()))

            // The whole point of the split: validation must not swallow the absent-image answer.
            try await app.testing().test(.DELETE, "/v1.51/images/definitely-not-here:1.0") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }
}

/// Fails the test if a route hands it a name: every call here means validation did not run first.
private actor NeverCalledImageClient: ClientImageProtocol {
    private(set) var calls: [String] = []

    private func record(_ call: String) { calls.append(call) }

    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        record("delete(\(id))")
        return ImageDeletionResult(untagged: id, digest: "sha256:abc", deletedDigest: nil)
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        record("pull(\(image))")
        return AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        record("push(\(reference))")
        return AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        FileManager.default.temporaryDirectory
    }
    func importImage(
        tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String],
        platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        (repo, "sha256:" + String(repeating: "b", count: 64))
    }
}

/// Answers the way the runtime does for a name that parses but matches no image.
private struct NotFoundImageClient: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String) async throws -> ImageDeletionResult {
        throw Abort(.notFound, reason: "No such image: \(id)")
    }
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func push(reference: String, platform: Platform?, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (results: [ImageDeletionResult], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(tarballPath: URL, platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> [String] { [] }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        FileManager.default.temporaryDirectory
    }
    func importImage(
        tarPath: URL, repo: String?, tag: String?, message: String?, changes: [String],
        platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        (repo, "sha256:" + String(repeating: "b", count: 64))
    }
}
