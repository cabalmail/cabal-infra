import XCTest
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: the testable halves of two command-tick receivers, pinned
/// before workstream 3.1 replaces the ticks with focused-window commands
/// (its defect 11, window-scoped menu commands, #1783, is the targeting they
/// ride on).
///
/// `refreshRequestTick`'s observer in `MessageListView` runs
/// `MessageListViewModel.hardReload()`. Its folder-scope paths, online and
/// offline, are pinned by `OfflineListResetTests` (#1796); this pins the
/// search-scope path: re-run the active search in place, never STATUS.
@MainActor
final class RefreshReceiverCharacterizationTests: XCTestCase {

    private func makeSearchModel(imap: FakeImapClient) throws -> MessageListViewModel {
        MessageListViewModel(
            scope: .search,
            client: try TestFixtures.makeClient(imap: imap),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            appState: AppState()
        )
    }

    /// One page of `count` matches starting at `firstUID`, with `cursor` as
    /// the next page's cursor.
    private func page(firstUID: UInt32, count: Int, cursor: String?) -> SearchResult {
        let rows = (0..<count).map { offset in
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: firstUID + UInt32(offset)), folder: "INBOX")
        }
        return SearchResult(
            envelopes: rows, totalEstimate: 60, nextCursor: cursor, foldersSearched: ["INBOX"], truncated: false
        )
    }

    private func assertNoFolderTraffic(
        _ imap: FakeImapClient, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let statusCalls = await imap.statusCalls
        let topCalls = await imap.topEnvelopesCalls
        let pageCalls = await imap.envelopesCalls
        XCTAssertTrue(statusCalls.isEmpty, "no STATUS on the search surface", file: file, line: line)
        XCTAssertTrue(topCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(pageCalls.isEmpty, file: file, line: line)
    }

    func testHardReloadOnTheSearchSurfaceReRunsTheActiveSearchAndNothingElse() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearch(page(firstUID: 1, count: 2, cursor: nil))
        let model = try makeSearchModel(imap: imap)
        model.searchQuery = "invoice"
        await model.runSearch()
        XCTAssertTrue(model.isSearchActive)

        await model.hardReload()

        let calls = await imap.searchCalls
        XCTAssertEqual(calls.count, 2, "exactly one more search")
        XCTAssertEqual(calls.last?.text, "invoice")
        XCTAssertEqual(calls.last?.limit, MessageListViewModel.searchPageSize)
        XCTAssertNil(calls.last?.cursor)
        await assertNoFolderTraffic(imap)
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.envelopes.map(\.uid), [1, 2])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    /// A reload re-walks as deep as the user has paged, rather than
    /// truncating the results back to one page.
    func testHardReloadOnTheSearchSurfaceReWalksThePagedInDepth() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearchPages([page(firstUID: 1, count: 50, cursor: "after-50")])
        let model = try makeSearchModel(imap: imap)
        model.searchQuery = "invoice"
        await model.runSearch()
        await imap.scriptSearchPages([page(firstUID: 51, count: 10, cursor: nil)])
        await model.loadMoreSearchResults()
        XCTAssertEqual(model.envelopes.count, 60)

        await imap.scriptSearchPages([
            page(firstUID: 1, count: 50, cursor: "after-50"), page(firstUID: 51, count: 10, cursor: nil),
        ])
        await model.hardReload()

        let calls = await imap.searchCalls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.suffix(2).map(\.limit), [50, 10], "two chunks, down to the depth already shown")
        XCTAssertEqual(calls.suffix(2).map(\.cursor), [nil, "after-50"])
        XCTAssertEqual(model.envelopes.count, 60)
        await assertNoFolderTraffic(imap)
    }

    /// A pill on the search surface runs a server search with no text
    /// (`selectFilter`). Refresh re-runs it with the pill still lit:
    /// `hardReload` keeps `filterTab` (`resetFilterTab: false`), and with it
    /// the filters the pill imposed. Reset, they would leave nothing to match
    /// on and the reload would end the search. The in-place reload also keeps
    /// a skipped-rows notice, which a fresh search drops (`preserveDepth`).
    func testHardReloadOnTheSearchSurfaceKeepsAPillDrivenSearchAndItsNotice() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearch(page(firstUID: 1, count: 2, cursor: nil))
        let model = try makeSearchModel(imap: imap)
        await model.setSearchAnchor(Folder(path: "Archive"))
        await model.selectFilter(.unread)
        XCTAssertTrue(model.isSearchActive)
        model.skippedNotice = "1 message was already gone."

        await model.hardReload()

        let calls = await imap.searchCalls
        XCTAssertEqual(calls.count, 2, "exactly one more search")
        let reload = try XCTUnwrap(calls.last)
        XCTAssertTrue(reload.unread, "the pill's predicate rides along")
        XCTAssertFalse(reload.flagged)
        XCTAssertNil(reload.text)
        XCTAssertEqual(reload.folder, "Archive", "still narrowed to the anchor")
        XCTAssertEqual(model.filterTab, .unread, "the pill stays lit")
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.skippedNotice, "1 message was already gone.")
        XCTAssertEqual(model.envelopes.map(\.uid), [1, 2])
        await assertNoFolderTraffic(imap)
    }

    /// The reload re-runs the query the user submitted, not whatever the
    /// search field holds now, so a term typed but never sent doesn't replace
    /// the results on Refresh; the field keeps what was typed. On the search
    /// surface that is the toolbar or menu Refresh (`hardReload`) and
    /// pull-to-refresh (`refresh()` takes the same path). Fixed in #1821;
    /// this test pinned the field text being run until then.
    func testHardReloadOnTheSearchSurfaceReRunsTheSubmittedQuery() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearch(page(firstUID: 1, count: 1, cursor: nil))
        let model = try makeSearchModel(imap: imap)
        model.searchQuery = "invoice"
        await model.runSearch()
        model.searchQuery = "receipt"

        await model.hardReload()

        let calls = await imap.searchCalls
        XCTAssertEqual(calls.map(\.text), ["invoice", "invoice"])
        XCTAssertEqual(model.submittedQuery, "invoice")
        XCTAssertEqual(model.searchQuery, "receipt", "the field keeps what was typed")
    }

    func testHardReloadOnTheSearchSurfaceWithNoSearchDoesNothing() async throws {
        let imap = FakeImapClient()
        let model = try makeSearchModel(imap: imap)
        model.searchQuery = "typed but not sent"

        await model.hardReload()

        let calls = await imap.searchCalls
        XCTAssertTrue(calls.isEmpty)
        await assertNoFolderTraffic(imap)
        XCTAssertFalse(model.isSearchActive)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.submittedQuery, "")
    }
}

