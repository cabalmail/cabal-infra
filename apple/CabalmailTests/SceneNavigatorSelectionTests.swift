import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The window's hold on its folder list's selection
/// (`SceneNavigator.mailSelection(for:)`): a multi-selection goes to the
/// list a layout swap builds, and every other list starts afresh, as each
/// did when the selection lived on the list's view model and went with it.
@MainActor
final class SceneNavigatorSelectionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorSelectionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", attributes: ["\\HasNoChildren"], isSubscribed: true)
    private let archive = Folder(path: "Archive", attributes: ["\\HasNoChildren"], isSubscribed: true)

    /// A window landed on INBOX, its first tree, and its list's selection.
    private struct Window {
        let navigator: SceneNavigator
        let tree: UUID
        let selection: SelectionModel<MessageRef>
    }

    /// A window landed on INBOX in one layout, its list's selection holding
    /// `rows`.
    private func landed(isWide: Bool, rows: Set<MessageRef>, bulkMode: Bool = false) async throws -> Window {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: nil)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: isWide)
        navigator.foldersLoaded([inbox, archive])
        let selection = navigator.mailSelection(for: "INBOX")
        selection.bulkMode = bulkMode
        selection.selected = rows
        return Window(navigator: navigator, tree: tree, selection: selection)
    }

    private func ref(_ uid: UInt32, in folder: String = "INBOX") -> MessageRef {
        MessageRef(folder: folder, uid: uid)
    }

    // MARK: - What a swap hands over

    func testAMultiSelectionSurvivesNarrowing() async throws {
        let window = try await landed(isWide: true, rows: [ref(1), ref(2), ref(3)])
        let navigator = window.navigator
        let selection = window.selection
        selection.setAnchor(ref(2))
        selection.cursor = ref(3)

        await navigator.mailTreeAppeared(UUID(), isWide: false)
        let handed = navigator.mailSelection(for: "INBOX")

        XCTAssertIdentical(handed, selection)
        XCTAssertEqual(handed.selected, [ref(1), ref(2), ref(3)])
        XCTAssertTrue(handed.bulkMode, "the compact list draws a multi-selection as Select mode")
        XCTAssertEqual(handed.anchor, ref(2))
        XCTAssertEqual(handed.rangeBase, [ref(1), ref(2), ref(3)])
        XCTAssertEqual(handed.cursor, ref(3))
    }

    func testSelectModeSurvivesWidening() async throws {
        let window = try await landed(isWide: false, rows: [ref(4)], bulkMode: true)
        let navigator = window.navigator
        let selection = window.selection

        await navigator.mailTreeAppeared(UUID(), isWide: true)
        let handed = navigator.mailSelection(for: "INBOX")

        XCTAssertIdentical(handed, selection)
        XCTAssertEqual(handed.selected, [ref(4)])
        XCTAssertTrue(handed.bulkMode)
    }

    func testASelectionSurvivesARoundTrip() async throws {
        let window = try await landed(isWide: true, rows: [ref(1), ref(2)])
        let navigator = window.navigator
        let selection = window.selection

        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertIdentical(navigator.mailSelection(for: "INBOX"), selection)
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertIdentical(navigator.mailSelection(for: "INBOX"), selection)
        XCTAssertEqual(selection.selected, [ref(1), ref(2)])
    }

    /// The open message is the route's to carry (`rehand` re-parks it for
    /// the new list), so a lone selection doesn't go across as well.
    func testALoneSelectionStaysBehind() async throws {
        let window = try await landed(isWide: true, rows: [ref(1)])
        let navigator = window.navigator
        let selection = window.selection

        await navigator.mailTreeAppeared(UUID(), isWide: false)
        let handed = navigator.mailSelection(for: "INBOX")

        XCTAssertNotIdentical(handed, selection)
        XCTAssertTrue(handed.selected.isEmpty)
        XCTAssertFalse(handed.bulkMode)
    }

    // MARK: - Every other list starts afresh

    /// The same tree mounting its list again, with no swap: the compact list
    /// pushed again, or the wide one back from a search. Each list had a
    /// selection of its own before, so it starts empty.
    func testAListMountingAgainWithoutASwapStartsAfresh() async throws {
        let window = try await landed(isWide: true, rows: [ref(1), ref(2)])
        let navigator = window.navigator
        let tree = window.tree
        let selection = window.selection
        await navigator.mailTreeAppeared(tree, isWide: true)

        let again = navigator.mailSelection(for: "INBOX")

        XCTAssertNotIdentical(again, selection)
        XCTAssertTrue(again.selected.isEmpty)
    }

    func testAHandOffGoesToOneList() async throws {
        let window = try await landed(isWide: true, rows: [ref(1), ref(2)])
        let navigator = window.navigator
        let selection = window.selection
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertIdentical(navigator.mailSelection(for: "INBOX"), selection)

        let later = navigator.mailSelection(for: "INBOX")

        XCTAssertNotIdentical(later, selection)
        XCTAssertTrue(later.selected.isEmpty)
    }

    /// The folder changing before the new list asks — a tapped
    /// notification for another folder, or the wide split switching to a
    /// feed — and back again: the list INBOX gets then is a new one.
    func testAFolderChangeDropsTheHandOff() async throws {
        let window = try await landed(isWide: true, rows: [ref(1), ref(2)])
        let navigator = window.navigator
        let selection = window.selection
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        navigator.selectFolder(archive)
        navigator.selectFolder(inbox)

        XCTAssertNotIdentical(navigator.mailSelection(for: "INBOX"), selection)
    }

    /// Backing out to the folder list pops the message list, which took its
    /// selection with it; a swap afterwards hands nothing to the folder's
    /// next list.
    func testBackingOutToTheFolderListDropsTheSelection() async throws {
        let window = try await landed(isWide: false, rows: [ref(1), ref(2)], bulkMode: true)
        let navigator = window.navigator
        let tree = window.tree
        let selection = window.selection

        navigator.setCompactColumn(.sidebar, isSearching: false, from: tree)
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(navigator.selectedFolder, inbox, "the folder stays selected")
        XCTAssertNotIdentical(navigator.mailSelection(for: "INBOX"), selection)
    }

    /// Going back from the reader to the list leaves the list where it was,
    /// selection and all: only backing out to the folder list pops it.
    func testGoingBackFromTheReaderKeepsTheSelection() async throws {
        let window = try await landed(isWide: false, rows: [ref(1), ref(2)], bulkMode: true)
        let navigator = window.navigator
        navigator.selectMessage(TestFixtures.makeEnvelope(uid: 9), isSearching: false, from: window.tree)
        navigator.setCompactColumn(.content, isSearching: false, from: window.tree)

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertIdentical(navigator.mailSelection(for: "INBOX"), window.selection)
    }

    /// A swap tears the old tree down after the new one is built; its
    /// collapsing navigation going back to the sidebar on the way out is
    /// not the user backing out.
    func testATornDownTreeCannotDropTheHandOff() async throws {
        let window = try await landed(isWide: false, rows: [ref(1), ref(2)], bulkMode: true)
        let navigator = window.navigator
        let tree = window.tree
        let selection = window.selection
        navigator.setCompactColumn(.content, isSearching: false, from: tree)

        await navigator.mailTreeAppeared(UUID(), isWide: true)
        navigator.setCompactColumn(.sidebar, isSearching: false, from: tree)

        XCTAssertIdentical(navigator.mailSelection(for: "INBOX"), selection)
    }

    func testAListForAnotherFolderTakesNoHandOff() async throws {
        let window = try await landed(isWide: true, rows: [ref(1), ref(2)])
        let navigator = window.navigator
        let selection = window.selection
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        let other = navigator.mailSelection(for: "Archive")

        XCTAssertNotIdentical(other, selection)
        XCTAssertTrue(other.selected.isEmpty)
    }
}
