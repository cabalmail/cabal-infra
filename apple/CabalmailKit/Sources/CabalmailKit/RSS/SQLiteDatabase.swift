import Foundation
import SQLite3

/// The one place `CabalmailKit` touches the C SQLite API.
///
/// Deliberately small: open, `exec`, prepared statements with positional
/// binds, and typed column reads. It exists so the RSS reader's local store
/// (`RssStore`) can use the SQLite every Apple OS ships - with FTS5 - without
/// making GRDB the package's first third-party dependency (operator decision,
/// 2026-09-10). Not thread-safe; `RssStore` is an actor and owns the only
/// reference.
final class SQLiteDatabase {
    struct Error: Swift.Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite error \(code): \(message)" }
    }

    /// A bound parameter value.
    enum Value: Equatable {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null

        init(_ string: String?) { self = string.map { .text($0) } ?? .null }
        init(_ int: Int) { self = .integer(Int64(int)) }
        init(_ bool: Bool) { self = .integer(bool ? 1 : 0) }
    }

    /// One result row, read by column index in SELECT order.
    struct Row {
        fileprivate let values: [Value]

        func string(_ index: Int) -> String {
            if case .text(let value) = values[index] { return value }
            if case .integer(let value) = values[index] { return String(value) }
            return ""
        }

        func int(_ index: Int) -> Int {
            if case .integer(let value) = values[index] { return Int(value) }
            if case .real(let value) = values[index] { return Int(value) }
            return 0
        }

        func bool(_ index: Int) -> Bool { int(index) != 0 }

        func isNull(_ index: Int) -> Bool {
            if case .null = values[index] { return true }
            return false
        }
    }

    private var handle: OpaquePointer?
    // SQLITE_TRANSIENT is a C macro (a cast of -1) the Swift importer drops.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let opened { sqlite3_close_v2(opened) }
            throw Error(code: status, message: message)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 2_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Runs one or more statements with no binds (DDL, PRAGMAs).
    func exec(_ sql: String) throws {
        guard let handle else { throw Error(code: SQLITE_MISUSE, message: "closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if status != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw Error(code: status, message: message)
        }
    }

    /// Runs one statement with positional binds and discards any rows.
    func run(_ sql: String, _ binds: [Value] = []) throws {
        _ = try rows(sql, binds)
    }

    /// Runs one statement and returns every row.
    func rows(_ sql: String, _ binds: [Value] = []) throws -> [Row] {
        guard let handle else { throw Error(code: SQLITE_MISUSE, message: "closed") }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw Error(code: prepared, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement, handle: handle)
        var result: [Row] = []
        let columns = Int(sqlite3_column_count(statement))
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw Error(code: status, message: String(cString: sqlite3_errmsg(handle)))
            }
            result.append(Row(values: (0..<columns).map { Self.value(of: statement, column: Int32($0)) }))
        }
        return result
    }

    private func bind(_ binds: [Value], to statement: OpaquePointer, handle: OpaquePointer) throws {
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let int): status = sqlite3_bind_int64(statement, index, int)
            case .real(let double): status = sqlite3_bind_double(statement, index, double)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else {
                throw Error(code: status, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private static func value(of statement: OpaquePointer, column: Int32) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_NULL: return .null
        default:
            guard let text = sqlite3_column_text(statement, column) else { return .null }
            return .text(String(cString: text))
        }
    }

    /// The `user_version` pragma, used for forward-only migrations.
    var userVersion: Int {
        get { (try? rows("PRAGMA user_version").first?.int(0)) ?? 0 }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }

    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }
}
