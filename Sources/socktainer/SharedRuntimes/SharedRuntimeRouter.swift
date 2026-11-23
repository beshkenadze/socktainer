import Foundation
import NIOCore
import Vapor

/// The routes of a session (F-009). The regex router calls `intercept` for each route when
/// `--shared-runtimes` is on; a request whose container ID names a session is answered here, and
/// every other route that takes a container ID answers 409 (deny by default).
enum SharedRuntimeRouter {
    static let notSupported = "not supported for a session of a shared group"

    static func intercept(
        _ req: Request, method: HTTPMethod, pattern: String, service: SharedRuntimeService, containers: ClientContainerProtocol
    ) async throws -> Response? {
        // A dedicated container cannot take the name of a session.
        if method == .POST, pattern == "/containers/{id}/rename", var name = req.query[String.self, at: "name"] {
            if name.hasPrefix("/") { name.removeFirst() }
            if await service.manager.isSessionName(name) { throw SharedRuntimeService.nameConflict(name) }
        }
        let reference: String?
        if pattern.hasPrefix("/containers/{id") {
            reference = req.parameters.get("id")
        } else if pattern == "/commit" {
            reference = req.query[String.self, at: "container"]
        } else if method == .POST, pattern == "/networks/{id}/connect" || pattern == "/networks/{id}/disconnect" {
            reference = try await NetworkConnectRoute.container(req)
        } else {
            return nil
        }
        guard let reference, let match = await service.manager.sessionMatch(reference) else { return nil }
        // An error of the dedicated lookup (for example an ambiguous prefix) is the answer.
        if match.byPrefix, try await containers.getContainer(id: reference) != nil { return nil }
        let session = match.session
        let manager = service.manager
        switch (method, pattern) {
        case (.POST, "/containers/{id}/attach"): return await attach(req, session, manager)
        case (.POST, "/containers/{id}/wait"): return try wait(req, session)
        case (.POST, "/containers/{id}/start"): return try await start(session, manager)
        case (.POST, "/containers/{id}/stop"): return try await stop(req, session, manager)
        case (.POST, "/containers/{id}/kill"): return try await kill(req, session, manager)
        case (.DELETE, "/containers/{id}"): return try await remove(req, session, manager)
        case (.GET, "/containers/{id}/json"): return try await inspect(req, session)
        case (.GET, "/containers/{id}/logs"): return try logs(req, session)
        default: throw Abort(.conflict, reason: notSupported)
        }
    }

    private static func attach(_ req: Request, _ session: SharedSession, _ manager: SharedRuntimeManager) async -> Response {
        // Recorded before the 101 answer: the CLI may send `start` before the stream handler runs.
        await manager.expectAttach(session)
        await manager.onEvent(manager.sessionEvent(session, "attach"))
        return Response.dockerTCPUpgrade(execId: session.spec.id, ttyEnabled: false) { channel, handler in
            let stream = SessionStream(channel: channel) {
                Task { await manager.attachDisconnected(session) }
            }
            await manager.bindAttach(session, stream: stream, stdin: handler)
        }
    }

    /// The waiter is the session's end latch, taken before the response head is sent.
    private static func wait(_ req: Request, _ session: SharedSession) throws -> Response {
        let ended = session.ended
        let body = Response.Body(managedAsyncStream: { writer in
            try await writer.write(.buffer(ByteBuffer()))
            let result = try await ContainerWaitRoute.withDisconnectCancellation(writer: writer) {
                RESTContainerWait(statusCode: Int64(await ended.wait() ?? 0))
            }
            try await writer.write(.buffer(ByteBuffer(data: try JSONEncoder().encode(result))))
        })
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: body)
    }

    private static func start(_ session: SharedSession, _ manager: SharedRuntimeManager) async throws -> Response {
        do {
            try await manager.start(session)
            return Response(status: .noContent)
        } catch SharedRuntimeManager.SessionError.alreadyStarted {
            return Response(status: .notModified)
        } catch {
            throw Abort(.internalServerError, reason: "cannot start the session: \(error)")
        }
    }

    private static func stop(_ req: Request, _ session: SharedSession, _ manager: SharedRuntimeManager) async throws -> Response {
        let timeout = req.query[Int.self, at: "t"] ?? req.query[Int.self, at: "timeout"]
        let stopped = try await signalCall { try await manager.stop(session, signal: req.query[String.self, at: "signal"], timeout: timeout) }
        return Response(status: stopped ? .noContent : .notModified)
    }

    private static func kill(_ req: Request, _ session: SharedSession, _ manager: SharedRuntimeManager) async throws -> Response {
        try await signalCall { try await manager.kill(session, signal: req.query[String.self, at: "signal"]) }
        return Response(status: .noContent)
    }

    private static func remove(_ req: Request, _ session: SharedSession, _ manager: SharedRuntimeManager) async throws -> Response {
        let force = req.query[Bool.self, at: "force"] ?? false
        try await signalCall { try await manager.remove(session, force: force) }
        return Response(status: .noContent)
    }

    /// Maps the session errors to Docker's answers.
    private static func signalCall<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as SharedRuntimeSignal.Failure {
            throw Abort(.badRequest, reason: error.description)
        } catch SharedRuntimeManager.SessionError.notRunning(let id) {
            throw Abort(.conflict, reason: "Container \(id) is not running")
        } catch SharedRuntimeManager.SessionError.running(let id) {
            throw Abort(
                .conflict,
                reason: "You cannot remove a running container \(id). Stop the container before attempting removal or force remove")
        }
    }
}
