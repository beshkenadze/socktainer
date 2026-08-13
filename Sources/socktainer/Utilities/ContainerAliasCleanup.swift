import Foundation

/// Unregisters a container's DNS aliases (name, `socktainer.dns.names`, Compose
/// service/project) — used by the `--rm` auto-remove paths, which never receive a
/// DELETE for `ContainerDeleteRoute` to react to.
///
/// `cachedIP` nil means ownership can't be confirmed, so nothing is touched: unregistering
/// blind risks yanking a live peer's identically-named alias, worse than a stale leftover.
enum ContainerAliasCleanup {
    /// Extra DNS names a container answers on, recorded at create. socktainer's own bookkeeping,
    /// not something the client set — `LabelNormalization` keeps it out of client-visible labels,
    /// which is exactly why callers must read it from the container's *raw* configuration labels
    /// and pass it in: the label sets that reach here have been through `restore`.
    static let dnsNamesLabel = "socktainer.dns.names"

    /// The recorded names, read from a raw (unrestored) label set.
    static func dnsNames(in rawLabels: [String: String]) -> [String] {
        guard let value = rawLabels[dnsNamesLabel] else { return [] }
        return value.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    static func unregisterAllAliases(
        nativeId: String,
        dnsNames: [String],
        labels: [String: String],
        cachedIP: String?,
        dnsServer: SocktainerDNSServer
    ) {
        guard let cachedIP else { return }

        if !nativeId.isEmpty {
            dnsServer.unregisterIfOwned(hostname: nativeId, expectedIP: cachedIP)
        }
        for name in dnsNames where !name.isEmpty {
            dnsServer.unregisterIfOwned(hostname: name, expectedIP: cachedIP)
        }
        if let serviceName = labels["com.docker.compose.service"], !serviceName.isEmpty {
            dnsServer.unregisterIfOwned(hostname: serviceName, expectedIP: cachedIP)
            if let projectName = labels["com.docker.compose.project"], !projectName.isEmpty {
                dnsServer.unregisterIfOwned(hostname: "\(serviceName).\(projectName)", expectedIP: cachedIP)
            }
        }
    }
}
