import ContainerResource
import CryptoKit
import Foundation

/// Docker clients expect container IDs to be 64-character hex digests and
/// freely truncate them — `docker ps` shows only the first 12 characters,
/// even with `-q` or `--format '{{.ID}}'`, and feeds them back into
/// `inspect`/`exec`/`stop`. Apple Container identifies containers by name, so
/// socktainer carries a Docker-shaped ID of its own.
///
/// The ID is *stored* on the container as a label, minted once at create, exactly as moby mints a
/// random ID. Deriving it from the name instead — which is what this did — made the ID a function
/// of mutable state: renaming a container changed its identity, because a rename here recreates the
/// container under a new name. Every store keyed by the Docker ID then had to be migrated, and
/// clients holding the old ID had to be redirected. A stored ID rides along in the configuration
/// the recreate copies, so `docker rename` preserves it the way Docker does.
///
/// Containers created outside socktainer — by the `container` CLI, or by an older build — have no
/// label, so the derived form remains as a fallback. It includes the creation date, which preserves
/// Docker's semantics that a container recreated under the same name is a different container.
enum DockerContainerID {
    /// Label carrying the container's Docker ID. Stripped from client-visible labels by
    /// `LabelNormalization.restore`, and rejected on create so a client cannot forge an identity.
    static let idLabel = "socktainer.docker-id"

    /// A fresh Docker-shaped ID: 32 random bytes, hex-encoded, like moby's.
    static func mint() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hexId(for container: ContainerSnapshot) -> String {
        if let stored = container.configuration.labels[idLabel], isWellFormed(stored) {
            return stored
        }
        return hexId(nativeId: container.id, createdAt: AppleContainerTimestampResolver.containerCreationDate(container))
    }

    static func hexId(nativeId: String, createdAt: Date?) -> String {
        var input = nativeId
        if let createdAt {
            input += "\n\(createdAt.timeIntervalSince1970)"
        }
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Guards against a malformed stored value producing an ID no client can round-trip: anything
    /// other than 64 lowercase hex characters falls back to the derived form.
    static func isWellFormed(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    enum Resolution: Equatable {
        case match(String)
        case ambiguous([String])
        case none
    }

    /// Resolves a client-supplied reference — a native ID/name, a full hex
    /// ID, or a hex ID prefix — against `(nativeId, hexId)` entries. Mirrors
    /// the Docker daemon's behavior of rejecting prefixes that match more
    /// than one container.
    static func resolve(reference: String, entries: [(nativeId: String, hexId: String)]) -> Resolution {
        if entries.contains(where: { $0.nativeId == reference }) {
            return .match(reference)
        }
        // Only hex strings can be (truncated) Docker IDs; normalize to
        // lowercase so callers can supply uppercase or mixed-case references.
        guard !reference.isEmpty, reference.allSatisfy({ $0.isHexDigit }) else {
            return .none
        }
        let refLower = reference.lowercased()
        let matches = entries.filter { $0.hexId.hasPrefix(refLower) }.map(\.nativeId)
        switch matches.count {
        case 0: return .none
        case 1: return .match(matches[0])
        default: return .ambiguous(matches)
        }
    }
}
