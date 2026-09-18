import XCTest
import CabalmailKit
@testable import Cabalmail

// Expand all / Collapse all on the two sidebar trees: each persists its
// collapsed set, so the affordances are "empty set" and "every node that
// can hide something".
final class SidebarTreeExpansionTests: XCTestCase {

    private func folder(_ path: String) -> Folder {
        Folder(path: path, attributes: [], isSubscribed: true)
    }

    func testMailCollapsibleFoldersAreTheOnesWithChildren() {
        let folders = [folder("INBOX"), folder("a"), folder("a/b"), folder("a/b/c"), folder("z")]
        XCTAssertEqual(SidebarTreeExpansion.collapsibleFolderPaths(folders), ["a", "a/b"])
        XCTAssertEqual(SidebarTreeExpansion.collapsibleFolderPaths([folder("INBOX"), folder("z")]), [],
                       "a flat mailbox has nothing to expand or collapse — the buttons disable")
    }

    func testFeedCollapsibleFoldersHoldAFolderOrASubscription() {
        let folders = [
            RssFolder(folderId: "tech", name: "Tech"),
            RssFolder(folderId: "apple", parentFolderId: "tech", name: "Apple"),
            RssFolder(folderId: "empty", name: "Empty"),
        ]
        let subs = [RssSubscription(subscriptionId: "s", feedId: "f", folderId: "apple")]
        XCTAssertEqual(SidebarTreeExpansion.collapsibleFeedFolderIds(folders: folders, subscriptions: subs),
                       ["tech", "apple"])
    }

    func testCollapseAllIsEverythingCollapsibleAndExpandAllIsNothing() {
        XCTAssertEqual(SidebarTreeExpansion.collapsed(all: ["a", "b"], collapse: true), ["a", "b"])
        XCTAssertEqual(SidebarTreeExpansion.collapsed(all: ["a", "b"], collapse: false), [])
    }

    func testCommandsKnowTheirTreeAndDirection() {
        XCTAssertTrue(SidebarTreeCommand.expandAllFolders.isMail)
        XCTAssertFalse(SidebarTreeCommand.expandAllFeedFolders.isMail)
        XCTAssertTrue(SidebarTreeCommand.collapseAllFeedFolders.collapses)
        XCTAssertFalse(SidebarTreeCommand.expandAllFolders.collapses)
    }
}
