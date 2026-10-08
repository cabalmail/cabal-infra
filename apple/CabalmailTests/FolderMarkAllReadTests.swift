import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Mark All as Read for a mail folder (cross-media plan, decision 6): one
/// `/mark_folder_read` call through the IMAP client, then the client-side
/// after-effects every entry point shares — the badge zeroes its unread and
/// keeps its total, and the visible list is asked to reload.
@MainActor
final class FolderMarkAllReadTests: XCTestCase {

    func testMarksTheFolderZeroesUnreadKeepsTotalAndRequestsARefresh() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(12)])
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "Projects", unread: 12, total: 80)
        let model = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), mailStore: appState.mailStore)
        let ticks = appState.refreshRequestTick

        await model.markAllRead(folderPath: "Projects")

        let calls = await imap.markFolderReadCalls
        XCTAssertEqual(calls, ["Projects"])
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Projects"], 0)
        XCTAssertEqual(
            appState.mailStore.counts.folderTotalCounts["Projects"], 80, "the total is not the server's to change here"
        )
        XCTAssertEqual(appState.refreshRequestTick, ticks + 1, "the visible list re-renders read state")
        XCTAssertNil(model.errorMessage)
    }

    /// A folder with no STATUS yet zeroes its unread without inventing a
    /// total the badge would draw as `0/0`.
    func testAnUnfetchedFolderDoesNotGainATotal() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), mailStore: appState.mailStore)

        await model.markAllRead(folderPath: "Archive")

        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Archive"], 0)
        XCTAssertNil(appState.mailStore.counts.folderTotalCounts["Archive"])
    }

    func testAFailureSurfacesAndLeavesTheCountsAlone() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.failure(CabalmailError.network("offline"))])
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 5, total: 40)
        let model = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), mailStore: appState.mailStore)
        let ticks = appState.refreshRequestTick

        await model.markAllRead(folderPath: "INBOX")

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["INBOX"], 5)
        XCTAssertEqual(appState.refreshRequestTick, ticks, "nothing changed, so nothing to reload")
    }

    /// A folder marked from the sidebar while another is on screen keeps
    /// its saved list, every row read, so a list opened on it offline shows
    /// its messages (#1850). The snapshot used to be deleted, and nothing
    /// rebuilt it until the folder was next opened online.
    func testAFolderNotOnScreenKeepsItsSavedListMarkedRead() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(2)])
        let client = try TestFixtures.makeClient(imap: imap)
        try await client.envelopeCache.merge(
            envelopes: [
                TestFixtures.makeEnvelope(uid: 1),
                TestFixtures.makeEnvelope(uid: 2, flags: [.flagged]),
            ],
            uidValidity: 7, uidNext: 3, into: "Archive"
        )
        let appState = AppState()
        let sidebar = FolderListViewModel(client: client, mailStore: appState.mailStore)

        await sidebar.markAllRead(folderPath: "Archive")

        let list = MessageListViewModel(
            folder: Folder(path: "Archive", attributes: [], isSubscribed: false),
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: appState.mailStore
        )
        await list.window.hydrateFromCache()
        XCTAssertEqual(list.envelopes.map(\.uid).sorted(), [1, 2])
        XCTAssertTrue(list.envelopes.allSatisfy { $0.flags.contains(.seen) })
        XCTAssertTrue(list.envelopes.first { $0.uid == 2 }?.flags.contains(.flagged) == true)
    }

    /// The message list's own entry (toolbar More menu, Mailbox ⌥⌘T) runs
    /// the same routine for the folder it shows.
    func testTheMessageListEntryMarksItsOwnFolder() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(3)])
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "Sent", unread: 3, total: 9)
        let model = try TestFixtures.makeModel(
            imap: imap, envelopes: [], folderPath: "Sent", mailStore: appState.mailStore
        )

        await model.markAllRead()

        let calls = await imap.markFolderReadCalls
        XCTAssertEqual(calls, ["Sent"])
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Sent"], 0)
        XCTAssertEqual(appState.mailStore.counts.folderTotalCounts["Sent"], 9)
    }
}
