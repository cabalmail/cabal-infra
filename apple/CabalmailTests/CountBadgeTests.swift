import XCTest
import AppKit
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

// Coverage for the shared sidebar count badge (workstream 1.5). The mail
// folder rows and the feed rows both draw `CountBadge`; what it says is
// `FolderCountBadge`'s rule, which `FolderCountBadgeTests` covers. These
// measure what the view does with that rule, the way a sidebar row lays it
// out.
@MainActor
final class CountBadgeTests: XCTestCase {

    /// A count the mode hides draws nothing at all, so a caught-up row has
    /// no empty capsule beside its name.
    func testAHiddenCountTakesNoSpace() {
        let hidden = Self.size(of: CountBadge(display: .unread, unread: 0, total: 40))
        XCTAssertEqual(hidden.width, 0, accuracy: 0.5)
        XCTAssertEqual(hidden.height, 0, accuracy: 0.5)

        let unfetched = Self.size(of: CountBadge(display: .both, unread: nil, total: nil))
        XCTAssertEqual(unfetched.width, 0, accuracy: 0.5, "an unfetched folder shows no 0/0")
    }

    /// A shown count sits 8 pt in from each side of its capsule and 2 pt
    /// from top and bottom: mail's padding, which the feed rows (6 by 1)
    /// now share.
    func testAShownCountIsPaddedEightByTwo() {
        let shown = Self.size(of: CountBadge(display: .unread, unread: 4, total: 40))
        let digits = Self.size(of: Text("4").font(.caption.monospacedDigit()))
        XCTAssertEqual(shown.width, digits.width + 16, accuracy: 0.5, "8 pt of padding each side")
        XCTAssertEqual(shown.height, digits.height + 4, accuracy: 0.5, "2 pt of padding top and bottom")
    }

    /// The digits are monospaced, so a badge keeps its width as the count
    /// changes instead of jittering the row's trailing edge: "111" is as
    /// wide as "888", where proportional digits draw the ones narrower.
    func testTheBadgeKeepsItsWidthAsTheCountChanges() {
        let ones = Self.size(of: CountBadge(display: .unread, unread: 111, total: nil)).width
        let eights = Self.size(of: CountBadge(display: .unread, unread: 888, total: nil)).width
        XCTAssertEqual(ones, eights, accuracy: 0.25)
    }

    private static func size<V: View>(of view: V) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: 1_000, height: 1_000))
    }
}
