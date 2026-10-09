import Foundation
import Testing
@testable import SuseCore

struct SystemMonitorHistoryTests {
    @Test func cubicHoverMatchesCurveAndNeverOvershootsOrBridgesMissingData() throws {
        let start = Date(timeIntervalSince1970: 100)
        let points: [MonitorHistoryPoint] = [(0.0, 0.1), (1.0, 0.9), (10.0, 0.2), (11.0, nil), (12.0, 0.8)].map { offset, value in
            .init(time: start.addingTimeInterval(offset), value: value, minimum: value, maximum: value, peakTime: value == nil ? nil : start.addingTimeInterval(offset))
        }
        for step in 0..<100 {
            let offset = Double(step) / 10
            let value = try #require(MonitorPlotGeometry.value(at: start.addingTimeInterval(offset), points: points))
            #expect(value >= 0.1 - 0.000001 && value <= 0.9 + 0.000001)
        }
        #expect(MonitorPlotGeometry.value(at: start.addingTimeInterval(10.5), points: points) == nil)
        #expect(MonitorPlotGeometry.value(at: start.addingTimeInterval(11.5), points: points) == nil)
        #expect(MonitorPlotGeometry.value(at: start.addingTimeInterval(-1), points: points) == nil)
        #expect(MonitorPlotGeometry.value(at: start.addingTimeInterval(13), points: points) == nil)
    }

    @Test func processBaselinesRejectReuseAndCounterResets() {
        var counters = SystemProcessCounters()
        let id = SystemProcessIdentity(pid: 42, startedAt: 10)
        let next = SystemProcessIdentity(pid: 42, startedAt: 20)
        func reading(_ identity: SystemProcessIdentity, _ ticks: UInt64) -> SystemProcessCounters.Reading {
            .init(id: identity, name: "Synthetic worker", cpuNanoseconds: ticks, memory: 100)
        }
        #expect(counters.sample([reading(id, 0)], elapsed: 1, coreCount: 4)[0].cpu == nil)
        #expect(counters.sample([reading(id, 2_000_000_000)], elapsed: 2, coreCount: 4)[0].cpu == 0.25)
        #expect(counters.sample([reading(next, 5_000_000_000)], elapsed: 1, coreCount: 4)[0].cpu == nil)
        #expect(counters.sample([reading(next, 0)], elapsed: 1, coreCount: 4)[0].cpu == nil)
        counters.reset()
        #expect(counters.sample([reading(next, 10)], elapsed: 1, coreCount: 4)[0].cpu == nil)
    }

    @Test func topCPUAndMemoryAreDeduplicatedAndBounded() {
        let samples = (0..<20).map {
            SystemProcessSample(id: .init(pid: Int32($0), startedAt: 1), name: "Process \($0)",
                                cpu: Double($0) / 100, memory: UInt64(20 - $0))
        }
        let top = SystemProcessSample.top(samples)
        #expect(top.count == 10)
        #expect(top.first?.id.pid == 19)
        #expect(top.last?.id.pid == 4)
        #expect(SystemProcessSample.top(samples, limit: 0).isEmpty)
        #expect(SystemProcessSample.top(Array(samples.suffix(2))).count == 2)
    }

    @Test func aggregationPreservesPeaksTheirTimeAndWeightedAverage() throws {
        let start = Date(timeIntervalSince1970: 100)
        func sample(_ offset: Double, _ cpu: Double?, _ duration: Double) -> SystemMetricsSnapshot {
            var value = SystemMetricsSnapshot()
            value.sampledAt = start.addingTimeInterval(offset)
            value.cpu = cpu
            value.sampleInterval = duration
            return value
        }
        let values = [sample(0, 0.1, 5), sample(1, 0.9, 1), sample(2, 0.2, 1)]
        let points = MonitorHistory.points(values, series: .cpu, from: start, to: start.addingTimeInterval(10), maximumPoints: 1)
        let point = try #require(points.first)
        #expect(points.count == 1)
        #expect(abs(point.value! - 1.6 / 7) < 0.00001)
        #expect(point.minimum == 0.1)
        #expect(point.maximum == 0.9)
        #expect(point.peakTime == start.addingTimeInterval(1))
        #expect(MonitorHistory.nearest(values, to: point.peakTime!, tolerance: 0.1)?.cpu == 0.9)
    }

    @Test func missingReadingsAndSleepProduceGapsRatherThanZeros() {
        let start = Date(timeIntervalSince1970: 100)
        let samples: [SystemMetricsSnapshot] = [(0.0, 0.1), (1.0, nil), (2.0, 0.0), (90.0, 0.2)].map { offset, cpu in
            var sample = SystemMetricsSnapshot()
            sample.sampledAt = start.addingTimeInterval(offset)
            sample.sampleInterval = 1
            sample.cpu = cpu
            return sample
        }
        let points = MonitorHistory.points(samples, series: .cpu, from: start, to: start.addingTimeInterval(100), maximumPoints: 1)
        #expect(points.filter { $0.value == nil }.count == 2)
        #expect(points.contains { $0.value == 0 })
        #expect(MonitorHistory.nearest(samples, to: start.addingTimeInterval(40), tolerance: 5) == nil)
    }
}
