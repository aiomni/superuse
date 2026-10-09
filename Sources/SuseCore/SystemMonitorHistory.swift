import Foundation

public struct SystemProcessIdentity: Codable, Sendable, Hashable {
    public let pid: Int32
    public let startedAt: UInt64

    public init(pid: Int32, startedAt: UInt64) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

public struct SystemProcessSample: Codable, Sendable, Equatable, Identifiable {
    public let id: SystemProcessIdentity
    public let name: String
    /// Fraction of the whole machine's CPU capacity, matching the system chart.
    public let cpu: Double?
    public let memory: UInt64

    public init(id: SystemProcessIdentity, name: String, cpu: Double?, memory: UInt64) {
        self.id = id
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }

    public static func top(_ samples: [Self], limit: Int = 5) -> [Self] {
        let cpu = samples.filter { $0.cpu?.isFinite == true }.sorted {
            $0.cpu == $1.cpu ? $0.id.pid < $1.id.pid : ($0.cpu ?? 0) > ($1.cpu ?? 0)
        }.prefix(max(0, limit))
        let memory = samples.sorted {
            $0.memory == $1.memory ? $0.id.pid < $1.id.pid : $0.memory > $1.memory
        }.prefix(max(0, limit))
        var seen = Set<SystemProcessIdentity>()
        return (Array(cpu) + Array(memory)).filter { seen.insert($0.id).inserted }
    }
}

public struct SystemProcessCounters: Sendable {
    public struct Reading: Sendable {
        public let id: SystemProcessIdentity
        public let name: String
        public let cpuNanoseconds: UInt64
        public let memory: UInt64

        public init(id: SystemProcessIdentity, name: String, cpuNanoseconds: UInt64, memory: UInt64) {
            self.id = id
            self.name = name
            self.cpuNanoseconds = cpuNanoseconds
            self.memory = memory
        }
    }

    private var previous: [SystemProcessIdentity: UInt64] = [:]
    public init() { }
    public mutating func reset() { previous.removeAll() }

    public mutating func sample(_ readings: [Reading], elapsed: TimeInterval, coreCount: Int) -> [SystemProcessSample] {
        defer { previous = Dictionary(readings.map { ($0.id, $0.cpuNanoseconds) }, uniquingKeysWith: { _, new in new }) }
        return readings.map { reading in
            var cpu: Double?
            if let old = previous[reading.id], reading.cpuNanoseconds >= old,
               elapsed.isFinite, elapsed > 0, coreCount > 0 {
                cpu = min(1, Double(reading.cpuNanoseconds - old) / 1_000_000_000 / elapsed / Double(coreCount))
            }
            return SystemProcessSample(id: reading.id, name: reading.name, cpu: cpu, memory: reading.memory)
        }
    }
}

public enum MonitorSeries: String, Codable, Sendable, CaseIterable {
    case cpu, memory, swap, gpu, download, upload, diskRead, diskWrite
    case availableSpace, cpuTemperature, gpuTemperature, battery

