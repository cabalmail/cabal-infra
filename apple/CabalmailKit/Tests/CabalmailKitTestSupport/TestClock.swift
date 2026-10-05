import Foundation
import Synchronization

/// A settable clock for `SendQueue`'s `now:` hook, so a test can step past a
/// retry backoff instead of sleeping through it.
public final class TestClock: Sendable {
    private let current: Mutex<Date>

    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = Mutex(start)
    }

    public var now: Date {
        current.withLock { $0 }
    }

    public func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}
