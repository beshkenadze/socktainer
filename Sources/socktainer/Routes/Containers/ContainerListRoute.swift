import ContainerAPIClient
import ContainerResource
import Vapor

struct ContainerListQuery: Content {
    var all: Bool?
    var limit: Int?
    var filters: String?
}

struct ContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/json", use: ContainerListRoute.handler(client: client))
    }
}

extension ContainerListRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> [RESTContainerSummary] {
        { req in
            let query = try req.query.decode(ContainerListQuery.self)
            let limit = query.limit ?? 0
            // Docker Engine API: limit returns "this number of most recently
            // created containers, including non-running ones", so a positive
            // limit implies the all behavior.
            let showAll = (query.all ?? false) || limit > 0

            let parsedFilters = try DockerContainerFilterUtility.parseContainerFilters(filtersParam: query.filters, logger: req.logger)
            let containers = try await client.list(showAll: showAll, filters: parsedFilters)

            // Apply health filter here using the real HealthCheckManager state.
            // ClientContainerService skips the health filter to avoid a stale heuristic.
            let healthFilter = parsedFilters["health"]
            let healthManager = req.application.storage[HealthCheckManagerKey.self]
            var filteredContainers: [ContainerSnapshot] = []
            for container in containers {
                if let healthFilter, !healthFilter.isEmpty {
                    // Containers with no healthcheck configured report "none"
                    let status =
                        await healthManager?.currentHealth(for: container.id)?.Status ?? "none"
                    guard healthFilter.contains(status) else { continue }
                }
                filteredContainers.append(container)
            }

            // moby returns list responses newest-first regardless of limit.
            // Creation dates are resolved once per container here (the resolver
            // touches the filesystem) and reused for the summary's Created field.
            var decorated = filteredContainers.map {
                (container: $0, created: AppleContainerTimestampResolver.containerCreationDate($0))
            }
            decorated.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
            // A positive limit keeps only the N most recently created containers.
            if limit > 0 {
                decorated = Array(decorated.prefix(limit))
            }

