import XCTest
import AppKit
import SwiftUI
@testable import Cabalmail

// Regression coverage for #1355.
//
// The unsubscribed-folder banner is mounted in `safeAreaInset(edge: .bottom)`,
// which makes its *ideal* height part of the hosting window's minimum content
// height. Its sentence carried `.fixedSize(horizontal: false, vertical: true)`
// and no line limit, so it had no ideal height until it was proposed a width —
// and AppKit computes a window minimum by proposing a width near zero, where
// the sentence wraps to about one word per line. Measured 731 pt for the whole
// banner, which is where the reported 973 pt minimum window height came from:
// selecting Drafts, Sent or Trash grew the window and it then refused to shrink
// until a subscribed folder removed the inset again.
//
// These measure the banner the way the window does — the ideal height of the
// exact view `safeAreaInset` mounts, at a proposed width — rather than scanning
// the source, because the defect is a number and the fix is a bound on it. The
// whole row and not just its sentence, because the icon, the spacer and the
// refresh button take width off the text: the sentence is laid out narrower
// than the column, and a limit measured against the bare label reads as
// generous when it is in fact truncating.
final class UnsubscribedBannerLineLimitTests: XCTestCase {

    /// The banner's ideal height at `width`, which is the quantity
    /// `safeAreaInset` contributes to the window's minimum content height.
    private static func idealHeight(width: CGFloat, lineLimit: Int?) -> CGFloat {
        let banner = UnsubscribedBannerRow(isRefreshing: false, lineLimit: lineLimit, refresh: {})
        let host = NSHostingController(rootView: banner)
        return host.sizeThatFits(in: NSSize(width: width, height: 30_000)).height
    }

    private static func bounded(_ width: CGFloat) -> CGFloat {
        idealHeight(width: width, lineLimit: UnsubscribedBannerPolicy.messageLineLimit)
    }

    private static func unbounded(_ width: CGFloat) -> CGFloat {
        idealHeight(width: width, lineLimit: nil)
    }

    /// The defect and the fix, in one comparison: at the near-zero width a
    /// window-minimum calculation proposes, the unbounded sentence is hundreds
    /// of points tall and the bounded one is a few lines. Both halves matter —
    /// the first is what makes this a real failure rather than a tautology.
    func testLineLimitBoundsTheIdealHeightAtTheWidthAWindowMinimumProposes() {
        let unbounded = Self.unbounded(1)
        let bounded = Self.bounded(1)

        XCTAssertGreaterThan(
            unbounded, 400,
            """
            the unbounded sentence should still collapse to ~one word per line here; \
            if it does not, this test no longer exercises #1355
            """
        )
        XCTAssertLessThan(
            bounded, 100,
            """
            \(UnsubscribedBannerPolicy.messageLineLimit) lines of .caption, not \(unbounded) pt — \
            this is the window minimum the banner is allowed to ask for (#1355)
            """
        )
    }

    /// What the bound must not cost: the narrowest width the banner is ever
    /// laid out at for real is the squeezed macOS message-list column (iPad and
    /// visionOS floor the column at `ListColumnWidth.minimum`, compact iPhone
    /// gives it the screen). The limit has to be loose enough that the sentence
    /// still wraps in full there — equal heights mean no line was dropped.
    func testLineLimitDoesNotTruncateAtTheNarrowestColumnTheBannerCanDrawIn() {
        let width = ListColumnWidth.squeezedMinimum
        XCTAssertEqual(
            Self.bounded(width), Self.unbounded(width), accuracy: 0.5,
            "at \(width) pt the sentence needs more lines than messageLineLimit allows, so the banner truncates (#1355)"
        )
    }

    /// And nothing changes where the banner already fit: at the column's launch
    /// width the sentence is short enough that the limit is not reached.
    func testNothingChangesAtTheColumnsLaunchWidth() {
        XCTAssertEqual(
            Self.bounded(ListColumnWidth.ideal), Self.unbounded(ListColumnWidth.ideal), accuracy: 0.5,
            "the limit should be invisible at a comfortable width (#1355)"
        )
    }

    /// The bound is only load-bearing while the sentence keeps `.fixedSize`:
    /// without it the label truncates to one line at every width instead of
    /// wrapping, which is a different regression with the same window minimum.
    func testTheSentenceStillWrapsRatherThanTruncatingToOneLine() {
        let oneLine = Self.bounded(ListColumnWidth.ideal)
        XCTAssertGreaterThan(
            Self.bounded(ListColumnWidth.squeezedMinimum), oneLine,
            "the sentence should wrap to more than one line in a squeezed column (#1355)"
        )
    }
}
