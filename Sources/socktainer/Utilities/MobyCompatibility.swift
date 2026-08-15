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
    /// Every path that reports a state goes through here. The list and inspect each grew their own
    /// answer and disagreed twice, in opposite directions: first inspect said `exited` where the list
    /// said `created`, then the reverse (issues #8, #16). Compose lists containers by state to decide
    /// what needs starting, so a service that has never run looking like one that already finished is
    /// not a cosmetic difference.
    public static func state(for container: ContainerSnapshot) -> String {
        if container.status != .running, container.startedDate == nil {
            return "created"
        }
        return toMobyState(container.status)
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
