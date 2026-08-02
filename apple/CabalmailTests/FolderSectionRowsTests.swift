import XCTest
import CabalmailKit
@testable import Cabalmail

// The sidebar draws its folders through two sections over two different
// lists (Subscribed is a subset of All folders; the filter narrows both),
// so every row's depth, chevron and collapse has to come from the list its
// own section is drawing.
final class FolderSectionRowsTests: XCTestCase {

    private func folder(_ path: String, subscribed: Bool = true) -> Folder {
        Folder(path: path, attributes: [], isSubscribed: subscribed)
    }

    /// The mailbox from the report: INBOX, a parent with one child, an
    /// unrelated sibling, and Archive — all subscribed.
    private var nested: [Folder] {
        [folder("INBOX"), folder("alpha0802"), folder("alpha0802/kid"), folder("zeta0802"), folder("Archive")]
    }

    func testNestedFolderIndentsUnderItsParent() {
        let rows = FolderSectionRows.rows(for: nested, collapsed: [], activeSelection: nil)
        let depths = Dictionary(uniqueKeysWithValues: rows.map { ($0.folder.path, $0.depth) })
        XCTAssertEqual(depths["alpha0802"], 0)
        XCTAssertEqual(depths["alpha0802/kid"], 1, "a child is one step in from its parent")
        XCTAssertEqual(depths["zeta0802"], 0, "an unrelated top-level folder stays flush")
        XCTAssertEqual(depths["INBOX"], 0)
        XCTAssertEqual(depths["Archive"], 0, "system folders never indent")
    }

    func testCollapsingAParentHidesItsChildInTheSameSection() {
        let rows = FolderSectionRows.rows(
            for: nested,
            collapsed: ["alpha0802"],
            activeSelection: nil
        )
        XCTAssertEqual(
            rows.map(\.folder.path),
            ["INBOX", "alpha0802", "zeta0802", "Archive"],
            "the collapsed parent's child drops out of this section, not just some other one"
        )
    }

    func testOnlyAParentWithChildrenInThisSectionGetsAChevron() {
        let rows = FolderSectionRows.rows(for: nested, collapsed: [], activeSelection: nil)
        let chevrons = Dictionary(uniqueKeysWithValues: rows.map { ($0.folder.path, $0.hasChildren) })
        XCTAssertEqual(chevrons["alpha0802"], true)
        XCTAssertEqual(chevrons["zeta0802"], false)
        XCTAssertEqual(chevrons["alpha0802/kid"], false)
    }

    // MARK: - Subscribed as a subset of All folders

    func testSubscribedChildOfAnUnsubscribedParentStaysFlatAndVisible() {
        // Only the child is subscribed. The Subscribed section can't show
        // the parent, so it must neither indent the child under a row that
        // isn't there nor hide it behind a chevron it never draws.
        let subscribedOnly = [folder("INBOX"), folder("alpha0802/kid")]
        let rows = FolderSectionRows.rows(
            for: subscribedOnly,
            collapsed: ["alpha0802"],
            activeSelection: nil
        )
        XCTAssertEqual(rows.map(\.folder.path), ["INBOX", "alpha0802/kid"])
        XCTAssertEqual(rows.last?.depth, 0)
    }

    func testTheTwoSectionsAgreeOnAFolderTheyBothShow() {
        let all = nested + [folder("Sent"), folder("Trash", subscribed: false)]
        let subscribed = all.filter(\.isSubscribed)
        let allRows = FolderSectionRows.rows(for: all, collapsed: [], activeSelection: nil)
        let subRows = FolderSectionRows.rows(for: subscribed, collapsed: [], activeSelection: nil)
        for path in ["INBOX", "alpha0802", "alpha0802/kid", "zeta0802", "Archive"] {
            XCTAssertEqual(
                subRows.first { $0.folder.path == path }?.depth,
                allRows.first { $0.folder.path == path }?.depth,
                "\(path) draws at the same depth in both sections"
            )
        }
        XCTAssertNil(subRows.first { $0.folder.path == "Trash" }, "unsubscribed folders stay out")
    }

    func testActiveSelectionOverridesAStaleCollapse() {
        let rows = FolderSectionRows.rows(
            for: nested,
            collapsed: ["alpha0802"],
            activeSelection: "alpha0802/kid"
        )
        XCTAssertTrue(
            rows.contains { $0.folder.path == "alpha0802/kid" },
            "the open folder never disappears behind a collapsed ancestor"
        )
    }
}
