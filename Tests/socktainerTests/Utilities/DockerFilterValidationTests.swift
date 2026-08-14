import Logging
import Testing
import Vapor

@testable import socktainer

@Suite("Filter parameter decoding rejects shapes Docker rejects")
struct DockerFilterValidationTests {

    private let logger = Logger(label: "test")

    // MARK: - DockerFilterDecoder shapes

    @Test("array-of-strings encoding decodes to the key's values")
    func arrayEncoding() throws {
        let decoded = try DockerFilterDecoder.decode(#"{"status": ["running", "paused"]}"#)
        #expect(decoded == ["status": ["running", "paused"]])
    }

    @Test("a value-set filter keeps every key of a bool map, because moby's Args.Get ignores the bools")
    func boolMapKeepsEveryKeyForValueSets() throws {
        let decoded = try DockerFilterDecoder.decode(#"{"status": {"running": true, "exited": false}}"#)
        #expect(decoded == ["status": ["exited", "running"]])
    }

    /// `dangling` is read as one truth, not a set, so the parsers that own it declare it boolean and
    /// the decoder resolves it the way `GetBoolOrDefault` does.
    @Test("a boolean filter resolves to the single truth moby reports")
    func booleanFilterResolves() throws {
        let cases = [
            #"{"dangling": {"true": true, "false": false}}"#: "true",
            #"{"dangling": {"false": true}}"#: "false",
            #"{"dangling": {"true": true}}"#: "true",
            #"{"dangling": ["false"]}"#: "false",
            #"{"dangling": "true"}"#: "true",
        ]
        for (param, expected) in cases {
            let decoded = try DockerFilterDecoder.decode(param, booleanKeys: ["dangling"])
            #expect(decoded == ["dangling": [expected]], "param: \(param)")
        }
    }

    @Test("a boolean filter whose entries contradict is a 400, as GetBoolOrDefault errors")
    func contradictoryBooleanFilterIs400() throws {
        // `{"true": false}` is neither true nor false to moby; `["true","false"]` stores both as true.
        // Handing either on as a value set let a consumer reading the first value pick "false" and,
        // on a prune, delete every unused image instead of only the dangling ones.
        for param in [#"{"dangling": {"true": false}}"#, #"{"dangling": ["true", "false"]}"#] {
            let error = #expect(throws: Abort.self) {
                try DockerFilterDecoder.decode(param, booleanKeys: ["dangling"])
            }
            #expect(error?.status == .badRequest, "param: \(param)")
        }

        // An empty set is not a contradiction: the key stays registered so its owner can decide.
        // Image prune 400s it, matching moby; the list route treats it as matching nothing.
        #expect(try DockerFilterDecoder.decode(#"{"dangling": {}}"#, booleanKeys: ["dangling"]) == ["dangling": []])
    }

    @Test("nil and empty parameter mean no filter, not an error")
    func nilAndEmptyParameter() throws {
        #expect(try DockerFilterDecoder.decode(nil).isEmpty)
        #expect(try DockerFilterDecoder.decode("").isEmpty)
    }

    @Test(
        "malformed JSON, a top-level array, a numeric value, a non-bool map, and a mixed array are all a 400 Abort",
        arguments: [
            "notjson",
            "[]",
            #"{"status": 1}"#,
            #"{"label": {"k": "v"}}"#,
            #"{"reference": [1, 2]}"#,
        ])
    func invalidShapesAre400(filtersParam: String) {
        let error = #expect(throws: Abort.self) {
            try DockerFilterDecoder.decode(filtersParam)
        }
        #expect(error?.status == .badRequest, "filtersParam: \(filtersParam)")
    }

    @Test("an empty value set still registers the key, so a consumer can tell it from an absent one")
    func emptyValueSetRegistersKey() throws {
        #expect(try DockerFilterDecoder.decode(#"{"status": {}}"#) == ["status": []])
        #expect(try DockerFilterDecoder.decode(#"{"status": []}"#) == ["status": []])
    }

    // MARK: - every parser rejects the bad shapes

