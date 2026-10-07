import XCTest
import AppKit
import SwiftUI
@testable import CabalmailUI

// Coverage for the shared filter pill (workstream 1.5). The message list, the
// feed item list and both sidebar filter rows draw their pills with
// `FilterPill`, and the two list bars lay theirs out in a `FilterPillStrip`.
//
// The layout cases measure the views the way the bars mount them, with
// `NSHostingController.sizeThatFits`, rather than scanning the source: what
// matters is when the pills stack, and that is a number.
@MainActor
final class FilterPillTests: XCTestCase {

    // MARK: - Spoken label

    func testSpokenLabelReadsTheCountAfterTheLabel() {
        XCTAssertEqual(FilterPill.spokenLabel("Unread", count: 3), "Unread, 3")
        XCTAssertEqual(FilterPill.spokenLabel("All", count: 0), "All, 0")
    }

    /// A large count is grouped as the drawn one is (`Text("\(count)")`
    /// formats with the locale), so the label and the pill agree.
    func testSpokenLabelGroupsALargeCountForTheLocale() {
        XCTAssertEqual(FilterPill.spokenLabel("All", count: 12_345), "All, \(12_345.formatted())")
        XCTAssertNotEqual(
            FilterPill.spokenLabel("All", count: 12_345), "All, 12345", "the en_US test host groups thousands"
        )
    }

    func testSpokenLabelWithoutACountIsTheLabel() {
        XCTAssertEqual(FilterPill.spokenLabel("Flagged", count: nil), "Flagged")
    }

    // MARK: - One line

    /// The strip can only tell that a row no longer fits if each pill keeps
    /// its label on one line. Squeezed to a sliver, a pill is as tall as it is
    /// with room to spare; without `.fixedSize` the label wraps a character
    /// at a time and the pill grows several lines tall.
    func testAPillKeepsItsLabelOnOneLineWhenSqueezed() {
        let pill = FilterPill(label: "Flagged", isOn: true, count: 128, identifier: "probe") {}
        let roomy = Self.size(of: pill, width: 1_000).height
        let squeezed = Self.size(of: pill, width: 8).height
        XCTAssertEqual(squeezed, roomy, accuracy: 0.5, "the pill's label wrapped instead of staying on one line")
    }

    // MARK: - Stacking

    /// The pills stack exactly when the whole row stops fitting, which is
    /// what the message list's bar did when its `ViewThatFits` wrapped the
    /// row and its trailing controls: with 20 pt to spare they sit side by
    /// side, and 20 pt short of the row they stack. A strip that gave up
    /// sooner, at an even share of the free width say, fails the first half.
    func testPillsStackOnlyWhenTheWholeRowNoLongerFits() {
        let pills = Self.size(of: Self.strip, width: 10_000).width
        let oneRow = Self.size(of: Self.row, width: 10_000).height
        let needed = pills + Self.trailingWidth + 2 * Self.rowSpacing

        XCTAssertEqual(
            Self.size(of: Self.row, width: needed + 20).height, oneRow, accuracy: 0.5,
            "at \(needed + 20) pt the whole row fits, but the pills stacked"
        )
        XCTAssertGreaterThan(
            Self.size(of: Self.row, width: needed - 20).height, oneRow * 2,
            "at \(needed - 20) pt the row does not fit, but the pills stayed side by side"
        )
    }

    // MARK: - Fixtures

    private static let trailingWidth: CGFloat = 80
    private static let rowSpacing: CGFloat = 6

    private static var strip: some View {
        FilterPillStrip {
            ForEach(["All", "Unread", "Flagged"], id: \.self) { label in
                FilterPill(label: label, isOn: label == "All", count: 1_234, identifier: label) {}
            }
        }
    }

    /// The bars' shape: the strip, a spacer, then fixed trailing controls.
    private static var row: some View {
        HStack(spacing: rowSpacing) {
            strip
            Spacer()
            Color.clear.frame(width: trailingWidth, height: 10)
        }
    }

    private static func size<V: View>(of view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: width, height: 10_000))
    }
}
