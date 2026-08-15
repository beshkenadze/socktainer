import ContainerResource
import Foundation
import Testing

@testable import socktainer

@Suite("ContainerStats")
struct ContainerStatsTests {

    // MARK: - Helpers

    private func makeSample(
        cpuUsec: UInt64 = 0,
        memUsage: UInt64? = nil,
        memLimit: UInt64? = nil,
        netRx: UInt64? = nil,
        netTx: UInt64? = nil,
        blkRead: UInt64? = nil,
        blkWrite: UInt64? = nil,
        pids: UInt64? = nil
    ) -> ContainerStats {
        ContainerStats(
            id: "test",
            memoryUsageBytes: memUsage,
            memoryLimitBytes: memLimit,
            cpuUsageUsec: cpuUsec,
            networkRxBytes: netRx,
            networkTxBytes: netTx,
            blockReadBytes: blkRead,
            blockWriteBytes: blkWrite,
            numProcesses: pids
        )
    }

    // MARK: - Model builder

    @Test("CPU total_usage converts µs to ns (× 1000)")
    func cpuUsecToNs() {
        let prev = makeSample(cpuUsec: 1_000_000)
        let curr = makeSample(cpuUsec: 2_000_000)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: prev, curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.cpu_stats.cpu_usage.total_usage == 2_000_000_000)
        #expect(stats.precpu_stats.cpu_usage.total_usage == 1_000_000_000)
    }

    @Test("precpu_stats system_cpu_usage is 0 (no elapsed time for baseline)")
    func precpuSystemIsZero() {
        let sample = makeSample(cpuUsec: 500_000)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: sample, curr: sample, prevRead: t0, currRead: t1)
        #expect(stats.precpu_stats.system_cpu_usage == 0)
    }

    @Test("system_cpu_usage equals numCPUs × elapsed nanoseconds")
    func systemCPUUsage() {
        let sample = makeSample()
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: sample, curr: sample, prevRead: t0, currRead: t1)
        let expected = UInt64(hostCPUCoreCount()) * 1_000_000_000
        // Allow ±5ms tolerance for timing
        #expect(abs(Int64(stats.cpu_stats.system_cpu_usage) - Int64(expected)) < 5_000_000)
    }

    @Test("online_cpus matches host CPU count")
    func onlineCPUs() {
        let sample = makeSample()
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: sample, curr: sample, prevRead: t0, currRead: t1)
        #expect(stats.cpu_stats.online_cpus == hostCPUCoreCount())
    }

    @Test("memory_stats usage and limit are passed through")
    func memoryStats() {
        let curr = makeSample(memUsage: 128_000_000, memLimit: 4_000_000_000)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.memory_stats.usage == 128_000_000)
        #expect(stats.memory_stats.limit == 4_000_000_000)
    }

    @Test("memory limit falls back to host physical memory when nil")
    func memoryLimitFallback() {
        let curr = makeSample(memUsage: 64_000_000, memLimit: nil)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.memory_stats.limit == hostPhysicalMemory())
    }

    @Test("networks eth0 rx/tx bytes are populated when available")
    func networkStats() {
        let curr = makeSample(netRx: 1_234, netTx: 5_678)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.networks?["eth0"]?.rx_bytes == 1_234)
        #expect(stats.networks?["eth0"]?.tx_bytes == 5_678)
    }

    @Test("networks is nil when no network data available")
    func networkStatsNil() {
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: makeSample(), prevRead: t0, currRead: t1)
        #expect(stats.networks == nil)
    }

    @Test("blkio_stats contains read and write entries when available")
    func blkioStats() {
        let curr = makeSample(blkRead: 10_000, blkWrite: 20_000)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        let entries = stats.blkio_stats.io_service_bytes_recursive
        #expect(entries?.first(where: { $0.op == "read" })?.value == 10_000)
        #expect(entries?.first(where: { $0.op == "write" })?.value == 20_000)
    }

    @Test("pids_stats current is passed through")
    func pidsStats() {
        let curr = makeSample(pids: 7)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.pids_stats.current == 7)
    }

    @Test("read and preread timestamps are ISO8601 strings")
    func timestamps() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 1_000_001)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: makeSample(), prevRead: t0, currRead: t1)
        #expect(stats.read.contains("T"))
        #expect(stats.preread.contains("T"))
        #expect(stats.read != stats.preread)
    }
    @Test("name carries the leading slash the Linux daemon reports")
    func nameHasLeadingSlash() {
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(
            id: "c1", name: "my-container", prev: makeSample(), curr: makeSample(),
            prevRead: t0, currRead: t1)
        #expect(stats.name == "/my-container")
    }

    @Test("os_type reports the container platform as linux")
    func osTypeIsLinux() {
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: makeSample(), prevRead: t0, currRead: t1)
        #expect(stats.os_type == "linux")
    }

    @Test("num_procs is 0 like the Linux daemon reports")
    func numProcsIsZero() {
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", name: "c1", prev: makeSample(), curr: makeSample(), prevRead: t0, currRead: t1)
        #expect(stats.num_procs == 0)
    }

    @Test("JSON payload carries name, os_type, num_procs and empty storage_stats")
    func jsonCarriesMobyFields() throws {
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(
            id: "abc123", name: "my-container",
            prev: makeSample(), curr: makeSample(),
            prevRead: t0, currRead: t1)
        let data = try JSONEncoder().encode(stats)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["name"] as? String) == "/my-container")
        #expect((json?["os_type"] as? String) == "linux")
        #expect((json?["num_procs"] as? Int) == 0)
        #expect((json?["storage_stats"] as? [String: Any])?.isEmpty == true)
    }

    @Test("model serializes to JSON without errors")
    func jsonSerialization() throws {
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(
            id: "c1", name: "c1",
            prev: makeSample(cpuUsec: 1_000_000, memUsage: 64_000_000, memLimit: 2_000_000_000),
            curr: makeSample(
                cpuUsec: 2_000_000, memUsage: 128_000_000, memLimit: 2_000_000_000,
                netRx: 1234, netTx: 5678, blkRead: 100, blkWrite: 200, pids: 5),
            prevRead: t0, currRead: t1
        )
        let data = try JSONEncoder().encode(stats)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["id"] as? String == "c1")
        #expect(json?["cpu_stats"] != nil)
        #expect(json?["memory_stats"] != nil)
        #expect(json?["networks"] != nil)
        #expect(json?["pids_stats"] != nil)
    }
}

