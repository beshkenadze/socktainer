import Foundation
import Network
import Security
import Synchronization
import Testing

@testable import socktainer

@Suite("Registry scheme selection")
struct RegistrySchemeTests {
    private final class ProbeLog: Sendable {
        private let answering: Set<String>
        private let seen = Mutex<[String]>([])

        init(answering: Set<String>) {
            self.answering = answering
        }

        var urls: [String] { seen.withLock { $0 } }

        func probe(_ url: URL) async -> Bool {
            seen.withLock { $0.append(url.absoluteString) }
            return answering.contains(url.scheme ?? "")
        }
    }

    @Test(
        "localhost and 127.0.0.0/8 are loopback registries",
        arguments: ["localhost", "localhost:5000", "LOCALHOST:5000", "127.0.0.1", "127.0.0.1:5050", "127.255.255.254:443"]
    )
    func loopbackRegistry(server: String) {
        #expect(RegistryScheme.isLoopback(server: server))
    }

    @Test(
        "other registries are not loopback registries",
        arguments: ["registry-1.docker.io", "ghcr.io", "128.0.0.1:5000", "192.168.64.1:5000", "[::1]:5000", "localhost.example.com", "127.1", ""]
    )
    func otherRegistry(server: String) {
        #expect(!RegistryScheme.isLoopback(server: server))
    }

    @Test("a registry that is not on loopback gets https and no probe")
    func remoteRegistryIsNotProbed() async {
        let log = ProbeLog(answering: ["http"])
        #expect(await RegistryScheme.scheme(forServer: "ghcr.io", probe: log.probe) == .https)
        #expect(log.urls.isEmpty)
    }

    @Test("a loopback registry that answers https gets https")
    func loopbackRegistryWithHTTPS() async {
        let log = ProbeLog(answering: ["https", "http"])
        #expect(await RegistryScheme.scheme(forServer: "localhost:5000", probe: log.probe) == .https)
        #expect(log.urls == ["https://localhost:5000/v2/"])
    }

    @Test("a loopback registry that answers only http gets http")
    func loopbackRegistryWithHTTPOnly() async {
        let log = ProbeLog(answering: ["http"])
        #expect(await RegistryScheme.scheme(forServer: "127.0.0.1:5050", probe: log.probe) == .http)
        #expect(log.urls == ["https://127.0.0.1:5050/v2/", "http://127.0.0.1:5050/v2/"])
    }

    @Test("a loopback registry that answers neither scheme gets https")
    func loopbackRegistryWithoutAnswer() async {
        let log = ProbeLog(answering: [])
        #expect(await RegistryScheme.scheme(forServer: "localhost:5000", probe: log.probe) == .https)
    }

    @Test("the registry of a reference decides the scheme")
    func referenceRegistry() async {
        let log = ProbeLog(answering: ["http"])
        #expect(await RegistryScheme.scheme(forReference: "localhost:5000/team/app:1", probe: log.probe) == .http)
        #expect(await RegistryScheme.scheme(forReference: "docker.io/library/redis:7", probe: log.probe) == .https)
        #expect(log.urls == ["https://localhost:5000/v2/", "http://localhost:5000/v2/"])
    }

    @Test("the probe tells a plain HTTP registry from an HTTPS one")
    func probeAgainstPlainHTTPServer() async throws {
        let server = try await TestServer.start(behavior: .answer)
        defer { server.stop() }
        let address = "127.0.0.1:\(server.port)"

        let httpAnswers = await RegistryScheme.answersHTTP(URL(string: "http://\(address)/v2/")!)
        let httpsAnswers = await RegistryScheme.answersHTTP(URL(string: "https://\(address)/v2/")!)
        #expect(httpAnswers)
        #expect(!httpsAnswers)
        #expect(await RegistryScheme.scheme(forServer: address) == .http)
    }

    @Test("a loopback TLS registry with an untrusted certificate keeps https")
    func probeAcceptsAnUntrustedCertificate() async throws {
        let server = try await TestServer.start(behavior: .answer, identity: Self.untrustedIdentity())
        defer { server.stop() }
        let address = "127.0.0.1:\(server.port)"

        let httpsAnswers = await RegistryScheme.answersHTTP(URL(string: "https://\(address)/v2/")!)
        #expect(httpsAnswers)
        #expect(await RegistryScheme.scheme(forServer: address) == .https)
    }

    @Test("the probe returns at the response head when the server sends no body")
    func probeReturnsAtTheResponseHead() async throws {
        let server = try await TestServer.start(behavior: .headWithoutBody)
        defer { server.stop() }

        let clock = ContinuousClock()
        let start = clock.now
        let answers = await RegistryScheme.answersHTTP(URL(string: "http://127.0.0.1:\(server.port)/v2/")!, timeout: 5)
        #expect(answers)
        #expect(clock.now - start < .seconds(2))
    }

