import XCTest
@testable import CabalmailUI

// A sidebar tree's collapsed set is per window (#2039): each window keeps its
// own in scene storage, tagged with the account, and seeds from the
// device-wide value a new window inherits.
final class SidebarCollapseTests: XCTestCase {

    private let account = StoredRoute.Account(controlDomain: "admin.example.test", username: "someone")
    private let other = StoredRoute.Account(controlDomain: "admin.example.test", username: "somebody-else")

    // MARK: - Seeding

    func testAWindowWithNothingStoredSeedsFromTheDeviceWideValue() {
        XCTAssertEqual(
            SidebarCollapse.effective(scene: "", device: "Archive\nArchive/2025", for: account),
            ["Archive", "Archive/2025"]
        )
    }

    func testAWindowWithNothingStoredAndNoDeviceValueHasNothingCollapsed() {
        XCTAssertEqual(SidebarCollapse.effective(scene: "", device: "", for: account), [])
    }

    func testAWindowsOwnSetWinsOverTheDeviceWideValue() {
        let scene = SidebarCollapse.scene(["Archive"], for: account)
        XCTAssertEqual(
            SidebarCollapse.effective(scene: scene, device: "Sent\nSent/2025", for: account),
            ["Archive"]
        )
    }

    // A window that has collapsed nothing is not a window with nothing
    // stored: it must keep showing the tree expanded rather than seeding the
    // device-wide set back in on the next read.
    func testAWindowThatExpandedEverythingStaysExpanded() {
        let scene = SidebarCollapse.scene([], for: account)
        XCTAssertEqual(SidebarCollapse.effective(scene: scene, device: "Archive", for: account), [])
    }

    // MARK: - The account tag

    func testAnotherAccountsStoredSetIsIgnored() {
        let scene = SidebarCollapse.scene(["Archive"], for: other)
        XCTAssertEqual(SidebarCollapse.effective(scene: scene, device: "Sent", for: account), ["Sent"],
                       "a window the system kept across a sign-in seeds from the device-wide value")
        XCTAssertNil(SidebarCollapse.stored(in: scene, for: account))
    }

    func testAnUndecodableSceneValueSeedsFromTheDeviceWideValue() {
        XCTAssertNil(SidebarCollapse.stored(in: "not json", for: account))
        XCTAssertEqual(SidebarCollapse.effective(scene: "not json", device: "Sent", for: account), ["Sent"])
    }

    // MARK: - Encoding

    func testAWindowsSetRoundTrips() {
        let set: Set<String> = ["Archive", "Archive/2025", "Sent"]
        XCTAssertEqual(SidebarCollapse.stored(in: SidebarCollapse.scene(set, for: account), for: account), set)
    }

    // The device-wide half keeps the encoding the key has always used, so a
    // value stored before this change is read back as it was. Pinned in both
    // directions: a JSON device value would be read as one long path.
    func testTheDeviceWideValueKeepsItsNewlineJoinedEncoding() {
        XCTAssertEqual(SidebarCollapse.device(["Sent", "Archive"]), "Archive\nSent")
        XCTAssertEqual(SidebarCollapse.decodeDevice("Archive\nSent"), ["Archive", "Sent"])
        XCTAssertEqual(SidebarCollapse.decodeDevice(""), [])
    }

    // MARK: - The defect

    // Two windows, one device-wide value: collapsing in one must leave the
    // other's tree alone. This is #2039's arm 2 as arithmetic — the pre-fix
    // rule (both windows read the device-wide value) answers
    // `["Tech"]` for the background window and fails here.
    func testCollapsingInOneWindowLeavesAnotherWindowsTreeAlone() {
        var front = SidebarCollapse.scene([], for: account)
        var background = SidebarCollapse.scene([], for: account)
        var device = ""

        // The front window collapses the feed folder.
        let collapsed = SidebarTreeExpansion.collapsed(all: ["Tech"], collapse: true)
        front = SidebarCollapse.scene(collapsed, for: account)
        device = SidebarCollapse.device(collapsed)

        XCTAssertEqual(SidebarCollapse.effective(scene: front, device: device, for: account), ["Tech"])
        XCTAssertEqual(SidebarCollapse.effective(scene: background, device: device, for: account), [],
                       "the background window still shows the folder expanded")

        // And the other way: expanding in the background window does not
        // re-expand the front one.
        background = SidebarCollapse.scene([], for: account)
        device = SidebarCollapse.device([])
        XCTAssertEqual(SidebarCollapse.effective(scene: front, device: device, for: account), ["Tech"])
    }

    // A window opened after that change inherits where the tree was left,
    // which is what the device-wide write-back is for.
    func testANewWindowOpensTheWayTheLastChangeLeftTheTree() {
        let device = SidebarCollapse.device(["Tech"])
        XCTAssertEqual(SidebarCollapse.effective(scene: "", device: device, for: account), ["Tech"])
    }
}
