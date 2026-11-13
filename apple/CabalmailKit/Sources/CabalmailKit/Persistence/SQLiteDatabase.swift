import Foundation
import SQLite3

/// The one place `CabalmailKit` touches the C SQLite API.
///
/// Deliberately small: open, `exec`, prepared statements with positional
/// binds, typed column reads, a write transaction and the `user_version`
/// pragma. It exists so the Kit's stores (`RssStore` today) can use the
/// SQLite every Apple OS ships - with FTS5 - without making GRDB the
/// package's first third-party dependency (operator decision, 2026-09-10).
/// Not thread-safe; a store is an actor and owns the only reference.
///
/// Every failure is thrown as `CabalmailError.storage`, here where it is
/// raised, so no store built on this can hand a caller a raw SQLite error.
final class SQLiteDatabase {
    /// A bound parameter value.
    enum Value: Equatable {
        case text(String)
        case integer(Int64)
        case real(Double)
        case blob(Data)
        case null

        init(_ string: String?) { self = string.map { .text($0) } ?? .null }
        init(_ int: Int) { self = .integer(Int64(int)) }
        init(_ bool: Bool) { self = .integer(bool ? 1 : 0) }
        init(_ data: Data?) { self = data.map { .blob($0) } ?? .null }
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

        /// A BLOB column's bytes; empty for any other type.
        func data(_ index: Int) -> Data {
            if case .blob(let value) = values[index] { return value }
            return Data()
        }

        func isNull(_ index: Int) -> Bool {
            if case .null = values[index] { return true }
            return false
        }
    }

    /// Whether this OS's SQLite has `octet_length()` (3.43.0 and later),
    /// which answers from a row's header: a query can test that a text
    /// column is non-empty without reading the column, and so without
    /// reading the pages a long row overflows onto.
    static let hasOctetLength = sqlite3_libversion_number() >= 3_043_000

    private var handle: OpaquePointer?
    // SQLITE_TRANSIENT is a C macro (a cast of -1) the Swift importer drops.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    #if DEBUG
    /// The write-failure switches this connection answers to.
    let faults = SQLiteFaultProbe()
    #endif

    /// Opens the file at `path`, creating it unless `existing` says it must
    /// already be there.
    init(path: String, existing: Bool = false) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (existing ? 0 : SQLITE_OPEN_CREATE)
        let status = sqlite3_open_v2(path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let opened { sqlite3_close_v2(opened) }
            throw Self.failure(status, message)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 2_000)
        #if DEBUG
        faults.watch(opened)
        #endif
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Closes the file for good; every later statement throws.
    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// Runs one or more statements with no binds (DDL, PRAGMAs).
    func exec(_ sql: String) throws {
        guard let handle else { throw Self.failure(SQLITE_MISUSE, "closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if status != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw refusal(status, message)
        }
    }

    /// Runs one statement with positional binds and discards any rows.
    func run(_ sql: String, _ binds: [Value] = []) throws {
        _ = try rows(sql, binds)
    }

    /// Runs one statement and returns every row.
    func rows(_ sql: String, _ binds: [Value] = []) throws -> [Row] {
        guard let handle else { throw Self.failure(SQLITE_MISUSE, "closed") }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw refusal(prepared, String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement, handle: handle)
        var result: [Row] = []
        let columns = Int(sqlite3_column_count(statement))
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw Self.failure(status, String(cString: sqlite3_errmsg(handle)))
            }
            result.append(Row(values: (0..<columns).map { Self.value(of: statement, column: Int32($0)) }))
        }
        return result
    }

    /// Runs `body` as one write transaction: committed when it returns,
    /// rolled back when it throws, and the error rethrown.
    ///
    /// `BEGIN IMMEDIATE` takes the write lock at the start, waiting out the
    /// busy timeout for it. A deferred `BEGIN` takes it at the first write
    /// instead, and when another connection has written since this one's
    /// first read, that upgrade fails at once without waiting.
    ///
    /// Transactions do not nest: one opened inside another throws, which
    /// rolls the outer one back.
    @discardableResult
    func transaction<Output>(_ body: () throws -> Output) throws -> Output {
        try exec("BEGIN IMMEDIATE")
        do {
            let output = try body()
            try exec("COMMIT")
            return output
        } catch {
            // Also after a COMMIT that failed (a full disk), which leaves
            // the transaction open.
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func bind(_ binds: [Value], to statement: OpaquePointer, handle: OpaquePointer) throws {
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let int): status = sqlite3_bind_int64(statement, index, int)
            case .real(let double): status = sqlite3_bind_double(statement, index, double)
            case .blob(let data): status = bind(data, to: statement, at: index)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else {
                throw Self.failure(status, String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) -> Int32 {
        // An empty `Data` may have no base address, and a nil pointer binds
        // NULL: a zero-length BLOB keeps the column's type.
        guard !data.isEmpty else { return sqlite3_bind_zeroblob(statement, index, 0) }
        return data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
    }

    private static func value(of statement: OpaquePointer, column: Int32) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_NULL: return .null
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            guard let text = sqlite3_column_text(statement, column) else { return .null }
            return .text(String(cString: text))
        }
    }

    /// The `user_version` pragma, which `SchemaMigrator` keeps the schema
    /// version in.
    func userVersion() throws -> Int {
        try rows("PRAGMA user_version").first?.int(0) ?? 0
    }

    func setUserVersion(_ version: Int) throws {
        try exec("PRAGMA user_version = \(version)")
    }

    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    // MARK: - Errors

    static func failure(_ code: Int32, _ message: String) -> CabalmailError {
        .storage("SQLite error \(code): \(message)")
    }

    /// The error for a statement SQLite would not compile or run, which in a
    /// debug build is also where a write-failure switch shows.
    private func refusal(_ code: Int32, _ message: String) -> CabalmailError {
        #if DEBUG
        if let table = faults.takeTripped() {
            // Said in the log as well: a caller may drop the error, and a
            // soak reads the Debug Log to see that the switch fired.
            CabalmailLog.warn("SQLiteDatabase", "injected fault: failed a write to \(table)")
            return .storage("injected fault: a write to \(table) was failed (\(SQLiteFaultSwitch.launchArgument))")
        }
        #endif
        return Self.failure(code, message)
    }
}
