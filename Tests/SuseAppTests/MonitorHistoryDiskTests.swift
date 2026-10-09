import Foundation
import Testing
import SuseCore
@testable import Suse

struct MonitorHistoryDiskTests {
    @Test func chartBucketsRetainExactPeaksWithoutDoubleCountingOrClippingEdges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = MonitorHistoryDisk(url: folder.appendingPathComponent("monitor.sqlite"))
        let now = Date(timeIntervalSince1970: 200_000)
        let start = now.addingTimeInterval(-3600)
        for index in 0..<360 {
            var sample = SystemMetricsSnapshot()
            sample.sampledAt = start.addingTimeInterval(Double(index) * 10)
            sample.sampleInterval = 10; sample.cpu = index == 60 ? 0.95 : 0.1
            sample.network = .init(incoming: 100, outgoing: 20)
            try await disk.append(sample, now: now)
            if index == 60 { try await disk.append(sample, now: now) }
        }
        let records = try await disk.chartSamples(from: start.addingTimeInterval(5), to: now, now: now)
        let total = records.reduce(0.0) { $0 + ($1.historyAggregates[.download]?.weightedSum ?? ($1.network!.incoming * $1.sampleInterval)) }
        #expect(total == 359_000)
        let points = MonitorHistory.points(records, series: .cpu, from: start, to: now)
        #expect(points.compactMap(\.maximum).max() == 0.95)
        #expect(points.first { $0.maximum == 0.95 }?.peakTime == start.addingTimeInterval(600))
        #expect(!points.contains { $0.value == nil })
        #expect(try await disk.snapshot(at: start.addingTimeInterval(600), now: now)?.cpu == 0.95)
    }

    @Test func persistsPrivateSnapshotsAndRestoresExitedProcesses() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("monitor.sqlite")
        let now = Date(timeIntervalSince1970: 200_000)
        var sample = SystemMetricsSnapshot()
        sample.sampledAt = now.addingTimeInterval(-10)
        sample.sampleInterval = 5
        sample.cpu = 0.75
        let process = SystemProcessSample(id: .init(pid: 42, startedAt: 100), name: "Synthetic worker", cpu: 0.5, memory: 1024)
        sample.processes = [process]
        let disk = MonitorHistoryDisk(url: url)
        try await disk.append(sample, now: now)
        let reopened = MonitorHistoryDisk(url: url)
        let restored = try #require(try await reopened.snapshot(at: sample.sampledAt!, now: now))
        #expect(restored.cpu == 0.75)
        #expect(restored.processes == [process])
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
        let reused = SystemProcessIdentity(pid: 42, startedAt: 200)
        #expect(try await reopened.processHistory(reused, from: now.addingTimeInterval(-30), to: now, now: now).isEmpty)
    }

    @Test func rollingRetentionRejectsFutureSamplesAndDoesNotResurrectExpiredOnes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = MonitorHistoryDisk(url: folder.appendingPathComponent("monitor.sqlite"))
        let now = Date(timeIntervalSince1970: 200_000)
        func sample(at time: Date) -> SystemMetricsSnapshot {
            var result = SystemMetricsSnapshot()
            result.sampledAt = time
            result.cpu = 0.25
            return result
        }
        try await disk.append(sample(at: now.addingTimeInterval(-86_400)), now: now)
        try await disk.append(sample(at: now.addingTimeInterval(-86_401)), now: now)
        try await disk.append(sample(at: now.addingTimeInterval(60)), now: now)
        #expect(try await disk.samples(from: now.addingTimeInterval(-100_000), to: now, now: now).count == 1)
        #expect(try await disk.samples(from: now.addingTimeInterval(-100_000), to: now.addingTimeInterval(2), now: now.addingTimeInterval(2)).isEmpty)
    }
}
