import Foundation
import os
import Synchronization

/// The one way to log from the Kit and the apps.
///
/// Each line goes to two places, synchronously and in call order:
///
/// - the unified log, through an `os.Logger` with subsystem `subsystem` and
///   the caller's category, so Console, `log stream` and a sysdiagnose see it;
/// - `DebugLogStore.shared`, the ring behind Settings → Debug Log.
///
/// The message is logged to the unified log as private data, because lines
/// carry folder names, addresses and server errors. Console shows the text
/// while Xcode is attached, or once private data is enabled for the subsystem;
/// the Debug Log always shows it. The notification extensions don't link the
/// Kit and keep their own `os.Logger`.
public enum CabalmailLog {
    /// Shared by every category, so `log stream --predicate
    /// 'subsystem == "com.cabalmail.Cabalmail"'` shows everything.
    public static let subsystem = "com.cabalmail.Cabalmail"

    public static func debug(_ category: String, _ message: @autoclosure () -> String) {
        record(.debug, category, message(), into: .shared)
    }

    public static func info(_ category: String, _ message: @autoclosure () -> String) {
        record(.info, category, message(), into: .shared)
    }

    public static func warn(_ category: String, _ message: @autoclosure () -> String) {
        record(.warn, category, message(), into: .shared)
    }

    public static func error(_ category: String, _ message: @autoclosure () -> String) {
        record(.error, category, message(), into: .shared)
    }

    /// Writes one line to the unified log and to `store`. `MetricKitCollector`
    /// and the tests pass their own store; everything else uses `.shared`.
    static func record(
        _ level: DebugLogStore.Level,
        _ category: String,
        _ message: String,
        into store: DebugLogStore
    ) {
        logger(for: category).log(level: level.osLogType, "\(message, privacy: .private)")
        store.append(DebugLogStore.Entry(level: level, category: category, message: message))
    }

    private static let loggers = Mutex<[String: Logger]>([:])

    private static func logger(for category: String) -> Logger {
        loggers.withLock { cache in
            if let logger = cache[category] { return logger }
            let logger = Logger(subsystem: subsystem, category: category)
            cache[category] = logger
            return logger
        }
    }
}

extension DebugLogStore.Level {
    /// `warn` maps to the default (notice) type so the unified log keeps it
    /// apart from errors; `os.Logger.warning` would file it as an error.
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .default
        case .error: return .error
        }
    }
}
