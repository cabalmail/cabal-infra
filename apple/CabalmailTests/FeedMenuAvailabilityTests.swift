import XCTest
import CabalmailKit
@testable import Cabalmail

// The Feeds menu's item commands (cross-media plan, Phase 1) follow the rule
// #985 set for the Message menu: enabled iff there is something to act on.
// And because they carry the Message / Mailbox menus' own chords (⌘T, ⌘⇧8,
// ⌥⌘T), `SharedChordPolicy` must never leave both menus' items live at once
// — a key equivalent fires app-wide, and two enabled items on one chord
// leave AppKit to pick a winner.
@MainActor
final class FeedMenuAvailabilityTests: XCTestCase {

    // MARK: - The feed rule

    func testNothingSelectedAndNoScopeDimsEveryCommand() {
        let availability = FeedMenuAvailability.none
        XCTAssertFalse(availability.canActOnSelection)
        XCTAssertFalse(availability.canMarkAllRead)
    }

    // A scope on screen with nothing picked: Mark All as Read has its
    // target, the per-item toggles do not.
    func testAScopeAloneEnablesMarkAllReadOnly() {
        let availability = FeedMenuAvailability(selectedCount: 0, hasOpenItem: false, hasScope: true)
        XCTAssertFalse(availability.canActOnSelection)
        XCTAssertTrue(availability.canMarkAllRead)
    }

    // The feed list is single-selection and the selected row is the open
    // item, so today both fields move together; either alone still counts.
    func testASelectedRowOrAnOpenItemEnablesTheToggles() {
        XCTAssertTrue(FeedMenuAvailability(selectedCount: 1, hasOpenItem: true, hasScope: true).canActOnSelection)
        XCTAssertTrue(FeedMenuAvailability(selectedCount: 1, hasOpenItem: false, hasScope: true).canActOnSelection)
        XCTAssertTrue(FeedMenuAvailability(selectedCount: 0, hasOpenItem: true, hasScope: true).canActOnSelection)
    }

    // MARK: - One section holds a chord at a time

    private static let mailStates: [MessageMenuAvailability] = [
        .none,
        MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true),
        MessageMenuAvailability(selectedCount: 3, hasOpenMessage: false),
        MessageMenuAvailability(selectedCount: 0, hasOpenMessage: true),
    ]

    private static let feedStates: [FeedMenuAvailability] = [
        .none,
        FeedMenuAvailability(selectedCount: 0, hasOpenItem: false, hasScope: true),
        FeedMenuAvailability(selectedCount: 1, hasOpenItem: true, hasScope: true),
        FeedMenuAvailability(selectedCount: 1, hasOpenItem: false, hasScope: true),
    ]

    private static let mailboxStates: [MailboxMenuAvailability] = {
        var withFolder = MailboxMenuAvailability.none
        withFolder.surfaceAppeared()
        withFolder.folderListAppeared("INBOX")
        var surfaceOnly = MailboxMenuAvailability.none
        surfaceOnly.surfaceAppeared()
        return [.none, surfaceOnly, withFolder]
    }()

    private static let sections: [ResumeSession.Section] = [.mail, .feeds]

    /// The compact tabs keep each section's selection while the other is in
    /// front, so both availabilities can be non-empty at once; the section
    /// is what breaks the tie, in every combination.
    func testTheItemChordsAreNeverLiveInBothMenus() {
        for section in Self.sections {
            for mail in Self.mailStates {
                for feeds in Self.feedStates {
                    let mailLive = SharedChordPolicy.mailItemsLive(mail, activeSection: section)
                    let feedsLive = SharedChordPolicy.feedItemsLive(feeds, activeSection: section)
                    XCTAssertFalse(mailLive && feedsLive, "\(section): both menus live for \(mail) / \(feeds)")
                }
            }
        }
    }

    func testTheMarkAllReadChordIsNeverLiveInBothMenus() {
        for section in Self.sections {
            for mailbox in Self.mailboxStates {
                for feeds in Self.feedStates {
                    let mailLive = SharedChordPolicy.mailMarkAllReadLive(mailbox, activeSection: section)
                    let feedsLive = SharedChordPolicy.feedMarkAllReadLive(feeds, activeSection: section)
                    XCTAssertFalse(mailLive && feedsLive, "\(section): both menus live for \(mailbox) / \(feeds)")
                }
            }
        }
    }

    /// The section in front keeps its own rule intact: gating never dims a
    /// command that has a target in the section the user is looking at.
    func testTheFrontSectionKeepsItsOwnAvailability() {
        for mail in Self.mailStates {
            XCTAssertEqual(SharedChordPolicy.mailItemsLive(mail, activeSection: .mail), mail.canActOnSelection)
        }
        for feeds in Self.feedStates {
            XCTAssertEqual(SharedChordPolicy.feedItemsLive(feeds, activeSection: .feeds), feeds.canActOnSelection)
            XCTAssertEqual(SharedChordPolicy.feedMarkAllReadLive(feeds, activeSection: .feeds), feeds.canMarkAllRead)
        }
        for mailbox in Self.mailboxStates {
            XCTAssertEqual(
                SharedChordPolicy.mailMarkAllReadLive(mailbox, activeSection: .mail), mailbox.canMarkAllRead
            )
        }
    }

    /// The section behind is dimmed whatever it has selected.
    func testTheOtherSectionIsAlwaysDimmed() {
        let mail = MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true)
        let feeds = FeedMenuAvailability(selectedCount: 1, hasOpenItem: true, hasScope: true)
        XCTAssertFalse(SharedChordPolicy.mailItemsLive(mail, activeSection: .feeds))
        XCTAssertFalse(SharedChordPolicy.feedItemsLive(feeds, activeSection: .mail))
        XCTAssertFalse(SharedChordPolicy.feedMarkAllReadLive(feeds, activeSection: .mail))
        var mailbox = MailboxMenuAvailability.none
        mailbox.surfaceAppeared()
        mailbox.folderListAppeared("INBOX")
        XCTAssertFalse(SharedChordPolicy.mailMarkAllReadLive(mailbox, activeSection: .feeds))
    }

    // MARK: - What the surfaces report

    func testAppStateStartsOnMailWithNoFeedTargets() {
        let appState = AppState()
        XCTAssertEqual(appState.activeSection, .mail)
        XCTAssertEqual(appState.feedMenuAvailability, .none)
    }
}
