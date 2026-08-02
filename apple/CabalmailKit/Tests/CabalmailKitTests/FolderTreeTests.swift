import XCTest
@testable import CabalmailKit

final class FolderTreeTests: XCTestCase {

    private func folders(_ paths: [String]) -> [Folder] {
        paths.map { Folder(path: $0) }
    }

    // MARK: sortUserTree

    func testSortUserTreeArrangesPeersAlphabeticallyAndChildrenUnderParent() {
        let input = folders([
            "Projects/Zeta",
            "Projects",
            "Projects/Alpha/Sub",
            "Projects/Alpha",
            "Newsletters",
        ])
        let ordered = FolderTree.sortUserTree(input).map(\.path)
        XCTAssertEqual(ordered, [
            "Newsletters",
            "Projects",
            "Projects/Alpha",
            "Projects/Alpha/Sub",
            "Projects/Zeta",
        ])
    }

    func testSortUserTreeSkipsIntermediateSegmentsNotPresent() {
        let input = folders(["Projects/Alpha", "Other"])
        let ordered = FolderTree.sortUserTree(input).map(\.path)
        XCTAssertEqual(ordered, ["Other", "Projects/Alpha"])
    }

    // MARK: sidebarOrder

    func testSidebarOrderPinsInboxFirstAndSystemFoldersLast() {
        let input = folders([
            "Trash",
            "Projects/Zeta",
            "INBOX",
            "Archive",
            "Newsletters",
            "Projects",
            "Sent",
        ])
        XCTAssertEqual(FolderTree.sidebarOrder(input).map(\.path), [
            "INBOX",
            "Newsletters",
            "Projects",
            "Projects/Zeta",
            "Archive",
            "Sent",
            "Trash",
        ])
    }

    func testSidebarOrderMatchesInboxCaseInsensitively() {
        let input = folders(["Work", "inbox"])
        XCTAssertEqual(FolderTree.sidebarOrder(input).map(\.path), ["inbox", "Work"])
    }

    func testSidebarOrderKeepsNoselectUserFoldersByDefault() {
        let input = [
            Folder(path: "INBOX"),
            Folder(path: "Containers", attributes: ["\\Noselect"]),
            Folder(path: "Containers/Real"),
        ]
        XCTAssertEqual(FolderTree.sidebarOrder(input).map(\.path), [
            "INBOX",
            "Containers",
            "Containers/Real",
        ])
    }

    func testSidebarOrderDropsNoselectUserFoldersWhenAsked() {
        let input = [
            Folder(path: "INBOX"),
            Folder(path: "Containers", attributes: ["\\Noselect"]),
            Folder(path: "Containers/Real"),
        ]
        let ordered = FolderTree.sidebarOrder(input, dropNoselectUserFolders: true)
        XCTAssertEqual(ordered.map(\.path), ["INBOX", "Containers/Real"])
    }

    /// The drop flag is scoped to the user section: a `\Noselect` system
    /// folder still shows. Callers that want those gone (the move sheet)
    /// filter before calling.
    func testSidebarOrderKeepsNoselectSystemFoldersEvenWhenDropping() {
        let input = [
            Folder(path: "INBOX", attributes: ["\\Noselect"]),
            Folder(path: "Archive", attributes: ["\\Noselect"]),
        ]
        let ordered = FolderTree.sidebarOrder(input, dropNoselectUserFolders: true)
        XCTAssertEqual(ordered.map(\.path), ["INBOX", "Archive"])
    }

    // MARK: depth

    func testDepthIsZeroForSystemFoldersRegardlessOfSlashes() {
        XCTAssertEqual(FolderTree.depth(for: Folder(path: "INBOX")), 0)
        XCTAssertEqual(FolderTree.depth(for: Folder(path: "Sent")), 0)
        XCTAssertEqual(FolderTree.depth(for: Folder(path: "Archive")), 0)
    }

    func testDepthCountsSlashSegmentsForUserFolders() {
        XCTAssertEqual(FolderTree.depth(for: Folder(path: "Work")), 0)
        XCTAssertEqual(FolderTree.depth(for: Folder(path: "Work/Q1")), 1)
        XCTAssertEqual(FolderTree.depth(for: Folder(path: "Work/Q1/Archive")), 2)
    }

    // MARK: hasChildren

    func testHasChildrenIsTrueOnlyForParentsOfPresentFolders() {
        let input = folders(["INBOX", "Work", "Work/Q1", "Receipts"])
        XCTAssertFalse(FolderTree.hasChildren(Folder(path: "INBOX"), in: input))
        XCTAssertTrue(FolderTree.hasChildren(Folder(path: "Work"), in: input))
        XCTAssertFalse(FolderTree.hasChildren(Folder(path: "Work/Q1"), in: input))
        XCTAssertFalse(FolderTree.hasChildren(Folder(path: "Receipts"), in: input))
    }

    func testHasChildrenNeverTrueForSystemFolders() {
        // Defensive: even if some IMAP server were to nest under a system
        // name, the sidebar collapse mechanism shouldn't offer it.
        let input = folders(["INBOX", "INBOX/Subfolder"])
        XCTAssertFalse(FolderTree.hasChildren(Folder(path: "INBOX"), in: input))
    }

    // MARK: ancestors

    func testAncestorsExcludesSelf() {
        XCTAssertEqual(FolderTree.ancestors(of: "Work"), [])
        XCTAssertEqual(FolderTree.ancestors(of: "Work/Q1"), ["Work"])
        XCTAssertEqual(FolderTree.ancestors(of: "Work/Q1/Archive"), ["Work", "Work/Q1"])
    }

    // MARK: visibleFolders

    func testVisibleFoldersHidesDescendantsOfCollapsedAncestors() {
        let input = folders(["INBOX", "Work", "Work/Q1", "Work/Q2", "Receipts"])
        let (visible, effective) = FolderTree.visibleFolders(
            from: input,
            collapsed: ["Work"],
            activeSelection: "INBOX"
        )
        XCTAssertEqual(visible.map(\.path), ["INBOX", "Work", "Receipts"])
        XCTAssertEqual(effective, ["Work"])
    }

    func testVisibleFoldersAutoExpandsAncestorsOfActiveSelection() {
        let input = folders(["INBOX", "Work", "Work/Q1", "Work/Q2"])
        let (visible, effective) = FolderTree.visibleFolders(
            from: input,
            collapsed: ["Work"],
            activeSelection: "Work/Q1"
        )
        XCTAssertEqual(visible.map(\.path), ["INBOX", "Work", "Work/Q1", "Work/Q2"])
        XCTAssertTrue(effective.isEmpty, "ancestors of active selection should be removed from collapsed set")
    }

    func testVisibleFoldersWithoutCollapsedReturnsInputUnchanged() {
        let input = folders(["INBOX", "Work", "Work/Q1"])
        let (visible, effective) = FolderTree.visibleFolders(
            from: input,
            collapsed: [],
            activeSelection: nil
        )
        XCTAssertEqual(visible.map(\.path), input.map(\.path))
        XCTAssertTrue(effective.isEmpty)
    }

    func testVisibleFoldersIgnoresCollapseOfGhostAncestor() {
        // "Projects" is collapsed but not actually present in the list,
        // so "Projects/Alpha" should still be visible.
        let input = folders(["Projects/Alpha", "Other"])
        let (visible, _) = FolderTree.visibleFolders(
            from: input,
            collapsed: ["Projects"],
            activeSelection: nil
        )
        XCTAssertEqual(Set(visible.map(\.path)), Set(["Projects/Alpha", "Other"]))
    }
}
