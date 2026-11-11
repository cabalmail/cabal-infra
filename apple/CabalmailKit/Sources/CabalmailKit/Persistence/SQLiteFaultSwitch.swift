#if DEBUG
import Foundation
import SQLite3
import Synchronization

/// Fails the next write to one named table, once: how a soak or a test shows
/// what a store does when SQLite refuses a write, which a full disk or a
/// damaged index cannot be made to do on demand (#1939 could only be cleared
/// on tests for want of this).
///
/// Launch a debug build with `-CabalmailFailNextWrite <table>`, for example
/// `-CabalmailFailNextWrite pending`: the first INSERT, UPDATE or DELETE on
/// that table throws `CabalmailError.storage`, and every later one runs.
/// Release builds do not contain the switch.
final class SQLiteFaultSwitch: Sendable {
    static let launchArgument = "-CabalmailFailNextWrite"

    /// The switch the launch argument arms. One for the process, which
    /// every connection answers to, so the write fails once however many
    /// stores are open on the file.
    static let launch: SQLiteFaultSwitch = {
        let named = table(in: ProcessInfo.processInfo.arguments)
        if let named {
            CabalmailLog.warn("SQLiteDatabase", "\(launchArgument): the next write to \(named) will be failed")
        }
        return SQLiteFaultSwitch(table: named)
    }()

    private let armed: Mutex<String?>

    init(table: String? = nil) {
        armed = Mutex(table)
    }

    func arm(table: String) {
        armed.withLock { $0 = table }
    }

    /// Whether a write to `table` fails now. A yes disarms the switch.
    func trips(on table: String) -> Bool {
        armed.withLock { armed in
            guard armed == table else { return false }
            armed = nil
            return true
        }
    }

    /// The table named after the launch argument, if it is there.
    static func table(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(flag + 1) else { return nil }
        let table = arguments[flag + 1]
        return table.isEmpty || table.hasPrefix("-") ? nil : table
    }
}

/// One connection's hook for the switches: it asks SQLite to check every
/// statement it compiles (the authorizer callback, which names the table a
/// statement writes, a trigger's writes included) and refuses the one a
/// switch is armed for.
final class SQLiteFaultProbe {
    /// This connection's own switch, which a test arms.
    let own = SQLiteFaultSwitch()
    /// The process-wide switch; a test substitutes its own.
    var shared = SQLiteFaultSwitch.launch
    private var tripped: String?

    /// Fails this connection's next write to `table`.
    func arm(table: String) {
        own.arm(table: table)
    }

    func watch(_ handle: OpaquePointer) {
        // Unretained: the connection owns this probe and closes the handle
        // before it lets go of it.
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_set_authorizer(handle, { context, action, table, _, _, _ in
            guard let context, let table,
                  action == SQLITE_INSERT || action == SQLITE_UPDATE || action == SQLITE_DELETE
            else { return SQLITE_OK }
            let probe = Unmanaged<SQLiteFaultProbe>.fromOpaque(context).takeUnretainedValue()
            return probe.refuses(String(cString: table)) ? SQLITE_DENY : SQLITE_OK
        }, context)
    }

    private func refuses(_ table: String) -> Bool {
        guard own.trips(on: table) || shared.trips(on: table) else { return false }
        tripped = table
        return true
    }

    /// The table whose write was just refused, handed over once, so the
    /// error can say the failure was injected.
    func takeTripped() -> String? {
        defer { tripped = nil }
        return tripped
    }
}
#endif