    @Test("the probe stops at its timeout while a server sends the response head slowly")
    func probeStopsAtItsTimeout() async throws {
        let server = try await TestServer.start(behavior: .slowHead)
        defer { server.stop() }

        let clock = ContinuousClock()
        let start = clock.now
        let answers = await RegistryScheme.answersHTTP(URL(string: "http://127.0.0.1:\(server.port)/v2/")!, timeout: 1)
        #expect(!answers)
        #expect(clock.now - start < .seconds(3))
    }

    @Test("the probe stops at its timeout while a server sends only informational responses")
    func probeStopsAtItsTimeoutDuringInformationalResponses() async throws {
        let server = try await TestServer.start(behavior: .informationalOnly)
        defer { server.stop() }

        let clock = ContinuousClock()
        let start = clock.now
        let answers = await RegistryScheme.answersHTTP(URL(string: "http://127.0.0.1:\(server.port)/v2/")!, timeout: 1)
        #expect(!answers)
        #expect(clock.now - start < .seconds(3))
    }

    @Test("the probe does not use a proxy")
    func probeDoesNotUseAProxy() {
        let configuration = RegistryScheme.probeConfiguration(timeout: 5)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.timeoutIntervalForRequest == 5)
        #expect(configuration.timeoutIntervalForResource == 5)
    }

    @Test("the probe does not follow a redirect")
    func probeDoesNotFollowRedirects() async throws {
        let target = try await TestServer.start(behavior: .answer)
        defer { target.stop() }
        let server = try await TestServer.start(behavior: .redirect(to: "http://127.0.0.1:\(target.port)/elsewhere"))
        defer { server.stop() }

        let answers = await RegistryScheme.answersHTTP(URL(string: "http://127.0.0.1:\(server.port)/v2/")!)
        #expect(answers)
        #expect(server.requests == 1)
        #expect(target.requests == 0)
    }

    private static func untrustedIdentity() throws -> SecIdentity {
        let data = try #require(Data(base64Encoded: registrySchemeTestIdentity, options: .ignoreUnknownCharacters))
        let options = [kSecImportExportPassphrase: "test", kSecImportToMemoryOnly: true] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &items)
        #expect(status == errSecSuccess)
        let first = try #require((items as? [[String: Any]])?.first)
        let identity = try #require(first[kSecImportItemIdentity as String])
        return identity as! SecIdentity
    }
}

private final class TestServer: @unchecked Sendable {
    enum Behavior {
        case answer
        case headWithoutBody
        case slowHead
        case informationalOnly
        case redirect(to: String)
    }

    private let listener: NWListener
    private let received: Received
    let port: UInt16

    var requests: Int { received.count }

    private init(listener: NWListener, received: Received, port: UInt16) {
        self.listener = listener
        self.received = received
        self.port = port
    }

    static func start(behavior: Behavior, identity: SecIdentity? = nil) async throws -> TestServer {
        let parameters: NWParameters
        if let identity, let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "RegistrySchemeTests.TestServer")
        let received = Received()
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, _, _ in
                if content?.isEmpty == false {
                    received.add()
                }
                switch behavior {
                case .answer:
                    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                case .headWithoutBody:
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                case .slowHead:
                    let start = Data("HTTP/1.1 200 OK\r\nX-Slow: ".utf8)
                    connection.send(content: start, completion: .contentProcessed { _ in trickle(connection, queue: queue, chunk: Data("x".utf8), remaining: 50) })
                case .informationalOnly:
                    trickle(connection, queue: queue, chunk: Data("HTTP/1.1 103 Early Hints\r\nLink: </v2/>; rel=preload\r\n\r\n".utf8), remaining: 50)
                case .redirect(let location):
                    let response = Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                let value: Result<UInt16, Error>?
                switch state {
                case .ready:
                    value = listener.port.map { .success($0.rawValue) } ?? .failure(POSIXError(.EADDRNOTAVAIL))
                case .failed(let error):
                    value = .failure(error)
                default:
                    value = nil
                }
                guard let value, resumed.claim() else { return }
                continuation.resume(with: value)
            }
            listener.start(queue: queue)
        }
        return TestServer(listener: listener, received: received, port: port)
    }

    private static func trickle(_ connection: NWConnection, queue: DispatchQueue, chunk: Data, remaining: Int) {
        guard remaining > 0 else {
            connection.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.2) {
            connection.send(
                content: chunk,
                completion: .contentProcessed { error in
                    guard error == nil else { return }
                    trickle(connection, queue: queue, chunk: chunk, remaining: remaining - 1)
                }
            )
        }
    }

    func stop() {
        listener.cancel()
    }
}

private final class Received: Sendable {
    private let value = Mutex(0)

    var count: Int { value.withLock { $0 } }

    func add() {
        value.withLock { $0 += 1 }
    }
}

private final class Once: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
