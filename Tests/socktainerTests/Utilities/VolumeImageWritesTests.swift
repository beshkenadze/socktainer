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
    private static let postgres = ["PGDATA=/data"]

    /// Records every call in order, answers the verdicts it is given, and fails the copy-ups it
    /// is told to fail.
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

        func copyUp(_ volumes: [(source: String, destination: String)], into container: ContainerSnapshot) -> [String: String] {
            for volume in volumes {
                record("copy-up \(volume.source) from \(volume.destination)")
            }
            return failing
        }
    }

    private func volume(_ name: String, at destination: String = "/data", noCopy: Bool = false) -> VolumeImageWrites.Volume {
        VolumeImageWrites.Volume(name: name, source: "/vols/\(name)/volume.img", destination: destination, labels: [:], noCopy: noCopy)
    }

    private func snapshot(_ id: String, mounts: [Filesystem] = []) throws -> ContainerSnapshot {
        var snapshot = try makeContainerSnapshot(nativeId: id, networks: [], labels: [:])
        snapshot.configuration.mounts = mounts
        return snapshot
    }

    private func mount(_ name: String) -> Filesystem {
        .volume(name: name, format: "ext4", source: "/vols/\(name)/volume.img", destination: "/x", options: [])
    }

    /// Runs `create`. The container list answers from `lists` in turn (nil: that call fails;
    /// past the end: it fails).
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
                let next: [ContainerSnapshot]?? = answers.withLock { $0.isEmpty ? .none : .some($0.removeFirst()) }
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

    @Test("nothing is written before the native create; an empty volume is filled after it")
    func order() async throws {
        let v = volume("pg")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        let warnings = try await run([v], recorder: recorder, lists: [[try snapshot("new", mounts: [mount("pg")])]])
        #expect(recorder.events == ["create", "list", "copy-up \(v.source) from /data"])
        #expect(warnings.isEmpty)
    }

    @Test("a native create that fails gets no list and no write")
    func failedCreateWritesNothing() async throws {
        let v = volume("pg")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        await #expect(throws: CancellationError.self) {
            _ = try await run([v], recorder: recorder, lists: [[]], createFails: true)
        }
        #expect(recorder.events == ["create"])
    }

    @Test("a failed list is tried three times; when it then answers, the copy-up runs")
    func listIsRetried() async throws {
        let v = volume("v")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        let warnings = try await run([v], recorder: recorder, lists: [nil, nil, []])
        #expect(recorder.events == ["create", "list", "list", "list", "copy-up \(v.source) from /data"])
        #expect(warnings.isEmpty)
    }

    @Test("no write when the list fails three times, and a warning that says so")
    func listFailureMeansNoWrite() async throws {
        let v = volume("pg")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
        let warnings = try await run([v], recorder: recorder, lists: [nil, nil, nil])
        #expect(recorder.events == ["create", "list", "list", "list"])
        #expect(warnings.count == 1 && warnings[0].contains("the container list could not be read"))
    }

    @Test("no write to a volume that another container names, by name or as a block device, and a warning")
    func namedElsewhereMeansNoWrite() async throws {
        let v = volume("shared")
        let byName = try snapshot("other", mounts: [mount("shared")])
        let byPath = try snapshot("alias", mounts: [.block(format: "ext4", source: v.source, destination: "/y", options: [])])
        for holder in [byName, byPath] {
            let recorder = Recorder([v.source: .replaceable(hasLostFound: true)])
            let warnings = try await run([v], recorder: recorder, lists: [[holder]])
            #expect(recorder.events == ["create", "list"], "holder \(holder.id)")
            #expect(warnings.count == 1 && warnings[0].contains("another container names it"))
        }
    }

    @Test("a volume with data gets no list, no write and no warning; one that cannot be judged gets a warning")
    func verdictsDecide() async throws {
        let data = volume("data")
        let doubt = volume("doubt")
        let recorder = Recorder([data.source: .holdsData, doubt.source: .doubtful("not marked clean")])
        let warnings = try await run([data, doubt], recorder: recorder, lists: [[]])
        #expect(recorder.events == ["create"])
        #expect(warnings.count == 1 && warnings[0].contains("\"doubt\"") && warnings[0].contains("not marked clean"))
    }

    @Test("a copy-up that fails gives a warning with its reason")
    func failedCopyUpWarns() async throws {
        let v = volume("v")
        let recorder = Recorder([v.source: .replaceable(hasLostFound: true)], failing: [v.source: "the copy-up failed: disk full"])
        let warnings = try await run([v], recorder: recorder, lists: [[]])
        #expect(recorder.events == ["create", "list", "copy-up \(v.source) from /data"])
        #expect(warnings.count == 1 && warnings[0].contains("disk full"))
    }

    @Test("nocopy: the volume is not touched; Postgres at its root with /lost+found gets a warning")
    func noCopyWritesNothing() async throws {
        let pg = volume("pg", noCopy: true)
        var recorder = Recorder([pg.source: .replaceable(hasLostFound: true)])
        var warnings = try await run([pg], recorder: recorder, lists: [[]])
        #expect(recorder.events == ["create"])
        #expect(warnings.count == 1 && warnings[0].contains("nocopy is set") && warnings[0].contains("its /lost+found directory was not removed"))
        #expect(!warnings[0].contains("were not copied"))

        // No warning: PGDATA elsewhere, no PGDATA, or no /lost+found.
        for (env, verdict) in [
            (["PGDATA=/data/sub"], VolumeImageEligibility.Verdict.replaceable(hasLostFound: true)),
            (["FOO=1"], .replaceable(hasLostFound: true)),
            (Self.postgres, .replaceable(hasLostFound: false)),
        ] {
            recorder = Recorder([pg.source: verdict])
            warnings = try await run([pg], env: env, recorder: recorder, lists: [[]])
            #expect(recorder.events == ["create"])
            #expect(warnings.isEmpty, "\(env) \(verdict)")
        }
    }

    @Test("a volume mounted at two paths is prepared once, from its first mount")
    func onePlanPerVolume() async throws {
        let first = volume("v", at: "/etc")
        let second = volume("v", at: "/data", noCopy: true)
        var recorder = Recorder([first.source: .replaceable(hasLostFound: true)])
        _ = try await run([first, second], recorder: recorder, lists: [[]])
        #expect(recorder.events == ["create", "list", "copy-up \(first.source) from /etc"])

        // The first mount has nocopy: the volume is not touched, whatever the second asks.
        recorder = Recorder([first.source: .replaceable(hasLostFound: true)])
        _ = try await run([second, first], env: [], recorder: recorder, lists: [[]])
        #expect(recorder.events == ["create"])
    }

    @Test("the warning names /lost+found as present only when the check saw it")
    func warningSaysWhatIsKnown() {
        let v = volume("v")
        let seen = VolumeImageWrites.notPrepared(v, reason: "r", verdict: .replaceable(hasLostFound: true))
        #expect(seen.contains("files at /data were not copied") && seen.contains("its /lost+found directory was not removed"))
        let absent = VolumeImageWrites.notPrepared(v, reason: "r", verdict: .replaceable(hasLostFound: false))
        #expect(!absent.contains("lost+found directory"))
        let unknown = VolumeImageWrites.notPrepared(v, reason: "r", verdict: .doubtful("x"))
        #expect(unknown.contains("a /lost+found directory, if it has one, was not removed"))
    }

    @Test("nocopy is taken off the mount options")
    func splitNoCopy() {
        #expect(VolumeImageWrites.splitNoCopy(["ro", "nocopy"]) == (["ro"], true))
        #expect(VolumeImageWrites.splitNoCopy(["NoCopy"]) == ([], true))
        #expect(VolumeImageWrites.splitNoCopy(["ro"]) == (["ro"], false))
    }

    @Test("an anonymous long-form mount keeps NoCopy")
    func anonymousNoCopy() throws {
        let mount = try JSONDecoder().decode(
            Mount.self, from: Data(#"{"Type":"volume","Target":"/etc","VolumeOptions":{"NoCopy":true}}"#.utf8))
        let parsed = try ContainerCreateRoute.anonymousVolume(for: mount)
        #expect(VolumeImageWrites.splitNoCopy(parsed.options).noCopy)
    }
}
