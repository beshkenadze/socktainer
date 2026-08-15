import ContainerAPIClient
import Foundation
import Vapor

struct ContainerStatsRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/containers/{id}/stats", use: ContainerStatsRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let stream = MobyBool.queryValue(req.query["stream"] as String?, defaultingTo: true)

            // Resolve through socktainer's client, not Apple's: `docker stats` addresses containers by
            // the 64-hex Docker id it read from /containers/json, which the runtime does not know. Going
            // straight to the runtime answered 404 for every one of them, so the CLI printed an empty row
            // no matter what fields the payload carried.
            guard let snapshot = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }
            let name = snapshot.id
            // Sampling goes to the runtime, and must use the id the runtime knows — the resolved one,
            // not whatever reference the client sent.
            let runtime = ContainerClient()
            let runtimeId = snapshot.id

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")

            let body = Response.Body { writer in
                Task.detached {
                    defer { _ = writer.write(.end) }

                    do {
                        var prevSample = try await runtime.stats(id: runtimeId)
                        var prevRead = Date()

                        if stream {
                            // Streaming mode: emit one JSON object per second indefinitely
                            // until the client disconnects or the container stops.
                            while true {
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                                guard let currSample = try? await runtime.stats(id: runtimeId) else { break }
                                let currRead = Date()
                                let stats = RESTContainerStats.build(
                                    id: id, name: name, prev: prevSample, curr: currSample,
                                    prevRead: prevRead, currRead: currRead)
                                if let data = try? JSONEncoder().encode(stats) {
                                    var buf = sharedAllocator.buffer(capacity: data.count + 1)
                                    buf.writeBytes(data)
                                    buf.writeString("\n")
                                    _ = writer.write(.buffer(buf))
                                }
                                prevSample = currSample
                                prevRead = currRead
                            }
                        } else {
                            // One-shot mode: take two samples 1s apart to get a CPU delta,
                            // then return a single JSON object and close.
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                            guard let currSample = try? await runtime.stats(id: runtimeId) else { return }
                            let currRead = Date()
                            let stats = RESTContainerStats.build(
                                id: id, name: name, prev: prevSample, curr: currSample,
                                prevRead: prevRead, currRead: currRead)
                            if let data = try? JSONEncoder().encode(stats) {
                                var buf = sharedAllocator.buffer(capacity: data.count)
                                buf.writeBytes(data)
                                _ = writer.write(.buffer(buf))
                            }
                        }
                    } catch {
                        // Container gone or stats unavailable — close stream cleanly
                    }
                }
            }

            return Response(status: .ok, headers: headers, body: body)
        }
    }
}
