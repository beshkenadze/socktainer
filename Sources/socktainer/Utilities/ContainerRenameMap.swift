import Foundation

/// Keeps a renamed container reachable under the Docker ID it had before the rename.
///
/// Docker's rename changes only the name — the container ID is stable for the container's whole
/// life. Apple Container has no rename: a container *is* its id, so socktainer implements the
/// route by recreating the container under the new name, which derives a brand-new Docker ID
/// (`DockerContainerID.hexId` hashes the native id and creation date).
///
/// Clients hold the pre-rename ID and keep using it. `docker compose up` on a changed service is
/// exactly that sequence: rename the old container aside, create the replacement, then delete the
/// old one *by the ID it was inspected under*. Without this map that delete would 404 and Compose
/// would report a failed recreate.
actor ContainerRenameMap {
    static let shared = ContainerRenameMap()

    private var nativeIdsByRetiredHexId: [String: String] = [:]

    /// Records that the container formerly known as `previousNativeId`, whose Docker ID was
    /// `retiredHexId`, is now `nativeId`. Retired IDs already pointing at the previous container
    /// are repointed too, so a container renamed twice stays reachable under its original ID
    /// instead of leaving a chain to walk on every lookup.
    func record(retiredHexId: String, previousNativeId: String, nativeId: String) {
        for (hexId, target) in nativeIdsByRetiredHexId where target == previousNativeId {
            nativeIdsByRetiredHexId[hexId] = nativeId
        }
        nativeIdsByRetiredHexId[retiredHexId] = nativeId
    }

    /// The container a retired ID now refers to, if that ID belonged to a renamed container.
    ///
    /// Accepts a prefix, because Docker clients truncate: `docker ps` prints 12 characters and
    /// feeds them straight back into `rm`/`inspect`. An ambiguous prefix resolves to nothing rather
    /// than to an arbitrary one of the candidates.
    func nativeId(forRetiredHexId hexId: String) -> String? {
        if let exact = nativeIdsByRetiredHexId[hexId] { return exact }
        guard !hexId.isEmpty else { return nil }
        let matches = Set(nativeIdsByRetiredHexId.filter { $0.key.hasPrefix(hexId) }.values)
        return matches.count == 1 ? matches.first : nil
    }

    /// Drops every retired ID that pointed at `nativeId`. Called when the container is deleted:
    /// once it is gone, its old IDs must 404 like any other unknown reference.
    func forget(nativeId: String) {
        nativeIdsByRetiredHexId = nativeIdsByRetiredHexId.filter { $0.value != nativeId }
    }
}
