import Foundation

public struct MonitorHistoryAggregate: Codable, Sendable, Equatable {
    public private(set) var minimum: Double?
    public private(set) var maximum: Double?
    public private(set) var peakTime: Date?
    public private(set) var weightedSum = 0.0
    public private(set) var duration = 0.0
    public private(set) var validCount = 0
    public private(set) var totalCount = 0
    public var average: Double? { duration > 0 ? weightedSum / duration : nil }
    public init() { }

    public mutating func append(_ value: Double?, at time: Date, elapsed: TimeInterval) {
        totalCount += 1
        guard let value, value.isFinite, value >= 0 else { return }
        let weight = elapsed.isFinite && elapsed > 0 ? elapsed : 0.001
        validCount += 1
        weightedSum += value * weight
        duration += weight
        minimum = min(minimum ?? value, value)
        if maximum == nil || value > maximum! { maximum = value; peakTime = time }
    }

    public mutating func merge(_ other: Self) {
        totalCount += other.totalCount; validCount += other.validCount
        weightedSum += other.weightedSum; duration += other.duration
        if let value = other.minimum { minimum = min(minimum ?? value, value) }
        if let value = other.maximum, maximum == nil || value > maximum! {
            maximum = value; peakTime = other.peakTime
        }
    }
}

public struct MonitorHistoryBucket: Codable, Sendable {
    public private(set) var latest = SystemMetricsSnapshot()
    public private(set) var aggregates: [MonitorSeries: MonitorHistoryAggregate] = [:]
    public init() { }

    public mutating func append(_ snapshot: SystemMetricsSnapshot) {
        guard let time = snapshot.sampledAt else { return }
        let interval = snapshot.historyAggregates.isEmpty ? max(15, snapshot.sampleInterval * 3) : MonitorHistory.bucketDuration * 1.5
        let gap = latest.sampledAt.map { time.timeIntervalSince($0) > interval } ?? false
        latest = snapshot
        for series in MonitorSeries.allCases {
            var stats = aggregates[series] ?? MonitorHistoryAggregate()
            if gap { stats.append(nil, at: time, elapsed: 0) }
            if let existing = snapshot.historyAggregates[series] { stats.merge(existing) }
            else { stats.append(series.value(in: snapshot), at: time, elapsed: snapshot.sampleInterval) }
            aggregates[series] = stats
        }
    }

    public var chartSnapshot: SystemMetricsSnapshot {
        var value = latest
        value.historyAggregates = aggregates
        return value
    }
}
