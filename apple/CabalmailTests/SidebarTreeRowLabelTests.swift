import XCTest
import AppKit
import SwiftUI
@testable import CabalmailUI

// Coverage for the shared sidebar tree row (workstream 1.5): the mail folder
// rows and the feed rows both draw `SidebarTreeRowLabel`. The tints are
// `FolderIconTint` / `FolderNameTint`'s and have their own tests; these
// measure the row's geometry the way a sidebar lays it out.
@MainActor
final class SidebarTreeRowLabelTests: XCTestCase {

    /// A row with nothing under it keeps the chevron's slot, so its icon
    /// lines up with a parent's at the same depth instead of reading as one
    /// level shallower.
    func testALeafReservesTheChevronSlot() {
        let leaf = Self.width(of: Self.row(depth: 1, hasChildren: false))
        let parent = Self.width(of: Self.row(depth: 1, hasChildren: true))
        XCTAssertEqual(leaf, parent, accuracy: 0.5)
    }

    /// Each level deeper indents the row by 14 pt, on both trees.
    func testEachLevelIndentsByFourteen() {
        let one = Self.width(of: Self.row(depth: 1, hasChildren: false))
        let two = Self.width(of: Self.row(depth: 2, hasChildren: false))
        let three = Self.width(of: Self.row(depth: 3, hasChildren: false))
        XCTAssertEqual(two - one, 14, accuracy: 0.5)
        XCTAssertEqual(three - two, 14, accuracy: 0.5)
    }

    /// A feed title keeps to one line (`titleLineLimit: 1`); a mail folder
    /// name, with no limit, wraps rather than truncating.
    func testTheTitleLineLimitIsTheCallers() {
        let long = "A feed with a title much too long for the sidebar column it sits in"
        let oneLine = Self.height(of: Self.row(title: long, lineLimit: 1), width: 160)
        let wrapped = Self.height(of: Self.row(title: long, lineLimit: nil), width: 160)
        let short = Self.height(of: Self.row(title: "Tech", lineLimit: 1), width: 160)
        XCTAssertEqual(oneLine, short, accuracy: 0.5, "the one-line title wrapped")
        XCTAssertGreaterThan(wrapped, short + 10, "the unlimited title did not wrap")
    }

    // MARK: - Fixtures

    private static func row(
        title: String = "Tech", depth: Int = 0, hasChildren: Bool = false, lineLimit: Int? = nil
    ) -> some View {
        SidebarTreeRowLabel(
            title: title,
            systemImage: "folder",
            depth: depth,
            disclosure: hasChildren ? SidebarTreeDisclosure(isCollapsed: false, name: title, toggle: {}) : nil,
            hasUnread: false,
            isSelected: false,
            titleLineLimit: lineLimit
        ) {
            EmptyView()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func width<V: View>(of view: V) -> CGFloat {
        NSHostingController(rootView: view.fixedSize()).sizeThatFits(in: NSSize(width: 1_000, height: 1_000)).width
    }

    private static func height<V: View>(of view: V, width: CGFloat) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: width, height: 1_000)).height
    }
}
