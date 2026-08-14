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

    @Test("bool-map encoding keeps every key, sorted, because moby's Args.Get ignores the booleans")
    func boolMapEncoding() throws {
        let decoded = try DockerFilterDecoder.decode(#"{"dangling": {"true": true, "false": false}}"#)
        #expect(decoded == ["dangling": ["false", "true"]])
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

    @Test("a false-valued entry keeps its key as a filter value, as moby does")
    func falseValuedEntryIsAValue() throws {
        // `Args.Get` returns the inner map's keys regardless of their bool (parse.go), so this is a
        // filter on the value "true", not an empty filter. Boolean filters like dangling read their
        // truth from that value string, so the result still means dangling=true.
        let decoded = try DockerFilterDecoder.decode(#"{"dangling": {"true": false}}"#)
        #expect(decoded["dangling"] == ["true"])
    }

    @Test("an empty bool map still registers the key, so a consumer can tell it from an absent one")
    func emptyBoolMapRegistersKey() throws {
        #expect(try DockerFilterDecoder.decode(#"{"dangling": {}}"#) == ["dangling": []])
        #expect(try DockerFilterDecoder.decode(#"{"dangling": []}"#) == ["dangling": []])
    }

    // MARK: - every parser rejects the bad shapes

    @Test(
        "each parser 400s a malformed filters parameter",
        arguments: [
            "notjson",
            "[]",
            #"{"status": 1}"#,
        ])
    func parsersRejectBadShapes(filtersParam: String) {
        #expect(throws: Abort.self) {
            try DockerNetworkFilterUtility.parseNetworkFilters(
                filtersParam: filtersParam, defaultDangling: false, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerContainerFilterUtility.parseContainerPruneFilters(filtersParam: filtersParam, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerContainerFilterUtility.parseContainerFilters(filtersParam: filtersParam, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: filtersParam, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerVolumeFilterUtility.parseVolumeFilters(filtersParam: filtersParam, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerImageFilterUtility.parseImageListFilters(filterParam: filtersParam, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerBuildFilterUtility.parseBuildPruneFilters(filtersParam: filtersParam, logger: logger)
        }
        #expect(throws: Abort.self) {
            try DockerImageFilterUtility.parseImagePruneFilters(filterParam: filtersParam, logger: logger)
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
        #expect(try DockerNetworkFilterUtility.parseNetworkFilters(
            filtersParam: #"{"dangling": "true"}"#, defaultDangling: false, logger: logger)
            == ["dangling": ["true"]])
        #expect(try DockerContainerFilterUtility.parseContainerFilters(
            filtersParam: #"{"status": "running"}"#, logger: logger)
            == ["status": ["running"]])
        #expect(try DockerVolumeFilterUtility.parseVolumeFilters(
            filtersParam: #"{"dangling": "true"}"#, logger: logger)
            == ["dangling": ["true"]])
        #expect(try DockerBuildFilterUtility.parseBuildPruneFilters(
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
