import XCTest
@testable import Cabalmail

// Regression coverage for issue #1162: with every macOS window closed — the
// state the menu-bar residency exists to make ordinary — File ▸ New Message
// and Mailbox ▸ Refresh both reported `enabled = true` and silently did
// nothing, because each dispatches through an `AppState` tick whose only
// consumer is a modifier mounted inside the main window.
//
// The two commands get opposite answers, and that split is what these tests
// pin. Refresh has nothing to reload with no list on screen, so it dims (the
// rule `MessageMenuAvailability` already applies to the Message menu). New
// Message does have somewhere to go — the compose `WindowGroup` mounts on its
// own, which is why the menu-bar extra's item worked in that very state — so
// it stays enabled and the command opens the window itself.
//
// The routing half (the File command reaching `ComposeWindowCommand` rather
// than the tick) has no unit seam: `OpenWindowAction` cannot be constructed
// outside SwiftUI and a `Commands` body cannot be invoked from a test. That
// half is verified live on macOS; see the PR.
@MainActor
final class MailboxMenuAvailabilityTests: XCTestCase {

    // MARK: - The rule

    func testRefreshDimsWithNoMailSurfaceMounted() {
        XCTAssertFalse(MailboxMenuAvailability.none.canRefresh)
    }

    func testRefreshIsLiveWithAMailSurfaceMounted() {
        var availability = MailboxMenuAvailability.none
        availability.surfaceAppeared()

        XCTAssertTrue(availability.canRefresh)
    }

    func testNewMessageStaysLiveWithNoMailSurfaceMounted() {
        // The broad reading of "dim what cannot act" would take this one down
        // too, and it is the command the zero-window state most needs.
        XCTAssertTrue(MailboxMenuAvailability.none.canCompose)
    }

    // MARK: - What the mail surfaces report

    func testAMountedSurfaceMakesRefreshLive() {
        let appState = AppState()
        XCTAssertFalse(appState.mailboxMenuAvailability.canRefresh)

        appState.mailboxMenuAvailability.surfaceAppeared()

        XCTAssertTrue(appState.mailboxMenuAvailability.canRefresh)
    }

    func testTheLastSurfaceClosingDimsRefresh() {
        let appState = AppState()
        appState.mailboxMenuAvailability.surfaceAppeared()

        appState.mailboxMenuAvailability.surfaceDisappeared()

        XCTAssertFalse(appState.mailboxMenuAvailability.canRefresh)
    }

    func testRefreshStaysLiveWhileASecondMailWindowIsOpen() {
        // macOS can have several mail windows; closing one leaves the menu's
        // target on screen in the others.
        let appState = AppState()
        appState.mailboxMenuAvailability.surfaceAppeared()
        appState.mailboxMenuAvailability.surfaceAppeared()

        appState.mailboxMenuAvailability.surfaceDisappeared()

        XCTAssertTrue(appState.mailboxMenuAvailability.canRefresh)
    }

    func testAnUnpairedDisappearDoesNotWedgeTheMenuDim() {
        // SwiftUI can deliver a disappear this instance never saw an appear
        // for; a count that went negative would need two appears to recover.
        let appState = AppState()
        appState.mailboxMenuAvailability.surfaceDisappeared()

        appState.mailboxMenuAvailability.surfaceAppeared()

        XCTAssertTrue(appState.mailboxMenuAvailability.canRefresh)
    }
}
