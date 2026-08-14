import Foundation
import Vapor

/// Decodes the `filters` query parameter into `[key: [values]]`, rejecting
/// with a 400 the shapes whose meaning would otherwise be silently dropped:
/// malformed JSON, a non-object top level, and values that are not an array
/// of strings, a map of string->bool, or a single string.
///
/// A map's values are ignored, keeping every key: moby's `Args.Get` walks the
/// inner map's keys and never reads their booleans, so `{"status":{"exited":
/// false}}` filters on `exited` there. Dropping such a key discarded the
/// filter instead, which for a prune endpoint widens the request into an
/// unfiltered sweep. Keys are sorted so a multi-value filter is deterministic.
///
/// Two documented divergences from `filters.FromJSON`, both narrower than the
/// silent drops they replace: a bare string is accepted (moby 400s it) because
/// it is unambiguous and honoured, and a boolean filter written with a
/// contradictory bool (`{"dangling":{"true":false}}`) resolves from the value
/// string rather than 400ing the way `GetBoolOrDefault` does.
enum DockerFilterDecoder {
    /// `booleanKeys` are the keys a caller reads as a single truth rather than a set of values —
    /// `dangling` and friends. moby resolves those through `GetBoolOrDefault`, which reads the
    /// booleans stored under the `"true"`/`"1"` and `"false"`/`"0"` entries and errors when they
    /// agree, so `{"dangling":{"true":true,"false":false}}` is `true` there and
    /// `{"dangling":{"true":false}}` is a 400. Passing the raw key set on instead let a consumer that
    /// reads the first value decide from `"false"` and, on a prune, delete every unused image.
    static func decode(_ filtersParam: String?, booleanKeys: Set<String> = []) throws -> [String: [String]] {
        guard let filtersParam, !filtersParam.isEmpty, let data = filtersParam.data(using: .utf8) else {
            return [:]
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw Abort(.badRequest, reason: "invalid filter '\(filtersParam)'")
        }
        guard let filters = object as? [String: Any] else {
            throw Abort(.badRequest, reason: "invalid filter '\(filtersParam)'")
        }

        var decoded: [String: [String]] = [:]
        for (key, value) in filters {
            if let array = value as? [Any] {
                guard let strings = array as? [String] else {
                    throw Abort(.badRequest, reason: "invalid filter '\(key)'")
                }
                // The legacy array encoding stores every value as true, so moby sees the same map.
                // Its order is the client's own, so it is kept as given.
                decoded[key] = try resolve(strings.map { ($0, true) }, forKey: key, booleanKeys: booleanKeys, sorted: false)
            } else if let map = value as? [String: Any] {
                // `as? Bool` bridges any NSNumber so a JSON `1` would pass as
                // `true`; require actual JSON booleans, matching real Docker.
                guard map.values.allSatisfy({ DockerImageFilterUtility.isJSONBool($0) }) else {
                    throw Abort(.badRequest, reason: "invalid filter '\(key)'")
                }
                decoded[key] = try resolve(
                    map.map { ($0.key, $0.value as? Bool == true) }, forKey: key, booleanKeys: booleanKeys, sorted: true)
            } else if let str = value as? String {
                decoded[key] = try resolve([(str, true)], forKey: key, booleanKeys: booleanKeys, sorted: false)
            } else {
                throw Abort(.badRequest, reason: "invalid filter '\(key)'")
            }
        }
        return decoded
    }

    /// Keeps every key for a value-set filter, as `Args.Get` does, and collapses a boolean filter to
    /// the one truth `GetBoolOrDefault` would report. A map's keys are sorted because Swift's
    /// dictionary order is not stable; an array's order is the client's and is left alone.
    private static func resolve(
        _ entries: [(String, Bool)],
        forKey key: String,
        booleanKeys: Set<String>,
        sorted: Bool
    ) throws -> [String] {
        guard booleanKeys.contains(key) else {
            let values = entries.map(\.0)
            return sorted ? values.sorted() : values
        }
        guard !entries.isEmpty else { return [] }

        let isTrue = entries.contains { ($0.0 == "true" || $0.0 == "1") && $0.1 }
        let isFalse = entries.contains { ($0.0 == "false" || $0.0 == "0") && $0.1 }
        guard isTrue != isFalse else {
            throw Abort(.badRequest, reason: "invalid filter '\(key)'")
        }
        return [isTrue ? "true" : "false"]
    }
}
// utility for parsing network filters from query string
struct DockerNetworkFilterUtility {
    // parses network filters from a query string, optionally defaulting to dangling only
    // dangling networks are networks with no containers are attached to them
    static func parseNetworkFilters(filtersParam: String?, defaultDangling: Bool, logger: Logger) throws -> [String: [String]] {
        let decoded = try DockerFilterDecoder.decode(filtersParam, booleanKeys: ["dangling"])

        // Validate keys — the full set moby accepts for network list
        // (docker network ls -f): dangling, driver, id, label, name,
        // scope, type. Must stay in sync with the knownKeys handled by
        // ClientNetworkService.applyFilters.
        let allowedKeys: Set<String> = ["dangling", "driver", "id", "label", "name", "scope", "type"]
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
            throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
        }

