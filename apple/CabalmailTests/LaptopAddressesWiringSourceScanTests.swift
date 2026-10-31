import XCTest

// The laptop panel's address list (#1649) and what ties it to the rest of
// the window. The rules are pure and tested in `LaptopPanelPolicyTests`,
// `CoveredMessageWatchTests`, `FeedListHoldTests` and
// `AddressFavoriteRefreshTests`; the call sites that feed them are in
// `#if os(iOS)` shell code, or in SwiftUI modifiers with no unit seam, so
// this reads the source, in the shape the other `*SourceScanTests` set.
// Each call site is useless if it goes, and the tests of the rules would
// stay green:
//
//   - the menus hear the cover: no message, item or feed scope while the
//     address list covers the reader, with no list mounted to answer;
//   - a feed list's hand-off no list took is let go when the window leaves
//     its scope, or the next pick of that scope adopts a stale model;
//   - a message parked for the list ends the address list, or the list that
//     would open it never mounts;
//   - removals reach the watch while covered, and it follows the cover;
//   - leaving laptop pose from the address list moves no list, since none
//     is mounted, and the `@` moves the list only when the list leaves;
//   - every address list re-reads the list when another one changes it.
final class LaptopAddressesWiringSourceScanTests: XCTestCase {

    func testTheMenusHearTheCover() throws {
        let body = try Self.source("CabalmailUI/Shell/WideMail.swift")
        XCTAssertEqual(body.components(separatedBy: "LaptopAddressesPolicy.reported(").count - 1, 2)
        XCTAssertTrue(body.contains("hasScope: LaptopAddressesPolicy.reportsScope("))
        XCTAssertTrue(body.contains("!mail.isSearching, covered: covered"))
    }

    func testTheLifecycleKeepsItsHooks() throws {
        let body = try Self.source("CabalmailUI/Shell/LaptopListPanel.swift")
        XCTAssertTrue(body.contains("""
            .onChange(of: mail.selectedFeedScope) {
                            feedListHold.releaseUntakenHandOff()
                        }
            """))
        XCTAssertTrue(body.contains("""
            .onChange(of: mail.navigator.restores.pendingRestore) { _, restore in
                            if restore != nil { mail.endLaptopPanelAddresses() }
                        }
            """))
        XCTAssertTrue(body.contains("watch.isCovering = covered"))
        XCTAssertTrue(body.contains("watch.openMessage = ref"))
        XCTAssertTrue(body.contains("LaptopAddressesPolicy.coveredMessage("))
        XCTAssertTrue(body.contains("appState.mailStore.events.subscribe(watch)"))
    }

    func testTheSplitWiresTheLifecycleAndMovesOnlyAMountedList() throws {
        let body = try Self.source("CabalmailUI/Shell/SplitShell.swift")
        XCTAssertTrue(body.contains(".laptopAddressesLifecycle(mail, feedListHold: feedListHold)"))
        XCTAssertTrue(body.contains("if crease != nil || !mail.laptopPanelShowsAddresses { listMoves() }"))
        XCTAssertTrue(body.contains("mail.laptopArrangement(isArranged: crease != nil)"))
        XCTAssertTrue(body.contains("if !mail.laptopPanelShowsAddresses { listMoves() }"))
    }

    func testEveryAddressListFollowsTheOthersChanges() throws {
        let body = try Self.source("CabalmailUI/Addresses/AddressListView.swift")
        XCTAssertTrue(body.contains("AddressesViewModel(client: client, changed: { appState.addressesChanged() })"))
        XCTAssertTrue(body.contains(".onChange(of: appState.addressListRevision)"))
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