            var summaries: [RESTContainerSummary] = []
            for (container, createdDate) in decorated {
                let ports = container.configuration.publishedPorts.map { port in
                    ContainerPort(
                        IP: port.hostAddress.description,
                        PrivatePort: Int(port.containerPort),
                        PublicPort: Int(port.hostPort),
                        type: port.proto.rawValue
                    )
                }

                let networkMode = container.networks.first?.network ?? "default"

                let networkSettings = Dictionary(
                    container.networks.map { attachment in
                        (attachment.network, ContainerEndpointSettings.live(attachment))
                    },
                    uniquingKeysWith: { first, _ in first }
                )

                let mounts = container.configuration.mounts.map { mount in
                    let mountType: String
                    let mountName: String?
                    let driver: String?

                    switch mount.type {
                    case .block(_, _, _):
                        mountType = "bind"
                        mountName = nil
                        driver = nil
                    case .volume(let name, _, _, _):
                        mountType = "volume"
                        mountName = name
                        driver = "local"
                    case .virtiofs:
                        mountType = "bind"
                        mountName = nil
                        driver = nil
                    case .tmpfs:
                        mountType = "tmpfs"
                        mountName = nil
                        driver = nil
                    }

                    let isReadOnly = mount.options.readonly
                    let mode = isReadOnly ? "ro" : "rw"

                    return ContainerMountPoint(
                        type: mountType,
                        name: mountName,
                        source: mount.source,
                        destination: mount.destination,
                        driver: driver,
                        mode: mode,
                        rw: !isReadOnly,
                        propagation: ""
                    )
                }

                let createdTimestamp = AppleContainerTimestampResolver.unixTimestampSeconds(createdDate)

                // Build human-readable status matching Docker's "Up X seconds/minutes/hours" format.
                // Docker reports exited containers as "Exited (<code>) <age> ago",
                // preserving the exit code and age for quick triage without inspect.
                // Reference: https://raw.githubusercontent.com/moby/moby/v28.5.2/container/state.go
                // Switch on the state Docker reports, not on the runtime's own status: a container
                // created and never started is `.stopped` to the runtime, and reading that directly
                // printed "Exited (0)" for something that has never run (issue #16).
                let mobyState = container.mobyStateString
                let baseStatus: String
                switch mobyState {
                case "running":
                    if let started = container.startedDate {
                        baseStatus = "Up \(Self.humanReadableAge(since: started))"
                    } else {
                        baseStatus = "Up"
                    }
                case "created":
                    // moby's State.String() for a container that never ran is the bare word.
                    baseStatus = "Created"
                case "exited":
                    let exitCode = await Self.exitCode(for: container)
                    // The age is measured from when the container *finished*, as moby's
                    // `State.String` reads `FinishedAt`. The snapshot only carries a start time, so
                    // using that reported a container's whole runtime: three hours of work exiting a
                    // second ago printed "Exited (7) 3 hours ago". The exit monitor stamps the finish
                    // time when it records the code; a container that exited before this daemon
                    // started has neither, and then Docker's own format degrades to no age at all.
                    if let finished = await Self.finishTime(for: container) {
                        baseStatus = "Exited (\(exitCode)) \(Self.humanReadableAge(since: finished)) ago"
                    } else {
                        baseStatus = "Exited (\(exitCode))"
                    }
                default:
                    baseStatus = mobyState.prefix(1).uppercased() + mobyState.dropFirst()
                }
                let statusStr: String
                if let health = await req.application.storage[HealthCheckManagerKey.self]?.currentHealth(
                    for: container.id)
                {
                    // Match Docker's format: "Up 2 minutes (healthy)" not "(health: healthy)"
                    statusStr = "\(baseStatus) (\(health.Status))"
                } else {
                    statusStr = baseStatus
                }

                let summary = RESTContainerSummary(
                    Id: DockerContainerID.hexId(for: container),
                    Names: ["/" + container.id],
                    Image: container.configuration.image.reference,
                    ImageID: container.configuration.image.digest,
                    ImageManifestDescriptor: nil,
                    Command: ([container.configuration.initProcess.executable] + container.configuration.initProcess.arguments).joined(separator: " "),
                    Created: createdTimestamp,
                    Ports: ports,
                    SizeRw: nil,  // there is no mechanism to retrieve this value from apple container
                    SizeRootFs: nil,  // there is no mechanism to retrieve this value from apple container
                    Labels: LabelNormalization.restore(container.configuration.labels),
                    State: mobyState,
                    Status: statusStr,
                    HostConfig: ContainerHostConfig(NetworkMode: networkMode, Annotations: nil),
                    NetworkSettings: ContainerNetworkSummary(Networks: networkSettings.isEmpty ? nil : networkSettings),
                    Mounts: mounts,
                    Platform: "linux"  // Apple containers always run linux platform
                )
                summaries.append(summary)
            }
            return summaries
        }
    }

    static func exitCode(for container: ContainerSnapshot) async -> Int32 {
        let hexId = DockerContainerID.hexId(for: container)
        let nativeCode = await ContainerExitCodeStore.shared.get(id: container.id)
        let hexCode = await ContainerExitCodeStore.shared.get(id: hexId)
        return nativeCode ?? hexCode ?? 0
    }

    /// When the container finished, if this daemon saw it happen. Probes both keys the exit monitor
    /// writes under, the same way `exitCode(for:)` does.
    static func finishTime(for container: ContainerSnapshot) async -> Date? {
        if let native = await ContainerExitCodeStore.shared.finishTime(id: container.id) {
            return native
        }
        return await ContainerExitCodeStore.shared.finishTime(id: DockerContainerID.hexId(for: container))
    }

    /// Returns a human-readable duration string matching Docker's "Up X seconds/minutes/hours" format.
    static func humanReadableAge(since date: Date) -> String {
        let elapsedSeconds = max(0, Int(-date.timeIntervalSinceNow))
        if elapsedSeconds < 1 { return "Less than a second" }
        if elapsedSeconds < 60 { return "\(elapsedSeconds) second\(elapsedSeconds == 1 ? "" : "s")" }
        let minutes = elapsedSeconds / 60
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s")"
    }
}
