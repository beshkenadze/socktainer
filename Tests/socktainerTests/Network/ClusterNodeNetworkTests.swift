import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Spec F-101: network connect and disconnect refuse a node of a Kubernetes cluster, with and
/// without `--shared-runtimes`. For other containers they stay the no-op 200.
@Suite("Cluster node guard — network connect and disconnect")
struct ClusterNodeNetworkTests {
    private typealias Fixtures = ClusterNodeFixtures

    @Test("connect and disconnect refuse a node", arguments: [false, true], ["connect", "disconnect"])
    func refusesNode(sharedRuntimes: Bool, action: String) async throws {
        let name = Fixtures.uniqueName("node-net")
        let runtime = RecordingNodeRuntime([try Fixtures.node(name)])

        try await SessionRouteHarness.withApp(sharedRuntimes: sharedRuntimes, containers: runtime) { app, _ in
            try await app.testing().test(
                .POST, "/v1.51/networks/kind/\(action)",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"Container":"\#(name)"}"#)
                },
                afterResponse: { res async in
                    #expect(res.status == .conflict)
                    #expect(Fixtures.message(res.body) == Fixtures.refusal(name))
                })
        }
    }

    @Test(
        "connect and disconnect of an ordinary, an unknown or no container answer 200", arguments: [false, true],
        ["connect", "disconnect"])
    func allowsOthers(sharedRuntimes: Bool, action: String) async throws {
        let name = Fixtures.uniqueName("plain-net")
        let runtime = RecordingNodeRuntime([try Fixtures.ordinary(name, status: .running)])

        try await SessionRouteHarness.withApp(sharedRuntimes: sharedRuntimes, containers: runtime) { app, _ in
            for body in [#"{"Container":"\#(name)"}"#, #"{"Container":"no-such-container"}"#, nil] {
                try await app.testing().test(
                    .POST, "/v1.51/networks/kind/\(action)",
                    beforeRequest: { req in
                        guard let body else { return }
                        req.headers.contentType = .json
                        req.body = ByteBuffer(string: body)
                    },
                    afterResponse: { res async in
                        #expect(res.status == .ok, "\(body ?? "no body")")
                    })
            }
        }
        #expect(await runtime.calls.isEmpty)
    }
}