    public func value(in sample: SystemMetricsSnapshot) -> Double? {
        let value: Double?
        switch self {
        case .cpu: value = sample.cpu
        case .memory: value = sample.memory.map { Double($0.used) }
        case .swap: value = sample.memory?.swap.map(Double.init)
        case .gpu: value = sample.gpu
        case .download: value = sample.network?.incoming
        case .upload: value = sample.network?.outgoing
        case .diskRead: value = sample.diskIO?.incoming
        case .diskWrite: value = sample.diskIO?.outgoing
        case .availableSpace: value = sample.diskSpace.map { Double($0.available) }
        case .cpuTemperature: value = sample.cpuTemperature
        case .gpuTemperature: value = sample.gpuTemperature
        case .battery: value = sample.battery?.fraction
        }
        return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// A plot point retains the actual peak's timestamp, so selection can find its process snapshot.
public struct MonitorHistoryPoint: Sendable, Equatable {
    public let time: Date
    public let value: Double?
    public let minimum: Double?
    public let maximum: Double?
    public let peakTime: Date?
    public let duration: TimeInterval

    public init(time: Date, value: Double?, minimum: Double?, maximum: Double?, peakTime: Date?, duration: TimeInterval = 1) {
        self.time = time; self.value = value; self.minimum = minimum; self.maximum = maximum; self.peakTime = peakTime; self.duration = duration
    }
}

public enum MonitorHistory {
    public static let retention: TimeInterval = 24 * 60 * 60
    public static let detailedRetention: TimeInterval = 15 * 60
    public static let bucketDuration: TimeInterval = 30

    public static func points(_ snapshots: [SystemMetricsSnapshot], series: MonitorSeries,
                              from start: Date, to end: Date, maximumPoints: Int = 600) -> [MonitorHistoryPoint] {
        guard end > start, maximumPoints > 0 else { return [] }
        let width = max(1, end.timeIntervalSince(start) / Double(maximumPoints))
        let samples = snapshots.filter { sample in
            guard let time = sample.sampledAt else { return false }
            return time >= start && time <= end
        }.sorted { $0.sampledAt! < $1.sampledAt! }
        var output: [MonitorHistoryPoint] = []
        var group: [SystemMetricsSnapshot] = []
        var bucket: Int?
        var lastTime: Date?
        func flush() {
            guard let first = group.first, let date = first.sampledAt else { return }
            let valid = group.compactMap { sample -> (Date, Double, Double, Double, Double, Date)? in
                guard let time = sample.sampledAt else { return nil }
                if let stats = sample.historyAggregates[series] {
                    guard let average = stats.average, let minimum = stats.minimum, let maximum = stats.maximum, let peak = stats.peakTime else { return nil }
                    return (time, average, stats.duration, minimum, maximum, peak)
                }
                guard let value = series.value(in: sample) else { return nil }
                return (time, value, max(0.001, sample.sampleInterval), value, value, time)
            }
            if let peak = valid.max(by: { $0.4 < $1.4 }) {
                let weight = valid.reduce(0) { $0 + $1.2 }
                output.append(MonitorHistoryPoint(time: date, value: valid.reduce(0) { $0 + $1.1 * $1.2 } / weight,
                                                  minimum: valid.map { $0.3 }.min(), maximum: peak.4, peakTime: peak.5, duration: weight))
            } else {
                output.append(MonitorHistoryPoint(time: date, value: nil, minimum: nil, maximum: nil, peakTime: nil))
            }
            group.removeAll(keepingCapacity: true)
        }
        func validValue(_ sample: SystemMetricsSnapshot) -> Double? {
            sample.historyAggregates[series].map { $0.average } ?? series.value(in: sample)
        }
        for sample in samples {
            let time = sample.sampledAt!
            let nextBucket = Int(time.timeIntervalSince(start) / width)
            let gapThreshold = sample.historyAggregates.isEmpty ? max(15, sample.sampleInterval * 3) : MonitorHistory.bucketDuration * 1.5
            if let lastTime, time.timeIntervalSince(lastTime) > gapThreshold {
                flush()
                output.append(MonitorHistoryPoint(time: lastTime.addingTimeInterval(0.001), value: nil,
                                                  minimum: nil, maximum: nil, peakTime: nil))
            }
            // Missing samples split a line, even when the display buckets are wide.
            if nextBucket != bucket || validValue(sample) == nil || group.last.map({ validValue($0) == nil }) == true {
                flush()
            }
            bucket = nextBucket
            if let stats = sample.historyAggregates[series], stats.validCount < stats.totalCount {
                flush()
                output.append(MonitorHistoryPoint(time: time.addingTimeInterval(-0.001), value: nil, minimum: nil, maximum: nil, peakTime: nil))
                group.append(sample)
                flush()
                output.append(MonitorHistoryPoint(time: time.addingTimeInterval(0.001), value: nil, minimum: nil, maximum: nil, peakTime: nil))
            } else { group.append(sample) }
            lastTime = time
        }
        flush()
        return output
    }

    public static func nearest(_ snapshots: [SystemMetricsSnapshot], to time: Date, tolerance: TimeInterval) -> SystemMetricsSnapshot? {
        let sample = snapshots.filter { $0.sampledAt != nil }.min {
            abs($0.sampledAt!.timeIntervalSince(time)) < abs($1.sampledAt!.timeIntervalSince(time))
        }
        guard let sample, abs(sample.sampledAt!.timeIntervalSince(time)) <= tolerance else { return nil }
        return sample
    }
}
