import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The global search surface shows no folder, so no request it makes may name one it would have to make
/// up. Until 2.2 C its list carried a sentinel folder with an empty path, and every folder call it could
/// reach had to be gated off by hand -- Mark All as Read was not. Now it has no folder window and no
/// folder: this drives every entry point a list has, with and without a search showing, and checks every
/// folder the client was asked about.
@MainActor
final class SearchSurfaceFolderPathTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!

    override func setUp() async throws {
        fixture = RefreshCharacterizationFixture()
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
    }

    func testNoRequestFromTheSearchSurfaceNamesAnEmptyFolderPath() async throws {
        let imap = fixture.imap
        let model = try await fixture.makeSearchScopeModel()
        XCTAssertNil(model.window, "the search surface has no folder window")
        XCTAssertNil(model.folder, "nor a folder")

        // A folder list's lifecycle and commands, with no search showing.
        await model.loadInitial()
        await model.startWatching()
        await model.refresh()
        await model.hardReload()
        await model.markAllRead()

        // A full first page -- a row from INBOX, one from Archive, the rest from Sent -- with a next page
        // behind it, then what a list does with a search showing.
        await imap.scriptSearchPages([Self.page([(7, "INBOX"), (7, "Archive")] + Self.sent(100..<148), cursor: "c1")])
        await imap.scriptSearch(Self.page([(3, "Sent")], cursor: nil))
        model.searchQuery = "invoice"
        await model.runSearch()
        XCTAssertEqual(model.envelopes.count, MailSearchSession.pageSize, "precondition: the first page shows")
        await model.setFlag(.flagged, add: true, envelope: model.envelopes[1])
        await model.dispose(model.envelopes[0])
        await model.search.loadMore()
        await model.refresh()
        await model.hardReload()
        await model.markAllRead()
        // A pill on the surface, narrowed to the sidebar's folder.
        await model.setSearchAnchor(Folder(path: "Archive"))
        await model.selectFilter(.unread)
        await model.clearSearch()
        await model.stopWatching()

        let named = await Self.foldersNamed(by: imap)
        XCTAssertFalse(named.contains(""), "a request named an empty folder: \(named)")
        // Floors, so a model that sent nothing can't pass.
        let flagged = await imap.flagCalls.map(\.folder)
        let moved = await imap.moveCalls.map(\.folder)
        let searches = await imap.searchCalls
        XCTAssertEqual(flagged, ["Archive"], "the flag reached its row's own folder")
        XCTAssertEqual(moved, ["INBOX"], "so did the dispose")
        XCTAssertTrue(searches.contains { $0.cursor == "c1" }, "the next page was asked for")
        XCTAssertEqual(searches.last?.folder, "Archive", "the pill narrowed to the anchor")
    }

    /// One search page of `rows` (UID, folder).
    private static func page(_ rows: [(UInt32, String)], cursor: String?) -> SearchResult {
        SearchResult(
            envelopes: rows.map { SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: $0.0), folder: $0.1) },
            totalEstimate: rows.count + 1,
            nextCursor: cursor,
            foldersSearched: ["INBOX", "Archive", "Sent"],
            truncated: false
        )
    }

    private static func sent(_ uids: Range<UInt32>) -> [(UInt32, String)] {
        uids.map { ($0, "Sent") }
    }

    /// Every folder a request to `imap` named, in any role.
    private static func foldersNamed(by imap: FakeImapClient) async -> [String] {
        var named = await imap.statusCalls.map(\.path)
        named += await imap.topEnvelopesCalls.map(\.folder)
        named += await imap.envelopesCalls.map(\.folder)
        named += await imap.fetchBodyCalls.map(\.folder)
        named += await imap.idleFolders
        named += await imap.markFolderReadCalls
        named += await imap.emptyTrashCalls
        named += await imap.flagCalls.map(\.folder)
        let moves = await imap.moveCalls
        named += moves.map(\.folder) + moves.map(\.destination)
        named += await imap.purgeCalls.map(\.folder)
        named += await imap.searchCalls.compactMap(\.folder)
        return named
    }
}
