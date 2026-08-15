import ContainerAPIClient
import ContainerPersistence
import Vapor

struct ImageTagRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/tag") { [systemConfig] req in
            try await ImageTagRoute.handler(req, systemConfig: systemConfig)
        }
    }
}

struct RESTImageTagQuery: Vapor.Content {
    let repo: String?
    let tag: String?
}

extension ImageTagRoute {
    static func handler(_ req: Request, systemConfig: ContainerSystemConfig) async throws -> Response {
        guard let sourceImageName = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing image name parameter")
        }

        // moby validates both sides before touching the store
        // (api/server/httputils/form.go RepoTagReference and
        // daemon/images/image.go GetImage → errdefs.InvalidParameter): a
        // malformed source or target is a 400, not a 404/500.
        if let reason = DockerReference.invalidReason(for: sourceImageName) {
            throw Abort(.badRequest, reason: reason)
        }

        let query = try req.query.decode(RESTImageTagQuery.self)

        guard let repo = query.repo, !repo.isEmpty else {
            throw Abort(.badRequest, reason: "repo parameter is required")
        }

        let rawTarget =
            query.tag.flatMap { $0.isEmpty ? nil : $0 }.map { "\(repo):\($0)" } ?? repo
        if let reason = DockerReference.invalidReason(for: rawTarget) {
            throw Abort(.badRequest, reason: reason)
        }

        let targetReference: String
        do {
            targetReference = try ClientImage.normalizeReference(rawTarget, containerSystemConfig: systemConfig)
        } catch {
            // Grammar-valid input should normalize; any residual parse
            // failure is still the client's, never a 500.
            throw Abort(.badRequest, reason: "invalid reference format")
        }

        let sourceImage: ClientImage
        do {
            sourceImage = try await ClientImage.get(reference: sourceImageName, containerSystemConfig: systemConfig)
        } catch {
            throw Abort(.notFound, reason: "No such image: \(sourceImageName)")
        }

        do {
            _ = try await sourceImage.tag(new: targetReference)
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                // moby's tag event uses the image digest as Actor.ID and the new
                // reference as the `name` attribute (no `image`/`from` for image events).
                await broadcaster.broadcast(
                    DockerEvent.make(
                        type: "image", action: "tag", actorID: sourceImage.digest,
                        attributes: ["name": targetReference]))
            }
            return Response(status: .created)
        } catch {
            req.logger.error("Failed to tag image: \(error)")
            throw Abort(.internalServerError, reason: "Failed to tag image: \(error.localizedDescription)")
        }
    }
}
