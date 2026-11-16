import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Vapor

/// The decision of `POST /containers/create` with `--shared-runtimes` (F-001, F-002, F-003, F-008).
extension SharedRuntimeService {
    enum CreateOutcome: Equatable {
        /// The create route goes on as without the flag; `skipped` is the value of
        /// `containerstack.group.skipped` when a rule selected a group.
        case dedicated(skipped: String?)
        case session(id: String)
    }

    /// Runs before the create route resolves the image.
    func decideCreate(
        data: Data, body: CreateContainerRequest, name: String, explicitName: Bool, platform: Platform,
        containers: ClientContainerProtocol
    ) async throws -> CreateOutcome {
        if explicitName, await manager.isSessionName(name) { throw Self.nameConflict(name) }
        let label = body.Labels?[SharedRuntimeLabels.group]
        // A request that cannot select a group waits for nothing and reads no image.
        if label == SharedRuntimeLabels.noGroup { return .dedicated(skipped: nil) }
        if label == nil {
            guard case .active(let document) = await file.current(), document.groups.contains(where: \.isActive) else {
                return .dedicated(skipped: nil)
            }
        }
        guard case .on(let document) = await admission() else { return .dedicated(skipped: nil) }

        let request: SharedRuntimeCreateRequest
        do {
            request = try SharedRuntimeCreateRequest(data: data)
        } catch {
            guard let label else { return .dedicated(skipped: nil) }
            throw Abort(.internalServerError, reason: "cannot read the request for shared runtime group \"\(label)\": \(error)")
        }
        // A run that can never be a session (no stdin, a TTY, a label with no active group) is
        // decided without the image; most runs that are not sessions stop here.
        if let decision = SharedRuntimeDecision.decideWithoutImage(request: request, groups: document) {
            return try Self.outcome(decision)
        }
        let facts: SharedRuntimeImageFactsResult?
        do {
            facts = try await imageFacts.facts(reference: body.Image, platform: platform)
        } catch {
            guard let label else { return .dedicated(skipped: nil) }
            throw Abort(.internalServerError, reason: "cannot read the image for shared runtime group \"\(label)\": \(error)")
        }
        guard let facts else { return .dedicated(skipped: nil) }

        let decision = try SharedRuntimeDecision.decide(request: request, image: facts.image, groups: document)
        switch decision {
        case .dedicated, .skipped, .rejected:
            return try Self.outcome(decision)
        case .session(let groupName, let key, let process):
            guard let group = document.group(named: groupName) else { return .dedicated(skipped: nil) }
            if let existing = try? await containers.getContainer(id: name) {
                throw Self.nameConflict(name, id: DockerContainerID.hexId(for: existing))
            }
            let spec = SharedSessionSpec(
                id: DockerContainerID.mint(), name: name, group: group, key: key, process: process,
                image: SharedRuntimeManager.Image(description: facts.description, platform: platform),
                imageID: facts.image.id, imageName: body.Image, labels: body.Labels ?? [:], created: Date())
            let session: SharedSession
            do {
                session = try await manager.addSession(spec)
            } catch {
                throw Self.nameConflict(name)
            }
            await manager.onEvent(manager.sessionEvent(session, "create"))
            return .session(id: spec.id)
        }
    }

    /// The outcome of a decision that is not a session.
    private static func outcome(_ decision: SharedRuntimeDecision) throws -> CreateOutcome {
        switch decision {
        case .skipped(let group, let reason): return .dedicated(skipped: "\(group):\(reason.code)")
        case .rejected(let group, let reason): throw rejection(group: group, reason: reason)
        case .dedicated, .session: return .dedicated(skipped: nil)
        }
    }

    static func rejection(group: String, reason: SharedRuntimeReason) -> Abort {
        Abort(.badRequest, reason: SharedRuntimeDecision.rejected(group: group, reason: reason).rejectionMessage ?? reason.code)
    }

    static func nameConflict(_ name: String, id: String? = nil) -> Abort {
        let owner = id.map { " by container \"\($0)\"" } ?? ""
        return Abort(
            .conflict,
            reason: "Conflict. The container name \"/\(name)\" is already in use\(owner). You have to remove (or rename) that container to be able to reuse that name.")
    }
}
