import Foundation
import Testing
@testable import SuseCore

struct SystemMetricsTests {
    @Test func samplingMedianRejectsFailuresWithoutHidingSpikes() throws {
        let odd = try #require(SystemSampleStatistics(values: [0.1, 0.2, 0.9, nil, .nan]))
        #expect(odd.median == 0.2)
        #expect(odd.minimum == 0.1 && odd.maximum == 0.9)
        #expect(odd.validCount == 3 && odd.totalCount == 5)
        let even = try #require(SystemSampleStatistics(values: [0, 1, 0.2, 0.4]))
        #expect(abs(even.median - 0.3) < 0.00001)
        #expect(SystemSampleStatistics(values: [nil, .infinity, .nan]) == nil)
    }
    @Test func cpuUsesIntervalTicksAndHandlesCounterWrap() {
        let previous = CPULoadTicks(user: .max - 9, system: 10, idle: 100, nice: 0)
        let current = CPULoadTicks(user: 10, system: 20, idle: 160, nice: 10)
        #expect(current.utilization(since: previous) == 0.4)
        #expect(current.utilization(since: current) == nil)
    }

    @Test func ioRatesIgnoreNewDevicesAndResetCounters() throws {
        var counters = SystemIOCounters()
        #expect(counters.sample(["a": .init(incoming: 100, outgoing: 200)], elapsed: 1) == nil)
        let connectedCandidate = counters.sample([
            "a": .init(incoming: 300, outgoing: 600), "b": .init(incoming: 900_000, outgoing: 800_000),
        ], elapsed: 2)
        let connected = try #require(connectedCandidate)
        #expect(connected == SystemIORate(incoming: 100, outgoing: 200))
        let resetCandidate = counters.sample([
            "a": .init(incoming: 0, outgoing: 0), "b": .init(incoming: 900_200, outgoing: 800_400),
        ], elapsed: 2)
        let reset = try #require(resetCandidate)
        #expect(reset == SystemIORate(incoming: 100, outgoing: 200))
        let removedCandidate = counters.sample(["a": .init(incoming: 100, outgoing: 200)], elapsed: 1)
        let removed = try #require(removedCandidate)
        #expect(removed == SystemIORate(incoming: 100, outgoing: 200))
        counters.reset()
        #expect(counters.sample(["a": .init(incoming: 50_000, outgoing: 50_000)], elapsed: 3_600) == nil)
        #expect(counters.sample([:], elapsed: 0) == nil)
        #expect(counters.sample([:], elapsed: .nan) == nil)
    }

    @Test func ratesUse64BitCountersAndMissingReadingsStayMissing() throws {
        var counters = SystemIOCounters()
        let value = UInt64(UInt32.max) + 1_000
        _ = counters.sample(["device": .init(incoming: value, outgoing: value)], elapsed: 1)
        let rateCandidate = counters.sample(["device": .init(incoming: value + 500, outgoing: value + 1_000)], elapsed: 0.5)
        let rate = try #require(rateCandidate)
        #expect(rate == SystemIORate(incoming: 1_000, outgoing: 2_000))
        #expect(SystemMetricFormat.percent(nil) == "—")
        #expect(SystemMetricFormat.percent(.nan) == "—")
        #expect(SystemMetricFormat.percent(1.2) == "100%")
        #expect(SystemMetricFormat.rate(1024) == "1.0 KiB/s")
        #expect(SystemMetricFormat.rate(-1) == "—")
    }
}
