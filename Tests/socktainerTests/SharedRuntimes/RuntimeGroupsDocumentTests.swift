import Foundation
import Testing

@testable import socktainer

@Suite struct RuntimeGroupsDocumentTests {
    private func decode(_ json: String) throws -> RuntimeGroupsDocument {
        try RuntimeGroupsDocument.decode(Data(json.utf8))
    }

    private func expectMalformed(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try decode(json)
            Issue.record("expected a malformed document", sourceLocation: sourceLocation)
        } catch let error as RuntimeGroupsDocumentError {
            guard case .malformed = error else {
                Issue.record("expected .malformed, got \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    private func group(_ fields: String) -> String {
        #"{"version":1,"groups":[{"# + fields + #"}],"rules":[]}"#
    }

    @Test func defaultDocumentIsTheFixtureByteForByte() throws {
        #expect(Data(RuntimeGroupsDocument.defaultJSON.utf8) == (try SharedRuntimeFixtures.groupsFile()))
    }

    @Test func fixtureDecodesToTheDefaults() throws {
        let document = try SharedRuntimeFixtures.defaults()
        #expect(document == RuntimeGroupsDocument.defaults)
        #expect(document.version == 1)
        #expect(
            document.groups == [
                RuntimeGroup(name: "mcp-catalog", kind: .exec, idleMinutes: 10, enabled: false),
                RuntimeGroup(name: "stdio-sessions", kind: .exec, idleMinutes: 10, enabled: false),
            ])
        #expect(
            document.rules == [
                .image(group: "mcp-catalog", pattern: "mcp/*"),
                .stdioSession(group: "stdio-sessions"),
            ])
        #expect(document.group(named: "mcp-catalog")?.isActive == false)
        #expect(document.group(named: "stdio-sessions")?.isActive == false)
    }

    @Test func unknownVersionIsReportedAsSuchEvenWithUnknownKeys() throws {
        #expect(throws: RuntimeGroupsDocumentError.unsupportedVersion(2)) {
            try decode(#"{"version":2,"groups":[],"rules":[],"newKey":true}"#)
        }
    }

    @Test func notJSONOrMissingVersionIsMalformed() {
        expectMalformed("{")
        expectMalformed("[]")
        expectMalformed(#"{"groups":[],"rules":[]}"#)
        expectMalformed(#"{"version":"1","groups":[],"rules":[]}"#)
        expectMalformed(#"{"version":1.5,"groups":[],"rules":[]}"#)
        expectMalformed(#"{"version":1.00000000000000001,"groups":[],"rules":[]}"#)
        expectMalformed(#"{"version":1.0,"groups":[],"rules":[]}"#)
        expectMalformed(group(#""name":"a","kind":"exec","idleMinutes":10.000000000000001,"enabled":true"#))
    }

    @Test func unknownKeysAreMalformed() {
        expectMalformed(#"{"version":1,"groups":[],"rules":[],"extra":0}"#)
        expectMalformed(group(#""name":"a","kind":"exec","idleMinutes":0,"enabled":true,"memory":1"#))
        expectMalformed(
            #"{"version":1,"groups":[{"name":"a","kind":"exec","idleMinutes":0,"enabled":true}],"rules":[{"group":"a","image":"x","note":""}]}"#
        )
    }

    @Test func missingTopLevelOrGroupFieldIsMalformed() {
        expectMalformed(#"{"version":1,"rules":[]}"#)
        expectMalformed(#"{"version":1,"groups":[]}"#)
        expectMalformed(group(#""name":"a","kind":"exec","idleMinutes":0"#))
    }

    @Test func groupNameMustMatchThePatternAndBeUnique() {
        expectMalformed(group(#""name":"A","kind":"exec","idleMinutes":0,"enabled":true"#))
        expectMalformed(group(#""name":"","kind":"exec","idleMinutes":0,"enabled":true"#))
        expectMalformed(group(#""name":"a_b","kind":"exec","idleMinutes":0,"enabled":true"#))
        expectMalformed(group(#""name":"\#(String(repeating: "a", count: 33))","kind":"exec","idleMinutes":0,"enabled":true"#))
        #expect(throws: Never.self) {
            try decode(group(#""name":"\#(String(repeating: "a", count: 32))","kind":"exec","idleMinutes":0,"enabled":true"#))
        }
        expectMalformed(
            #"{"version":1,"groups":[{"name":"a","kind":"exec","idleMinutes":0,"enabled":true},{"name":"a","kind":"exec","idleMinutes":5,"enabled":false}],"rules":[]}"#
        )
    }

    @Test func idleMinutesMustBeOneOfTheAllowedValues() throws {
        for minutes in [0, 5, 10, 30, 60] {
            #expect(throws: Never.self) {
                try decode(group(#""name":"a","kind":"exec","idleMinutes":\#(minutes),"enabled":true"#))
            }
        }
        expectMalformed(group(#""name":"a","kind":"exec","idleMinutes":7,"enabled":true"#))
        expectMalformed(group(#""name":"a","kind":"exec","idleMinutes":-5,"enabled":true"#))
    }

    @Test func podKindIsAcceptedButDisablesTheGroup() throws {
        let document = try decode(group(#""name":"a","kind":"pod","idleMinutes":0,"enabled":true"#))
        #expect(document.group(named: "a")?.isActive == false)
        expectMalformed(group(#""name":"a","kind":"vm","idleMinutes":0,"enabled":true"#))
    }

    @Test func ruleNeedsAKnownGroupAndExactlyOneCondition() {
        let groups = #"[{"name":"a","kind":"exec","idleMinutes":0,"enabled":true}]"#
        expectMalformed(#"{"version":1,"groups":\#(groups),"rules":[{"group":"a"}]}"#)
        expectMalformed(#"{"version":1,"groups":\#(groups),"rules":[{"group":"a","image":"x","stdioSession":true}]}"#)
        expectMalformed(#"{"version":1,"groups":\#(groups),"rules":[{"group":"b","image":"x"}]}"#)
        expectMalformed(#"{"version":1,"groups":\#(groups),"rules":[{"group":"a","stdioSession":false}]}"#)
        expectMalformed(#"{"version":1,"groups":\#(groups),"rules":[{"group":"a","image":""}]}"#)
    }
}
