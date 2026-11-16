import Foundation
import Testing

@testable import socktainer

@Suite struct SharedRuntimeDecisionTests {
    private typealias F = SharedRuntimeFixtures

    private func decide(
        image: String,
        label: String? = nil,
        groups: RuntimeGroupsDocument? = nil,
        imageVolumes: [String: [String: String]]? = nil,
        _ edit: @escaping (inout [String: Any]) -> Void = { _ in }
    ) throws -> SharedRuntimeDecision {
        let request = try F.request {
            $0["Image"] = image
            if let label { $0["Labels"] = [SharedRuntimeLabels.group: label] }
            edit(&$0)
        }
        return try SharedRuntimeDecision.decide(
            request: request, image: F.image(volumes: imageVolumes), groups: groups ?? F.mcpEnabled())
    }

    private func sessionGroup(_ decision: SharedRuntimeDecision) -> String? {
        if case .session(let group, _, _) = decision { return group }
        return nil
    }

    // MARK: F-001 selection. `groups` defaults to the fixture with `mcp-catalog` turned on.

    @Test func withTheFixtureBothGroupsAreOff() throws {
        let fixture = try F.defaults()
        #expect(try decide(image: "mcp/time", groups: fixture) == .dedicated)
        #expect(try decide(image: "mcp/time", groups: fixture) { $0["Tty"] = true }.skippedLabelValue == nil)
        #expect(try decide(image: "busybox", groups: fixture) == .dedicated)
        #expect(try decide(image: "mcp/time", label: "mcp-catalog", groups: fixture) == .rejected(group: "mcp-catalog", reason: .disabledGroup))
        #expect(try decide(image: "mcp/time", label: "none", groups: fixture) == .dedicated)
    }

    @Test func ruleSelectsAMatchingImage() throws {
        #expect(sessionGroup(try decide(image: "mcp/time")) == "mcp-catalog")
    }

    @Test func noMatchingRuleMeansNoGroup() throws {
        #expect(try decide(image: "busybox:1.37-musl") == .dedicated)
    }

    @Test func labelNoneMeansNoGroupEvenWhenARuleMatches() throws {
        #expect(try decide(image: "mcp/time", label: "none") == .dedicated)
    }

    @Test func labelWinsOverAMatchingRule() throws {
        let both = try F.bothEnabled()
        #expect(sessionGroup(try decide(image: "mcp/time", label: "stdio-sessions", groups: both)) == "stdio-sessions")
        #expect(try decide(image: "mcp/time", label: "stdio-sessions") == .rejected(group: "stdio-sessions", reason: .disabledGroup))
    }

    @Test func labelSelectsAGroupWithNoMatchingRule() throws {
        #expect(sessionGroup(try decide(image: "busybox", label: "mcp-catalog")) == "mcp-catalog")
    }

    @Test func firstMatchingRuleWins() throws {
        let both = try F.bothEnabled()
        #expect(sessionGroup(try decide(image: "mcp/time", groups: both)) == "mcp-catalog")
        #expect(sessionGroup(try decide(image: "busybox", groups: both)) == "stdio-sessions")
    }

    @Test func aRuleOfADisabledGroupDoesNotMatch() throws {
        #expect(try decide(image: "busybox") == .dedicated)
        let stdioOnly = try F.enabling(mcpCatalog: false, stdioSessions: true)
        #expect(sessionGroup(try decide(image: "mcp/time", groups: stdioOnly)) == "stdio-sessions")
        #expect(try decide(image: "mcp/time", groups: stdioOnly) { $0["Tty"] = true } == .dedicated)
    }

    @Test func stdioSessionRuleMatchesOnlyEligibleRuns() throws {
        let both = try F.bothEnabled()
        #expect(try decide(image: "busybox", groups: both) { $0["Tty"] = true } == .dedicated)
    }

    @Test func imagePatternIgnoresTagDigestAndDockerHubPrefix() throws {
        for image in ["mcp/time:latest", "docker.io/mcp/time", "docker.io/mcp/time:1@sha256:abcd", "mcp/time@sha256:abcd"] {
            #expect(sessionGroup(try decide(image: image)) == "mcp-catalog", "\(image)")
        }
        for image in ["mcp/a/b", "ghcr.io/mcp/time", "localhost:5000/mcp/time", "mcp", "library/mcp/time", "xmcp/time"] {
            #expect(try decide(image: image) == .dedicated, "\(image)")
        }
    }

