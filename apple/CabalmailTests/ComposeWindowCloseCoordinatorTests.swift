#if os(macOS)
import AppKit
import XCTest
@testable import Cabalmail

/// Pins the one property of the close intercept that the source comments
/// around it now lean on: `windowShouldClose` never lets AppKit close the
/// window on the user's gesture. It declines the close and hands the
/// decision to `onCloseAttempt`, which therefore runs *after* the close has
/// already been deferred and is free to be asynchronous.
///
/// #1099 documented the opposite — that the intercept "answers an
/// `NSWindowDelegate` synchronously and cannot wait for the bridge" — and
/// used that as the reason Cmd+W and the red close button still ask over an
/// untouched composer (#1106). The behaviour is real; the reason was not.
/// These assertions are what makes the corrected comment checkable.
@MainActor
final class ComposeWindowCloseCoordinatorTests: XCTestCase {

    /// A user-initiated close is declined, and the handler is invoked. The
    /// window stays up until something else closes it, so whatever the
    /// handler does may take as long as it likes.
    func testAnUnapprovedCloseIsDeclinedAndHandsOffToTheHandler() {
        let coordinator = ComposeWindowCloseCoordinator()
        var attempts = 0
        coordinator.onCloseAttempt = { attempts += 1 }

        let shouldClose = coordinator.windowShouldClose(NSWindow())

        XCTAssertFalse(shouldClose, "the close must be deferred, not performed")
        XCTAssertEqual(attempts, 1)
    }

    /// The pre-approved path — what the dialog buttons and `cancelOrAsk()`
    /// set before they run the model's close action — closes without asking
    /// again, which is the second half of the deferral contract.
    func testAPreApprovedCloseGoesThroughWithoutAsking() {
        let coordinator = ComposeWindowCloseCoordinator()
        var attempts = 0
        coordinator.onCloseAttempt = { attempts += 1 }
        coordinator.allowsClose = true

        let shouldClose = coordinator.windowShouldClose(NSWindow())

        XCTAssertTrue(shouldClose)
        XCTAssertEqual(attempts, 0, "a close we already decided on must not re-ask")
    }
}
#endif
