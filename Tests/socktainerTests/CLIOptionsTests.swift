import Testing

@testable import socktainer

@Suite("CLIOptions")
struct CLIOptionsTests {

    @Test("parses startup-housekeeping flags")
    func parsesStartupHousekeepingFlags() throws {
        let enabled = try CLIOptions.parse(["--startup-housekeeping"])
        #expect(enabled.startupHousekeeping == true)

        let disabled = try CLIOptions.parse(["--no-startup-housekeeping"])
        #expect(disabled.startupHousekeeping == false)
    }

    @Test("custom socket does not alter startup-housekeeping")
    func customSocketDoesNotChangeHousekeeping() throws {
        let options = try CLIOptions.parse(["--socket", "/tmp/scratch.sock"])
        #expect(options.startupHousekeeping == true)
    }
}
