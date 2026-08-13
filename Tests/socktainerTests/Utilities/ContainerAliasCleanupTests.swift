import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// The recorded DNS names are socktainer's own bookkeeping, so they are stripped from the label sets
/// clients see — and every cleanup path receives labels that went through that stripping, whether
/// from `ContainerInfoCache` or from a restored fallback. Reading the names out of those sets would
/// silently unregister nothing, leaving a Compose service's aliases resolving to a container that no
/// longer exists. They have to come from the container's raw configuration labels.
@Suite("ContainerAliasCleanup")
struct ContainerAliasCleanupTests {
    private static let rawLabels = [
        ContainerAliasCleanup.dnsNamesLabel: "project-web-1,web",
        "com.docker.compose.service": "web",
        "com.docker.compose.project": "project"
    ]

    @Test("The recorded names are read from raw labels")
    func namesFromRawLabels() {
        #expect(ContainerAliasCleanup.dnsNames(in: Self.rawLabels) == ["project-web-1", "web"])
        #expect(ContainerAliasCleanup.dnsNames(in: [:]).isEmpty)
        #expect(ContainerAliasCleanup.dnsNames(in: [ContainerAliasCleanup.dnsNamesLabel: "a,,b"]) == ["a", "b"])
    }

    @Test("A restored label set no longer carries them, which is why callers must pass them in")
    func restoredLabelsDropTheNames() {
        let restored = LabelNormalization.restore(Self.rawLabels)

        #expect(ContainerAliasCleanup.dnsNames(in: restored).isEmpty)
        #expect(restored["com.docker.compose.service"] == "web", "genuine client labels survive")
    }

    @Test("Every recorded name is unregistered, plus the container name and the Compose aliases")
    func unregistersEveryAlias() {
        let dnsServer = SocktainerDNSServer()
        let address = "192.168.64.9"
        for hostname in ["project-web-1", "web", "web.project"] {
            dnsServer.register(hostname: hostname, ip: address)
        }

        ContainerAliasCleanup.unregisterAllAliases(
            nativeId: "project-web-1",
            dnsNames: ContainerAliasCleanup.dnsNames(in: Self.rawLabels),
            labels: LabelNormalization.restore(Self.rawLabels),
            cachedIP: address,
            dnsServer: dnsServer
        )

        #expect(dnsServer.listEntries().isEmpty, "leftovers keep answering for a container that is gone")
    }

    @Test("Without a confirmed IP nothing is touched, so a live peer's alias is never yanked")
    func unknownIPLeavesEverythingAlone() {
        let dnsServer = SocktainerDNSServer()
        dnsServer.register(hostname: "web", ip: "192.168.64.9")

        ContainerAliasCleanup.unregisterAllAliases(
            nativeId: "project-web-1",
            dnsNames: ["web"],
            labels: [:],
            cachedIP: nil,
            dnsServer: dnsServer
        )

        #expect(dnsServer.listEntries()["web"] == "192.168.64.9")
    }
}


/// The helper above is only correct if the routes hand it the *raw* labels. This exercises the
/// delete route end to end, so passing it a restored label set — which no longer carries the
/// recorded names — fails here instead of leaking silently in production.
@Suite("DELETE /containers/{id} unregisters recorded DNS names")
struct ContainerDeleteAliasCleanupTests {
    @Test("Compose service aliases recorded at create are unregistered on delete")
    func deleteUnregistersRecordedNames() async throws {
        let nativeId = "alias-delete-ctr"
        let address = "192.168.65.120"
        let snapshot = try makeContainerSnapshot(
            nativeId: nativeId,
            networks: [(network: "myapp_default", ip: address)],
            labels: [
                // `extra-alias` exists only here: the container name and the Compose service
                // name are unregistered by their own branches, so an assertion on those could not
                // tell whether the recorded names were read at all.
                ContainerAliasCleanup.dnsNamesLabel: "\(nativeId),extra-alias",
                "com.docker.compose.service": "web",
                "com.docker.compose.project": "myapp"
            ]
        )
        let dnsServer = SocktainerDNSServer()
        for hostname in [nativeId, "extra-alias", "web", "web.myapp"] {
            dnsServer.register(hostname: hostname, ip: address)
        }

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[SocktainerDNSServerKey.self] = dnsServer
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerDeleteRoute(client: StaticSnapshotClientMock(snapshot: snapshot)))

            try await app.testing().test(.DELETE, "/v1.51/containers/\(nativeId)") { res async in
                #expect(res.status == .noContent)
            }
        }

        #expect(
            dnsServer.listEntries()["extra-alias"] == nil,
            "a recorded alias left behind keeps resolving to a container that no longer exists"
        )
        #expect(dnsServer.listEntries()[nativeId] == nil)
        #expect(dnsServer.listEntries()["web"] == nil, "the Compose service alias goes too")
    }
}