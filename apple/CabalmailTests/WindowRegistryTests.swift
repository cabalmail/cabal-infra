import XCTest
@testable import CabalmailUI

/// Main windows by identity, each holding an object weakly
/// (`WindowRegistry`): the deep-link router's navigators, and on iPad the
/// scene sessions a closing compose window or a tapped notification looks
/// up. A scene session cannot be built in a test, so a plain object stands in.
@MainActor
final class WindowRegistryTests: XCTestCase {
    private final class Session {}

    func testAWindowsObjectIsFoundByItsWindowAndTheWindowByItsObject() {
        var registry = WindowRegistry<Session>()
        let window = UUID()
        let session = Session()

        registry.register(session, for: window)

        XCTAssertTrue(registry.value(for: window) === session)
        XCTAssertEqual(registry.window(holding: session), window)
        XCTAssertNil(registry.value(for: UUID()))
        XCTAssertNil(registry.value(for: nil))
        XCTAssertNil(registry.window(holding: Session()))
        XCTAssertNil(registry.window(holding: nil))
    }

    /// The fallback when no window is named: the one registered last.
    func testTheLatestIsTheOneRegisteredLast() {
        var registry = WindowRegistry<Session>()
        XCTAssertNil(registry.latest)
        let first = Session()
        let second = Session()
        registry.register(first, for: UUID())
        registry.register(second, for: UUID())

        XCTAssertTrue(registry.latest === second)
    }

    /// The registry keeps nothing alive: a window gone without saying so
    /// drops out, and the latest falls back to one still there.
    func testAnObjectThatHasGoneDropsOut() {
        var registry = WindowRegistry<Session>()
        let kept = Session()
        let keptWindow = UUID()
        let goneWindow = UUID()
        registry.register(kept, for: keptWindow)
        do {
            let gone = Session()
            registry.register(gone, for: goneWindow)
            XCTAssertTrue(registry.latest === gone, "precondition")
        }

        XCTAssertNil(registry.value(for: goneWindow))
        XCTAssertTrue(registry.latest === kept)
    }

    /// iPadOS can reconnect a scene under a new window identity while its
    /// session lives on: the session answers to the new window only.
    func testAnObjectRegisteredUnderANewWindowLeavesItsOldOne() {
        var registry = WindowRegistry<Session>()
        let session = Session()
        let old = UUID()
        let new = UUID()
        registry.register(session, for: old)

        registry.register(session, for: new)

        XCTAssertNil(registry.value(for: old))
        XCTAssertEqual(registry.window(holding: session), new)
    }

    func testRegisteringAgainReplacesWhatTheWindowHeld() {
        var registry = WindowRegistry<Session>()
        let window = UUID()
        let first = Session()
        let second = Session()
        registry.register(first, for: window)

        registry.register(second, for: window)

        XCTAssertTrue(registry.value(for: window) === second)
        XCTAssertNil(registry.window(holding: first))
    }

    /// A torn-down instance cannot remove the one that replaced it.
    func testRemovingHoldsOnlyWhileTheWindowStillHasThatObject() {
        var registry = WindowRegistry<Session>()
        let window = UUID()
        let old = Session()
        let replacement = Session()
        registry.register(old, for: window)
        registry.register(replacement, for: window)

        registry.remove(window, holding: old)
        XCTAssertTrue(registry.value(for: window) === replacement)

        registry.remove(window, holding: replacement)
        XCTAssertNil(registry.value(for: window))
    }

    func testRemovingAWindowOutrightForgetsIt() {
        var registry = WindowRegistry<Session>()
        let window = UUID()
        let session = Session()
        registry.register(session, for: window)

        registry.remove(window)

        XCTAssertNil(registry.value(for: window))
        XCTAssertNil(registry.latest)
    }
}