    @Test func imageGlob() {
        #expect(SharedRuntimeSelection.imageMatches(pattern: "mcp/*", image: "mcp/"))
        #expect(SharedRuntimeSelection.imageMatches(pattern: "*/*-mcp", image: "acme/db-mcp"))
        #expect(SharedRuntimeSelection.imageMatches(pattern: "ghcr.io/github/*", image: "ghcr.io/github/github-mcp-server:v1"))
        #expect(!SharedRuntimeSelection.imageMatches(pattern: "*", image: "mcp/time"))
        #expect(!SharedRuntimeSelection.imageMatches(pattern: "mcp/t", image: "mcp/time"))
        #expect(SharedRuntimeSelection.imageName("localhost:5000/a/b:tag") == "localhost:5000/a/b")
    }

    // MARK: F-008 decision: rule-selected runs fall back, label-selected runs are rejected

    @Test func ruleSelectedIneligibleRunFallsBackWithTheSkippedLabel() throws {
        let decision = try decide(image: "mcp/time") { $0["Tty"] = true }
        #expect(decision == .skipped(group: "mcp-catalog", reason: .tty))
        #expect(decision.skippedLabelValue == "mcp-catalog:tty")
    }

    @Test func labelSelectedIneligibleRunIsRejectedWithTheReason() throws {
        let decision = try decide(image: "mcp/time", label: "mcp-catalog") { $0["Tty"] = true }
        #expect(decision == .rejected(group: "mcp-catalog", reason: .tty))
        #expect(decision.rejectionMessage?.contains("tty") == true)
        #expect(decision.rejectionMessage?.contains("mcp-catalog") == true)
        #expect(decision.skippedLabelValue == nil)
    }

    @Test func optionReasonOnBothPaths() throws {
        let privileged = F.setHostConfig("Privileged", true)
        #expect(try decide(image: "mcp/time", privileged) == .skipped(group: "mcp-catalog", reason: .option("Privileged")))
        #expect(try decide(image: "mcp/time", privileged).skippedLabelValue == "mcp-catalog:option:Privileged")
        let rejected = try decide(image: "mcp/time", label: "mcp-catalog", privileged)
        #expect(rejected == .rejected(group: "mcp-catalog", reason: .option("Privileged")))
        #expect(rejected.rejectionMessage?.contains("option:Privileged") == true)
    }

    @Test func imageVolumeOnBothPaths() throws {
        let volumes = ["/data": [String: String]()]
        #expect(try decide(image: "mcp/time", imageVolumes: volumes) == .skipped(group: "mcp-catalog", reason: .mount))
        #expect(try decide(image: "busybox", label: "mcp-catalog", imageVolumes: volumes) == .rejected(group: "mcp-catalog", reason: .mount))
    }

    @Test func unknownGroupInALabelIsRejected() throws {
        let decision = try decide(image: "mcp/time", label: "nope")
        #expect(decision == .rejected(group: "nope", reason: .unknownGroup))
        #expect(decision.rejectionMessage?.contains("unknown-group") == true)
    }

    @Test func disabledGroupInALabelIsRejected() throws {
        let decision = try decide(image: "busybox", label: "stdio-sessions")
        #expect(decision == .rejected(group: "stdio-sessions", reason: .disabledGroup))
        #expect(decision.rejectionMessage?.contains("disabled-group") == true)
    }

