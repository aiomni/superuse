import Foundation
import SuseCore

/// Actor-owned, private, rolling history. Reads never cancel an already accepted write.
actor MonitorHistoryDisk {
    private let url: URL
    private var database: SQLiteDatabase?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) { self.url = url }

    func append(_ snapshot: SystemMetricsSnapshot, now: Date = Date()) throws {
        guard let time = snapshot.sampledAt, time.timeIntervalSince1970.isFinite,
              time <= now.addingTimeInterval(1), time >= now.addingTimeInterval(-MonitorHistory.retention) else { return }
        let payload = try encoder.encode(snapshot)
        let db = try open()
        try db.transaction {
            let replacing = try db.query("SELECT time FROM monitor_samples WHERE time = ?", [.real(time.timeIntervalSince1970)]) { $0.double(0) }.first != nil
            try db.run("INSERT OR REPLACE INTO monitor_samples(time, payload) VALUES (?, ?)",
                       [.real(time.timeIntervalSince1970), .blob(payload)])
            let bucketTime = floor(time.timeIntervalSince1970 / MonitorHistory.bucketDuration) * MonitorHistory.bucketDuration
            let old = try db.query("SELECT payload FROM monitor_buckets WHERE time = ?", [.real(bucketTime)]) { row in
                try decoder.decode(MonitorHistoryBucket.self, from: row.data(0)!)
            }.first
            var bucket = old ?? MonitorHistoryBucket()
            if replacing {
                bucket = MonitorHistoryBucket()
                let records = try db.query("SELECT payload FROM monitor_samples WHERE time >= ? AND time < ? ORDER BY time", [.real(bucketTime), .real(bucketTime + MonitorHistory.bucketDuration)]) { row in
                    try decoder.decode(SystemMetricsSnapshot.self, from: row.data(0)!)
                }
                records.forEach { bucket.append($0) }
            } else { bucket.append(snapshot) }
            try db.run("INSERT OR REPLACE INTO monitor_buckets(time, payload) VALUES (?, ?)", [.real(bucketTime), .blob(try encoder.encode(bucket))])
            try trim(db, now: now)
        }
    }

    func samples(from start: Date, to end: Date, now: Date = Date()) throws -> [SystemMetricsSnapshot] {
        let db = try open()
        try trim(db, now: now)
        let beginning = max(start, now.addingTimeInterval(-MonitorHistory.retention))
        return try db.query("SELECT payload FROM monitor_samples WHERE time >= ? AND time <= ? ORDER BY time",
                            [.real(beginning.timeIntervalSince1970), .real(min(end, now).timeIntervalSince1970)]) { row in
            guard let payload = row.data(0) else { throw SQLiteStorageError(message: "监控记录不完整。") }
            return try decoder.decode(SystemMetricsSnapshot.self, from: payload)
        }
    }

    func chartSamples(from start: Date, to end: Date, now: Date = Date()) throws -> [SystemMetricsSnapshot] {
        if end.timeIntervalSince(start) <= MonitorHistory.detailedRetention { return try samples(from: start, to: end, now: now) }
        let db = try open()
        try trim(db, now: now)
        let beginning = max(start, now.addingTimeInterval(-MonitorHistory.retention))
        let ending = min(end, now)
        let cutoff = now.addingTimeInterval(-MonitorHistory.detailedRetention)
        // Only complete buckets may stand in for raw samples; both clipped edges stay exact.
        let firstBucket = ceil(beginning.timeIntervalSince1970 / MonitorHistory.bucketDuration) * MonitorHistory.bucketDuration
        let lastBucket = floor(min(ending, cutoff).timeIntervalSince1970 / MonitorHistory.bucketDuration) * MonitorHistory.bucketDuration
        guard lastBucket > firstBucket else { return try samples(from: beginning, to: ending, now: now) }
        let older = try db.query("SELECT payload FROM monitor_buckets WHERE time >= ? AND time < ? ORDER BY time",
                                [.real(firstBucket), .real(lastBucket)]) { row in
            try decoder.decode(MonitorHistoryBucket.self, from: row.data(0)!).chartSnapshot
        }
        let prefix = try samples(from: beginning, to: Date(timeIntervalSince1970: firstBucket).addingTimeInterval(-0.000001), now: now)
        let suffix = try samples(from: Date(timeIntervalSince1970: lastBucket), to: ending, now: now)
        return prefix + older + suffix
    }

    func snapshot(at time: Date, tolerance: TimeInterval = 0.01, now: Date = Date()) throws -> SystemMetricsSnapshot? {
        let values = try samples(from: time.addingTimeInterval(-tolerance), to: time.addingTimeInterval(tolerance), now: now)
        return MonitorHistory.nearest(values, to: time, tolerance: tolerance)
    }

    func processHistory(_ identity: SystemProcessIdentity, from start: Date, to end: Date, now: Date = Date()) throws -> [SystemMetricsSnapshot] {
        try samples(from: start, to: end, now: now).filter { $0.processes.contains { $0.id == identity } }
    }

    private func trim(_ db: SQLiteDatabase, now: Date) throws {
        try db.run("DELETE FROM monitor_samples WHERE time < ? OR time > ?",
                   [.real(now.addingTimeInterval(-MonitorHistory.retention).timeIntervalSince1970), .real(now.addingTimeInterval(1).timeIntervalSince1970)])
        try db.run("DELETE FROM monitor_buckets WHERE time < ? OR time > ?",
                   [.real(now.addingTimeInterval(-MonitorHistory.retention - MonitorHistory.bucketDuration).timeIntervalSince1970), .real(now.addingTimeInterval(1).timeIntervalSince1970)])
        // At most one accepted sample per second for 24 hours, including both endpoints.
        try db.run("DELETE FROM monitor_samples WHERE time IN (SELECT time FROM monitor_samples ORDER BY time DESC LIMIT -1 OFFSET 86401)")
    }

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        let db = try SQLiteDatabase(url: url)
        try db.execute("CREATE TABLE IF NOT EXISTS monitor_samples(time REAL PRIMARY KEY NOT NULL, payload BLOB NOT NULL) STRICT; CREATE TABLE IF NOT EXISTS monitor_buckets(time REAL PRIMARY KEY NOT NULL, payload BLOB NOT NULL) STRICT;")
        database = db
        return db
    }
}
