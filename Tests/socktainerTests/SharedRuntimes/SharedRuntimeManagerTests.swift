import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite(.timeLimit(.minutes(1))) struct SharedRuntimeManagerTests {
    static let socket = "/tmp/bridge-a.sock"
    static let group = RuntimeGroup(name: "mcp-catalog", kind: .exec, idleMinutes: 10, enabled: true)
    static let image = SharedRuntimeManager.Image(
        description: ImageDescription(
            reference: "docker.io/mcp/time:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 1)),
        platform: .current)

    static func key(_ value: String = "A=1") -> SharingKey {
        SharingKey(
            imageID: "sha256:abc",
            process: SharedRuntimeProcess(
                executable: "/server", arguments: [], environment: [value], workingDirectory: "/", user: .id(uid: 0, gid: 0)))
    }

    static func manager(
        _ client: FakeSharedRuntimeClient, socket: String = socket, sleeper: ManualSleeper = ManualSleeper(), suffix: String? = nil
    ) -> SharedRuntimeManager {
        let counter = Counter()
        return SharedRuntimeManager(
            client: client, socketPath: socket,
            launcherDirectory: { URL(fileURLWithPath: "/tmp/launcher") },
            sleep: { try await sleeper.sleep($0) },
            makeSuffix: { suffix.map { "\($0)\(counter.next())" } ?? "s\(counter.next())" })
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    // MARK: F-004 one container for one key

    @Test func concurrentFirstSessionsWithOneKeyCreateOneContainer() async throws {
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.holdCreates = true }
        let manager = Self.manager(client)
        let key = Self.key()

        async let first = manager.join(sessionID: "s1", group: Self.group, key: key, image: Self.image)
        async let second = manager.join(sessionID: "s2", group: Self.group, key: key, image: Self.image)
        async let third = manager.join(sessionID: "s3", group: Self.group, key: key, image: Self.image)
        await client.waitUntil { $0.createsInFlight == 1 }
        while await manager.joinsInProgress < 3 { await Task.yield() }
        #expect(await client.state.created.count == 1)

        await client.releaseCreates()
        let containers = try await [first, second, third]
        #expect(Set(containers.map(\.nativeID)).count == 1)
        #expect(await client.state.created.count == 1)
        #expect(await manager.sessionCount(of: containers[0].nativeID) == 3)
    }

    @Test func oneKeyInTwoGroupsGivesTwoContainersWithDifferentNames() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = Self.manager(client)
        let other = RuntimeGroup(name: "stdio-sessions", kind: .exec, idleMinutes: 10, enabled: true)
        let a = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        let b = try await manager.join(sessionID: "s2", group: other, key: Self.key(), image: Self.image)
        #expect(a.nativeID != b.nativeID)
        #expect(await client.state.created.count == 2)
        #expect(await client.state.created.map { $0.labels[SharedRuntimeLabels.sharedGroup] } == ["mcp-catalog", "stdio-sessions"])
    }

    @Test func oneKeyOnTwoBridgesGivesTwoContainersWithDifferentNames() async throws {
        let client = FakeSharedRuntimeClient()
        let bridgeA = Self.manager(client, socket: "/tmp/a.sock", suffix: "a")
        let bridgeB = Self.manager(client, socket: "/tmp/b.sock", suffix: "b")
        let a = try await bridgeA.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        let b = try await bridgeB.join(sessionID: "s2", group: Self.group, key: Self.key(), image: Self.image)
        #expect(a.nativeID != b.nativeID)
        #expect(await client.state.created.map { $0.labels[SharedRuntimeLabels.sharedSocket] } == ["/tmp/a.sock", "/tmp/b.sock"])
    }

    @Test func differentKeysGetDifferentContainers() async throws {
        let client = FakeSharedRuntimeClient()
        let manager = Self.manager(client)
        let a = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key("A=1"), image: Self.image)
        let b = try await manager.join(sessionID: "s2", group: Self.group, key: Self.key("A=2"), image: Self.image)
        #expect(a.nativeID != b.nativeID)
    }

    @Test func aContainerWithTheSameKeyLabelInTheRuntimeIsNeverJoined() async throws {
        let client = FakeSharedRuntimeClient()
        let key = Self.key()
        await client.configure {
            $0.records = [
                SharedRuntimeContainerRecord(
                    nativeID: "cs-shared-mcp-catalog-\(key.nameFragment)-old",
                    labels: [
                        SharedRuntimeLabels.sharedGroup: "mcp-catalog", SharedRuntimeLabels.sharedKey: key.labelValue,
                        SharedRuntimeLabels.sharedSocket: Self.socket,
                    ])
            ]
        }
        let manager = Self.manager(client)
        let container = try await manager.join(sessionID: "s1", group: Self.group, key: key, image: Self.image)
        #expect(container.nativeID != "cs-shared-mcp-catalog-\(key.nameFragment)-old")
        #expect(await client.state.created.count == 1)
    }

    @Test func aFailedCreationFailsEveryWaiterAndTheNextJoinTriesAgain() async throws {
        let client = FakeSharedRuntimeClient()
        await client.configure {
            $0.holdCreates = true
            $0.failCreates = true
        }
        let manager = Self.manager(client)
        let first = Task { try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image) }
        let second = Task { try await manager.join(sessionID: "s2", group: Self.group, key: Self.key(), image: Self.image) }
        await client.waitUntil { $0.createsInFlight == 1 }
        while await manager.joinsInProgress < 2 { await Task.yield() }
        await client.releaseCreates()
        await #expect(throws: FakeSharedRuntimeClient.Failure.self) { _ = try await first.value }
        await #expect(throws: FakeSharedRuntimeClient.Failure.self) { _ = try await second.value }

        await client.configure { $0.failCreates = false }
        _ = try await manager.join(sessionID: "s3", group: Self.group, key: Self.key(), image: Self.image)
        #expect(await client.state.created.count == 2)
    }

    // MARK: F-007 idle stop

    @Test func noStopBeforeTheLimit() async throws {
        let client = FakeSharedRuntimeClient()
        let sleeper = ManualSleeper()
        let manager = Self.manager(client, sleeper: sleeper)
        _ = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        await manager.leave(sessionID: "s1")
        await sleeper.waitUntil { $0.pending == [.seconds(600)] }
        #expect(await client.state.removed.isEmpty)
        #expect(await manager.runningContainers().count == 1)
    }

    @Test func stopAtTheLimit() async throws {
        let client = FakeSharedRuntimeClient()
        let sleeper = ManualSleeper()
        let manager = Self.manager(client, sleeper: sleeper)
        let container = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        await manager.leave(sessionID: "s1")
        await sleeper.waitUntil { $0.pending.count == 1 }
        sleeper.fireAll()
        await client.waitUntil { $0.removed == [container.nativeID] }
        #expect(await manager.runningContainers().isEmpty)
    }

    @Test func aContainerWithSessionsLeftIsNotStopped() async throws {
        let client = FakeSharedRuntimeClient()
        let sleeper = ManualSleeper()
        let manager = Self.manager(client, sleeper: sleeper)
        _ = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        _ = try await manager.join(sessionID: "s2", group: Self.group, key: Self.key(), image: Self.image)
        await manager.leave(sessionID: "s1")
        #expect(sleeper.snapshot.pending.isEmpty)
    }

    @Test func aJoinCancelsTheTimer() async throws {
        let client = FakeSharedRuntimeClient()
        let sleeper = ManualSleeper()
        let manager = Self.manager(client, sleeper: sleeper)
        let first = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        await manager.leave(sessionID: "s1")
        await sleeper.waitUntil { $0.pending.count == 1 }
        let second = try await manager.join(sessionID: "s2", group: Self.group, key: Self.key(), image: Self.image)
        await sleeper.waitUntil { $0.cancelled == 1 && $0.pending.isEmpty }
        #expect(first == second)
        sleeper.fireAll()
        #expect(await client.state.removed.isEmpty)
        #expect(await manager.runningContainers() == [first])
    }

    @Test func aJoinWhileTheStopRunsGetsANewContainer() async throws {
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.holdRemoves = true }
        let sleeper = ManualSleeper()
        let manager = Self.manager(client, sleeper: sleeper)
        let old = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        await manager.leave(sessionID: "s1")
        await sleeper.waitUntil { $0.pending.count == 1 }
        sleeper.fireAll()
        await client.waitUntil { $0.removesInFlight == 1 }

        let new = try await manager.join(sessionID: "s2", group: Self.group, key: Self.key(), image: Self.image)
        #expect(new.nativeID != old.nativeID)
        #expect(await client.state.created.count == 2)
        await client.releaseRemoves()
        await client.waitUntil { $0.removed == [old.nativeID] }
        #expect(await manager.runningContainers() == [new])
    }

    @Test func aFailedIdleRemovalIsRetried() async throws {
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.failRemoves = 2 }
        let sleeper = ManualSleeper()
        let manager = Self.manager(client, sleeper: sleeper)
        let container = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        await manager.leave(sessionID: "s1")
        await sleeper.waitUntil { $0.pending.count == 1 }
        sleeper.fireAll()
        for attempt in 1...2 {
            await client.waitUntil { $0.removeAttempts == attempt }
            await sleeper.waitUntil { $0.pending == [.seconds(5)] }
            sleeper.fireAll()
        }
        await client.waitUntil { $0.removed == [container.nativeID] }
        while await !manager.stoppingContainers().isEmpty { await Task.yield() }
    }

    @Test func aContainerThatCannotBeRemovedStaysKnownAndIsNotJoined() async throws {
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.failRemoves = 3 }
        let sleeper = ManualSleeper()
        let manager = Self.manager(client, sleeper: sleeper)
        let old = try await manager.join(sessionID: "s1", group: Self.group, key: Self.key(), image: Self.image)
        await manager.leave(sessionID: "s1")
        await sleeper.waitUntil { $0.pending.count == 1 }
        sleeper.fireAll()
        for attempt in 1...2 {
            await client.waitUntil { $0.removeAttempts == attempt }
            await sleeper.waitUntil { $0.pending == [.seconds(5)] }
            sleeper.fireAll()
        }
        await client.waitUntil { $0.removeAttempts == 3 }
        while await manager.stoppingContainers() != [old.nativeID] { await Task.yield() }
        let new = try await manager.join(sessionID: "s2", group: Self.group, key: Self.key(), image: Self.image)
        #expect(new.nativeID != old.nativeID)
    }

    @Test func idleMinutesZeroMeansNever() async throws {
        let client = FakeSharedRuntimeClient()
        let sleeper = ManualSleeper()
        let manager = Self.manager(client, sleeper: sleeper)
        let never = RuntimeGroup(name: "mcp-catalog", kind: .exec, idleMinutes: 0, enabled: true)
        _ = try await manager.join(sessionID: "s1", group: never, key: Self.key(), image: Self.image)
        await manager.leave(sessionID: "s1")
        #expect(sleeper.snapshot.pending.isEmpty)
        #expect(await manager.runningContainers().count == 1)
    }

    // MARK: F-012 cleanup at start

    @Test func cleanupRemovesOnlyTheContainersOfThisSocket() async throws {
        let client = FakeSharedRuntimeClient()
        await client.configure {
            $0.records = [
                SharedRuntimeContainerRecord(nativeID: "ours", labels: [SharedRuntimeLabels.sharedSocket: Self.socket]),
                SharedRuntimeContainerRecord(nativeID: "theirs", labels: [SharedRuntimeLabels.sharedSocket: "/tmp/other.sock"]),
                SharedRuntimeContainerRecord(nativeID: "plain", labels: [:]),
            ]
        }
        let removed = try await Self.manager(client).cleanupAtStart()
        #expect(removed == ["ours"])
        #expect(await client.state.removed == ["ours"])
    }

    @Test func cleanupFailsWhenTheListFails() async {
        let client = FakeSharedRuntimeClient()
        await client.configure { $0.failList = true }
        await #expect(throws: FakeSharedRuntimeClient.Failure.self) { try await Self.manager(client).cleanupAtStart() }
    }
}