    /// Each parser gets a numeric value under a key it accepts, so the 400 has to come from the value
    /// shape. Feeding a key the parser rejects anyway would let the assertion pass on unknown-key
    /// validation even if the shape check disappeared.
    @Test("each parser 400s a malformed filters parameter", arguments: ["notjson", "[]"])
    func parsersRejectBadShapes(filtersParam: String) {
        for badValue in [filtersParam, #"{"label": 1}"#] {
            #expect(throws: Abort.self) {
                try DockerNetworkFilterUtility.parseNetworkFilters(
                    filtersParam: badValue, defaultDangling: false, logger: logger)
            }
            #expect(throws: Abort.self) {
                try DockerContainerFilterUtility.parseContainerPruneFilters(filtersParam: badValue, logger: logger)
            }
            #expect(throws: Abort.self) {
                try DockerContainerFilterUtility.parseContainerFilters(filtersParam: badValue, logger: logger)
            }
            #expect(throws: Abort.self) {
                try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: badValue, logger: logger)
            }
            #expect(throws: Abort.self) {
                try DockerVolumeFilterUtility.parseVolumeFilters(filtersParam: badValue, logger: logger)
            }
            #expect(throws: Abort.self) {
                try DockerImageFilterUtility.parseImageListFilters(filterParam: badValue, logger: logger)
            }
            #expect(throws: Abort.self) {
                try DockerBuildFilterUtility.parseBuildPruneFilters(filtersParam: badValue, logger: logger)
            }
            #expect(throws: Abort.self) {
                try DockerImageFilterUtility.parseImagePruneFilters(filterParam: badValue, logger: logger)
            }
        }
    }

    /// A prune is destructive, so decoding its filter to "no filters" is the one failure that deletes
    /// more than the client asked for. moby validates before its backend runs.
    @Test("image prune rejects a bad filter instead of pruning unfiltered")
    func imagePruneRejectsBadFilters() throws {
        for param in ["notjson", #"{"bogus": ["x"]}"#, #"{"dangling": 1}"#, #"{"dangling": {}}"#] {
            let error = #expect(throws: Abort.self) {
                try DockerImageFilterUtility.parseImagePruneFilters(filterParam: param, logger: logger)
            }
            #expect(error?.status == .badRequest, "param: \(param)")
        }

        // What the CLI actually sends still parses.
        #expect(
            try DockerImageFilterUtility.parseImagePruneFilters(
                filterParam: #"{"dangling": {"true": true}}"#, logger: logger) == ["dangling": ["true"]])
        #expect(try DockerImageFilterUtility.parseImagePruneFilters(filterParam: nil, logger: logger).isEmpty)
    }

    // MARK: - parsers keep their own behaviour

    @Test("string value is the accepted superset shape in every parser")
    func stringValueAcceptedEverywhere() throws {
        #expect(
            try DockerNetworkFilterUtility.parseNetworkFilters(
                filtersParam: #"{"dangling": "true"}"#, defaultDangling: false, logger: logger)
                == ["dangling": ["true"]])
        #expect(
            try DockerContainerFilterUtility.parseContainerFilters(
                filtersParam: #"{"status": "running"}"#, logger: logger)
                == ["status": ["running"]])
        #expect(
            try DockerVolumeFilterUtility.parseVolumeFilters(
                filtersParam: #"{"dangling": "true"}"#, logger: logger)
                == ["dangling": ["true"]])
        #expect(
            try DockerBuildFilterUtility.parseBuildPruneFilters(
                filtersParam: #"{"until": "24h"}"#, logger: logger)
                == ["until": ["24h"]])
    }

    @Test("unknown keys still throw as before")
    func unknownKeyStillThrows() {
        #expect(throws: Abort.self) {
            try DockerNetworkFilterUtility.parseNetworkFilters(
                filtersParam: #"{"bogus": ["x"]}"#, defaultDangling: false, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerContainerFilterUtility.parseContainerPruneFilters(
                filtersParam: #"{"bogus": ["x"]}"#, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerContainerFilterUtility.parseContainerFilters(
                filtersParam: #"{"bogus": ["x"]}"#, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerVolumeFilterUtility.parsePruneFilters(
                filtersParam: #"{"bogus": ["x"]}"#, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerVolumeFilterUtility.parseVolumeFilters(
                filtersParam: #"{"bogus": ["x"]}"#, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerImageFilterUtility.parseImageListFilters(
                filterParam: #"{"bogus": ["x"]}"#, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerBuildFilterUtility.parseBuildPruneFilters(
                filtersParam: #"{"bogus": ["x"]}"#, logger: logger)
        }
    }

    @Test("absent network prune filters still default to dangling only")
    func networkPruneDefaultPreserved() throws {
        let parsed = try DockerNetworkFilterUtility.parseNetworkFilters(
            filtersParam: nil, defaultDangling: true, logger: logger)
        #expect(parsed == ["dangling": ["true"]])
        let noDefault = try DockerNetworkFilterUtility.parseNetworkFilters(
            filtersParam: nil, defaultDangling: false, logger: logger)
        #expect(noDefault.isEmpty)
    }
}
