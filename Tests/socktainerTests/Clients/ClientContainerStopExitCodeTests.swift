import Testing

@testable import socktainer

struct ClientContainerStopExitCodeTests {
    @Test("a signal that races with process exit still allows cleanup", arguments: ["SIGTERM", "SIGKILL"])
    func signalFailureStillAllowsCleanup(failedSignal: String) async throws {
        let runtime = StopRuntime(code: 0)
        try await ClientContainerService.stopPreservingExitCode(
            signal: "SIGTERM",
            timeout: .zero,
            sendSignal: { signal in
                if signal == failedSignal { throw WaitUnavailable() }
                await runtime.signal(signal)
            },
            waitForExit: {
                try await Task.sleep(for: .seconds(60))
                return -1
            },
            stop: { await runtime.stop() }
        )
        #expect(await runtime.stopped)
    }

    @Test("stop records a forced exit before cleanup when the first signal is ignored")
    func recordsForcedExitBeforeCleanup() async throws {
        let runtime = StopRuntime(code: 137, ignoresTerm: true)
        try await ClientContainerService.stopPreservingExitCode(
            signal: "SIGTERM",
            timeout: .zero,
            sendSignal: { await runtime.signal($0) },
            waitForExit: { try await runtime.wait() },
            stop: { await runtime.stop() }
        )
        #expect(await runtime.recordedCode == 137)
        #expect(await runtime.signals == ["SIGTERM", "SIGKILL"])
        #expect(await runtime.stopped)
    }

    @Test("stop still cleans up when no exit recorder is available")
    func cleansUpWithoutRecorder() async throws {
        let runtime = StopRuntime(code: 137)
        try await ClientContainerService.stopPreservingExitCode(
            signal: "SIGTERM",
            timeout: .zero,
            sendSignal: { await runtime.signal($0) },
            waitForExit: {
                try await Task.sleep(for: .seconds(60))
                return -1
            },
            stop: { await runtime.stop() }
        )
        #expect(await runtime.stopped)
        #expect(await runtime.recordedCode == nil)
    }

    @Test("stop records the observed exit before runtime cleanup", arguments: [Int32(0), 137, 143])
    func recordsExitBeforeCleanup(code: Int32) async throws {
        let runtime = StopRuntime(code: code)
        try await ClientContainerService.stopPreservingExitCode(
            signal: "SIGTERM",
            timeout: .seconds(5),
            sendSignal: { await runtime.signal($0) },
            waitForExit: { try await runtime.wait() },
            stop: { await runtime.stop() }
        )
        #expect(await runtime.recordedCode == code)
        #expect(await runtime.signals == ["SIGTERM"])
        #expect(await runtime.stopped)
    }
}

private actor StopRuntime {
    let code: Int32
    let ignoresTerm: Bool
    var signals: [String] = []
    var stopped = false
    var recordedCode: Int32?

    init(code: Int32, ignoresTerm: Bool = false) {
        self.code = code
        self.ignoresTerm = ignoresTerm
    }

    func signal(_ signal: String) { signals.append(signal) }

    func wait() async throws -> Int32 {
        while ignoresTerm && !signals.contains("SIGKILL") {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !stopped, !signals.isEmpty else { throw WaitUnavailable() }
        recordedCode = code
        return code
    }

    func stop() { stopped = true }
}

private struct WaitUnavailable: Error {}