/// The Feeds menu's catalog commands, as the mounted feed sidebar answers
/// them through `FeedManagementSheets` -> `FeedManagementActions.handle`
/// (RSS phase 5c, 91589fb4, `docs/1.x/rss-implementation-plan.md`; scoped
/// to one window by #1783). Pinned with no management model, the state a
/// sidebar is in before its catalog loads; the item commands belong to the
/// item list and must not open anything here.
@MainActor
final class FeedCommandReceiverCharacterizationTests: XCTestCase {

    /// What the sidebar does with each command. No `default`: a case added
    /// to `FeedCommand` during workstream 3.1 stops this file compiling until
    /// its handling is decided here.
    private func expectedHandling(of command: FeedCommand) -> FeedCommandHandling {
        switch command {
        case .subscribe: FeedCommandHandling(handled: true, sheet: "subscribe")
        case .newFolder: FeedCommandHandling(handled: true, sheet: "folder")
        case .importOpml: FeedCommandHandling(handled: true, importer: true)
        // No catalog loaded, so there is nothing to export.
        case .exportOpml: FeedCommandHandling(handled: true)
        // False hands the refresh back to the host's own sidebar refresh.
        case .refresh: FeedCommandHandling(handled: false)
        // The item list answers these; the sidebar must not refresh for them.
        case .toggleRead, .toggleFlag, .markAllRead: FeedCommandHandling(handled: true)
        }
    }

