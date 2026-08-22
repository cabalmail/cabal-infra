import XCTest
import SwiftUI
@testable import Cabalmail

// Regression coverage for issue #1217: on iPadOS regular width, picking a
// folder in the sidebar while a search was showing did nothing visible. The
// panel slid away, the sidebar drew the row as `Selected`, and the message
// column kept the search results under a "Search" title. The pick had landed
// — clearing the query dropped you straight into the folder — so the two
// pieces of state disagreed and only one of them was on screen.
//
// `contentColumn` prefers search to any folder while the search field is
// engaged, which is right; nothing was ending the search when the user asked
// to go somewhere else, which is the defect. Both halves are stated in
// `ContentColumnPolicy` so the transition can be tested as a sequence.
final class ContentColumnPolicyTests: XCTestCase {

    // MARK: - The precedence the column renders

    func testSearchOwnsTheColumnWhileTheFieldIsEngaged() {
        XCTAssertEqual(
            ContentColumnPolicy.mode(isSearching: true, selectedFolderPath: "INBOX"),
            .search
        )
    }

    func testAFolderOwnsTheColumnWhenNoSearchIsRunning() {
        XCTAssertEqual(
            ContentColumnPolicy.mode(isSearching: false, selectedFolderPath: "Sent"),
            .folder("Sent")
        )
    }

    func testNoFolderAndNoSearchIsTheEmptyPrompt() {
        XCTAssertEqual(
            ContentColumnPolicy.mode(isSearching: false, selectedFolderPath: nil),
            .empty
        )
    }

    // MARK: - What a pick has to do to be visible

    /// The reported flow: search from INBOX, pick Sent. The pick has to end
    /// the search, or the column it lands in is one the user cannot see.
    func testPickingADifferentFolderDuringASearchEndsIt() {
        XCTAssertTrue(ContentColumnPolicy.pickEndsSearch(isSearching: true, picked: "Sent"))
    }

    /// The report's second variant, where not even the folder panel
    /// dismissed: the folder picked is the one that was already selected when
    /// the search started. Same intent, same answer — which is why the
    /// dismissal rides the sidebar's binding rather than a change handler.
    func testRePickingTheAlreadySelectedFolderStillEndsTheSearch() {
        XCTAssertTrue(ContentColumnPolicy.pickEndsSearch(isSearching: true, picked: "INBOX"))
    }

    /// The launch landing and the cross-client cursor restore write
    /// `selectedFolder` with no user gesture behind them.
    func testAPickWithNoSearchRunningChangesNothing() {
        XCTAssertFalse(ContentColumnPolicy.pickEndsSearch(isSearching: false, picked: "Archive"))
    }

    /// A write of `nil` is not a navigation intent — a sidebar remount or a
    /// folder that stopped existing clears the selection, and throwing away a
    /// search the user is still reading would be a worse bug than the one
    /// being fixed here.
    func testClearingTheSelectionDoesNotEndASearch() {
        XCTAssertFalse(ContentColumnPolicy.pickEndsSearch(isSearching: true, picked: nil))
    }

    // MARK: - The two rules composed, which is the actual regression

    /// The whole defect in one assertion: apply the pick, apply whatever it
    /// does to the search state, and ask what the column shows. Pre-#1217 the
    /// pick did nothing to the search, so this read `.search` — the sidebar
    /// claiming Sent while the column showed the results.
    func testAFolderPickDuringASearchLandsTheColumnOnThatFolder() {
        let picked = "Sent"
        var isSearching = true
        if ContentColumnPolicy.pickEndsSearch(isSearching: isSearching, picked: picked) {
            isSearching = false
        }
        XCTAssertEqual(
            ContentColumnPolicy.mode(isSearching: isSearching, selectedFolderPath: picked),
            .folder(picked)
        )
    }

    /// The same sequence for the re-pick variant.
    func testARePickDuringASearchLandsTheColumnBackOnThatFolder() {
        let picked = "INBOX"
        var isSearching = true
        if ContentColumnPolicy.pickEndsSearch(isSearching: isSearching, picked: picked) {
            isSearching = false
        }
        XCTAssertEqual(
            ContentColumnPolicy.mode(isSearching: isSearching, selectedFolderPath: picked),
            .folder(picked)
        )
    }

    /// The control: with the selection cleared rather than picked, the search
    /// survives and still owns the column. This passes before the fix as well
    /// as after, deliberately — it is the guard rail against "fixing" #1217
    /// by making any sidebar write end the search.
    func testASearchSurvivesTheSelectionBeingCleared() {
        var isSearching = true
        if ContentColumnPolicy.pickEndsSearch(isSearching: isSearching, picked: nil) {
            isSearching = false
        }
        XCTAssertEqual(
            ContentColumnPolicy.mode(isSearching: isSearching, selectedFolderPath: nil),
            .search
        )
    }
}
