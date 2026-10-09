import Foundation

public struct CPULoadTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public func utilization(since previous: Self) -> Double? {
        let busy = Double(user &- previous.user) + Double(system &- previous.system) + Double(nice &- previous.nice)
        let total = busy + Double(idle &- previous.idle)
        return total > 0 ? busy / total : nil
    }
}

public struct SystemIORate: Codable, Sendable, Equatable {
    public var incoming: Double
    public var outgoing: Double

    public init(incoming: Double, outgoing: Double) {
        self.incoming = incoming
        self.outgoing = outgoing
    }
}

/// Keep a baseline per device: attaching a device must not count its lifetime traffic.
public struct SystemIOCounters: Sendable {
    public struct Counter: Sendable, Equatable {
        public var incoming: UInt64
        public var outgoing: UInt64

        public init(incoming: UInt64, outgoing: UInt64) {
            self.incoming = incoming
            self.outgoing = outgoing
        }
    }

    private var previous: [String: Counter]?

    public init() { }

    public mutating func reset() { previous = nil }

    public mutating func sample(_ counters: [String: Counter], elapsed: TimeInterval) -> SystemIORate? {
        defer { previous = counters }
        guard let previous, elapsed.isFinite, elapsed > 0 else { return nil }
        var incoming = 0.0
        var outgoing = 0.0
        for (id, current) in counters {
            guard let old = previous[id] else { continue }
            // A driver reset re-establishes both baselines, rather than inventing a spike.
            guard current.incoming >= old.incoming, current.outgoing >= old.outgoing else { continue }
            incoming += Double(current.incoming - old.incoming) / elapsed
            outgoing += Double(current.outgoing - old.outgoing) / elapsed
        }
        return SystemIORate(incoming: incoming, outgoing: outgoing)
    }
}

public struct SystemMemory: Codable, Sendable {
    public var used: UInt64
    public var total: UInt64
    public var compressed: UInt64
    public var swap: UInt64?
    public var pressure: Int?

    public init(used: UInt64, total: UInt64, compressed: UInt64, swap: UInt64?, pressure: Int?) {
        self.used = used
        self.total = total
        self.compressed = compressed
        self.swap = swap
        self.pressure = pressure
    }
}

public struct SystemDiskSpace: Codable, Sendable {
    public var total: UInt64
    public var available: UInt64

    public init(total: UInt64, available: UInt64) {
        self.total = total
        self.available = available
    }
}

public struct SystemBattery: Codable, Sendable {
    public var fraction: Double
    public var charging: Bool
    public var pluggedIn: Bool

    public init(fraction: Double, charging: Bool, pluggedIn: Bool) {
        self.fraction = fraction
        self.charging = charging
        self.pluggedIn = pluggedIn
    }
}

public struct SystemMetricsSnapshot: Codable, Sendable {
    public var cpu: Double?
    public var coreLoads: [Double?] = []
    public var memory: SystemMemory?
    public var gpu: Double?
    public var network: SystemIORate?
    public var diskIO: SystemIORate?
    public var diskSpace: SystemDiskSpace?
    public var battery: SystemBattery?
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var fanRPM: [Double] = []
    public var thermalState: Int?
    public var uptime: TimeInterval = 0
    public var sampleInterval: TimeInterval = 0
    public var processes: [SystemProcessSample] = []
    public var historyAggregates: [MonitorSeries: MonitorHistoryAggregate] = [:]
    public var sampledAt: Date?
    /// A missing metric's explanation, including pending baseline and unsupported hardware.
    public var notes: [String: String] = [:]

    public init() { }
}

/// Invalid readings count as failures, never as zero. Bounds expose spikes hidden by a median.
public struct SystemSampleStatistics: Sendable, Equatable {
    public let totalCount: Int
    public let validCount: Int
    public let minimum: Double
    public let maximum: Double
    public let median: Double

    public init?(values: [Double?]) {
        let valid = values.compactMap { $0 }.filter(\.isFinite).sorted()
        guard let first = valid.first, let last = valid.last else { return nil }
        totalCount = values.count
        validCount = valid.count
        minimum = first
        maximum = last
        let middle = valid.count / 2
        median = valid.count.isMultiple(of: 2) ? valid[middle - 1] / 2 + valid[middle] / 2 : valid[middle]
    }
}

public enum SystemMetricFormat {
    public static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return String(format: "%.0f%%", min(1, max(0, fraction)) * 100)
    }

    public static func bytes(_ bytes: UInt64) -> String {
        bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }

    public static func rate(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "—" }
        let units = ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s"]
        var value = bytes
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}
