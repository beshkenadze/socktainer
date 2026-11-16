import ContainerResource
import ContainerizationOCI
import Foundation

/// Owns the shared containers of this bridge (spec §3.4): one container for one group and one
/// sharing key (F-004), idle stop (F-007) and cleanup at start (F-012).
///
/// A container is `starting` or `running` in `slots`. When it starts to stop it leaves `slots`,
/// so a join for its key creates a new container under a new name suffix. Each state change is
/// written before the next `await`, because an actor runs other calls while one is suspended.
actor SharedRuntimeManager {
    struct SharedContainer: Sendable, Equatable {
        let nativeID: String
        let dockerID: String
        let group: String
        let key: SharingKey
    }

    struct Image: Sendable {
        let description: ImageDescription
        let platform: Platform
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case cleanupFailed([String])

        var description: String {
            switch self {
            case .cleanupFailed(let ids): "could not remove shared containers of a previous run: \(ids.joined(separator: ", "))"
            }
        }
    }

    /// The full sharing key, not the 16-character label value.
    private struct Slot: Hashable {
        let group: String
        let key: String
    }

    private struct Running {
        let container: SharedContainer
        var sessions: Set<String> = []
        var idleMinutes: Int
        var idleTimer: Task<Void, Never>?
        var generation = 0
    }

    private enum Entry {
        case starting(id: UUID, task: Task<SharedContainer, Error>)
        case running(Running)
    }

    private let client: SharedRuntimeClient
    private let socketPath: String
    private let launcherDirectory: @Sendable () async throws -> URL
    private let sleep: @Sendable (Duration) async throws -> Void
    private let idleMinute: Duration
    private let makeSuffix: @Sendable () -> String

    private var slots: [Slot: Entry] = [:]
    private var sessionSlots: [String: Slot] = [:]
    private var stopping: Set<String> = []
    private(set) var joinsInProgress = 0

    /// - Parameter idleMinute: the length of one minute of `idleMinutes`; tests and the live check
    ///   make it shorter.
    init(
        client: SharedRuntimeClient,
        socketPath: String,
        launcherDirectory: @escaping @Sendable () async throws -> URL,
        idleMinute: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        makeSuffix: @escaping @Sendable () -> String = { String(UUID().uuidString.lowercased().prefix(8)) }
    ) {
        self.client = client
        self.socketPath = socketPath
        self.launcherDirectory = launcherDirectory
        self.idleMinute = idleMinute
        self.sleep = sleep
        self.makeSuffix = makeSuffix
    }

    /// Adds a session to the container of `group` and `key`, and creates the container when there
    /// is none. Concurrent joins for one key wait for one creation.
    func join(sessionID: String, group: RuntimeGroup, key: SharingKey, image: Image) async throws -> SharedContainer {
        joinsInProgress += 1
        defer { joinsInProgress -= 1 }
        let slot = Slot(group: group.name, key: key.hex)
        while true {
            switch slots[slot] {
            case .running(var running):
                running.sessions.insert(sessionID)
                running.idleTimer?.cancel()
                running.idleTimer = nil
                running.generation += 1
                running.idleMinutes = group.idleMinutes
                slots[slot] = .running(running)
                sessionSlots[sessionID] = slot
                return running.container
            case .starting(let id, let task):
                let result = await task.result
                finishStart(slot: slot, id: id, result: result, idleMinutes: group.idleMinutes)
                if case .failure(let error) = result { throw error }
            case nil:
                let task = startContainer(group: group.name, key: key, image: image)
                slots[slot] = .starting(id: UUID(), task: task)
            }
        }
    }

    /// Removes a session. The last session of a container starts its idle timer.
    func leave(sessionID: String) {
        guard let slot = sessionSlots.removeValue(forKey: sessionID), case .running(var running) = slots[slot] else { return }
        running.sessions.remove(sessionID)
        if running.sessions.isEmpty, running.idleMinutes > 0, running.idleTimer == nil {
            running.generation += 1
            let generation = running.generation
            let delay = idleMinute * running.idleMinutes
            let sleep = self.sleep
            running.idleTimer = Task {
                do { try await sleep(delay) } catch { return }
                await self.idleExpired(slot: slot, generation: generation)
            }
        }
        slots[slot] = .running(running)
    }

    /// Removes the shared containers that carry this bridge's socket label and that this manager
    /// does not own: those of a previous run of the bridge.
    @discardableResult
    func cleanupAtStart() async throws -> [String] {
        let owned = ownedContainerIDs()
        let leftovers = try await client.listContainers()
            .filter { $0.labels[SharedRuntimeLabels.sharedSocket] == socketPath && !owned.contains($0.nativeID) }
            .map(\.nativeID)
        var failed: [String] = []
        for id in leftovers {
            do {
                try await client.removeSharedContainer(nativeID: id)
            } catch {
                failed.append(id)
            }
        }
        if !failed.isEmpty { throw Failure.cleanupFailed(failed) }
        return leftovers
    }

    /// The containers that sessions can join now.
    func runningContainers() -> [SharedContainer] {
        slots.values.compactMap {
            if case .running(let running) = $0 { return running.container }
            return nil
        }
    }

    func sessionCount(of nativeID: String) -> Int {
        for case .running(let running) in slots.values where running.container.nativeID == nativeID {
            return running.sessions.count
        }
        return 0
    }

    private func startContainer(group: String, key: SharingKey, image: Image) -> Task<SharedContainer, Error> {
        let client = self.client
        let socketPath = self.socketPath
        let launcherDirectory = self.launcherDirectory
        let suffix = makeSuffix()
        return Task {
            let spec = SharedContainerSpec.make(
                group: group, key: key, socketPath: socketPath, image: image.description, platform: image.platform,
                launcherDirectory: try await launcherDirectory(), suffix: suffix)
            try await client.createSharedContainer(spec)
            return SharedContainer(nativeID: spec.name, dockerID: spec.dockerID, group: group, key: key)
        }
    }

    /// Records the end of a creation once; every waiter calls it, the first one wins.
    private func finishStart(slot: Slot, id: UUID, result: Result<SharedContainer, Error>, idleMinutes: Int) {
        guard case .starting(let current, _) = slots[slot], current == id else { return }
        switch result {
        case .success(let container): slots[slot] = .running(Running(container: container, idleMinutes: idleMinutes))
        case .failure: slots[slot] = nil
        }
    }

    private func idleExpired(slot: Slot, generation: Int) {
        guard case .running(let running) = slots[slot], running.generation == generation, running.sessions.isEmpty else { return }
        slots[slot] = nil
        let id = running.container.nativeID
        stopping.insert(id)
        let client = self.client
        let sleep = self.sleep
        Task {
            var removed = false
            for attempt in 1...Self.removalAttempts {
                do {
                    try await client.removeSharedContainer(nativeID: id)
                    removed = true
                    break
                } catch {
                    if attempt < Self.removalAttempts { try? await sleep(Self.removalRetryDelay) }
                }
            }
            await self.stopFinished(id, removed: removed)
        }
    }

    static let removalAttempts = 3
    static let removalRetryDelay = Duration.seconds(5)

    /// A container that could not be removed stays in `stopping`: no session joins it, and the
    /// cleanup at the next start of the bridge removes it by its socket label.
    private func stopFinished(_ id: String, removed: Bool) {
        if removed { stopping.remove(id) }
    }

    func stoppingContainers() -> Set<String> { stopping }

    private func ownedContainerIDs() -> Set<String> {
        stopping.union(runningContainers().map(\.nativeID))
    }
}
