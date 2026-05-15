import Foundation
import OSLog

// Issue #403 follow-up: body-fetch instrumentation. The macOS client behaves
// per the fix in #405, but iOS reports the error/retry screen rendering
// before the navigation slide-in even completes, which would only be possible
// if `load()` is finishing (failing) sub-frame. These helpers let us log
// entry/exit timing, which catch arm fires, and `Task.isCancelled` so a
// stage capture can tell us whether the outer SwiftUI `.task` is being
// cancelled mid-push. Call sites stay short so SwiftLint's line/function
// caps don't fight us. Strip once the iOS path is fully understood.
enum BodyFetchLog {
    static let logger = Logger(subsystem: "com.cabalmail.Cabalmail", category: "body-fetch")

    static func debug(_ event: String, uid: UInt32, _ extras: String = "") {
        let suffix = extras.isEmpty ? "" : " \(extras)"
        logger.debug("\(event, privacy: .public) uid=\(uid, privacy: .public)\(suffix, privacy: .public)")
    }

    static func error(_ event: String, uid: UInt32, _ extras: String = "") {
        let suffix = extras.isEmpty ? "" : " \(extras)"
        logger.error("\(event, privacy: .public) uid=\(uid, privacy: .public)\(suffix, privacy: .public)")
    }

    static func flag(_ name: String, _ value: Bool) -> String { "\(name)=\(value)" }
    static func int(_ name: String, _ value: Int) -> String { "\(name)=\(value)" }
    static func text(_ name: String, _ value: String) -> String { "\(name)=\(value)" }

    static func join(_ parts: String...) -> String { parts.joined(separator: " ") }

    // Convenience used by `MessageDetailViewModel.load()` so each catch arm
    // stays a single line. Returns the user-facing error string the view
    // model should set on `errorMessage`.
    static func cancelledMessage(uid: UInt32, attempt: Int, source: String) -> String {
        debug("load \(source)", uid: uid, join(
            int("attempt", attempt),
            flag("taskCancelled", Task.isCancelled)
        ))
        return "Couldn't load message body."
    }

    static func cabalmailMessage(uid: UInt32, attempt: Int, error err: Error) -> String {
        let described = String(describing: err)
        error("load CabalmailError", uid: uid, join(int("attempt", attempt), text("error", described)))
        return described
    }

    static func loadEnter(uid: UInt32, hadError: Bool, hasAttemptedLoad: Bool) {
        debug("load enter", uid: uid, join(
            flag("cancelled", Task.isCancelled),
            flag("hadError", hadError),
            flag("hasAttemptedLoad", hasAttemptedLoad)
        ))
    }

    static func loadExit(uid: UInt32, startedAt: Date, errorSet: Bool) {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        debug("load exit", uid: uid, join(
            int("elapsed_ms", elapsedMs),
            flag("errorSet", errorSet),
            flag("cancelled", Task.isCancelled)
        ))
    }

    static func loadAttempt(uid: UInt32, attempt: Int) {
        debug("load attempt", uid: uid, join(int("attempt", attempt), flag("cancelled", Task.isCancelled)))
    }

    static func otherMessage(uid: UInt32, attempt: Int, error err: Error) -> String {
        let typeName = String(describing: type(of: err))
        let described = err.localizedDescription
        error("load other", uid: uid, join(int("attempt", attempt), text("type", typeName), text("error", described)))
        return described
    }
}
