import XCTest
@testable import Cabalmail

/// Issue #1419: a search that covered only the subscribed folders answered
/// "No matches" for a message sitting in Sent, and the only thing on screen
/// about scope was `in 2 folders` — a bare number, stacked over the match
/// count, that never named a folder and never hinted at the recourse. These
/// pin what each surface now says about where the search looked.
final class SearchScopeSummaryTests: XCTestCase {
    private func scope(
        _ folders: [String],
        thisFolderOnly: Bool = false,
        anchor: String = "INBOX"
    ) -> SearchScopeSummary {
        SearchScopeSummary(
            foldersSearched: folders,
            thisFolderOnly: thisFolderOnly,
            anchorFolderName: anchor
        )
    }

    // MARK: - The reported line

    /// The exact banner from the report: two subscribed folders, no names.
    func testTwoFoldersAreNamedInsteadOfCounted() {
        let label = scope(["INBOX", "Archive"]).bannerLabel
        XCTAssertTrue(label.contains("INBOX"), label)
        XCTAssertTrue(label.contains("Archive"), label)
        XCTAssertFalse(label.contains("2 folders"), label)
    }

    /// `1 of 1 match` over `in 2 folders` was self-contradictory on its face.
    /// Leading with the verb is what stops the line reading as a property of
    /// the results underneath it.
    func testTheScopeLineReadsAsAnActionNotAsAPropertyOfTheResults() {
        for folders in [["INBOX"], ["INBOX", "Archive"], ["A", "B", "C", "D"]] {
            let label = scope(folders).bannerLabel
            XCTAssertTrue(label.hasPrefix("Searched"), label)
            XCTAssertFalse(label.hasPrefix("in "), label)
        }
    }

    /// The single-folder case already named its folder; that must survive.
    func testASingleFolderIsStillNamed() {
        XCTAssertEqual(scope(["Archive"]).bannerLabel, "Searched Archive")
    }

    // MARK: - Naming many folders

    func testFoldersAreListedUpToTheLimitThenCounted() {
        XCTAssertEqual(SearchScopeSummary.phrase(for: ["A"]), "A")
        XCTAssertEqual(SearchScopeSummary.phrase(for: ["A", "B"]), "A and B")
        XCTAssertEqual(SearchScopeSummary.phrase(for: ["A", "B", "C"]), "A, B and C")
        XCTAssertEqual(SearchScopeSummary.phrase(for: ["A", "B", "C", "D"]), "A, B, C and 1 more")
        XCTAssertEqual(
            SearchScopeSummary.phrase(for: ["A", "B", "C", "D", "E"]),
            "A, B, C and 2 more"
        )
    }

    /// Every folder is either named or counted — the phrase never drops one
    /// silently, which is the failure the bare count was.
    func testTheOverflowCountAccountsForEveryUnnamedFolder() {
        let folders = (1...9).map { "F\($0)" }
        let phrase = SearchScopeSummary.phrase(for: folders)
        XCTAssertTrue(phrase.contains("and \(9 - SearchScopeSummary.namedFolderLimit) more"), phrase)
    }

    // MARK: - The empty state's recourse

    func testTheEmptyStateNamesTheScopeAndTheWayToWidenIt() throws {
        let note = try XCTUnwrap(scope(["INBOX", "Archive"]).emptyStateNote)
        XCTAssertTrue(note.contains("INBOX"), note)
        XCTAssertTrue(note.contains("Archive"), note)
        XCTAssertTrue(note.lowercased().contains("subscrib"), note)
    }

    /// Trash is excluded from cross-folder search even when it is subscribed
    /// (`CROSS_FOLDER_EXCLUDES` in `lambda/api/search_envelopes/function.py`),
    /// so the note must not promise that subscribing to it would help.
    func testTheNoteSaysTrashIsNeverSearched() {
        let note = scope(["INBOX", "Archive"]).emptyStateNote ?? ""
        XCTAssertTrue(note.contains("Trash"), note)
    }

    /// A pinned search has a different recourse: the filter, not a
    /// subscription.
    func testThisFolderOnlyPointsAtTheFilterInstead() {
        let note = scope(["Archive"], thisFolderOnly: true).emptyStateNote ?? ""
        XCTAssertTrue(note.contains("Archive"), note)
        XCTAssertTrue(note.contains("This folder only"), note)
        XCTAssertFalse(note.lowercased().contains("subscrib"), note)
    }

    func testThisFolderOnlyFallsBackToTheAnchorBeforeTheServerReports() {
        let summary = scope([], thisFolderOnly: true, anchor: "Drafts")
        XCTAssertEqual(summary.bannerLabel, "Searched Drafts only")
        XCTAssertTrue(summary.emptyStateNote?.contains("Drafts") == true)
    }

    // MARK: - Claiming nothing when nothing is known

    /// Before a search reports (or after one fails) the app knows no scope.
    /// The old wording was "in all folders", which is false for every
    /// account: an unsubscribed folder is never searched and Trash never is.
    func testAnUnknownScopeMakesNoClaim() {
        let summary = scope([])
        XCTAssertFalse(summary.bannerLabel.lowercased().contains("all folders"))
        XCTAssertNil(summary.emptyStateNote)
    }
}
