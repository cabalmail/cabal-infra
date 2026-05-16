import Foundation
import OSLog

// Issue #403 follow-up. The `.onAppear` + unstructured-Task fix landed but
// the iPhone error/retry-on-slide-in symptom persists, suggesting something
// other than SwiftUI's `.task` machinery is cancelling the body fetch.
// This file logs the load-path state machine end to end so a real-device
// capture can show us where `load()` is dying. Strip once we understand.
//
// Stream from the device:
//   log stream --predicate 'subsystem == "com.cabalmail.Cabalmail" \
//     && category == "body-fetch"'
// (no --level debug needed: everything below is `.info` or `.error`.)
enum BodyFetchLog {
    static let logger = Logger(subsystem: "com.cabalmail.Cabalmail", category: "body-fetch")

    // `.notice` instead of `.info` so the messages aren't dropped on
    // optimized / TestFlight builds. Switch back to `.info` (or strip the
    // helper entirely) once #403 is closed.
    private static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    private static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func appear(uid: UInt32, modelExists: Bool) {
        info("onAppear uid=\(uid) modelExists=\(modelExists)")
    }

    static func disappear(uid: UInt32, hadTask: Bool) {
        info("onDisappear uid=\(uid) hadTask=\(hadTask)")
    }

    static func startGate(uid: UInt32, hasHTML: Bool, hasPlain: Bool, isLoading: Bool, hasTask: Bool) {
        info("startLoadIfNeeded uid=\(uid) hasHTML=\(hasHTML) hasPlain=\(hasPlain) "
             + "isLoading=\(isLoading) hasTask=\(hasTask)")
    }

    static func startSpawn(uid: UInt32) {
        info("startLoadIfNeeded spawn uid=\(uid)")
    }

    static func loadEnter(uid: UInt32) {
        info("load enter uid=\(uid) taskCancelled=\(Task.isCancelled)")
    }

    static func loadExit(uid: UInt32, startedAt: Date, errorSet: Bool, hasBody: Bool) {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        info("load exit uid=\(uid) elapsed_ms=\(elapsedMs) errorSet=\(errorSet) "
             + "hasBody=\(hasBody) taskCancelled=\(Task.isCancelled)")
    }

    static func loadAttempt(uid: UInt32, attempt: Int) {
        info("load attempt uid=\(uid) attempt=\(attempt)")
    }

    static func loadSuccess(uid: UInt32, attempt: Int, bytes: Int) {
        info("load success uid=\(uid) attempt=\(attempt) bytes=\(bytes)")
    }

    static func loadURLError(uid: UInt32, attempt: Int, error err: URLError) {
        let host = err.failingURL?.host ?? "unknown"
        let underlying = (err.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain ?? "none"
        error("load URLError uid=\(uid) attempt=\(attempt) code=\(err.code.rawValue) "
              + "host=\(host) underlying=\(underlying) taskCancelled=\(Task.isCancelled)")
    }

    static func loadCancellation(uid: UInt32, attempt: Int) {
        error("load CancellationError uid=\(uid) attempt=\(attempt) "
              + "taskCancelled=\(Task.isCancelled)")
    }

    static func loadOther(uid: UInt32, attempt: Int, error err: Error) {
        let type = String(describing: type(of: err))
        error("load other uid=\(uid) attempt=\(attempt) type=\(type) "
              + "error=\(err.localizedDescription)")
    }

    // Diagnostic: pin down whether the two phantom `MessageDetailView`
    // instances on iPhone are looking up the *same* `MessageDetailModelStore`
    // and getting the *same* `MessageDetailViewModel` back. If `storeID`
    // differs between the two phantoms, the `.environment(...)` injection
    // isn't reaching one of them; if `storeID` matches but `modelID`
    // differs, the store's cache check is failing.
    static func envCheck(uid: UInt32, storeID: String) {
        info("envCheck uid=\(uid) storeID=\(storeID)")
    }

    static func storeLookup(uid: UInt32, storeID: String, hit: Bool, modelID: String, currentKey: String) {
        info("storeLookup uid=\(uid) storeID=\(storeID) hit=\(hit) "
             + "modelID=\(modelID) currentKey=\(currentKey)")
    }

    static func storeEntry(
        uid: UInt32,
        storeID: String,
        lookupKey: String,
        entryKey: String,
        entryModelID: String
    ) {
        info("storeEntry uid=\(uid) storeID=\(storeID) lookupKey=\(lookupKey) "
             + "entryKey=\(entryKey) entryModelID=\(entryModelID)")
    }
}
