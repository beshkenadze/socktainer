import ContainerResource
import Vapor

/// A container of the `cluster` plugin is a node of a Kubernetes cluster. Only `container cluster`
/// and ContainerStack start, stop or delete it. A route that can change a container calls `refuse`
/// on the container that it resolved, before any other step, so a node gets 409 and no change.
///
/// This prevents accidents from Docker clients (`docker rm -f`, `docker container prune`). It is
/// not a security boundary: a client of this socket controls the runtime anyway. The routes act
/// by native name after the check, so a container that becomes a node between the check and the
/// native call is not caught.
enum ClusterNodeGuard {
    static func isNode(_ container: ContainerSnapshot) -> Bool {
        container.configuration.labels[ResourceLabelKeys.plugin] == ResourcePluginValues.cluster
    }

    /// Throws the 409 when `container` is a node.
    static func refuse(_ container: ContainerSnapshot?) throws {
        guard let container, isNode(container) else { return }
        throw Abort(
            .conflict,
            reason: "\(container.id) is a node of a Kubernetes cluster. Use 'container cluster' or ContainerStack to start, stop or delete it."
        )
    }

    /// Throws Docker's 409 for an attach to a stopped container when `container` is a stopped node.
    /// The bridge holds an attach to a stopped container open until a start through the bridge,
    /// and a node is never started through the bridge.
    static func refuseAttach(_ container: ContainerSnapshot) throws {
        guard container.status == .stopped, isNode(container) else { return }
        throw Abort(.conflict, reason: "You cannot attach to a stopped container, start it first")
    }
}