        // An all-false bool map carries no values, so it filters nothing
        var parsedFilters = decoded.filter { !$0.value.isEmpty }
        logger.debug("Decoded filters: \(parsedFilters)")

        if filtersParam == nil, defaultDangling {
            parsedFilters["dangling"] = ["true"]
            logger.debug("No filters provided, defaulting to prune only dangling networks.")
        }
        return parsedFilters
    }
}

// utility for parsing container filters from query string
struct DockerContainerFilterUtility {
    static func parseContainerPruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["until", "label"]
        let decoded = try DockerFilterDecoder.decode(filtersParam)
        // Validate keys
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
            throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
        }
        // An all-false bool map carries no values, so it filters nothing
        let parsedFilters = decoded.filter { !$0.value.isEmpty }
        logger.debug("Decoded container prune filters: \(parsedFilters)")
        return parsedFilters
    }

    static func parseContainerFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = [
            "status",
            "exited",
            "label",
            "name",
            "id",
            "ancestor",
            "before",
            "since",
            "health",
            "volume",
            "expose",
            "health",
            "isolation",
            "is-task",
            "network",
            "publish",
            "since",
        ]
        let decoded = try DockerFilterDecoder.decode(filtersParam)
        // Validate keys
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
            throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
        }
        // An all-false bool map carries no values, so it filters nothing
        let parsedFilters = decoded.filter { !$0.value.isEmpty }
        logger.debug("Decoded filters: \(parsedFilters)")
        return parsedFilters
    }
}

// utility for parsing volume filters from query string
struct DockerVolumeFilterUtility {
    static func parsePruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        // "label!" is the key Docker CLI sends for --filter label!=key (negative match).
        let allowedKeys: Set<String> = ["label", "label!", "all"]
        let decoded = try DockerFilterDecoder.decode(filtersParam)
        // Validate keys
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
            throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
        }
        // An all-false bool map carries no values, so it filters nothing
        let parsedFilters = decoded.filter { !$0.value.isEmpty }
        logger.debug("Decoded filters: \(parsedFilters)")
        return parsedFilters
    }

    static func parseVolumeFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["name", "driver", "label", "dangling"]
        let decoded = try DockerFilterDecoder.decode(filtersParam)
        // Validate keys
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: allowedKeys) {
            logger.warning("Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
            throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(filterKeys.subtracting(allowedKeys))")
        }
        // An all-false bool map carries no values, so it filters nothing
        let parsedFilters = decoded.filter { !$0.value.isEmpty }
        logger.debug("Decoded filters: \(parsedFilters)")
        return parsedFilters
    }
}

struct DockerImageFilterUtility {
    /// Parses the `filters` query for POST /images/prune. moby's image-prune accepts dangling, label
    /// and until, and rejects anything else with a 400 before its backend runs
    /// (api/server/router/image/image_routes.go). Decoding a malformed parameter to "no filters" is
    /// the worst failure available here: a request meant to delete a narrow set becomes an
    /// unrestricted prune that reports 200.
    static func parseImagePruneFilters(filterParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["dangling", "label", "until"]
        let decoded = try DockerFilterDecoder.decode(filterParam, booleanKeys: ["dangling"])
        for key in decoded.keys where !allowedKeys.contains(key) {
            logger.warning("Invalid filter key '\(key)' for image prune")
            throw Abort(.badRequest, reason: "invalid filter '\(key)'")
        }
        // `dangling` with no values is a 400 in moby: image-prune reads it through
        // `GetBoolOrDefault`, which errors on an empty value set rather than falling back to its
        // default. An empty `label`/`until` is dropped instead, matching `MatchKVList` on an empty
        // map, which narrows nothing — the same prune scope as an absent key.
        if let dangling = decoded["dangling"], dangling.isEmpty {
            logger.warning("Filter 'dangling' carries no value")
            throw Abort(.badRequest, reason: "invalid filter 'dangling'")
        }
        logger.debug("Decoded filters: \(decoded)")
        return decoded.filter { !$0.value.isEmpty }
    }

