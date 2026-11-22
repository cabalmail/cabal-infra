import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// The mail sidebar's one list selection (`SidebarListSelection`): which row
/// it shows selected, and what a pick writes to the window's mail folder and
/// feed list. On the Mac a feed row is a row of that selection; in the
/// iPad's split it is a button beside it, and each rule here is run both
/// ways, so one is the other's control.
@MainActor
final class SidebarListSelectionTests: XCTestCase {
    private let mac = SidebarListSelection(selectsFeeds: true)
    private let split = SidebarListSelection(selectsFeeds: false)

    private let inbox = Folder(path: "INBOX", attributes: ["\\HasNoChildren"], isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private var folders: [Folder] { [inbox, archive] }

    // MARK: Which platform selects feeds

    func testOnlyTheMacsSidebarSelectsFeeds() {
        XCTAssertTrue(HostPlatform.macOS.sidebarSelectsFeeds)
        XCTAssertFalse(HostPlatform.iOS.sidebarSelectsFeeds, "the iPad's split keeps its row buttons")
        XCTAssertFalse(HostPlatform.visionOS.sidebarSelectsFeeds)
        XCTAssertFalse(HostPlatform.watchOS.sidebarSelectsFeeds)
    }

    func testTheFeedsSectionsRowsFollowThePlatform() {
        typealias Style = FeedSidebarContent<EmptyView>.Style
        XCTAssertEqual(Style.inMailSidebar(on: .macOS), .sidebarSelection)
        XCTAssertEqual(Style.inMailSidebar(on: .iOS), .rowButtons)
    }

    // MARK: The selected row

    func testAFolderIsSelectedByItsPath() {
        XCTAssertEqual(mac.current(folder: inbox, feedScope: nil), .mailFolder(path: "INBOX"))
        XCTAssertEqual(split.current(folder: inbox, feedScope: nil), .mailFolder(path: "INBOX"))
        // The stand-in a landing selects before the folder list has loaded
        // is the same row as the fetched folder (#1535).
        XCTAssertEqual(mac.current(folder: Folder(path: "INBOX"), feedScope: nil), .mailFolder(path: "INBOX"))
    }

    func testNothingIsSelectedWithNeither() {
        XCTAssertNil(mac.current(folder: nil, feedScope: nil))
        XCTAssertNil(split.current(folder: nil, feedScope: nil))
    }

    func testAFeedListOnScreenIsTheMacsSelectedRow() {
        XCTAssertEqual(mac.current(folder: nil, feedScope: .subscription("s")), .feedScope(.subscription("s")))
        XCTAssertEqual(mac.current(folder: nil, feedScope: .folder("tech")), .feedScope(.folder("tech")))
        XCTAssertEqual(mac.current(folder: nil, feedScope: .all), .feedScope(.all))
    }

    /// The control: where feed rows are buttons the list has no row to
    /// select for one, as before.
    func testAFeedListOnScreenSelectsNoRowWhereFeedsAreButtons() {
        XCTAssertNil(split.current(folder: nil, feedScope: .subscription("s")))
        XCTAssertNil(split.current(folder: nil, feedScope: .all))
    }

    // MARK: What a pick writes

    func testAFolderRowWritesTheFetchedFolder() {
        for rule in [mac, split] {
            XCTAssertEqual(
                rule.write(for: .mailFolder(path: "INBOX"), folders: folders, folder: archive, feedScope: nil),
                .folder(inbox)
            )
        }
        // The fetched value, attributes and all, not a stand-in for its path.
        guard case .folder(let written?) = mac.write(
            for: .mailFolder(path: "INBOX"), folders: folders, folder: nil, feedScope: nil
        ) else { return XCTFail("a folder row writes a folder") }
        XCTAssertEqual(written.attributes, ["\\HasNoChildren"])
        XCTAssertTrue(written.isSubscribed)
    }

    func testAFolderRowTheListNoLongerHoldsKeepsTheWindowsOwn() {
        let held = Folder(path: "Lists", isSubscribed: true)
        XCTAssertEqual(
            mac.write(for: .mailFolder(path: "Lists"), folders: folders, folder: held, feedScope: nil),
            .folder(held)
        )
        XCTAssertEqual(
            mac.write(for: .mailFolder(path: "Gone"), folders: folders, folder: held, feedScope: nil),
            .folder(Folder(path: "Gone"))
        )
    }

    func testAFolderRowPickedWhileAFeedIsOpenWritesTheFolder() {
        XCTAssertEqual(
            mac.write(for: .mailFolder(path: "Archive"), folders: folders, folder: nil, feedScope: .all),
            .folder(archive)
        )
    }

    func testAFeedRowWritesItsFeedListOnTheMac() {
        XCTAssertEqual(
            mac.write(for: .feedScope(.subscription("s")), folders: folders, folder: inbox, feedScope: nil),
            .feedScope(.subscription("s"))
        )
        XCTAssertEqual(
            mac.write(for: .feedScope(.all), folders: folders, folder: nil, feedScope: .subscription("s")),
            .feedScope(.all)
        )
    }

    /// The control: a list whose feed rows are buttons has no feed row to
    /// pick, and a feed selection reaching it writes nothing.
    func testAFeedSelectionWritesNothingWhereFeedsAreButtons() {
        XCTAssertEqual(
            split.write(for: .feedScope(.all), folders: folders, folder: inbox, feedScope: nil),
            .nothing
        )
    }

    func testClearingTheSelectionClearsTheMailFolder() {
        XCTAssertEqual(mac.write(for: nil, folders: folders, folder: inbox, feedScope: nil), .folder(nil))
        XCTAssertEqual(split.write(for: nil, folders: folders, folder: inbox, feedScope: nil), .folder(nil))
    }

    /// A click on the sidebar's empty space while a feed is open leaves the
    /// feed open on the Mac: a feed row was never a selection the list
    /// could clear. The iPad's list has no selected row then, and its clear
    /// writes the folder it always wrote.
    func testClearingTheSelectionLeavesAnOpenFeedOpen() {
        XCTAssertEqual(mac.write(for: nil, folders: folders, folder: nil, feedScope: .all), .nothing)
        XCTAssertEqual(split.write(for: nil, folders: folders, folder: nil, feedScope: .all), .folder(nil))
    }

    func testNoRowSelectsASmartViewYet() {
        for rule in [mac, split] {
            XCTAssertEqual(
                rule.write(for: .smartView(.flagged), folders: folders, folder: inbox, feedScope: nil),
                .nothing
            )
        }
    }

    // MARK: The binding

    /// A window's two selections, as a view would hold them.
    @MainActor
    private final class Held {
        var folder: Folder?
        var feedScope: RssItemScope?
        var folderWrites = 0
        var feedWrites = 0

        var folderBinding: Binding<Folder?> {
            Binding(get: { self.folder }, set: { self.folder = $0; self.folderWrites += 1 })
        }

        var feedBinding: Binding<RssItemScope?> {
            Binding(get: { self.feedScope }, set: { self.feedScope = $0; self.feedWrites += 1 })
        }
    }

    func testTheBindingReadsAndWritesTheWindowsTwoSelections() {
        let held = Held()
        held.folder = inbox
        let folders = folders
        let selection = mac.binding(folder: held.folderBinding, feedScope: held.feedBinding, folders: { folders })
        XCTAssertEqual(selection.wrappedValue, .mailFolder(path: "INBOX"))

        selection.wrappedValue = .feedScope(.subscription("s"))

        XCTAssertEqual(held.feedScope, .subscription("s"))
        XCTAssertEqual(held.feedWrites, 1)
        XCTAssertEqual(held.folderWrites, 0, "clearing the folder for a feed is the window's rule, not the list's")

        held.folder = nil
        XCTAssertEqual(selection.wrappedValue, .feedScope(.subscription("s")))
        selection.wrappedValue = .mailFolder(path: "Archive")

        XCTAssertEqual(held.folder, archive)
        XCTAssertEqual(held.folderWrites, 1)
        XCTAssertEqual(held.feedWrites, 1)
    }

    /// Picking the row already selected still writes, which is what lets the
    /// window end a search on it (#1217).
    func testPickingTheSelectedRowStillWrites() {
        let held = Held()
        held.folder = inbox
        let folders = folders
        let selection = mac.binding(folder: held.folderBinding, feedScope: held.feedBinding, folders: { folders })

        selection.wrappedValue = .mailFolder(path: "INBOX")

        XCTAssertEqual(held.folderWrites, 1)
    }

    /// The layouts whose sidebar has no Feeds section pass no feed binding.
    func testTheBindingWithNoFeedsSectionIsTheFolderAlone() {
        let held = Held()
        let folders = folders
        let selection = split.binding(folder: held.folderBinding, feedScope: nil, folders: { folders })

        selection.wrappedValue = .mailFolder(path: "INBOX")
        XCTAssertEqual(held.folder, inbox)
        XCTAssertEqual(selection.wrappedValue, .mailFolder(path: "INBOX"))

        selection.wrappedValue = .feedScope(.all)
        XCTAssertEqual(held.folder, inbox)
        XCTAssertNil(held.feedScope)
    }
}
