import ContainerPersistence
import Foundation
import Logging
import Vapor

struct SharedRuntimeServiceKey: StorageKey {
    typealias Value = SharedRuntimeService
}

/// Shared runtime groups of a bridge that runs with `--shared-runtimes`. Without the flag there is
/// no instance, and no code of the feature runs (F-014).
///
/// No session is admitted before cleanup at start has finished (F-012). If the cleanup fails or
/// does not finish in its time limit, grouping stays off for this run of the bridge.
actor SharedRuntimeService {
    enum Status: Equatable, Sendable {
        case on(RuntimeGroupsDocument)
        case off(cause: String)
    }

    static let infoLabelKey = "containerstack.shared-runtimes"

    let manager: SharedRuntimeManager
    let file: RuntimeGroupsFile
    let imageFacts: SharedRuntimeImageFacts
    private let cleanupTimeout: Duration
    /// Runs the cleanup with a time limit and returns whether it finished in time.
    typealias Bounded = @Sendable (Duration, @escaping @Sendable () async -> Void) async -> Bool
    private let bounded: Bounded

    private enum Cleanup {
        case notStarted
        case running(Task<Void, Never>)
        case finished(cause: String?)
    }

    private var cleanup = Cleanup.notStarted

    init(
        manager: SharedRuntimeManager,
        file: RuntimeGroupsFile,
        imageFacts: SharedRuntimeImageFacts,
        cleanupTimeout: Duration = .seconds(30),
        timerSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        bounded: Bounded? = nil
    ) {
        self.manager = manager
        self.file = file
        self.imageFacts = imageFacts
        self.cleanupTimeout = cleanupTimeout
        self.bounded = bounded ?? { timeout, work in await StartupHousekeeping.runBounded(timeout: timeout, sleep: timerSleep, work) }
    }

    /// Installs the service when `enabled` and starts the cleanup at start. Without the flag it
    /// does nothing.
    static func install(
        on app: Application, enabled: Bool, containers: ClientContainerProtocol, make: () -> SharedRuntimeService
    ) async {
        guard enabled else { return }
        let service = make()
        app.storage[SharedRuntimeServiceKey.self] = service
        app.regexRouter.interceptor = { req, method, pattern in
            try await SharedRuntimeRouter.intercept(req, method: method, pattern: pattern, service: service, containers: containers)
        }
        await service.startCleanup()
    }

    /// The limit of the cleanup at shutdown. ContainerStack sends SIGTERM and sends SIGKILL 500 ms
    /// later: the bridge ends by itself before that.
    static let shutdownLimit = Duration.milliseconds(400)

    /// Deletes the shared containers of this bridge, waiting at most `shutdownLimit`. The delete
    /// requests go out at once; what is left after a SIGKILL, the cleanup at the next start removes.
    struct ShutdownReport: Sendable, CustomStringConvertible {
        let containers: Int
        /// False when the limit passed before every delete was answered.
        let completed: Bool
        let elapsed: Duration

        var description: String {
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            return "deleted \(containers) shared container(s) in \(ms) ms\(completed ? "" : " (limit reached, deletes still pending)")"
        }
    }

    func shutdown(limit: Duration = SharedRuntimeService.shutdownLimit) async -> ShutdownReport {
        let start = ContinuousClock.now
        let done = SessionLatch<Bool>()
        let manager = self.manager
        let containers = await manager.sharedContainerCount
        Task {
            await manager.shutdown()
            done.resolve(true)
        }
        let completed = await done.wait(limit: limit) != nil
        return ShutdownReport(containers: containers, completed: completed, elapsed: ContinuousClock.now - start)
    }

    /// The service of a bridge on Apple Container.
    static func live(
        appSupport: URL, socketPath: String, logger: Logger, systemConfig: ContainerSystemConfig, events: EventBroadcaster
    ) -> SharedRuntimeService {
        let launcherDirectory = SharedRuntimeLauncher.directory(appSupport: appSupport)
        let source = PackagedLauncherSource()
        let idleMinute =
            ProcessInfo.processInfo.environment["SOCKTAINER_SHARED_RUNTIMES_IDLE_MINUTE_SECONDS"]
            .flatMap(Int.init).map { Duration.seconds($0) } ?? .seconds(60)
        let manager = SharedRuntimeManager(
            client: ContainerSharedRuntimeClient(logger: logger),
            socketPath: socketPath,
            launcherDirectory: { try SharedRuntimeLauncher.install(from: source, into: launcherDirectory) },
            idleMinute: idleMinute,
            onEvent: { await events.broadcast($0) })
        return SharedRuntimeService(manager: manager, file: RuntimeGroupsFile(), imageFacts: LocalImageFacts(systemConfig: systemConfig))
    }

    func startCleanup() {
        guard case .notStarted = cleanup else { return }
        let manager = self.manager
        let timeout = cleanupTimeout
        let bounded = self.bounded
        let task = Task {
            let outcome = CleanupOutcome()
            let finished = await bounded(timeout) {
                do {
                    try await manager.cleanupAtStart()
                } catch {
                    outcome.cause = "shared containers of a previous run could not be removed: \(error)"
                }
            }
            // Only the winner of the time limit decides: a cleanup that ends after it does not
            // turn grouping on.
            let cause = finished ? outcome.cause : "the removal of shared containers of a previous run did not finish within \(timeout)"
            self.finishCleanup(cause: cause)
        }
        cleanup = .running(task)
    }

    /// The status for a `create`: waits for the cleanup at start, then reads the file.
    func admission() async -> Status {
        if case .running(let task) = cleanup { await task.value }
        return await status()
    }

    /// The status for `/info`; it does not wait for the cleanup at start.
    func status() async -> Status {
        switch cleanup {
        case .notStarted, .running:
            return .off(cause: "the removal of shared containers of a previous run has not finished")
        case .finished(let cause?):
            return .off(cause: cause)
        case .finished(nil):
            switch await file.current() {
            case .active(let document): return .on(document)
            case .off(let cause): return .off(cause: cause)
            }
        }
    }

    /// The `/info` label and warning with `--shared-runtimes` (spec §3.2a).
    func infoEntries() async -> (label: String, warning: String?) {
        switch await status() {
        case .on: ("\(Self.infoLabelKey)=on", nil)
        case .off(let cause): ("\(Self.infoLabelKey)=off", "shared runtimes are off: \(cause)")
        }
    }

    private func finishCleanup(cause: String?) {
        cleanup = .finished(cause: cause)
    }
}

private final class CleanupOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    var cause: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
