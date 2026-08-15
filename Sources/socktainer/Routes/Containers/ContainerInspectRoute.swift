import ContainerAPIClient
import ContainerResource
import Containerization
import Vapor

struct ContainerInspectRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/json", use: ContainerInspectRoute.handler(client: client))
    }
}

extension ContainerInspectRoute {
    private static func getUserString(from user: ProcessConfiguration.User) -> String? {
        switch user {
        case .raw(let userString):
            return userString.isEmpty ? nil : userString
        case .id(let uid, let gid):
            return "\(uid):\(gid)"
        }
    }

    /// Apple Container only reports live network attachments while a
    /// container is running (`container.networks` is hardcoded to `[]` once
    /// stopped), whereas Docker's `NetworkSettings.Networks` reflects the
    /// container's configured attachments regardless of run state. Falling
    /// back to the persisted `configuration.networks` keeps that parity,
    /// though the IP/gateway are unknown without a live sandbox.
    private static func networkEndpoints(for container: ContainerSnapshot) -> [String: ContainerEndpointSettings] {
        // uniquingKeysWith rather than uniqueKeysWithValues: nothing in Attachment's array-based
        // storage guarantees distinct .network names, and a duplicate would otherwise trap.
        if !container.networks.isEmpty {
            return Dictionary(
                container.networks.map { attachment in
                    (attachment.network, ContainerEndpointSettings.live(attachment))
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return Dictionary(
            container.configuration.networks.map { attachment in
                (attachment.network, ContainerEndpointSettings.configured(networkID: attachment.network))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> RESTContainerInspect {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "Container not found")
            }

            // Two host ports can publish one container port (`-p 3000:3000 -p 3100:3000`), and
            // `ExposedPorts` is keyed by `port/proto`, so those collapse to a single key.
            // `uniqueKeysWithValues` traps on that, taking the whole daemon down with it; the
            // host bindings are still reported individually under `NetworkSettings.Ports`.
            let exposedPorts = Dictionary(
                container.configuration.publishedPorts.map {
                    ("\($0.containerPort)/\($0.proto.rawValue)", EmptyObject())
                },
                uniquingKeysWith: { first, _ in first }
            )

            // Apple Container has no native healthcheck field; we round-trip
            // the original config via a JSON-encoded label set by the create
            // route, so Compose / Docker clients see the same Healthcheck
            // block they sent.
            let healthcheckConfig: HealthcheckConfig? =
                container.configuration.labels[HealthCheckManager.healthcheckLabel]
                .flatMap { Data($0.utf8) }
                .flatMap { try? JSONDecoder().decode(HealthcheckConfig.self, from: $0) }

            // Round-trips the label the create route persisted; defaults to "no", matching moby.
            let restartPolicy =
                await RestartPolicyManager.effectivePolicy(hexId: DockerContainerID.hexId(for: container), labels: container.configuration.labels)
                ?? RestartPolicy(Name: "no", MaximumRetryCount: nil)

            let containerConfig: ContainerConfig = ContainerConfig(
                Hostname: container.id,  // Use container ID as hostname since hostName property doesn't exist
                Domainname: container.configuration.dns?.domain,
                User: getUserString(from: container.configuration.initProcess.user),
                AttachStdin: false,  // no mechanism to derive this value
                AttachStdout: true,  // no mechanism to derive this value
                AttachStderr: true,  // no mechanism to derive this value
                ExposedPorts: exposedPorts.isEmpty ? nil : exposedPorts,
                Tty: container.configuration.initProcess.terminal,
                OpenStdin: false,  // no mechanism to derive this value
                StdinOnce: false,  // no mechanism to derive this value
                Env: container.configuration.initProcess.environment.isEmpty ? nil : container.configuration.initProcess.environment,
                Cmd: container.configuration.initProcess.arguments.isEmpty ? nil : container.configuration.initProcess.arguments,
                Healthcheck: healthcheckConfig,
                ArgsEscaped: false,  // no mechanism to derive this value
                Image: container.configuration.image.reference,
                Volumes: nil,  // Could be derived from mounts if needed
                WorkingDir: container.configuration.initProcess.workingDirectory.isEmpty ? nil : container.configuration.initProcess.workingDirectory,
                Entrypoint: [container.configuration.initProcess.executable],
                NetworkDisabled: container.configuration.networks.isEmpty,
                MacAddress: nil,  // no mechanism to derive this value
                OnBuild: nil,  // no mechanism to derive this value
                Labels: {
                    let restored = LabelNormalization.restore(container.configuration.labels)
                    return restored.isEmpty ? nil : restored
                }(),
                StopSignal: container.configuration.stopSignal,
                StopTimeout: nil,  // no mechanism to derive this value
                Shell: nil  // no mechanism to derive this value
            )

            let mounts = container.configuration.mounts.map { mount in
                let mountType: String
                let mountName: String?

                switch mount.type {
                case .block(_, _, _):
                    mountType = "bind"
                    mountName = nil
                case .volume(let name, _, _, _):
                    mountType = "volume"
                    mountName = name
                case .virtiofs:
                    mountType = "bind"
                    mountName = nil
                case .tmpfs:
                    mountType = "tmpfs"
                    mountName = nil
                }

                let isReadonly = mount.options.readonly
                let mode = isReadonly ? "ro" : "rw"

                return ContainerMountPoint(
                    type: mountType,
                    name: mountName,
                    source: mount.source,
                    destination: mount.destination,
                    driver: nil,  // we do not take into account any storage driver at this time
                    mode: mode,
                    rw: !isReadonly,
                    propagation: ""
                )
            }

            // dockerd reports the same published bindings under both
            // `HostConfig.PortBindings` and `NetworkSettings.Ports`.
            let portBindings = Dictionary(
                grouping: container.configuration.publishedPorts,
                by: { "\($0.containerPort)/\($0.proto.rawValue)" }
            ).mapValues { bindings in
                bindings.map { PortBinding(HostIp: $0.hostAddress.description, HostPort: "\($0.hostPort)") }
            }

            let hostConfig: HostConfig = HostConfig(restartPolicy: restartPolicy, portBindings: portBindings)

            // Enhanced network settings with proper port mapping
            let networkEndpoints = Self.networkEndpoints(for: container)
            let networkSettings = ContainerNetworkSettings(
                Bridge: nil,
                SandboxID: nil,
                Ports: portBindings,
                SandboxKey: nil,
                Networks: networkEndpoints,
                EndpointsConfig: networkEndpoints
            )

            let createdAt = AppleContainerTimestampResolver.containerCreationDate(container)

            // Live healthcheck status, if a probe loop is running for this
            // container. Returns nil when no healthcheck is configured or
            // the loop hasn't recorded its first result yet.
            let health = await req.application.storage[HealthCheckManagerKey.self]?.currentHealth(for: container.id)

            // True during the backoff window between a crash and its automatic restart.
            let isPendingRestart = await ContainerRestartState.shared.isPendingRestart(id: container.id)

            // Restarting is inspect's own knowledge — the runtime does not carry it. Everything else
            // comes from the shared rule, so this route and the list cannot drift apart again.
            let status = isPendingRestart ? "restarting" : container.mobyStateString

            // moby represents unknown timestamps as Go's zero time — dockerd
            // emits `0001-01-01T00:00:00Z`, which parses as a timestamp, unlike
            // the empty string previously sent here (issue #8).
            let dockerZeroTime = "0001-01-01T00:00:00Z"
            let startedAt =
                container.startedDate
                .map { AppleContainerTimestampResolver.iso8601Timestamp($0) }
                ?? dockerZeroTime

            // moby resets ExitCodeValue to 0 on every start (container/state.go
            // setRunning), so a running or never-started container inspects as 0.
            let exitCode: Int32
            if container.status == .running || container.startedDate == nil {
                exitCode = 0
            } else {
                // The exit monitor records the code under both the native and hex
                // container IDs; probe both like ContainerWaitRoute does.
                let hexId = DockerContainerID.hexId(for: container)
                let nativeCode = await ContainerExitCodeStore.shared.get(id: container.id)
                let hexCode = await ContainerExitCodeStore.shared.get(id: hexId)
                exitCode =
                    nativeCode ?? hexCode
                    // No entry means the daemon restarted after the container
                    // exited (the store is in-memory). Default to 0 — moby's own
                    // zero value for State.ExitCodeValue — rather than inventing
                    // a failure code: a fabricated non-zero would flip every
                    // "did it succeed" check (CI, Testcontainers) to failure for
                    // containers that really exited 0 before the restart. A code
                    // that genuinely could not be obtained is recorded as the
                    // store's -1 sentinel by the exit monitor and flows through.
                    ?? 0
            }

            let containerState: ContainerState = ContainerState(
                Status: status,
                // moby keeps Running=true through the restart backoff
                // (container/state.go SetRestarting), so a "restarting"
                // container still inspects as running.
                Running: container.status == .running || isPendingRestart,
                Paused: false,  // Apple containers don't have a paused state like Docker
                Restarting: isPendingRestart,
                OOMKilled: false,
                // moby's Dead marks a container whose removal failed mid-way
                // (container/state.go SetRemovalError / StateString); a cleanly
                // exited container is Dead=false — never "it stopped".
                Dead: false,
                Pid: 0,  // we have no mechanism to derive PID in Apple container
                ExitCode: Int(exitCode),
                Error: "",
                StartedAt: startedAt,
                // Apple exposes no finish time for a stopped container; moby's
                // zero time is the closest non-misleading value (a wall-clock
                // reading would fabricate an exit moment we never observed).
                FinishedAt: dockerZeroTime,
                Health: health
            )

            return RESTContainerInspect(
                Id: DockerContainerID.hexId(for: container),
                Created: AppleContainerTimestampResolver.iso8601Timestamp(createdAt),
                Path: container.configuration.initProcess.executable,
                Args: container.configuration.initProcess.arguments,
                State: containerState,
                Image: container.configuration.image.digest.isEmpty
                    ? container.configuration.image.reference
                    : container.configuration.image.digest,
                ResolvConfPath: "/etc/resolv.conf",
                HostnamePath: "/etc/hostname",
                HostsPath: "/etc/hosts",
                LogPath: nil,  // Apple containers don't have a log path
                Name: "/" + container.id,
                RestartCount: await ContainerRestartState.shared.count(id: container.id),
                Driver: Self.storageDriverName,
                // The Engine API swagger keeps `Platform` at this level (the OS
                // the container was created for — "linux" here).
                Platform: "linux",
                ImageManifestDescriptor: nil,
                MountLabel: "",
                ProcessLabel: "",
                AppArmorProfile: "",
                ExecIDs: nil,
                HostConfig: hostConfig,
                GraphDriver: ContainerDriverData(Name: Self.storageDriverName, Data: [:]),
                SizeRw: nil,
                SizeRootFs: nil,
                Mounts: mounts,
                Config: containerConfig,
                NetworkSettings: networkSettings
            )
        }
    }
}

extension ContainerInspectRoute {
    // moby reports the storage driver name here (`Driver: ctr.Driver`,
    // daemon/inspect.go). Apple Container has no graph driver; the Engine API
    // swagger's example value for the snapshotter-based daemons is "overlayfs",
    // so we report that constant rather than "" — which a client reads as
    // "field unset" and dockerd never sends.
    private static let storageDriverName = "overlayfs"
}
