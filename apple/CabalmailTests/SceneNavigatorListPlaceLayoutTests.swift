import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A change of layout voids the claim of the folder list in the layout the
/// window left, whether or not the new layout builds a mail tree
/// (`FolderListHold.leaveLayout`). A fold with the split's Settings sheet
/// open lands on the Settings tab, which builds no mail tree until the Mail
/// tab is shown: the split's list, still being torn down, must not write the
/// top of the folder over the window's place meanwhile.
@MainActor
final class SceneNavigatorListPlaceLayoutTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorListPlaceLayoutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)

    private func place(_ index: Int) throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: "INBOX", messageID: "<row\(index)@example.com>", uid: UInt32(5000 - index), index: index
        ))
    }

    /// A window landed on INBOX in one layout, and its folder list's claim,
    /// the list scrolled to row 300.
    private func window(isWide: Bool) async throws -> (navigator: SceneNavigator, list: FolderListHold.Claim) {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        navigator.layoutChanged(wasWide: isWide, isWide: isWide)
        await navigator.mailTreeAppeared(UUID(), isWide: isWide)
        navigator.foldersLoaded([inbox])
        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX", "precondition: landed")
        let list = navigator.listHold.claim("INBOX", isWide: isWide)
        XCTAssertTrue(navigator.listHold.record(try place(300), under: list))
        return (navigator, list)
    }

    /// The split's Settings sheet is open, so the fold opens the Settings
    /// tab and nothing hands the list over. The split's list loses its claim
    /// at the fold all the same, the place waits, and the Mail tab's list
    /// takes it.
    func testAFoldOntoTheSettingsTabKeepsThePlaceForTheMailTab() async throws {
        let (navigator, splitList) = try await window(isWide: true)
        navigator.openSettingsSheet()

        navigator.layoutChanged(wasWide: true, isWide: false)

        XCTAssertEqual(navigator.compactTab, .settings, "precondition: no mail tree is built")
        XCTAssertFalse(navigator.listHold.holds(splitList))
        XCTAssertFalse(navigator.listHold.record(nil, under: splitList), "its scroll view collapsing to the top")
        XCTAssertEqual(navigator.listHold.place, try place(300))
        XCTAssertNil(navigator.restores.pendingListAnchor, "no list to park it for yet")

        navigator.showTab(.mail)
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        let tabList = navigator.listHold.claim("INBOX", isWide: false)
        XCTAssertEqual(navigator.listHold.takeAnchor(under: tabList, from: navigator.restores), try place(300))
    }

    func testAnUnfoldVoidsTheTabListsClaim() async throws {
        let (navigator, tabList) = try await window(isWide: false)

        navigator.layoutChanged(wasWide: false, isWide: true)

        XCTAssertFalse(navigator.listHold.holds(tabList))
        XCTAssertEqual(navigator.listHold.place, try place(300))
    }

    /// The window can hear of the new layout from its first tree before the
    /// host reports the change. The new list's claim, taken in the layout
    /// arrived at, is not the one the report voids.
    func testAClaimTakenInTheNewLayoutOutlivesTheHostsReport() async throws {
        let (navigator, splitList) = try await window(isWide: true)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        let tabList = navigator.listHold.claim("INBOX", isWide: false)

        navigator.layoutChanged(wasWide: true, isWide: false)

        XCTAssertFalse(navigator.listHold.holds(splitList))
        XCTAssertTrue(navigator.listHold.holds(tabList))
        XCTAssertEqual(navigator.listHold.takeAnchor(under: tabList, from: navigator.restores), try place(300))
    }

    /// The host reports its layout when the window first appears, old and
    /// new the same. That is no swap: the list keeps its claim.
    func testAReportThatChangesNothingVoidsNothing() async throws {
        let (wide, splitList) = try await window(isWide: true)
        let (compact, tabList) = try await window(isWide: false)

        wide.layoutChanged(wasWide: true, isWide: true)
        compact.layoutChanged(wasWide: false, isWide: false)

        XCTAssertTrue(wide.listHold.holds(splitList))
        XCTAssertTrue(compact.listHold.holds(tabList))
    }
}
