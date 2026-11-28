import CSQLite
import Foundation

/// Owned exclusively by TelemetryArchive. Statements never escape synchronous calls.
final class DriveSQL {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Value {
        case integer(Int64), real(Double), text(String), blob(Data), null
        static func optional(_ value: Double?) -> Self { value.map(Self.real) ?? .null }
        static func time(_ date: Date?) -> Self { optional(date?.timeIntervalSince1970) }
    }

    private let handle: OpaquePointer
    var lastID: Int64 { sqlite3_last_insert_rowid(handle) }

    init(url: URL) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard let db else { throw Failure(message: "SQLite open: \(status)") }
        guard status == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close_v2(db)
            throw Failure(message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 250)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }

    func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        try execute(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func run(_ sql: String, _ bindings: [Value]) throws {
        try query(sql, bindings) { _ in }
    }

    func query(_ sql: String, _ bindings: [Value] = [], row: (OpaquePointer) throws -> Void) throws {
        var pending: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &pending, nil)
        guard status == SQLITE_OK, let statement = pending else { throw error }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == bindings.count else {
            throw Failure(message: "SQLite binding count")
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result = switch value {
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .blob(let data): data.withUnsafeBytes {
                if $0.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
                return sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count),
                                         unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            case .null: sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw error }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw error }
            try row(statement)
        }
    }

    func scalar(_ sql: String, _ bindings: [Value] = []) throws -> Double? {
        var value: Double?
        try query(sql, bindings) { value = Self.number($0, 0) }
        return value
    }

    static func number(_ row: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : sqlite3_column_double(row, column)
    }

    static func string(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    static func data(_ row: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(row, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(row, column))
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private var error: Failure { Failure(message: String(cString: sqlite3_errmsg(handle))) }
}
