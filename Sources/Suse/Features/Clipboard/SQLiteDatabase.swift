import Foundation
import SQLite3

enum SQLiteValue {
    case text(String), blob(Data), integer(Int), real(Double), null
}

struct ClipboardStorageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owned by ClipboardDisk. Statements never escape a synchronous database operation.
final class SQLiteDatabase {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        if !files.fileExists(atPath: url.path) {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ClipboardStorageError(message: "无法创建剪贴板历史文件。")
            }
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw ClipboardStorageError(message: "无法打开剪贴板历史文件。")
        }
        handle = connection
        sqlite3_busy_timeout(handle, 5_000)
        // Keep temporary sorting data in memory; SQLite journals inherit the private database mode.
        try execute("PRAGMA auto_vacuum = FULL; PRAGMA secure_delete = ON; PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA temp_store = MEMORY; PRAGMA cache_size = -8192;")
        let registered = sqlite3_create_function_v2(handle, "history_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                                                    nil, { context, _, arguments in
            guard let arguments else { sqlite3_result_int(context, 0); return }
            func string(_ value: OpaquePointer?) -> String {
                guard let bytes = sqlite3_value_text(value) else { return "" }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_value_bytes(value))), as: UTF8.self)
            }
            sqlite3_result_int(context, string(arguments[0]).localizedCaseInsensitiveContains(string(arguments[1])) ? 1 : 0)
        }, nil, nil, nil)
        try check(registered)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try withStatement(sql, values) { statement in
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW { result = sqlite3_step(statement) }
            try check(result)
        }
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        try withStatement(sql, values) { statement in
            sqlite3_progress_handler(handle, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            defer { sqlite3_progress_handler(handle, 0, nil, nil) }
            var rows: [T] = []
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                if result == SQLITE_INTERRUPT, Task.isCancelled { throw CancellationError() }
                try check(result)
                rows.append(try map(SQLiteRow(statement: statement)))
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ values: [SQLiteValue], body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw ClipboardStorageError(message: "无法读取剪贴板历史。") }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { sqlite3_bind_text64(statement, index, $0, UInt64(text.utf8.count), Self.transient, UInt8(SQLITE_UTF8)) }
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64($0.count), Self.transient)
                }
            case .integer(let number): result = sqlite3_bind_int64(statement, index, Int64(number))
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            try check(result)
        }
        return try body(statement)
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE else {
            throw ClipboardStorageError(message: "剪贴板存储失败：\(String(cString: sqlite3_errmsg(handle)))")
        }
    }
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func text(_ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    func integer(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
}
