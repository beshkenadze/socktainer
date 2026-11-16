import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite(.timeLimit(.minutes(1)))
struct ContainerAttachBrokenStdinTests {
    @Test func exitedReaderDoesNotEndAttachOutputOrWait() async throws {
        let id = "broken-stdin-\(UUID().uuidString)"
        let exit = SessionLatch<Int32>()
        let client = BrokenStdinContainer(id: id, exit: exit)
        try await withApp(configure: { _ in }) { app in
            let router = app.regexRouter(with: app.logger)
            app.setRegexRouter(router)
            router.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerAttachRoute(client: client))
            try app.register(collection: ContainerWaitRoute(client: client))
            // Only the route fixture listens here. No bridge configuration or runtime service.
            let path = "/tmp/attach-broken-\(UUID().uuidString.prefix(8)).sock"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try await withAttachTestServer(app, path: path) {
                // Resolve before the server and app shut down if any assertion throws.
                defer { exit.resolve(255) }
                let attach = try await RawSocketClient.connect(path: path, group: app.eventLoopGroup)
                do {
                    try await attach.send(RawSocketClient.upgradeRequest(path: "/containers/\(id)/attach?stream=1&stdin=1&stdout=1&stderr=0"))
                    try #require(await attach.waitUntil { String(decoding: $0.received, as: UTF8.self).hasPrefix("HTTP/1.1 101") })

                    // Stand in for /start's bootstrap: take the exact pipes parked by the attach route.
                    let pipes = try #require(await PendingAttachStart.shared.claim(containerId: id))
                    defer {
                        // The fake program owns these ends; the route owns the other ends.
                        try? pipes.stdin?.read.close()
                        try? pipes.stdout?.write.close()
                    }
                    let stdin = try #require(pipes.stdin)
                    let fd = stdin.write.fileDescriptor
                    await PendingAttachStart.shared.finish(containerId: id, result: .success(BrokenStdinProcess(id: id, exit: exit)))
                    // Fail safely if protection is removed, before triggering the broken pipe.
                    try #require(fcntl(fd, F_GETNOSIGPIPE) == 1)
                    try stdin.read.close()
                    // The client keeps sending after the program stops reading. Its output and wait
                    // are deliberately held open, so failure cannot be mistaken for normal teardown.
                    for _ in 0..<20 { try await attach.send([0x79, 0x0A]) }
                    var stdinClosed = false
                    for _ in 0..<500 {
                        if stdinHandleIsClosed(stdin.write) {
                            stdinClosed = true
                            break
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(stdinClosed, "the stdin forwarder must close its end after EPIPE")
                    #expect(!attach.isClosed, "stdin failure must leave output and wait alive")
                    try pipes.stdout?.write.write(contentsOf: Data("last output\n".utf8))
                    try pipes.stdout?.write.close()
                    try #require(await attach.waitUntil { String(decoding: $0.stream, as: UTF8.self).contains("last output\n") })
                    exit.resolve(7)
                    #expect(await attach.waitUntil { $0.isClosed })
                    try await app.testing().test(.POST, "/containers/\(id)/wait?condition=removed") { response in
                        #expect(response.status == .ok)
                        #expect(response.body.string.contains("\"StatusCode\":7"))
                    }
                    try? await attach.close()
                } catch {
                    try? await attach.close()
                    throw error
                }
            }
        }
    }

    @Test func fixtureShutsDownServerWhenBodyThrows() async throws {
        try await withApp(configure: { _ in }) { app in
            let path = "/tmp/attach-failure-\(UUID().uuidString.prefix(8)).sock"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let server = try #require(app.server as? HTTPServer)
            await #expect(throws: AttachFixtureFailure.self) {
                try await withAttachTestServer(app, path: path) { throw AttachFixtureFailure() }
            }
            #expect(server.localAddress == nil, "a failed test must stop its HTTP server")
            // Also keeps this regression safe when the error-path shutdown is removed.
            await app.server.shutdown()
        }
    }
}

private struct AttachFixtureFailure: Error {}

private func withAttachTestServer(
    _ app: Application, path: String, _ body: () async throws -> Void
) async throws {
    try await app.server.start(address: .unixDomainSocket(path: path))
    do {
        try await body()
    } catch {
        await app.server.shutdown()
        throw error
    }
    await app.server.shutdown()
}

private struct BrokenStdinProcess: ClientProcess {
    let id: String
    let exit: SessionLatch<Int32>
    func start() async throws {}
    func resize(_ size: ContainerizationOS.Terminal.Size) async throws {}
    func kill(_ signal: Int32) async throws {}
    func wait() async throws -> Int32 { await exit.wait() ?? 255 }
}

private struct BrokenStdinContainer: ClientContainerProtocol {
    let id: String
    let exit: SessionLatch<Int32>
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        let process = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [], terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(reference: "test:latest", descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        return ContainerSnapshot(configuration: ContainerConfiguration(id: self.id, image: image, process: process), status: .stopped, networks: [])
    }
    func prepareForStart(container: ContainerSnapshot) async throws {}
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait { RESTContainerWait(statusCode: Int64(await exit.wait() ?? 255)) }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}
