import Foundation
import SQLite3
import XCTest

/// A second connection to a SQLite file, holding its write lock: every write
/// another connection tries waits out its busy timeout and then fails. It
/// stands in for the SQLite failures a test cannot produce on demand (a full
/// disk, a damaged index), and is how a test shows that a write which could
/// not start changed nothing.
public final class SQLiteWriteLock {
    private var handle: OpaquePointer?

    /// Opens `path`, which must exist, and takes its write lock.
    public init(path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            XCTFail("could not open \(path) to lock it (SQLite \(status))", file: file, line: line)
            throw CocoaError(.fileReadUnknown)
        }
        handle = opened
        let begun = sqlite3_exec(opened, "BEGIN IMMEDIATE", nil, nil, nil)
        guard begun == SQLITE_OK else {
            release()
            XCTFail("could not take the write lock on \(path) (SQLite \(begun))", file: file, line: line)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit {
        release()
    }

    /// Lets go of the lock, having written nothing. Safe to call twice.
    public func release() {
        guard let handle else { return }
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close_v2(handle)
        self.handle = nil
    }
}
