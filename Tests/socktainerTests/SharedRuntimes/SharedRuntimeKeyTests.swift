import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor

@testable import socktainer

@Suite struct SharedRuntimeKeyTests {
    private typealias F = SharedRuntimeFixtures
    private static let secret = "s3cr3t-env-value-7f1c"

    /// Byte search: a grapheme-aware `contains` can miss a value that follows a combining mark.
    private static func leaks(_ text: String) -> Bool {
        Data(text.utf8).range(of: Data(secret.utf8)) != nil
    }

    private func process(
        image: SharedRuntimeImage = F.image(), _ edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> SharedRuntimeProcess {
        try SharedRuntimeProcess.resolve(body: F.request(edit).body, image: image.config)
    }

    private func key(
        image: SharedRuntimeImage = F.image(), _ edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> SharingKey {
        SharingKey(imageID: image.id, process: try process(image: image, edit))
    }

    private func withSecret(_ object: inout [String: Any]) {
        object["Env"] = ["API_TOKEN=\(Self.secret)", "MODE=read"]
    }

    @Test func equalRequestsGiveEqualKeys() throws {
        #expect(try key(withSecret) == key(withSecret))
        #expect(try key(withSecret).hex.count == 64)
    }

    @Test func environmentOrderDoesNotChangeTheKey() throws {
        let a = try key { $0["Env"] = ["A=1", "B=2", "C=3"] }
        let b = try key { $0["Env"] = ["C=3", "A=1", "B=2"] }
        #expect(a == b)
    }

    @Test func changingOneEnvironmentValueChangesTheKey() throws {
        #expect(try key { $0["Env"] = ["API_TOKEN=one"] } != key { $0["Env"] = ["API_TOKEN=two"] })
    }

    @Test func anotherImageIDBehindTheSameTagChangesTheKey() throws {
        let first = F.image(id: "sha256:" + String(repeating: "a", count: 64))
        let second = F.image(id: "sha256:" + String(repeating: "b", count: 64))
        #expect(try key(image: first) != key(image: second))
    }

    @Test func changingTheUserChangesTheKey() throws {
        #expect(try key { $0["User"] = "1000" } != key { $0["User"] = "1001" })
        #expect(try key { $0["User"] = "" } != key { $0["User"] = "nobody" })
    }

    @Test func overridingCmdChangesTheKeyAndTheLaunchedArguments() throws {
        let image = F.image(entrypoint: ["/server"], cmd: ["--stdio"])
        let plain = try process(image: image) { $0["Cmd"] = NSNull() }
        let overridden = try process(image: image) { $0["Cmd"] = ["--http", "--port", "1"] }
        #expect(plain.executable == "/server")
        #expect(plain.arguments == ["--stdio"])
        #expect(overridden.executable == "/server")
        #expect(overridden.arguments == ["--http", "--port", "1"])
        #expect(SharingKey(imageID: image.id, process: plain) != SharingKey(imageID: image.id, process: overridden))
    }

    @Test func argumentBoundariesArePartOfTheKey() throws {
        #expect(try key { $0["Cmd"] = ["a b"] } != key { $0["Cmd"] = ["a", "b"] })
    }

    @Test func theKeyCoversTheCommandLineNotHowItWasSplit() throws {
        #expect(
            try key {
                $0["Entrypoint"] = ["/x"]
                $0["Cmd"] = ["y"]
            }
                == key {
                    $0["Entrypoint"] = ["/x", "y"]
                    $0["Cmd"] = NSNull()
                })
    }

    @Test func workingDirectoryChangesTheKey() throws {
        #expect(try key { $0["WorkingDir"] = "/a" } != key { $0["WorkingDir"] = "/b" })
    }

    @Test func effectiveConfigurationUsesTheMergeRulesOfTheCreateRoute() throws {
        let image = F.image(entrypoint: ["/server"], cmd: ["--stdio"], env: ["PATH=/usr/bin", "MODE=image"], user: "app", workingDir: "/app")
        let resolved = try process(image: image) {
            $0["Cmd"] = NSNull()
            $0["Env"] = ["MODE=request", "EXTRA=1"]
            $0["User"] = ""
            $0["WorkingDir"] = ""
        }
        let routeEnvironment = try Parser.allEnv(imageEnvs: ["PATH=/usr/bin", "MODE=image"], envFiles: [], envs: ["MODE=request", "EXTRA=1"])
        #expect(resolved.environment == routeEnvironment.sorted())
        #expect(Set(resolved.environment) == ["PATH=/usr/bin", "MODE=request", "EXTRA=1"])
        #expect(resolved.executable == "/server")
        #expect(resolved.arguments == ["--stdio"])
        #expect(resolved.user == .raw(userString: "app"))
        #expect(resolved.workingDirectory == "/app")
    }

    @Test func noExecutableIsTheErrorOfTheCreateRoute() throws {
        #expect(throws: Abort.self) {
            try process(image: F.image(entrypoint: nil, cmd: nil)) { $0["Cmd"] = NSNull() }
        }
    }

    @Test func environmentValuesDoNotAppearInTheKeyOrInAnyText() throws {
        let image = F.image()
        let request = try F.request {
            withSecret(&$0)
            $0["Labels"] = ["containerstack.group": "mcp-catalog"]
        }
        let resolved = try SharedRuntimeProcess.resolve(body: request.body, image: image.config)
        let sharingKey = SharingKey(imageID: image.id, process: resolved)
        let decision = try SharedRuntimeDecision.decide(request: request, image: image, groups: F.mcpEnabled())
        guard case .session = decision else {
            Issue.record("expected a session, got \(decision)")
            return
        }
        var dumped = ""
        dump(decision, to: &dumped)
        let texts = [
            sharingKey.hex, sharingKey.labelValue, sharingKey.nameFragment,
            "\(decision)", String(reflecting: decision), dumped,
            "\(resolved)", String(reflecting: resolved),
        ]
        for text in texts {
            #expect(!Self.leaks(text), "\(text)")
        }
        #expect("\(resolved)".contains("API_TOKEN"))
    }

    @Test func aValueThatStartsWithACombiningMarkIsNotPrinted() throws {
        // `Parser.allEnv` drops such an entry, so only a process built directly can carry one.
        let resolved = SharedRuntimeProcess(
            executable: "/server", arguments: [], environment: ["API_TOKEN=\u{0301}\(Self.secret)"],
            workingDirectory: "/", user: .id(uid: 0, gid: 0))
        var dumped = ""
        dump(resolved, to: &dumped)
        for text in ["\(resolved)", String(reflecting: resolved), dumped] {
            #expect(!Self.leaks(text), "\(text)")
        }
        #expect(resolved.environmentNames == ["API_TOKEN"])
    }

    @Test func labelAndNameFragmentsArePrefixesOfTheKey() throws {
        let sharingKey = try key()
        #expect(sharingKey.labelValue == String(sharingKey.hex.prefix(16)))
        #expect(sharingKey.nameFragment == String(sharingKey.hex.prefix(8)))
    }
}
