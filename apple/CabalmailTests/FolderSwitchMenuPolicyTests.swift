import XCTest
import CabalmailKit
@testable import Cabalmail

/// The folder-switch menu behind the message list's folder name: subscribed
/// folders at the top level, the rest under an "Other folders" submenu, the
/// current folder checked wherever it sits.
final class FolderSwitchMenuPolicyTests: XCTestCase {
    private static func folder(
        _ path: String,
        subscribed: Bool = true,
        attributes: [String] = []
    ) -> Folder {
        Folder(path: path, attributes: attributes, isSubscribed: subscribed)
    }

    private let folders: [Folder] = [
        folder("INBOX"),
        folder("Archive", subscribed: false),
        folder("Drafts"),
        folder("Sent"),
        folder("Trash", subscribed: false),
        folder("Projects", subscribed: false),
        folder("Projects/Alpha"),
    ]

    func testSubscribedFoldersAreTopLevelAndTheRestGoToTheSubmenu() {
        let groups = FolderSwitchMenuPolicy.groups(folders: folders, current: Self.folder("INBOX"))
        XCTAssertEqual(
            groups.subscribed.map(\.option.path),
            ["INBOX", "Projects/Alpha", "Drafts", "Sent"]
        )
        XCTAssertEqual(groups.other.map(\.option.path), ["Projects", "Archive", "Trash"])
    }

    func testExactlyTheCurrentFolderIsChecked() {
        let groups = FolderSwitchMenuPolicy.groups(folders: folders, current: Self.folder("Sent"))
        XCTAssertEqual(groups.subscribed.filter(\.isOn).map(\.option.path), ["Sent"])
        XCTAssertTrue(groups.other.allSatisfy { !$0.isOn })
    }

    func testAnUnsubscribedCurrentFolderIsCheckedInTheSubmenu() {
        let groups = FolderSwitchMenuPolicy.groups(
            folders: folders,
            current: Self.folder("Trash", subscribed: false)
        )
        XCTAssertTrue(groups.subscribed.allSatisfy { !$0.isOn })
        XCTAssertEqual(groups.other.filter(\.isOn).map(\.option.path), ["Trash"])
    }

    func testWithNothingSubscribedEveryFolderIsTopLevel() {
        let none = folders.map { Self.folder($0.path, subscribed: false) }
        let groups = FolderSwitchMenuPolicy.groups(folders: none, current: Self.folder("INBOX"))
        XCTAssertEqual(groups.subscribed.count, none.count)
        XCTAssertTrue(groups.other.isEmpty)
    }

    func testNoselectContainersAreDropped() {
        let withContainer = folders + [
            Self.folder("Clients", subscribed: false, attributes: ["\\Noselect"]),
            Self.folder("Clients/Acme"),
        ]
        let groups = FolderSwitchMenuPolicy.groups(folders: withContainer, current: Self.folder("INBOX"))
        let listed = (groups.subscribed + groups.other).map(\.option.path)
        XCTAssertFalse(listed.contains("Clients"))
        XCTAssertTrue(listed.contains("Clients/Acme"))
    }

    func testBeforeTheListArrivesTheMenuShowsTheCurrentFolderChecked() {
        let groups = FolderSwitchMenuPolicy.groups(folders: [], current: Self.folder("INBOX"))
        XCTAssertEqual(groups.subscribed.map(\.option.path), ["INBOX"])
        XCTAssertTrue(groups.subscribed[0].isOn)
        XCTAssertTrue(groups.other.isEmpty)
    }

    func testACurrentFolderMissingFromTheListIsStillOffered() {
        let groups = FolderSwitchMenuPolicy.groups(folders: folders, current: Self.folder("gone"))
        XCTAssertEqual(groups.subscribed.first?.option.path, "gone")
        XCTAssertTrue(groups.subscribed.first?.isOn == true)
        XCTAssertEqual(groups.subscribed.filter(\.isOn).count, 1)
    }

    func testNestedFoldersAreLabelledByPath() {
        XCTAssertEqual(FolderSwitchMenuPolicy.label(for: Self.folder("Projects/Alpha")), "Projects/Alpha")
        XCTAssertEqual(FolderSwitchMenuPolicy.label(for: Self.folder("Projects")), "Projects")
        XCTAssertEqual(FolderSwitchMenuPolicy.label(for: Self.folder("INBOX")), "INBOX")
    }

    func testIdentityChangesWhenTheCheckedFolderDoes() {
        let inbox = FolderSwitchMenuPolicy.groups(folders: folders, current: Self.folder("INBOX"))
        let sent = FolderSwitchMenuPolicy.groups(folders: folders, current: Self.folder("Sent"))
        XCTAssertNotEqual(
            FolderSwitchMenuPolicy.identity(inbox),
            FolderSwitchMenuPolicy.identity(sent)
        )
    }

    func testIdentityChangesWhenTheListArrives() {
        let before = FolderSwitchMenuPolicy.groups(folders: [], current: Self.folder("INBOX"))
        let after = FolderSwitchMenuPolicy.groups(folders: folders, current: Self.folder("INBOX"))
        XCTAssertNotEqual(
            FolderSwitchMenuPolicy.identity(before),
            FolderSwitchMenuPolicy.identity(after)
        )
    }
}
