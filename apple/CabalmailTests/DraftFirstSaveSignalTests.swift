import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #1083: with the Drafts folder open, saving a
// brand-new message left the list unchanged until the status poll got round
// to noticing it — measured at t+5 s on one run and t+32 s on another, i.e.
// anywhere in the watcher's 30 s cycle (`ApiBackedImapClient.idle` has no
// real IDLE behind it and re-reads `folderStatus` on a timer).
//
// The three exits that already reported (#1071 send, #1078 save-on-resume,
// #1081 discard) all report *retirements*: something stale on screen. A
// first save leaves nothing stale — only something absent — so
// `DraftReplacementPolicy.retirement` returned nil for it by design and the
// list heard nothing.
//
// The fix widens that channel rather than adding a second one: a save
// reports its survivor whether or not it retired anything, and the refresh
// the list already runs on the signal is the whole point. The cases below
// pin both halves — that the arrival is now reported, and that reporting it
// does not disturb whatever the user is reading.
@MainActor
final class DraftFirstSaveSignalTests: XCTestCase {

    // The compose session's own half — that a first save now reports the
    // copy it created, and that a session which autosaved first still
    // reports its whole chain — lives in `DraftReplacementTests`, where the
    // rest of the retirement rule is pinned. This file starts where that
    // ends: what the signal does once it is sent.

    // MARK: - What AppState does with it

    /// The half that made the fix two lines instead of one: the signal
    /// sender used to drop anything with an empty retired chain, so even a
    /// reporting first save would have gone nowhere.
    func testAppStatePublishesAnArrivalOnlySignal() {
        let appState = AppState()

        appState.signalDraftReplaced(
            folderPath: "Drafts",
            replacement: DraftReplacement(retiredUIDs: [], survivingUID: 700)
        )

        XCTAssertEqual(appState.lastDraftReplaced?.folderPath, "Drafts")
        XCTAssertEqual(
            appState.lastDraftReplaced?.replacement,
            DraftReplacement(retiredUIDs: [], survivingUID: 700)
        )
    }

    /// Neither half means nothing happened on the server. Still dropped, so
    /// an empty compose opened and closed cannot make an open list refresh.
    func testAppStateStillDropsASignalWithNothingInIt() {
        let appState = AppState()

        appState.signalDraftReplaced(
            folderPath: "Drafts",
            replacement: DraftReplacement(retiredUIDs: [], survivingUID: nil)
        )

        XCTAssertNil(appState.lastDraftReplaced)
    }

    // MARK: - What the list does with it

    /// The arrival must not move anybody's reader. `resolve` is what the
    /// list consults after its refresh, and an empty retired chain can never
    /// match the displayed UID — swept over "reading another draft", "reading
    /// the folder's other message" and "reading nothing" rather than one
    /// example, since the whole risk of widening this channel is a stolen
    /// selection.
    func testAFirstSaveLeavesEveryReaderAlone() {
        let arrival = DraftReplacement(retiredUIDs: [], survivingUID: 700)
        for displayed: UInt32? in [610, 639, 700, nil] {
            XCTAssertEqual(
                DraftReplacementPolicy.resolve(
                    displayedUID: displayed,
                    replacement: arrival,
                    loadedUIDs: [610, 639, 700]
                ),
                .ignore,
                "displayed UID \(String(describing: displayed)) should be left alone"
            )
        }
    }
}
