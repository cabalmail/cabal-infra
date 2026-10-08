import Foundation
import XCTest

/// Ceiling for `waitUntil`. It is a bound on *failure*, not a performance
/// assertion: a condition that holds returns on the next poll, so a generous
/// budget costs wall clock only when something is genuinely stuck. Keep it
/// well clear of what a loaded CI runner can do to a sub-second drain — the
/// forward-compat runner once stretched one to 8.8 s against a 2 s ceiling.
public let defaultWaitTimeout: TimeInterval = 30

/// Polls `condition` until it holds or `timeout` elapses, failing at the
/// caller's line if it never does. The queue, cache and indexer actors these
/// suites drive run their work on their own executors, so a drain can't be
/// awaited from the outside — polling is the stable idiom for that handoff.
public func waitUntil(
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

/// `waitUntil` for main-actor state: polls `condition` on the main actor,
/// letting the model's own tasks run between polls, until it holds, failing
/// at the caller's line after `timeout`. Staying on the main actor keeps the
/// condition from crossing an isolation boundary, which `waitUntil`'s
/// nonisolated closure would.
@MainActor
public func waitUntilOnMainActor(
    timeout: TimeInterval = defaultWaitTimeout,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail(String(format: "condition never held within %.0fs", timeout), file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Counts the elements already buffered on `stream` without waiting for
/// more: cancelling the drain finishes the stream, which still hands over
/// its buffer, so this never waits on an element that isn't coming.
public func bufferedCount<Element: Sendable>(_ stream: AsyncStream<Element>) async -> Int {
    await bufferedElements(stream).count
}

/// The elements already buffered on `stream`, in order, without waiting for
/// more (see `bufferedCount`). The stream is finished afterwards.
public func bufferedElements<Element: Sendable>(_ stream: AsyncStream<Element>) async -> [Element] {
    let drain = Task {
        var elements: [Element] = []
        for await element in stream { elements.append(element) }
        return elements
    }
    drain.cancel()
    return await drain.value
}
