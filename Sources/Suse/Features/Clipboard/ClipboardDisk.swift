import CryptoKit
import Foundation
import SuseCore

/// Serializes incremental writes and reads. No original clipboard content is cached by the UI.
actor ClipboardDisk {
    private let url: URL
    private var database: SQLiteDatabase?
    private let columns = "id, kind, preview, source, created, modified, fingerprint, pin_order, thumbnail"
    private let ordering = "pin_order IS NULL, pin_order, modified DESC, id"

    init(url: URL) { self.url = url }

    func prepare(limit: Int) throws {
        let db = try open()
        try db.transaction { try trim(db, limit: limit) }
    }

    func page(query: String = "", offset: Int = 0, limit: Int = 100) throws -> ClipboardPage {
        let db = try open()
        let filter = searchFilter(query)
        let count = try db.query("SELECT COUNT(*) FROM history \(filter.sql)", filter.values) { $0.integer(0) }.first ?? 0
        let records = try db.query("SELECT \(columns) FROM history \(filter.sql) ORDER BY \(ordering) LIMIT ? OFFSET ?",
                                   filter.values + [.integer(max(1, limit)), .integer(max(0, offset))], map: record)
        return ClipboardPage(records: records, total: count, offset: max(0, offset))
    }

    func index(of id: UUID, query: String) throws -> Int? {
        let db = try open()
        let filter = searchFilter(query)
        return try db.query("""
            SELECT position FROM (
                SELECT id, ROW_NUMBER() OVER (ORDER BY \(ordering)) - 1 AS position FROM history \(filter.sql)
            ) WHERE id = ?
            """, filter.values + [.text(id.uuidString)]) { $0.integer(0) }.first
    }

    func content(for record: ClipboardRecord) throws -> ClipboardEntry {
        let db = try open()
        let entries = try db.query("SELECT kind, body, image, created, modified, source FROM history WHERE id = ? AND fingerprint = ?",
                                  [.text(record.id.uuidString), .text(record.fingerprint)]) { row in
            let content: ClipboardContent
            if row.integer(0) == 1 {
                guard let data = row.data(2), !data.isEmpty else { throw ClipboardStorageError(message: "历史图片内容损坏。") }
                content = .image(data)
            } else {
                guard !row.isNull(1) else { throw ClipboardStorageError(message: "历史文本内容损坏。") }
                content = .text(row.text(1))
            }
            return ClipboardEntry(id: record.id, content: content, capturedAt: Date(timeIntervalSince1970: row.double(3)),
                                  source: row.text(5), modifiedAt: Date(timeIntervalSince1970: row.double(4)))
        }
        guard let entry = entries.first else { throw ClipboardStorageError(message: "这条记录已删除或更新，请重新选择。") }
        return entry
    }

    @discardableResult
    func capture(_ entry: ClipboardEntry, limit: Int, convertImage: Bool = false) throws -> UUID {
        let db = try open()
        var entry = entry
        if convertImage, case .image(let data) = entry.content {
            entry = ClipboardEntry(id: entry.id, content: .image(try ClipboardImageData.png(from: data)),
                                   capturedAt: entry.capturedAt, source: entry.source, modifiedAt: entry.modifiedAt)
        }
        return try db.transaction {
            let id = try Self.insert(entry, in: db)
            try trim(db, limit: limit)
            return id
        }
    }

    func edit(_ record: ClipboardRecord, text: String, limit: Int, now: Date = Date()) throws {
        guard !text.isEmpty, !record.isImage else { throw ClipboardStorageError(message: "文本内容不能为空。") }
        let db = try open()
        try db.transaction {
            // Re-read the expected version so an editor cannot overwrite a newer edit or resurrect a deletion.
            _ = try content(for: record)
            let fingerprint = Self.digest(.text(text))
            let duplicate = try db.query("SELECT \(columns) FROM history WHERE fingerprint = ? AND id != ?",
                                         [.text(fingerprint), .text(record.id.uuidString)], map: self.record).first
            let current = try db.query("SELECT \(columns) FROM history WHERE id = ?", [.text(record.id.uuidString)], map: self.record).first
            let pinOrder = current?.pinOrder ?? duplicate?.pinOrder
            if let duplicate { try db.run("DELETE FROM history WHERE id = ?", [.text(duplicate.id.uuidString)]) }
            try db.run("UPDATE history SET body = ?, preview = ?, fingerprint = ?, modified = ?, pin_order = ? WHERE id = ?", [
                .text(text), .text(ClipboardContent.text(text).preview), .text(fingerprint), .real(now.timeIntervalSince1970),
                pinOrder.map(SQLiteValue.integer) ?? .null, .text(record.id.uuidString),
            ])
            try trim(db, limit: limit)
        }
    }

    func remove(id: UUID) throws {
        try open().run("DELETE FROM history WHERE id = ?", [.text(id.uuidString)])
    }

    func clear() throws { try open().run("DELETE FROM history") }

    func setPinned(id: UUID, pinned: Bool, limit: Int) throws {
        let db = try open()
        try db.transaction {
            guard let current = try db.query("SELECT pin_order IS NOT NULL FROM history WHERE id = ?",
                                             [.text(id.uuidString)], map: { $0.integer(0) != 0 }).first else {
                throw ClipboardStorageError(message: "这条记录已删除，请重新选择。")
            }
            guard current != pinned else { return }
            if pinned {
                try db.run("UPDATE history SET pin_order = (SELECT COALESCE(MIN(pin_order), 1) - 1 FROM history) WHERE id = ?",
                           [.text(id.uuidString)])
            } else {
                try db.run("UPDATE history SET pin_order = NULL WHERE id = ?", [.text(id.uuidString)])
                try trim(db, limit: limit)
            }
        }
    }

    /// Use a neighboring identity, rather than a visible row number that can change during a drag.
    func movePinned(id: UUID, before nextID: UUID?) throws {
        guard id != nextID else { return }
        let db = try open()
        try db.transaction {
            func order(of id: UUID) throws -> Int {
                guard let order = try db.query("SELECT pin_order FROM history WHERE id = ? AND pin_order IS NOT NULL",
                                               [.text(id.uuidString)], map: { $0.integer(0) }).first else {
                    throw ClipboardStorageError(message: "置顶记录已改变，请重新拖动。")
                }
                return order
            }
            let current = try order(of: id)
            let destination: Int
            if let nextID {
                let next = try order(of: nextID)
                destination = next > current ? next - 1 : next
            } else {
                destination = try db.query("SELECT MAX(pin_order) FROM history") { $0.integer(0) }.first ?? current
            }
            if destination < current {
                try db.run("UPDATE history SET pin_order = pin_order + 1 WHERE pin_order >= ? AND pin_order < ?",
                           [.integer(destination), .integer(current)])
            } else if destination > current {
                try db.run("UPDATE history SET pin_order = pin_order - 1 WHERE pin_order > ? AND pin_order <= ?",
                           [.integer(current), .integer(destination)])
            }
            try db.run("UPDATE history SET pin_order = ? WHERE id = ?", [.integer(destination), .text(id.uuidString)])
        }
    }

    func counts() throws -> (pinned: Int, ordinary: Int) {
        let db = try open()
        return try db.query("SELECT COUNT(pin_order), COUNT(*) - COUNT(pin_order) FROM history") {
            (pinned: $0.integer(0), ordinary: $0.integer(1))
        }.first ?? (0, 0)
    }

    func retentionPlan(limit: Int) throws -> ClipboardRetentionPlan {
        guard limit > 0 else { throw ClipboardStorageError(message: "保留数量必须是正整数。") }
        let counts = try counts()
        return ClipboardRetentionPlan(limit: limit, pinnedCount: counts.pinned, ordinaryCount: counts.ordinary)
    }

    /// If the dialog's deletion counts are stale, return an updated plan without deleting anything.
    func applyRetention(_ approved: ClipboardRetentionPlan) throws -> ClipboardRetentionPlan? {
        let db = try open()
        return try db.transaction {
            let current = try retentionPlan(limit: approved.limit)
            if current.removedCount > 0, current != approved { return current }
            try trim(db, limit: approved.limit)
            return nil
        }
    }

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        let db = try SQLiteDatabase(url: url)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY NOT NULL, kind INTEGER NOT NULL CHECK (kind IN (0, 1)), preview TEXT NOT NULL, source TEXT NOT NULL,
                created REAL NOT NULL, modified REAL NOT NULL, fingerprint TEXT NOT NULL UNIQUE,
                body TEXT, image BLOB, thumbnail BLOB, pin_order INTEGER,
                CHECK ((kind = 0 AND body IS NOT NULL AND image IS NULL)
                    OR (kind = 1 AND image IS NOT NULL AND body IS NULL))
            ) STRICT;
            CREATE INDEX IF NOT EXISTS history_order ON history(pin_order IS NULL, pin_order, modified DESC, id);
            CREATE INDEX IF NOT EXISTS history_ordinary_order ON history(modified DESC, id) WHERE pin_order IS NULL;
            """)
        database = db
        return db
    }

    private static func insert(_ entry: ClipboardEntry, in db: SQLiteDatabase) throws -> UUID {
        guard entry.content.byteCount > 0 else { throw ClipboardStorageError(message: "剪贴板内容不能为空。") }
        let fingerprint = digest(entry.content)
        if let existing = try db.query("SELECT id FROM history WHERE fingerprint = ?", [.text(fingerprint)], map: { $0.text(0) }).first,
           let id = UUID(uuidString: existing) {
            try db.run("UPDATE history SET modified = ?, source = ? WHERE id = ?",
                       [.real(entry.modifiedAt.timeIntervalSince1970), .text(entry.source), .text(existing)])
            return id
        }
        let text: SQLiteValue
        let image: SQLiteValue
        let thumbnail: SQLiteValue
        let kind: Int
        switch entry.content {
        case .text(let value): text = .text(value); image = .null; thumbnail = .null; kind = 0
        case .image(let value):
            text = .null; image = .blob(value); kind = 1
            thumbnail = ClipboardImageData.thumbnail(from: value).map(SQLiteValue.blob) ?? .null
        }
        try db.run("""
            INSERT INTO history(id, kind, preview, source, created, modified, fingerprint, body, image, thumbnail)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(entry.id.uuidString), .integer(kind), .text(entry.content.preview), .text(entry.source),
                   .real(entry.capturedAt.timeIntervalSince1970), .real(entry.modifiedAt.timeIntervalSince1970),
                   .text(fingerprint), text, image, thumbnail])
        return entry.id
    }

    private func trim(_ db: SQLiteDatabase, limit: Int) throws {
        guard limit > 0 else { throw ClipboardStorageError(message: "保留数量必须是正整数。") }
        try db.run("""
            DELETE FROM history WHERE id IN (
                SELECT id FROM history WHERE pin_order IS NULL ORDER BY modified DESC, id LIMIT -1 OFFSET ?
            )
            """, [.integer(limit)])
    }

    private func searchFilter(_ query: String) -> (sql: String, values: [SQLiteValue]) {
        guard !query.isEmpty else { return ("", []) }
        return ("WHERE history_contains(source, ?) OR (kind = 0 AND history_contains(body, ?)) OR (kind = 1 AND history_contains('图片 image', ?))",
                [.text(query), .text(query), .text(query)])
    }

    private func record(_ row: SQLiteRow) throws -> ClipboardRecord {
        guard let id = UUID(uuidString: row.text(0)) else { throw ClipboardStorageError(message: "历史记录标识损坏。") }
        return ClipboardRecord(id: id, isImage: row.integer(1) == 1, title: row.text(2), source: row.text(3),
                               capturedAt: Date(timeIntervalSince1970: row.double(4)), modifiedAt: Date(timeIntervalSince1970: row.double(5)),
                               fingerprint: row.text(6), pinOrder: row.isNull(7) ? nil : row.integer(7), thumbnail: row.data(8))
    }

    private static func digest(_ content: ClipboardContent) -> String {
        var hash = SHA256()
        switch content {
        case .text(let text): hash.update(data: Data([0])); hash.update(data: Data(text.utf8))
        case .image(let data): hash.update(data: Data([1])); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
