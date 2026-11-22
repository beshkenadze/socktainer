import ContainerResource
import Foundation
import Logging
import Synchronization
import Testing

@testable import socktainer

/// The order and the conditions of the host's volume image writes around a container create.
/// The create route performs its native create through `VolumeImageWrites.create`.
@Suite struct VolumeImageWritesTests {
    private let logger = Logger(label: "test.volume-writes")
    private static let postgres = ["PGDATA=/var/lib/postgresql/data"]

    /// Records every call in order and answers the verdicts it is given.
    private final class Recorder: VolumeImageWrites.Writer, @unchecked Sendable {
        private let lock = Mutex<[String]>([])
        let verdicts: [String: VolumeImageEligibility.Verdict]

        init(_ verdicts: [String: VolumeImageEligibility.Verdict]) {
            self.verdicts = verdicts
        }

        var events: [String] { lock.withLock { $0 } }
        func record(_ event: String) { lock.withLock { $0.append(event) } }

        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict {
            verdicts[imagePath] ?? .doubtful("unknown image")
        }
        func removeLostFound(imagePath: String) { record("clean \(imagePath)") }
        func copyUp(_ volumes: [(source: String, destination: String)], into container: ContainerSnapshot) {
            record("copy-up \(volumes.map(\.source).joined(separator: ",")) into \(container.id)")
        }
    }

    private func volume(_ name: String, noCopy: Bool = false, labels: [String: String] = [:]) -> VolumeImageWrites.Volume {
        VolumeImageWrites.Volume(name: name, source: "/vols/\(name)/volume.img", destination: "/data", labels: labels, noCopy: noCopy)
    }

    private func snapshot(_ id: String, mounts: [Filesystem] = []) throws -> ContainerSnapshot {
        var snapshot = try makeContainerSnapshot(nativeId: id, networks: [], labels: [:])
        snapshot.configuration.mounts = mounts
        return snapshot
    }

    private func mount(_ name: String) -> Filesystem {
        .volume(name: name, format: "ext4", source: "/vols/\(name)/volume.img", destination: "/x", options: [])
    }

    /// Runs `create` with lists that answer in turn from `lists` (nil: the list fails).
    private func run(
        _ volumes: [VolumeImageWrites.Volume], env: [String] = postgres, recorder: Recorder,
        lists: [[ContainerSnapshot]?], createFails: Bool = false
    ) async throws -> [String] {
        let answers = Mutex(lists)
        let created = try snapshot("new", mounts: volumes.map { mount($0.name) })
        let result = try await VolumeImageWrites.create(
            volumes: volumes,
            mergedEnv: env,
            listContainers: {
                recorder.record("list")
                let next: [ContainerSnapshot]?? = answers.withLock { lists in
                    lists.isEmpty ? .none : .some(lists.removeFirst())
                }
                guard case .some(.some(let list)) = next else { throw CancellationError() }
                return list
            },
            nativeCreate: {
                recorder.record("create")
                if createFails { throw CancellationError() }
                return created
            },
            writer: recorder,
            logger: logger
        )
        return result.warnings
    }

    @Test("an empty Postgres volume is cleaned before the native create and filled after it")
    func order() async throws {
        let v = volume("pg")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        let warnings = try await run([v], recorder: recorder, lists: [[], [try snapshot("new", mounts: [mount("pg")])]])
        #expect(recorder.events == ["list", "clean \(v.source)", "create", "list", "copy-up \(v.source) into new"])
        #expect(warnings.isEmpty)
    }

    @Test("no write at all when the container list cannot be read")
    func listFailureMeansNoWrite() async throws {
        let v = volume("pg")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        let warnings = try await run([v], recorder: recorder, lists: [nil, nil])
        #expect(recorder.events == ["list", "create", "list"])
        #expect(warnings.count == 1 && warnings[0].contains("could not be read"))
    }

    @Test("no write to a volume that another container names, by name or as a block device")
    func namedElsewhereMeansNoWrite() async throws {
        let v = volume("shared")
        let byName = try snapshot("other", mounts: [mount("shared")])
        let byPath = try snapshot(
            "alias", mounts: [.block(format: "ext4", source: v.source, destination: "/y", options: [])])
        for holder in [byName, byPath] {
            let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
            let warnings = try await run([v], recorder: recorder, lists: [[holder], [holder]])
            #expect(recorder.events == ["list", "create", "list"], "holder \(holder.id)")
            #expect(warnings.count == 1 && warnings[0].contains("is used by another container"))
        }
    }

    @Test("a container that names the volume and appears during the create stops the copy-up")
    func lateHolderStopsTheCopyUp() async throws {
        let v = volume("data")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        let late = try snapshot("late", mounts: [mount("data")])
        _ = try await run([v], env: [], recorder: recorder, lists: [[late]])
        #expect(recorder.events == ["create", "list"])
    }

    @Test("a volume with data gets no write and no warning; a doubtful one gets no write and a warning")
    func verdictsDecide() async throws {
        let data = volume("data")
        let doubt = volume("doubt")
        let recorder = Recorder([data.source: .holdsData, doubt.source: .doubtful("not marked clean")])
        let warnings = try await run([data, doubt], recorder: recorder, lists: [[], []])
        #expect(recorder.events == ["create", "list"])
        #expect(warnings.count == 1 && warnings[0].contains("\"doubt\"") && warnings[0].contains("not marked clean"))
    }

    @Test("nocopy stops the copy-up; a Postgres volume is still cleaned")
    func noCopy() async throws {
        let pg = volume("pg", noCopy: true)
        let plain = volume("plain", noCopy: true)
        let recorder = Recorder([pg.source: .replaceable(hasLostFound: true), plain.source: .replaceable(hasLostFound: true)])
        let warnings = try await run([pg, plain], recorder: recorder, lists: [[]])
        #expect(recorder.events == ["list", "clean \(pg.source)", "clean \(plain.source)", "create"])
        #expect(warnings.isEmpty)
    }

    @Test("no clean-up without PGDATA or with the opt-out label")
    func cleanUpConditions() async throws {
        let v = volume("v")
        var recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        _ = try await run([v], env: ["FOO=1"], recorder: recorder, lists: [[]])
        #expect(!recorder.events.contains { $0.hasPrefix("clean") })

        let optedOut = volume("o", labels: [VolumeImageCleaner.optOutLabel: "false"])
        recorder = Recorder([optedOut.source: .replaceable(hasLostFound: true)])
        _ = try await run([optedOut], recorder: recorder, lists: [[], []])
        #expect(!recorder.events.contains { $0.hasPrefix("clean") })
    }

    @Test("a native create that fails gets no copy-up")
    func failedCreateGetsNoCopyUp() async throws {
        let v = volume("v")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: false)])
        await #expect(throws: CancellationError.self) {
            _ = try await run([v], env: [], recorder: recorder, lists: [[]], createFails: true)
        }
        #expect(recorder.events == ["create"])
    }

    @Test("nocopy is taken off the mount options")
    func splitNoCopy() {
        #expect(VolumeImageWrites.splitNoCopy(["ro", "nocopy"]) == (["ro"], true))
        #expect(VolumeImageWrites.splitNoCopy(["NoCopy"]) == ([], true))
        #expect(VolumeImageWrites.splitNoCopy(["ro"]) == (["ro"], false))
    }
}
