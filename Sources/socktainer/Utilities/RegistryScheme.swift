import ContainerAPIClient
import ContainerizationOCI
import Foundation

/// Picks the scheme for a registry the way Docker does without daemon configuration.
///
/// Docker treats a registry on 127.0.0.0/8 as insecure: it tries HTTPS and then plain HTTP.
/// Every other registry gets HTTPS only. The HTTPS probe accepts any certificate, because it only
/// asks whether the server speaks TLS. The push or pull itself still checks the certificate. The
/// probe does not follow redirects, so it sends no request to a host that is not on loopback.
enum RegistryScheme {
    typealias Probe = @Sendable (URL) async -> Bool

    static func scheme(forReference reference: String, probe: Probe = { await answersHTTP($0) }) async -> RequestScheme {
        guard let server = try? Reference.parse(reference).resolvedDomain else {
            return .https
        }
        return await scheme(forServer: server, probe: probe)
    }

    static func scheme(forServer server: String, probe: Probe = { await answersHTTP($0) }) async -> RequestScheme {
        guard isLoopback(server: server) else {
            return .https
        }
        if let url = URL(string: "https://\(server)/v2/"), await probe(url) {
            return .https
        }
        if let url = URL(string: "http://\(server)/v2/"), await probe(url) {
            return .http
        }
        return .https
    }

    static func isLoopback(server: String) -> Bool {
        guard let host = URLComponents(string: "//\(server)")?.host?.lowercased() else {
            return false
        }
        if host == "localhost" {
            return true
        }
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else {
            return false
        }
        return UInt32(bigEndian: address.s_addr) >> 24 == 127
    }

    static func answersHTTP(_ url: URL, timeout: TimeInterval = 5) async -> Bool {
        let session = URLSession(configuration: probeConfiguration(timeout: timeout))
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.bytes(for: request, delegate: ProbeDelegate()) else {
            return false
        }
        return response is HTTPURLResponse
    }

    static func probeConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }
}

private final class ProbeDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
