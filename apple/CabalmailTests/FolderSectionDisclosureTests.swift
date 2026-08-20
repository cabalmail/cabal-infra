import XCTest
import CabalmailKit
@testable import Cabalmail

// The sidebar's two sections used to leave both the expand/collapse control
// and the row gating to `Section(_:isExpanded:)`. macOS and visionOS honoured
// the binding and drew no control, so "All folders" — collapsed by default —
// could never be opened and Sent/Trash/Drafts were unreachable (#1184);
// iPadOS drew every row whatever the binding said. These pin the rule now
// that it is ours.
final class FolderSectionDisclosureTests: XCTestCase {

    private func folder(_ path: String, subscribed: Bool = true) -> Folder {
        Folder(path: path, attributes: [], isSubscribed: subscribed)
    }

    /// The reported mailbox: two subscribed folders, three that are not.
    private var rows: [FolderSectionRow] {
        FolderSectionRows.rows(
            for: [folder("INBOX"), folder("Archive"), folder("Drafts", subscribed: false),
                  folder("Sent", subscribed: false), folder("Trash", subscribed: false)],
            collapsed: [],
            activeSelection: nil
        )
    }

    func testACollapsedSectionDrawsNoRows() {
        XCTAssertEqual(
            FolderSectionDisclosure.visibleRows(rows, isExpanded: false),
            [],
            "collapsed has to mean no rows here — leaving it to the list style is what made iPadOS ignore it"
        )
    }

    func testAnExpandedSectionDrawsEveryRowItWasGiven() {
        XCTAssertEqual(
            FolderSectionDisclosure.visibleRows(rows, isExpanded: true).map(\.folder.path),
            ["INBOX", "Archive", "Drafts", "Sent", "Trash"],
            "expanding is what puts Sent/Trash/Drafts back within reach"
        )
    }

    func testTheHeaderChevronPointsAtWhatThePressWillDo() {
        XCTAssertEqual(
            FolderSectionDisclosure.chevronRotation(isExpanded: false), 0,
            "collapsed points right, like a collapsed folder row"
        )
        XCTAssertEqual(
            FolderSectionDisclosure.chevronRotation(isExpanded: true), 90,
            "expanded points down"
        )
    }

    func testTheHeaderControlNamesTheActionItWillTake() {
        XCTAssertEqual(
            FolderSectionDisclosure.accessibilityLabel(title: "All folders", isExpanded: false),
            "Expand All folders",
            "a collapsed section's control offers to open it — the whole defect was that there was nothing to say this"
        )
        XCTAssertEqual(
            FolderSectionDisclosure.accessibilityLabel(title: "All folders", isExpanded: true),
            "Collapse All folders"
        )
    }
}
