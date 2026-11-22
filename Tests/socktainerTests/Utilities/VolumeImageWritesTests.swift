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

    /// Records every call in order, answers the verdicts it is given, and fails the jobs it is
    /// told to fail.
    private final class Recorder: VolumeImageWrites.Writer, @unchecked Sendable {
        private let lock = Mutex<[String]>([])
        let verdicts: [String: VolumeImageEligibility.Verdict]
        let failing: [String: String]

        init(_ verdicts: [String: VolumeImageEligibility.Verdict], failing: [String: String] = [:]) {
            self.verdicts = verdicts
            self.failing = failing
        }

        var events: [String] { lock.withLock { $0 } }
        func record(_ event: String) { lock.withLock { $0.append(event) } }

        func verdict(imagePath: String) -> VolumeImageEligibility.Verdict {
            verdicts[imagePath] ?? .doubtful("unknown image")
        }

        func prepare(_ jobs: [VolumeImageWrites.Job], for container: ContainerSnapshot) -> [String: String] {
            for job in jobs {
                switch job {
                case .copyUp(let source, _): record("copy-up \(source) into \(container.id)")
                case .dropLostFound(let source): record("drop lost+found \(source)")
                }
            }
            return failing
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

    /// Runs `create`; the container list answers `list` (nil: it fails).
    private func run(
        _ volumes: [VolumeImageWrites.Volume], env: [String] = postgres, recorder: Recorder,
        list: [ContainerSnapshot]?, createFails: Bool = false
    ) async throws -> [String] {
        let created = try snapshot("new", mounts: volumes.map { mount($0.name) })
        let result = try await VolumeImageWrites.create(
            volumes: volumes,
            mergedEnv: env,
            listContainers: {
                recorder.record("list")
                guard let list else { throw CancellationError() }
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

    @Test("nothing is written before the native create; an empty volume is filled after it")
    func order() async throws {
        let v = volume("pg")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        let warnings = try await run([v], recorder: recorder, list: [try snapshot("new", mounts: [mount("pg")])])
        #expect(recorder.events == ["create", "list", "copy-up \(v.source) into new"])
        #expect(warnings.isEmpty)
    }

    @Test("a native create that fails gets no list and no write")
    func failedCreateWritesNothing() async throws {
        let v = volume("pg")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        await #expect(throws: CancellationError.self) {
            _ = try await run([v], recorder: recorder, list: [], createFails: true)
        }
        #expect(recorder.events == ["create"])
    }

    @Test("no write when the container list cannot be read, and a warning that says so")
    func listFailureMeansNoWrite() async throws {
        let v = volume("pg")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        let warnings = try await run([v], recorder: recorder, list: nil)
        #expect(recorder.events == ["create", "list"])
        #expect(warnings.count == 1 && warnings[0].contains("could not be read") && warnings[0].contains("rmdir /v/lost+found"))
    }

    @Test("no write to a volume that another container names, by name or as a block device, and a warning")
    func namedElsewhereMeansNoWrite() async throws {
        let v = volume("shared")
        let byName = try snapshot("other", mounts: [mount("shared")])
        let byPath = try snapshot("alias", mounts: [.block(format: "ext4", source: v.source, destination: "/y", options: [])])
        for holder in [byName, byPath] {
            let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
            let warnings = try await run([v], recorder: recorder, list: [holder])
            #expect(recorder.events == ["create", "list"], "holder \(holder.id)")
            #expect(warnings.count == 1 && warnings[0].contains("another container uses it"))
        }
    }

    @Test("a volume with data gets no list, no write and no warning; a doubtful one gets a warning and no list")
    func verdictsDecide() async throws {
        let data = volume("data")
        let doubt = volume("doubt")
        let recorder = Recorder([data.source: .holdsData, doubt.source: .doubtful("not marked clean")])
        let warnings = try await run([data, doubt], recorder: recorder, list: [])
        #expect(recorder.events == ["create"])
        #expect(warnings.count == 1 && warnings[0].contains("\"doubt\"") && warnings[0].contains("not marked clean"))
    }

    @Test("a preparation that fails gives a warning with its reason")
    func failedPreparationWarns() async throws {
        let v = volume("v")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)], failing: [v.source: "the copy-up failed: disk full"])
        let warnings = try await run([v], recorder: recorder, list: [])
        #expect(recorder.events == ["create", "list", "copy-up \(v.source) into new"])
        #expect(warnings.count == 1 && warnings[0].contains("disk full"))
    }

    @Test("nocopy: no copy-up; a Postgres volume with /lost+found only loses it, and nothing else is wanted")
    func noCopy() async throws {
        let pg = volume("pg", noCopy: true)
        var recorder = Recorder([pg.source: .replaceable(hasLostFound: true)])
        var warnings = try await run([pg], recorder: recorder, list: [])
        #expect(recorder.events == ["create", "list", "drop lost+found \(pg.source)"])
        #expect(warnings.isEmpty)

        // Not Postgres, opted out, or already without /lost+found: nothing is wanted, no list.
        let optedOut = volume("o", noCopy: true, labels: [VolumeImageCleaner.optOutLabel: "false"])
        let clean = volume("c", noCopy: true)
        for (vol, env, verdict) in [
            (pg, ["FOO=1"], VolumeImageEligibility.Verdict.replaceable(hasLostFound: true)),
            (optedOut, Self.postgres, .replaceable(hasLostFound: true)),
            (clean, Self.postgres, .replaceable(hasLostFound: false)),
        ] {
            recorder = Recorder([vol.source: verdict])
            warnings = try await run([vol], env: env, recorder: recorder, list: [])
            #expect(recorder.events == ["create"], "\(vol.name)")
            #expect(warnings.isEmpty)
        }
    }

    @Test("nocopy is taken off the mount options")
    func splitNoCopy() {
        #expect(VolumeImageWrites.splitNoCopy(["ro", "nocopy"]) == (["ro"], true))
        #expect(VolumeImageWrites.splitNoCopy(["NoCopy"]) == ([], true))
        #expect(VolumeImageWrites.splitNoCopy(["ro"]) == (["ro"], false))
    }
}