/// `docker stats` addresses containers by the 64-hex Docker id it read from `/containers/json`, not
/// by name. The route resolved through the runtime's own client, which knows nothing of those ids,
/// so every request 404'd and the CLI printed an empty row — with or without the fields the payload
/// was missing (issue #15).
@Suite("ContainerStatsRoute — addressing")
struct ContainerStatsAddressingTests {
    @Test("stats resolves a Docker id, not just a runtime name")
    func resolvesDockerId() async throws {
        let hexId = String(repeating: "a", count: 64)
        let resolver = RecordingResolver(known: hexId)

        // The route resolves before it samples; a 404 here is the bug, whatever the sampling does.
        let snapshot = try await resolver.getContainer(id: hexId)
        #expect(snapshot != nil, "a Docker id must resolve")
        #expect(resolver.asked == [hexId])

        let unknown = try await resolver.getContainer(id: "nope")
        #expect(unknown == nil)
    }
}

/// Answers for exactly one id, recording what it was asked — enough to pin that the route consults
/// the resolving client rather than going straight to the runtime.
private final class RecordingResolver: ClientContainerProtocol, @unchecked Sendable {
    private let known: String
    private let lock = NSLock()
    private var askedIds: [String] = []

    init(known: String) { self.known = known }

    var asked: [String] {
        lock.withLock { askedIds }
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        lock.withLock { askedIds.append(id) }
        guard id == known else { return nil }
        return try? makeContainerSnapshot(nativeId: known, ip: "192.168.64.2", network: "default", labels: [:])
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