    /// Parses the `filters` query for GET /images/json. moby's image-ls accepts
    /// before, dangling, label, reference, since, and until, and rejects any
    /// other key with a 400 (filters.Validate); decoding goes through
    /// `DockerFilterDecoder`, which 400s malformed JSON, a non-object top
    /// level, and unsupported value shapes.
    ///
    /// An absent or empty `filters` param means "no filter" (200, unfiltered).
    /// Unlike the other parsers, a key whose bool map yields no values stays
    /// registered with an empty list: real Docker treats a present-but-empty
    /// filter as "match nothing" (verified live: `{"reference":{}}` and an
    /// all-false map both return no images), not "no filter" the way an
    /// absent key does.
    static func parseImageListFilters(filterParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["before", "dangling", "label", "reference", "since", "until"]
        let decoded = try DockerFilterDecoder.decode(filterParam, booleanKeys: ["dangling"])
        for key in decoded.keys {
            guard allowedKeys.contains(key) else {
                throw Abort(.badRequest, reason: "invalid filter '\(key)'")
            }
        }
        return decoded
    }

    /// True only for an actual JSON boolean node. `JSONSerialization` bridges
    /// both JSON booleans and numbers to `NSNumber`, so plain `is Bool`/`as?
    /// Bool` casts also accept a JSON `1`/`0` as `true`/`false` — checking the
    /// underlying CoreFoundation type tells them apart.
    static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

// utility for parsing build cache filters from query string
struct DockerBuildFilterUtility {
    static func parseBuildPruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let supportedKeys: Set<String> = ["until", "id", "inuse", "parent", "type", "description", "shared", "private"]
        let decoded = try DockerFilterDecoder.decode(filtersParam)

        // Validate keys
        let filterKeys = Set(decoded.keys)
        if !filterKeys.isSubset(of: supportedKeys) {
            let invalid = filterKeys.subtracting(supportedKeys)
            logger.warning("Invalid filter key(s) found: \(invalid)")
            throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(invalid)")
        }

        // An all-false bool map carries no values, so it filters nothing
        let parsedFilters = decoded.filter { !$0.value.isEmpty }
        logger.info("Parsed build prune filters: \(parsedFilters)")
        return parsedFilters
    }

    // Parse Docker's "until" filter value and convert to Date
    static func parseUntilFilter(_ untilValue: String) -> Date? {
        let now = Date()

        // Check if it's a duration string (e.g., "24h", "1h30m", "10m")
        if let duration = parseDuration(untilValue) {
            return now.addingTimeInterval(-duration)
        }

        // Check if it's a Unix timestamp
        if let timestamp = TimeInterval(untilValue) {
            return Date(timeIntervalSince1970: timestamp)
        }

        // Try parsing as ISO8601 date
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: untilValue) {
            return date
        }

        // Try parsing as RFC3339
        let rfc3339Formatter = DateFormatter()
        rfc3339Formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        if let date = rfc3339Formatter.date(from: untilValue) {
            return date
        }

        return nil
    }

    // Parse Go-style duration strings (e.g., "24h", "1h30m", "10m")
    private static func parseDuration(_ duration: String) -> TimeInterval? {
        var remainingString = duration
        var totalSeconds: TimeInterval = 0

        let units: [(suffix: String, multiplier: TimeInterval)] = [
            ("d", 86400),
            ("h", 3600),
            ("m", 60),
            ("s", 1),
        ]

        for (suffix, multiplier) in units {
            if let range = remainingString.range(of: suffix) {
                let numberPart = String(remainingString[..<range.lowerBound])
                if let value = TimeInterval(numberPart) {
                    totalSeconds += value * multiplier
                    remainingString = String(remainingString[range.upperBound...])
                }
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }
}
