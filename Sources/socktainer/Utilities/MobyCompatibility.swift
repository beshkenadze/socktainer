import ContainerAPIClient
import ContainerResource
import Foundation

public enum MobyContainerStatus {
    public static func toMobyState(_ appleStatus: RuntimeStatus) -> String {
        switch appleStatus {
        case .running:
            return "running"
        case .stopped:
            return "exited"
        case .stopping:
            return "exited"
        case .unknown:
            return "created"
        }
    }

    /// The state Docker reports for a container, including the one Apple Container cannot express.
    ///
    /// `RuntimeStatus` has no "created": a container that was created and never started comes back
    /// `.stopped` or `.unknown`, so mapping the status alone calls it `exited`. moby decides this by
    /// the clock — `container/state.go`'s `StateString()` reports "created" while `StartedAt` is
    /// zero — and a never-run container is exactly that.
    ///
    /// The clock alone is not enough here, because this runtime's `startedDate` is in-memory and
    /// reads nil for containers that certainly ran: everything that survives a daemon restart, and
    /// anything whose start booted the guest and then failed. Calling those "created" tells Compose
    /// a finished service has never run, and hides them from `--filter status=exited`. So the clock
    /// is confirmed against the runtime's own on-disk record of having booted the container.
    ///
    /// Every path that reports a state goes through here. The list and inspect each grew their own
    /// answer and disagreed twice, in opposite directions: first inspect said `exited` where the list
    /// said `created`, then the reverse (issues #8, #16). Compose lists containers by state to decide
    /// what needs starting, so a service that has never run looking like one that already finished is
    /// not a cosmetic difference.
    public static func state(for container: ContainerSnapshot) -> String {
        if container.status != .running, container.startedDate == nil, !ContainerRunHistory.hasRun(id: container.id) {
            return "created"
        }
        return toMobyState(container.status)
    }

    /// The exit code Docker should see for a container that has finished running,
    /// probing both keys the exit monitor records under — the native id and the
    /// Docker hex id. A container that ran with no record reads as
    /// `ContainerExitCodeStore.unknownExitCode`, never 0: absent and zero are
    /// different answers, and conflating them is what made a crashed service
    /// claim a clean exit after a daemon restart (issue #20).
    public static func exitCode(for container: ContainerSnapshot) async -> Int32 {
        let hexId = DockerContainerID.hexId(for: container)
        let nativeCode = await ContainerExitCodeStore.shared.get(id: container.id)
        let hexCode = await ContainerExitCodeStore.shared.get(id: hexId)
        return nativeCode ?? hexCode ?? ContainerExitCodeStore.unknownExitCode
    }

    /// When the container finished, when any daemon lifetime observed it — the
    /// persisted store keeps the answer across restarts, as moby's checkpointed
    /// `State.FinishedAt` does. nil when the finish was never observed, and the
    /// list's "Exited (N) <age> ago" then degrades to no age at all.
    public static func finishTime(for container: ContainerSnapshot) async -> Date? {
        if let native = await ContainerExitCodeStore.shared.finishTime(id: container.id) {
            return native
        }
        return await ContainerExitCodeStore.shared.finishTime(id: DockerContainerID.hexId(for: container))
    }

    /// The human-readable status `docker ps` shows — moby's `State.String()`
    /// (container/state.go): "Up 2 hours", "Created", "Exited (7) 3 seconds ago".
    /// Both surfaces Docker renders it on — the container list and /system/df —
    /// go through here so they cannot drift; dockerd shares one builder for the
    /// same reason (daemon/list.go's getContainerSummary serves both).
    public static func statusString(for container: ContainerSnapshot) async -> String {
        let mobyState = state(for: container)
        switch mobyState {
        case "running":
            if let started = container.startedDate {
                return "Up \(humanReadableAge(since: started))"
            }
            return "Up"
        case "created":
            // moby's State.String() for a container that never ran is the bare word.
            return "Created"
        case "exited":
            let exitCode = await exitCode(for: container)
            // The age is measured from when the container *finished*, as moby's
            // `State.String` reads `FinishedAt`. The snapshot only carries a start time, so
            // using that reported a container's whole runtime: three hours of work exiting a
            // second ago printed "Exited (7) 3 hours ago". The persisted exit store carries
            // the finish time across daemon restarts; an exit no daemon lifetime observed
            // has none, and then Docker's own format degrades to no age at all.
            if let finished = await finishTime(for: container) {
                return "Exited (\(exitCode)) \(humanReadableAge(since: finished)) ago"
            }
            return "Exited (\(exitCode))"
        default:
            return mobyState.prefix(1).uppercased() + mobyState.dropFirst()
        }
    }

    /// The duration wording `docker ps` prints inside "Up X" / "Exited (N) X ago" —
    /// moby renders these with `units.HumanDuration` (docker/go-units).
    public static func humanReadableAge(since date: Date) -> String {
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

/// Extension to RuntimeStatus to add Moby-compliant properties
extension RuntimeStatus {
    public var mobyState: String {
        MobyContainerStatus.toMobyState(self)
    }
}

extension ContainerSnapshot {
    /// The Docker state for this container: `MobyContainerStatus.state(for:)`, at the call site.
    public var mobyStateString: String {
        MobyContainerStatus.state(for: self)
    }
}
