import XCTest
@testable import Cabalmail

/// Issue #1426: the launch resume offer covered the filter pills and clipped
/// the first message row, and nothing the user could do would get rid of it —
/// it cleared itself after ten seconds and that was the only way out. Waiting
/// is not a dismissal action.
final class ToastDismissalTests: XCTestCase {

    // MARK: - The swipe

    /// The report asked for a swipe up, because the banner hung from the top.
    /// It hangs from the bottom now, where down is the natural direction — so
    /// the rule is direction-agnostic rather than picking a side and failing
    /// whoever guesses the other one.
    func testASwipeInAnyDirectionDismisses() {
        for translation in [
            CGSize(width: 0, height: -40),
            CGSize(width: 0, height: 40),
            CGSize(width: -40, height: 0),
            CGSize(width: 40, height: 0),
            CGSize(width: 30, height: -30)
        ] {
            XCTAssertTrue(ToastDismissal.dismisses(translation: translation), "\(translation)")
        }
    }

    /// A tap that slides a little is a tap. The banner carries a `Resume` /
    /// `Copy` button, and throwing it away under the user's finger while they
    /// reach for it is the failure mode a bare "any movement dismisses" has.
    func testASmallSlipDoesNotDismiss() {
        for translation in [
            CGSize(width: 0, height: 0),
            CGSize(width: 6, height: -8),
            CGSize(width: -12, height: 12)
        ] {
            XCTAssertFalse(ToastDismissal.dismisses(translation: translation), "\(translation)")
        }
    }

    /// The threshold is on the larger component, not on the diagonal, so a
    /// straight swipe of a given length dismisses whichever way it points.
    func testTheThresholdIsTheSameInEveryDirection() {
        let step = ToastDismissal.swipeThreshold
        XCTAssertTrue(ToastDismissal.dismisses(translation: CGSize(width: step, height: 0)))
        XCTAssertTrue(ToastDismissal.dismisses(translation: CGSize(width: 0, height: step)))
        XCTAssertFalse(ToastDismissal.dismisses(translation: CGSize(width: step - 1, height: step - 1)))
    }

    // MARK: - The close button

    /// @darth-sipid asked for enough distance between the close control and
    /// any other affordance: mistaking it for `Copy` writes the pasteboard and
    /// mistaking it for `Resume` navigates away, both unasked.
    func testTheCloseButtonIsHeldAwayFromATrailingAction() {
        XCTAssertGreaterThanOrEqual(ToastDismissal.closeButtonLeadingGap(hasAction: true), 16)
    }

    /// With no action button there is nothing to confuse it with, and the
    /// banner's own spacing already separates it from the text.
    func testAnActionlessBannerNeedsNoExtraGap() {
        XCTAssertEqual(ToastDismissal.closeButtonLeadingGap(hasAction: false), 0)
    }
}
