import XCTest
import SwiftUI
@testable import Cabalmail

// Regression coverage for issue #838: the cancel-compose dialog offered
// "Discard Draft" and "Save Draft", with the *cancel* role on Save Draft.
// SwiftUI drops the cancel-role button when a confirmation dialog renders
// as a popover — which is what iPhone does here — so the user saw a single
// destructive button under a message promising a keep option, and an
// outside tap (the popover's cancel path) silently saved and closed the
// composer with no way back to it.
//
// The fix gives the dialog all three outcomes and moves the cancel role
// onto a no-op "Keep Editing", so the popover's outside tap returns the
// user to the composer and both draft actions stay visible.
final class ComposeCancelChoiceTests: XCTestCase {

    func testOffersAllThreeOutcomesInOrder() {
        XCTAssertEqual(
            ComposeCancelChoice.allCases.map(\.title),
            ["Discard Draft", "Save Draft", "Keep Editing"]
        )
    }

    func testNoDraftActionCarriesTheCancelRole() {
        // The role is the whole defect: a cancel-roled button disappears in
        // popover presentation and runs on an outside tap instead. Neither
        // draft action may hold it, on any platform.
        let cancelRoled = ComposeCancelChoice.allCases.filter { $0.role == .cancel }
        XCTAssertFalse(cancelRoled.contains(.discard))
        XCTAssertFalse(cancelRoled.contains(.saveDraft))
    }

    func testKeepEditingRoleMatchesThePlatformPresentation() {
        #if os(macOS)
        // Alert presentation shows every button and maps Escape to the
        // cancel-roled one.
        XCTAssertEqual(ComposeCancelChoice.keepEditing.role, .cancel)
        #else
        // Popover presentation would swallow a cancel-roled button, which
        // is how "Save Draft" went missing in the first place.
        XCTAssertNil(ComposeCancelChoice.keepEditing.role)
        #endif
    }

    func testDraftActionsSurvivePopoverPresentation() {
        // Both draft outcomes must be non-cancel so they render even when
        // the dialog comes up as a popover.
        XCTAssertEqual(ComposeCancelChoice.discard.role, .destructive)
        XCTAssertNil(ComposeCancelChoice.saveDraft.role)
    }
}
