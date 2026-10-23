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

    // MARK: - The seed is taken once per window

    func testAWindowWithNothingStoredSeedsOnMount() {
        XCTAssertEqual(
            SidebarCollapse.seed(scene: "", device: "Tech", for: account),
            SidebarCollapse.scene(["Tech"], for: account)
        )
    }

    func testAWindowThatAlreadyHasItsOwnSetIsNotReseeded() {
        let scene = SidebarCollapse.scene([], for: account)
        XCTAssertNil(SidebarCollapse.seed(scene: scene, device: "Tech", for: account),
                     "a window that expanded everything must not have the device-wide set written back in")
    }

    func testAWindowHoldingAnotherAccountsSetIsSeededAfresh() {
        let scene = SidebarCollapse.scene(["Archive"], for: other)
        XCTAssertEqual(
            SidebarCollapse.seed(scene: scene, device: "Tech", for: account),
            SidebarCollapse.scene(["Tech"], for: account)
        )
    }

    // MARK: - The defect

    // Two windows, neither having touched its own tree yet — #2039's arm 2,
    // as the live arm of 2026-10-23 drove it: each window takes its seed on
    // mount, then the front one collapses the feed folder.
    //
    // Without the seed this is the defect, measured live: the background
    // window has nothing of its own, so it falls back to the device-wide
    // value the front window just moved and collapses with it. The second
    // assertion is the one that fails that way, which is why the seed is
    // taken rather than left as a running default.
    func testCollapsingInOneWindowLeavesAnotherWindowsTreeAlone() {
        var device = ""
        var front = SidebarCollapse.seed(scene: "", device: device, for: account) ?? ""
        let background = SidebarCollapse.seed(scene: "", device: device, for: account) ?? ""
        XCTAssertEqual(SidebarCollapse.effective(scene: background, device: device, for: account), [])

        // The front window collapses the feed folder.
        let collapsed = SidebarTreeExpansion.collapsed(all: ["Tech"], collapse: true)
        front = SidebarCollapse.scene(collapsed, for: account)
        device = SidebarCollapse.device(collapsed)

        XCTAssertEqual(SidebarCollapse.effective(scene: front, device: device, for: account), ["Tech"])
        XCTAssertEqual(SidebarCollapse.effective(scene: background, device: device, for: account), [],
                       "the background window still shows the folder expanded")

        // And the other way: expanding in the background window does not
        // re-expand the front one.
        let expanded = SidebarCollapse.scene([], for: account)
        device = SidebarCollapse.device([])
        XCTAssertEqual(SidebarCollapse.effective(scene: expanded, device: device, for: account), [])
        XCTAssertEqual(SidebarCollapse.effective(scene: front, device: device, for: account), ["Tech"])
    }

    // A window opened after that change inherits where the tree was left,
    // which is what the device-wide write-back is for. Its own set is taken
    // from that value, so a later change elsewhere no longer reaches it.
    func testANewWindowOpensTheWayTheLastChangeLeftTheTree() {
        let device = SidebarCollapse.device(["Tech"])
        XCTAssertEqual(SidebarCollapse.effective(scene: "", device: device, for: account), ["Tech"])
        let seeded = SidebarCollapse.seed(scene: "", device: device, for: account) ?? ""
        XCTAssertEqual(SidebarCollapse.effective(scene: seeded, device: "", for: account), ["Tech"],
                       "and it keeps it when the device-wide value moves again")
    }
}
