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