    func testEachCommandOnAFreshSidebarOpensOnlyItsOwnSurfaceAndLeavesRefreshToTheHost() {
        for command in CommandTickCharacterizationTests.everyFeedCommand {
            let actions = FeedManagementActions()
            let expected = expectedHandling(of: command)
            XCTAssertEqual(actions.handle(command, management: nil), expected.handled, "\(command)")
            XCTAssertEqual(actions.sheet?.id, expected.sheet, "\(command)")
            XCTAssertEqual(actions.opml.importerPresented, expected.importer, "\(command)")
            XCTAssertNil(actions.pendingMarkAllRead, "\(command): the item list owns that confirmation")
        }
    }

    func testSubscribeOpensTheSubscribeSheetWithACleanForm() {
        let actions = FeedManagementActions()
        actions.subscribeForm.url = "https://example.com/feed.xml"
        actions.subscribeForm.folderId = "folder-1"

        XCTAssertTrue(actions.handle(.subscribe, management: nil))
        XCTAssertEqual(actions.sheet?.id, "subscribe")
        XCTAssertEqual(actions.subscribeForm.url, "")
        XCTAssertEqual(actions.subscribeForm.folderId, "", "the menu subscribes at the top level")
        XCTAssertFalse(actions.opml.importerPresented)
    }

    func testNewFolderOpensTheFolderSheetAtTheTopLevel() {
        let actions = FeedManagementActions()
        // A rename left the form editing a nested folder.
        actions.editFolder(RssFolder(folderId: "folder-2", parentFolderId: "folder-1", name: "Leftover"))
        XCTAssertNotNil(actions.folderForm.editing)
        XCTAssertEqual(actions.folderForm.parentId, "folder-1")

        XCTAssertTrue(actions.handle(.newFolder, management: nil))
        XCTAssertEqual(actions.sheet?.id, "folder")
        XCTAssertEqual(actions.folderForm.name, "")
        XCTAssertEqual(actions.folderForm.parentId, "")
        XCTAssertNil(actions.folderForm.editing, "a new folder, not the rename")
    }

    func testImportPresentsTheFileImporterRootedAtTheTopLevel() {
        let actions = FeedManagementActions()
        actions.opml.beginImport(into: "folder-1")
        actions.opml.importerPresented = false

        XCTAssertTrue(actions.handle(.importOpml, management: nil))
        XCTAssertTrue(actions.opml.importerPresented)
        XCTAssertNil(actions.opml.importFolderId, "a menu import is never rooted in a folder")
        XCTAssertNil(actions.sheet)
    }

    /// With no catalog loaded there is nothing to export: the command is
    /// handled (so the host does not refresh) and nothing else moves. The
    /// exporter state cannot change without a management model, so what is
    /// pinned is the return value and the earlier state left in place.
    func testExportWithNoManagementModelDoesNothing() {
        let actions = FeedManagementActions()
        actions.newFolder()
        actions.opml.resultMessage = "Imported 3 feeds."

        XCTAssertTrue(actions.handle(.exportOpml, management: nil), "handled, so the host does not refresh")
        XCTAssertEqual(actions.sheet?.id, "folder", "an open sheet stays up")
        XCTAssertEqual(actions.opml.resultMessage, "Imported 3 feeds.")
        XCTAssertFalse(actions.opml.exporterPresented)
        XCTAssertNil(actions.opml.exportDocument)
    }

    func testACatalogCommandReplacesASheetAlreadyUpAndAnItemCommandLeavesIt() {
        let actions = FeedManagementActions()
        XCTAssertTrue(actions.handle(.newFolder, management: nil))
        XCTAssertTrue(actions.handle(.subscribe, management: nil))
        XCTAssertEqual(actions.sheet?.id, "subscribe")

        XCTAssertTrue(actions.handle(.toggleRead, management: nil))
        XCTAssertEqual(actions.sheet?.id, "subscribe")
        XCTAssertFalse(actions.handle(.refresh, management: nil))
        XCTAssertEqual(actions.sheet?.id, "subscribe")
    }
}

/// `FeedManagementActions.handle`'s answer to one command, and what it
/// leaves showing.
private struct FeedCommandHandling {
    let handled: Bool
    var sheet: String?
    var importer = false
}
