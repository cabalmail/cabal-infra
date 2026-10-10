import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a window carries across a change of layout shell (`SceneNavigator`'s
/// `layoutChanged`, `showsSettingsSheet` and `settingsSheetDismissed`).
///
/// Two things carry. A search: a window narrowed or folded mid-search opens
/// its Search tab, which shows the search with its field — it used to open
/// the Mail tab on a "Search" page with no field (#1989) — and widening from
/// the Search tab keeps it, while one left behind in the Search tab ends when
/// the window widens from another tab. And Settings: the split has no tab
/// bar, so a fold turns its open sheet into the Settings tab and an unfold
/// from that tab opens the sheet.
@MainActor
final class SceneNavigatorShellTransitionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!
    private var appState: AppState!

    override func setUp() async throws {
        suiteName = "SceneNavigatorShellTransitionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
        appState = AppState()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

    private func makeCoordinator() throws -> NavStateCoordinator {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    /// A window with no session to land on: enough for the tab rules.
    private func makeNavigator() -> SceneNavigator {
        SceneNavigator(coordinator: { nil }, hasClient: { true }, seed: .mail)
    }

    /// The window's search model, as its search field or Search tab takes it.
    private func search(in navigator: SceneNavigator) throws -> MessageListViewModel {
        navigator.searchModel(
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: appState.mailStore
        )
    }

    /// A wide window: the first layout report, then the split.
    private func wideNavigator() -> SceneNavigator {
        let navigator = makeNavigator()
        navigator.layoutChanged(wasWide: true, isWide: true)
        return navigator
    }

    // MARK: - Narrowing mid-search (#1989)

    func testNarrowingMidSearchOpensTheSearchTab() throws {
        let navigator = wideNavigator()
        try search(in: navigator).searchQuery = "invoice"

        navigator.layoutChanged(wasWide: true, isWide: false)

        XCTAssertEqual(navigator.compactTab, .search)
        XCTAssertFalse(navigator.layoutIsWide)
        XCTAssertEqual(navigator.route.section, .mail, "the Search tab is not a section of the session")
    }

    /// Results on screen with the field cleared are still a search.
    func testARunSearchCountsWithAnEmptyField() throws {
        let navigator = wideNavigator()
        try search(in: navigator).isSearchActive = true

        navigator.layoutChanged(wasWide: true, isWide: false)

        XCTAssertEqual(navigator.compactTab, .search)
    }

    func testNarrowingWithNoSearchKeepsTheTab() async throws {
        let untouched = wideNavigator()
        untouched.layoutChanged(wasWide: true, isWide: false)
        XCTAssertEqual(untouched.compactTab, .mail, "no search model at all")

        let idle = wideNavigator()
        _ = try search(in: idle)
        idle.layoutChanged(wasWide: true, isWide: false)
        XCTAssertEqual(idle.compactTab, .mail, "a model with nothing typed or run")

        let coordinator = try makeCoordinator()
        let inFeeds = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        inFeeds.layoutChanged(wasWide: true, isWide: true)
        await inFeeds.mailTreeAppeared(UUID(), isWide: true)
        inFeeds.showFeeds(.all)
        inFeeds.layoutChanged(wasWide: true, isWide: false)
        XCTAssertEqual(inFeeds.compactTab, .feeds, "the section the split showed")
    }

    /// The host reports its layout once as the window appears, with the same
    /// layout on both sides. A window that opens narrow with a search already
    /// in its model is not narrowing.
    func testTheFirstLayoutReportIsNotANarrowing() throws {
        let navigator = makeNavigator()
        try search(in: navigator).searchQuery = "invoice"

        navigator.layoutChanged(wasWide: false, isWide: false)

        XCTAssertEqual(navigator.compactTab, .mail)
    }

    /// The tab tree's Mail tab lands as it is built, which writes
    /// `layoutIsWide` before the host's report arrives. The rule reads the
    /// host's own old and new layouts, so the landing can't hide the
    /// narrowing.
    func testATreeLandingFirstCannotHideTheNarrowing() async throws {
        let navigator = wideNavigator()
        try search(in: navigator).searchQuery = "invoice"

        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.layoutChanged(wasWide: true, isWide: false)

        XCTAssertEqual(navigator.compactTab, .search)
    }

    /// The split's field reads the same model, so a search the user is in
    /// carries across the unfold — and back again.
    func testWideningFromTheSearchTabKeepsTheSearch() throws {
        let navigator = makeNavigator()
        navigator.layoutChanged(wasWide: false, isWide: false)
        navigator.showTab(.search)
        let model = try search(in: navigator)
        model.searchQuery = "invoice"
        model.isSearchActive = true

        navigator.layoutChanged(wasWide: false, isWide: true)

        XCTAssertEqual(model.searchQuery, "invoice")
        XCTAssertTrue(model.isSearchActive)
        XCTAssertFalse(navigator.showsSettingsSheet)

        navigator.layoutChanged(wasWide: true, isWide: false)
        XCTAssertEqual(navigator.compactTab, .search, "narrowing again reopens the Search tab")
    }

    /// A search left sitting in the Search tab must not take the split's list
    /// over from what the user was reading in another tab. Before the Mail
    /// tab had its own list, a folder pick there had already ended it.
    func testWideningFromAnotherTabEndsALeftoverSearch() throws {
        for tab in [CompactTab.mail, .feeds, .addresses] {
            let navigator = makeNavigator()
            navigator.layoutChanged(wasWide: false, isWide: false)
            navigator.showTab(.search)
            let model = try search(in: navigator)
            model.searchQuery = "invoice"
            model.isSearchActive = true
            navigator.showTab(tab)

            navigator.layoutChanged(wasWide: false, isWide: true)

            XCTAssertEqual(model.searchQuery, "", "\(tab)")
            XCTAssertFalse(model.isSearchActive, "\(tab)")
            XCTAssertEqual(navigator.compactTab, tab, "widening moves no tab")
        }
    }

    /// An open Settings sheet folds to the Settings tab, search or not: the
    /// user was in Settings.
    func testSettingsOutranksTheSearchOnNarrowing() throws {
        let navigator = wideNavigator()
        try search(in: navigator).searchQuery = "invoice"
        navigator.openSettingsSheet()

        navigator.layoutChanged(wasWide: true, isWide: false)

        XCTAssertEqual(navigator.compactTab, .settings)
    }

    // MARK: - Settings across a fold

    func testASettingsRequestWhileWideOpensTheSheet() {
        let navigator = wideNavigator()
        XCTAssertFalse(navigator.showsSettingsSheet)

        navigator.openSettingsSheet()

        XCTAssertTrue(navigator.showsSettingsSheet)
        XCTAssertEqual(navigator.compactTab, .mail, "the sheet is not a tab")
    }

    func testTheSheetBecomesTheTabOnAFoldAndBackOnAnUnfold() {
        let navigator = wideNavigator()
        navigator.openSettingsSheet()

        navigator.layoutChanged(wasWide: true, isWide: false)
        XCTAssertFalse(navigator.showsSettingsSheet, "the tabs have no sheet")
        XCTAssertEqual(navigator.compactTab, .settings)

        navigator.layoutChanged(wasWide: false, isWide: true)
        XCTAssertTrue(navigator.showsSettingsSheet)
    }

    /// With Settings open over the split, the list underneath still changes
    /// its own selection: a restore lands once the folder has loaded, another
    /// window archives the open message. Those move the window's tab, as any
    /// selection in the split does, and must not close Settings — nor stop a
    /// fold from landing on the Settings tab.
    func testASelectionNobodyMadeLeavesSettingsOpen() async throws {
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        navigator.layoutChanged(wasWide: false, isWide: false)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.foldersLoaded([inbox])
        navigator.showTab(.settings)
        navigator.layoutChanged(wasWide: false, isWide: true)
        let wide = UUID()
        await navigator.mailTreeAppeared(wide, isWide: true)
        XCTAssertTrue(navigator.showsSettingsSheet)

        navigator.selectMessage(message, isSearching: false, from: wide)

        XCTAssertEqual(navigator.compactTab, .mail, "the selection moved the tab, as it always has")
        XCTAssertTrue(navigator.showsSettingsSheet)

        navigator.layoutChanged(wasWide: true, isWide: false)
        XCTAssertEqual(navigator.compactTab, .settings)
    }

    /// A navigate request (a notification, Spotlight, the resume banner)
    /// arriving with Settings open leaves it open, as it did when the sheet
    /// was the split's own.
    func testANavigationLeavesSettingsOpen() async throws {
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        navigator.layoutChanged(wasWide: true, isWide: true)
        await navigator.mailTreeAppeared(UUID(), isWide: true)
        navigator.foldersLoaded([inbox])
        navigator.openSettingsSheet()

        navigator.navigate(to: NavState(folder: "INBOX", uid: 4, clientID: "push"))

        XCTAssertTrue(navigator.showsSettingsSheet)
    }

    func testClosingTheSheetReturnsTheSettingsTabToTheSplitsSection() async throws {
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        navigator.layoutChanged(wasWide: false, isWide: false)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.foldersLoaded([inbox])
        navigator.showTab(.settings)
        navigator.layoutChanged(wasWide: false, isWide: true)
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        navigator.settingsSheetDismissed()

        XCTAssertFalse(navigator.showsSettingsSheet)
        XCTAssertEqual(navigator.compactTab, .mail, "the next fold doesn't reopen Settings")

        navigator.showFeeds(.all)
        navigator.openSettingsSheet()
        navigator.layoutChanged(wasWide: true, isWide: false)
        navigator.layoutChanged(wasWide: false, isWide: true)
        navigator.settingsSheetDismissed()
        XCTAssertEqual(navigator.compactTab, .feeds)
    }

    /// Opened and closed without a fold, the sheet leaves the tab where the
    /// split had it.
    func testClosingASheetOpenedOnTheSplitMovesNoTab() {
        let navigator = wideNavigator()
        navigator.showTab(.addresses)
        navigator.openSettingsSheet()

        navigator.settingsSheetDismissed()

        XCTAssertFalse(navigator.showsSettingsSheet)
        XCTAssertEqual(navigator.compactTab, .addresses)
    }

    func testClosingIsANoOpOffTheSplit() {
        let narrow = makeNavigator()
        narrow.layoutChanged(wasWide: false, isWide: false)
        narrow.showTab(.settings)
        narrow.settingsSheetDismissed()
        XCTAssertEqual(narrow.compactTab, .settings, "the tab layout has no sheet to dismiss")
    }

    /// A fold takes the sheet down with the split. The view reports that as
    /// a dismissal a turn later, by which time the window is on the tabs:
    /// the Settings tab must still be the one in front.
    func testATornDownSheetIsNotADismissal() {
        let navigator = wideNavigator()
        navigator.openSettingsSheet()

        navigator.layoutChanged(wasWide: true, isWide: false)
        navigator.settingsSheetDismissed()

        XCTAssertEqual(navigator.compactTab, .settings)
    }

    /// The other order: the tab tree lands, writing `layoutIsWide`, and the
    /// torn-down sheet reports before the host's layout change does. The
    /// sheet's flag is still up, but off the split there is no sheet to
    /// dismiss, so the fold still lands on the Settings tab.
    func testASheetTornDownBeforeTheLayoutReportIsNotADismissal() async {
        let navigator = wideNavigator()
        navigator.openSettingsSheet()

        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertFalse(navigator.showsSettingsSheet, "no sheet once a tab tree has landed")
        navigator.settingsSheetDismissed()
        navigator.layoutChanged(wasWide: true, isWide: false)

        XCTAssertEqual(navigator.compactTab, .settings)
    }
}
