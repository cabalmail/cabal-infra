import XCTest
@testable import Cabalmail

/// UIKit answers `didReceive`'s completion handler by refreshing the window
/// scene's snapshot and state-restoration archive, which asserts the main
/// thread. The delegate method is `nonisolated`, so the completion used to run
/// on the global executor and every notification tap aborted the app with
/// `NSInternalInconsistencyException: Call must be made on main thread`
/// (#1534). The hop is this type's whole job, so this is where it is pinned.
final class PushActionCompletionTests: XCTestCase {
    func testTheCompletionRunsOnTheMainThreadFromABackgroundTask() async {
        let ranOnMain = LockedFlag()
        // `Task.detached` is the arm: it is the global executor the
        // nonisolated delegate body runs on, which is exactly where the
        // pre-fix code called the handler from.
        await Task.detached {
            await PushActionCompletion.finish { ranOnMain.record(Thread.isMainThread) }
        }.value
        XCTAssertEqual(ranOnMain.value, true, "the completion handler must run on the main thread")
    }

    func testTheCompletionRunsExactlyOnce() async {
        let calls = LockedCounter()
        await Task.detached {
            await PushActionCompletion.finish { calls.increment() }
        }.value
        XCTAssertEqual(calls.value, 1)
    }

    func testTheCallerResumesOnlyAfterTheCompletionHasRun() async {
        // The system's background budget for MARK_READ / ARCHIVE depends on
        // the completion not being fired-and-forgotten.
        let calls = LockedCounter()
        await PushActionCompletion.finish { calls.increment() }
        XCTAssertEqual(calls.value, 1, "finish must not return before the handler has run")
    }
}

/// Minimal lock-guarded boxes so the assertions can be written from a
/// `@Sendable` closure without reaching for an actor (which would add its own
/// hop and blunt the thread assertion).
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func record(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.lock(); stored += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
}
