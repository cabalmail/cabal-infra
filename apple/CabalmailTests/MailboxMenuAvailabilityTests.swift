import XCTest
@testable import CabalmailUI

// Regression coverage for issue #1162: with every macOS window closed — the
// state the menu-bar residency exists to make ordinary — File ▸ New Message
// and Mailbox ▸ Refresh both reported `enabled = true` and silently did
// nothing, because each answered inside a main window.
//
// The two get opposite answers, and that split is what these tests pin.
// Refresh has nothing to reload with no list on screen, so it dims. New
// Message has somewhere to go — the compose `WindowGroup` mounts on its own —
// so it stays enabled and the command opens the window itself.
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

    private func makeWindow() -> WindowCommands {
        WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: .mail))
    }

    func testAMountedSurfaceMakesRefreshLive() {
        let window = makeWindow()
        XCTAssertFalse(window.mailbox.canRefresh)

        window.mailbox.surfaceAppeared()

        XCTAssertTrue(window.mailbox.canRefresh)
    }

    func testTheLastSurfaceClosingDimsRefresh() {
        let window = makeWindow()
        window.mailbox.surfaceAppeared()

        window.mailbox.surfaceDisappeared()

        XCTAssertFalse(window.mailbox.canRefresh)
    }

    func testRefreshStaysLiveWhileTheWindowsSecondSurfaceRemains() {
        // A layout swap mounts the new mail surface before the old one goes;
        // the old one leaving keeps the menu's target on screen.
        let window = makeWindow()
        window.mailbox.surfaceAppeared()
        window.mailbox.surfaceAppeared()

        window.mailbox.surfaceDisappeared()

        XCTAssertTrue(window.mailbox.canRefresh)
    }

    func testAnUnpairedDisappearDoesNotWedgeTheMenuDim() {
        // SwiftUI can deliver a disappear this instance never saw an appear
        // for; a count that went negative would need two appears to recover.
        let window = makeWindow()
        window.mailbox.surfaceDisappeared()

        window.mailbox.surfaceAppeared()

        XCTAssertTrue(window.mailbox.canRefresh)
    }

    // MARK: - Mark All as Read (cross-media plan, Phase 1)

    // ⌥⌘T acts on the folder-scoped message list, so with none mounted (the
    // search surface, or no window) it dims, the same answer Refresh gives.

    func testMarkAllReadDimsWithNoFolderListOnScreen() {
        var availability = MailboxMenuAvailability.none
        availability.surfaceAppeared()
        XCTAssertFalse(availability.canMarkAllRead, "a mounted surface alone is not a folder list")
    }

    func testMarkAllReadIsLiveWhileAFolderListIsOnScreen() {
        var availability = MailboxMenuAvailability.none
        availability.surfaceAppeared()
        availability.folderListAppeared("INBOX")
        XCTAssertTrue(availability.canMarkAllRead)

        availability.folderListDisappeared("INBOX")
        XCTAssertFalse(availability.canMarkAllRead)
    }

    /// The list is re-keyed per folder, and SwiftUI delivers the new list's
    /// appear before the old list's disappear: the stale disappear must not
    /// wipe the fresh report.
    func testAStaleDisappearFromThePreviousFolderIsIgnored() {
        var availability = MailboxMenuAvailability.none
        availability.folderListAppeared("INBOX")
        availability.folderListAppeared("Sent")

        availability.folderListDisappeared("INBOX")

        XCTAssertTrue(availability.canMarkAllRead)
    }
}