    @Test func podGroupInALabelIsDisabled() throws {
        let pods = try RuntimeGroupsDocument.decode(
            Data(#"{"version":1,"groups":[{"name":"p","kind":"pod","idleMinutes":0,"enabled":true}],"rules":[]}"#.utf8))
        #expect(try decide(image: "busybox", label: "p", groups: pods) == .rejected(group: "p", reason: .disabledGroup))
    }

    @Test func sessionCarriesTheKeyAndTheEffectiveProcess() throws {
        let decision = try decide(image: "mcp/time") { $0["Cmd"] = ["--flag"] }
        guard case .session(_, let key, let process) = decision else {
            Issue.record("expected a session, got \(decision)")
            return
        }
        #expect(process.arguments == ["--flag"])
        #expect(key == SharingKey(imageID: F.image().id, process: process))
    }

    @Test func reasonCodesAreTheContract() {
        let codes: [SharedRuntimeReason: String] = [
            .noStdin: "no-stdin", .noAutoremove: "no-autoremove", .tty: "tty", .mount: "mount", .port: "port",
            .network: "network", .limits: "limits", .option("Privileged"): "option:Privileged",
            .unknownGroup: "unknown-group", .disabledGroup: "disabled-group",
        ]
        for (reason, code) in codes { #expect(reason.code == code) }
    }

    @Test func labelNamesAreTheContract() {
        #expect(SharedRuntimeLabels.group == "containerstack.group")
        #expect(SharedRuntimeLabels.noGroup == "none")
        #expect(SharedRuntimeLabels.sharedGroup == "containerstack.shared.group")
        #expect(SharedRuntimeLabels.sharedKey == "containerstack.shared.key")
        #expect(SharedRuntimeLabels.sharedSocket == "containerstack.shared.socket")
        #expect(SharedRuntimeLabels.sessionGroup == "containerstack.session.group")
        #expect(SharedRuntimeLabels.sessionContainer == "containerstack.session.container")
        #expect(SharedRuntimeLabels.groupSkipped == "containerstack.group.skipped")
    }

    // MARK: the decision before the image is read

    private static var requestEdits: [(String, (inout [String: Any]) -> Void)] {
        [
            ("eligible", { _ in }),
            ("no stdin", { $0["OpenStdin"] = false }),
            ("no autoremove", SharedRuntimeFixtures.setHostConfig("AutoRemove", false)),
            ("tty", { $0["Tty"] = true }),
            ("bind", SharedRuntimeFixtures.setHostConfig("Binds", ["/a:/b"])),
            ("port", SharedRuntimeFixtures.setHostConfig("PortBindings", ["80/tcp": [["HostPort": "8080"]]])),
            ("privileged", SharedRuntimeFixtures.setHostConfig("Privileged", true)),
        ]
    }

    @Test func aDecisionWithoutTheImageIsTheDecisionWithAnyImage() throws {
        var answered = 0
        for (name, edit) in Self.requestEdits {
            for image in ["mcp/time", "busybox"] {
                for label in [nil, "mcp-catalog", "none", "nope", "stdio-sessions"] as [String?] {
                    for groups in [try F.mcpEnabled(), try F.bothEnabled()] {
                        let request = try F.request {
                            $0["Image"] = image
                            if let label { $0["Labels"] = [SharedRuntimeLabels.group: label] }
                            edit(&$0)
                        }
                        guard let early = SharedRuntimeDecision.decideWithoutImage(request: request, groups: groups) else { continue }
                        answered += 1
                        for volumes in [nil, ["/data": [String: String]()]] as [[String: [String: String]]?] {
                            let full = try SharedRuntimeDecision.decide(request: request, image: F.image(volumes: volumes), groups: groups)
                            #expect(early == full, "\(name), \(image), \(label ?? "-")")
                        }
                    }
                }
            }
        }
        #expect(answered > 0)
    }

    @Test func aRunWithoutStdinIsDecidedWithoutTheImage() throws {
        let noStdin = try F.request {
            $0["Image"] = "mcp/time"
            $0["OpenStdin"] = false
        }
        #expect(SharedRuntimeDecision.decideWithoutImage(request: noStdin, groups: try F.bothEnabled()) == .skipped(group: "mcp-catalog", reason: .noStdin))
        let other = try F.request {
            $0["Image"] = "busybox"
            $0["OpenStdin"] = false
        }
        #expect(SharedRuntimeDecision.decideWithoutImage(request: other, groups: try F.bothEnabled()) == .dedicated)
    }

    @Test func aRunThatCanBeASessionNeedsTheImage() throws {
        let eligible = try F.request { $0["Image"] = "mcp/time" }
        #expect(SharedRuntimeDecision.decideWithoutImage(request: eligible, groups: try F.mcpEnabled()) == nil)
        // A port comes after the mount check, and the image can declare a volume.
        let port = try F.request {
            $0["Image"] = "mcp/time"
            SharedRuntimeFixtures.setHostConfig("PortBindings", ["80/tcp": [["HostPort": "8080"]]])(&$0)
        }
        #expect(SharedRuntimeDecision.decideWithoutImage(request: port, groups: try F.mcpEnabled()) == nil)
    }
}
