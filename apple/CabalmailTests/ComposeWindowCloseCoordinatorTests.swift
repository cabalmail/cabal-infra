#if os(macOS)
import AppKit
import XCTest
@testable import Cabalmail

/// Pins the one property of the close intercept that the source comments
/// around it lean on: `windowShouldClose` never lets AppKit close the window
/// on the user's gesture. It declines the close and hands the decision to
/// `onCloseAttempt`, which therefore runs *after* the close has already been
/// deferred and is free to be asynchronous.
///
/// #1099 documented the opposite — that the intercept "answers an
/// `NSWindowDelegate` synchronously and cannot wait for the bridge" — and
/// used that as the reason Cmd+W and the red close button still ask over an
/// untouched composer (#1106). The behaviour is real; the reason was not.
/// #1106 then cashed the deferral in: `onCloseAttempt` is `async` and
/// `ComposeView` binds it to the same `cancelOrAsk()` the toolbar Cancel
/// button runs, so the handler now genuinely suspends on the WebKit bridge
/// before it knows whether to raise the dialog. These assertions are what
/// makes that checkable.
@MainActor
final class ComposeWindowCloseCoordinatorTests: XCTestCase {

    /// A user-initiated close is declined, and the handler is invoked. The
    /// window stays up until something else closes it, so whatever the
    /// handler does may take as long as it likes.
    ///
    /// The handler used to be checked synchronously here (#1107). It is not
    /// any more: since #1106 `windowShouldClose` answers AppKit on this turn
    /// of the runloop and runs the handler in a `Task`, so the invocation is
    /// awaited rather than asserted inline. What the case pins — declined
    /// close, handler reached exactly once — is unchanged.
    func testAnUnapprovedCloseIsDeclinedAndHandsOffToTheHandler() async {
        let coordinator = ComposeWindowCloseCoordinator()
        let handled = expectation(description: "close handler runs")
        var attempts = 0
        coordinator.onCloseAttempt = {
            attempts += 1
            handled.fulfill()
        }

        let shouldClose = coordinator.windowShouldClose(NSWindow())

        XCTAssertFalse(shouldClose, "the close must be deferred, not performed")
        await fulfillment(of: [handled], timeout: 2)
        XCTAssertEqual(attempts, 1)
    }

    /// The pre-approved path — what the dialog buttons and `cancelOrAsk()`
    /// set before they run the model's close action — closes without asking
    /// again, which is the second half of the deferral contract.
    func testAPreApprovedCloseGoesThroughWithoutAsking() async {
        let coordinator = ComposeWindowCloseCoordinator()
        var attempts = 0
        coordinator.onCloseAttempt = { attempts += 1 }
        coordinator.allowsClose = true

        let shouldClose = coordinator.windowShouldClose(NSWindow())

        XCTAssertTrue(shouldClose)
        XCTAssertEqual(attempts, 0, "a close we already decided on must not re-ask")
    }

    /// The deferral is only worth anything if a handler that *suspends*
    /// still gets its decision honoured — that is the whole mechanism behind
    /// #1106. Stands in for the real handler: `cancelOrAsk()` awaits
    /// `computeMessageBodies()` on the WebKit bridge, finds nothing was
    /// typed, pre-approves the close and lets the model close the window.
    ///
    /// AppKit must have its `false` back before any of that resolves, and
    /// the close the handler then asks for must not be intercepted again.
    func testAHandlerThatSuspendsBeforeDecidingStillClosesTheWindow() async {
        let coordinator = ComposeWindowCloseCoordinator()
        let decided = expectation(description: "handler decided")
        var answeredBeforeHandlerFinished = false
        coordinator.onCloseAttempt = { [weak coordinator] in
            // Whatever the bridge round trip costs, it happens here.
            await Task.yield()
            coordinator?.allowsClose = true
            decided.fulfill()
        }

        let firstAnswer = coordinator.windowShouldClose(NSWindow())
        answeredBeforeHandlerFinished = !coordinator.allowsClose

        XCTAssertFalse(firstAnswer, "AppKit is answered without waiting for the decision")
        XCTAssertTrue(
            answeredBeforeHandlerFinished,
            "the delegate must return before the handler resolves, not after"
        )

        await fulfillment(of: [decided], timeout: 2)

        XCTAssertTrue(
            coordinator.windowShouldClose(NSWindow()),
            "the close the handler decided on must go through unintercepted"
        )
    }
}
#endif
