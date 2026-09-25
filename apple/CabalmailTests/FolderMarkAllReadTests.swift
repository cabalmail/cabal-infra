import XCTest
import CabalmailKit
@testable import Cabalmail

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
        appState.setFolderCounts(folderPath: "Projects", unread: 12, total: 80)
        let model = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), appState: appState)
        let ticks = appState.refreshRequestTick

        await model.markAllRead(folderPath: "Projects")

        let calls = await imap.markFolderReadCalls
        XCTAssertEqual(calls, ["Projects"])
        XCTAssertEqual(appState.folderUnreadCounts["Projects"], 0)
        XCTAssertEqual(appState.folderTotalCounts["Projects"], 80, "the total is not the server's to change here")
        XCTAssertEqual(appState.refreshRequestTick, ticks + 1, "the visible list re-renders read state")
        XCTAssertNil(model.errorMessage)
    }

    /// A folder with no STATUS yet zeroes its unread without inventing a
    /// total the badge would draw as `0/0`.
    func testAnUnfetchedFolderDoesNotGainATotal() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), appState: appState)

        await model.markAllRead(folderPath: "Archive")

        XCTAssertEqual(appState.folderUnreadCounts["Archive"], 0)
        XCTAssertNil(appState.folderTotalCounts["Archive"])
    }

    func testAFailureSurfacesAndLeavesTheCountsAlone() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.failure(CabalmailError.network("offline"))])
        let appState = AppState()
        appState.setFolderCounts(folderPath: "INBOX", unread: 5, total: 40)
        let model = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), appState: appState)
        let ticks = appState.refreshRequestTick

        await model.markAllRead(folderPath: "INBOX")

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(appState.folderUnreadCounts["INBOX"], 5)
        XCTAssertEqual(appState.refreshRequestTick, ticks, "nothing changed, so nothing to reload")
    }

    /// The message list's own entry (toolbar More menu, Mailbox ⌥⌘T) runs
    /// the same routine for the folder it shows.
    func testTheMessageListEntryMarksItsOwnFolder() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(3)])
        let appState = AppState()
        appState.setFolderCounts(folderPath: "Sent", unread: 3, total: 9)
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [], folderPath: "Sent", appState: appState)

        await model.markAllRead()

        let calls = await imap.markFolderReadCalls
        XCTAssertEqual(calls, ["Sent"])
        XCTAssertEqual(appState.folderUnreadCounts["Sent"], 0)
        XCTAssertEqual(appState.folderTotalCounts["Sent"], 9)
    }
}
