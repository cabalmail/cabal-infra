import Foundation
import XCTest

/// Ceiling for `waitUntil`. It is a bound on *failure*, not a performance
/// assertion: a condition that holds returns on the next poll, so a generous
/// budget costs wall clock only when something is genuinely stuck. Keep it
/// well clear of what a loaded CI runner can do to a sub-second drain — the
/// forward-compat runner once stretched one to 8.8 s against a 2 s ceiling.
let defaultWaitTimeout: TimeInterval = 30

/// Polls `condition` until it holds or `timeout` elapses, failing at the
/// caller's line if it never does. The queue, cache and indexer actors these
/// suites drive run their work on their own executors, so a drain can't be
/// awaited from the outside — polling is the stable idiom for that handoff.
func waitUntil(
    timeout: TimeInterval = defaultWaitTimeout,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () async throws -> Bool
) async throws {
    let started = Date()
    let deadline = started.addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let elapsed = Date().timeIntervalSince(started)
    XCTFail(
        String(format: "condition never met within %.0fs (waited %.1fs)", timeout, elapsed),
        file: file,
        line: line
    )
}
