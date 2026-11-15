import Testing
import Vapor

@testable import socktainer

/// Pins the entrypoint, command and working-directory merge of `POST /containers/create`.
@Suite struct ContainerCreateProcessMergeTests {
    private func commandLine(
        entrypoint: [String]? = nil, cmd: [String]? = nil,
        imageEntrypoint: [String]? = ["/image-ep"], imageCmd: [String]? = ["image-cmd"]
    ) throws -> [String] {
        let resolved = try ContainerCreateRoute.resolveCommandLine(
            requestEntrypoint: entrypoint, requestCmd: cmd, imageEntrypoint: imageEntrypoint, imageCmd: imageCmd)
        return [resolved.executable] + resolved.arguments
    }

    @Test func neitherOverriddenUsesImageEntrypointAndCmd() throws {
        #expect(try commandLine() == ["/image-ep", "image-cmd"])
    }

    @Test func entrypointOverrideDropsImageCmd() throws {
        #expect(try commandLine(entrypoint: ["/req-ep", "a"]) == ["/req-ep", "a"])
    }

    @Test func cmdOverrideKeepsImageEntrypoint() throws {
        #expect(try commandLine(cmd: ["req-cmd", "b"]) == ["/image-ep", "req-cmd", "b"])
    }

    @Test func bothOverridden() throws {
        #expect(try commandLine(entrypoint: ["/req-ep"], cmd: ["req-cmd"]) == ["/req-ep", "req-cmd"])
    }

    @Test func emptyCmdFallsBackToImageCmd() throws {
        #expect(try commandLine(cmd: []) == ["/image-ep", "image-cmd"])
    }

    @Test func emptyEntrypointClearsImageEntrypointAndCmd() throws {
        #expect(try commandLine(entrypoint: [], cmd: ["req-cmd"]) == ["req-cmd"])
        #expect(throws: Abort.self) { try commandLine(entrypoint: []) }
    }

    @Test func emptyEntrypointWithEmptyCmdUsesImageCmd() throws {
        #expect(try commandLine(entrypoint: [], cmd: []) == ["image-cmd"])
    }

    @Test func imageWithoutEntrypointRunsCmd() throws {
        #expect(try commandLine(imageEntrypoint: nil) == ["image-cmd"])
    }

    @Test func noExecutableIsBadRequest() throws {
        do {
            _ = try commandLine(imageEntrypoint: nil, imageCmd: nil)
            Issue.record("expected an error")
        } catch let error as Abort {
            #expect(error.status == .badRequest)
            #expect(error.reason.hasPrefix("No executable specified for container."))
        }
        #expect(throws: Abort.self) { try commandLine(entrypoint: [""]) }
    }

    @Test func workingDirectoryFromRequest() {
        #expect(ContainerCreateRoute.resolveWorkingDirectory(requestWorkingDir: "/req", imageWorkingDir: "/img") == "/req")
    }

    @Test func workingDirectoryFromImageWhenRequestEmptyOrMissing() {
        #expect(ContainerCreateRoute.resolveWorkingDirectory(requestWorkingDir: "", imageWorkingDir: "/img") == "/img")
        #expect(ContainerCreateRoute.resolveWorkingDirectory(requestWorkingDir: nil, imageWorkingDir: "/img") == "/img")
    }

    @Test func workingDirectoryDefaultsToRoot() {
        #expect(ContainerCreateRoute.resolveWorkingDirectory(requestWorkingDir: "", imageWorkingDir: nil) == "/")
    }
}
