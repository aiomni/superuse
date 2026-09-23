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
        let entries = try db.query("SELECT body, image FROM history WHERE id = ? AND fingerprint = ?",
                                  [.text(record.id.uuidString), .text(record.fingerprint)]) { row in
            ClipboardEntry(id: record.id, content: record.isImage ? .image(row.data(1) ?? Data()) : .text(row.text(0)),
                           capturedAt: record.capturedAt, source: record.source, modifiedAt: record.modifiedAt)
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
                .text(text), .text(preview(text)), .text(fingerprint), .real(now.timeIntervalSince1970),
                pinOrder.map(SQLiteValue.integer) ?? .null, .text(record.id.uuidString),
            ])
            try trim(db, limit: limit)
        }
    }

    func remove(id: UUID) throws {
        try open().run("DELETE FROM history WHERE id = ?", [.text(id.uuidString)])
    }

    func clear() throws { try open().run("DELETE FROM history") }

    func counts() throws -> (pinned: Int, ordinary: Int) {
        let db = try open()
        return try db.query("SELECT COUNT(pin_order), COUNT(*) - COUNT(pin_order) FROM history") {
            (pinned: $0.integer(0), ordinary: $0.integer(1))
        }.first ?? (0, 0)
    }

    func setLimit(_ limit: Int) throws {
        let db = try open()
        try db.transaction { try trim(db, limit: limit) }
    }

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        let db = try SQLiteDatabase(url: url)
        let version = try db.query("PRAGMA user_version") { $0.integer(0) }.first ?? 0
        guard version <= 1 else { throw ClipboardStorageError(message: "历史文件由更新版本创建，请升级应用后再打开。") }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY, kind INTEGER NOT NULL, preview TEXT NOT NULL, source TEXT NOT NULL,
                created REAL NOT NULL, modified REAL NOT NULL, fingerprint TEXT NOT NULL UNIQUE,
                body TEXT, image BLOB, thumbnail BLOB, pin_order INTEGER
            );
            CREATE INDEX IF NOT EXISTS history_order ON history(pin_order IS NULL, pin_order, modified DESC, id);
            CREATE TABLE IF NOT EXISTS migration (name TEXT PRIMARY KEY);
            PRAGMA user_version = 1;
            """)
        let legacy = url.deletingPathExtension().appendingPathExtension("json")
        let migrated = try db.query("SELECT name FROM migration WHERE name = 'legacy-json'") { $0.text(0) }.first != nil
        if !migrated {
            // Legacy files were bounded. Decode once, and commit all entries before removing the old file.
            let entries = FileManager.default.fileExists(atPath: legacy.path)
                ? try JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: legacy, options: .mappedIfSafe)) : []
            try db.transaction {
                for entry in entries.reversed() where entry.content.byteCount > 0 { _ = try Self.insert(entry, in: db) }
                try db.run("INSERT INTO migration(name) VALUES ('legacy-json')")
            }
        }
        if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
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
            """, [.text(entry.id.uuidString), .integer(kind), .text(entry.title), .text(entry.source),
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

    private func preview(_ text: String) -> String { String(text.prefix(300)).replacingOccurrences(of: "\n", with: " ") }
}
