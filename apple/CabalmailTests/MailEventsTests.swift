import XCTest
import CabalmailKit
@testable import CabalmailUI

// The mail store's events (`MailEvents`), which replaced the `last…` signal
// payloads the list observed with `.onChange`: every change reaches every
// subscriber, in order, before `post` returns, and nothing is coalesced, so
// two changes in one update both arrive.
@MainActor
final class MailEventsTests: XCTestCase {
    private let inbox = MessageRef(folder: "INBOX", uid: 4)
    private let archive = MessageRef(folder: "Archive", uid: 9)
    private let window = UUID()

    func testEveryEventReachesEverySubscriberInOrderBeforePostReturns() {
        let store = AppState().mailStore
        let first = MailEventRecorder(store)
        let second = MailEventRecorder(store)

        store.events.post(.removed([inbox]), from: window)
        XCTAssertEqual(first.changes, [.removed([inbox])], "delivered before post returns")
        store.events.post(.flagsChanged([archive], flag: .seen, added: true), from: nil)

        let expected = [
            MailEvent(change: .removed([inbox]), origin: window),
            MailEvent(change: .flagsChanged([archive], flag: .seen, added: true), origin: nil),
        ]
        XCTAssertEqual(first.events, expected)
        XCTAssertEqual(second.events, expected)
    }

    /// The signals kept only their latest value: a second post in the same
    /// update replaced the first before `.onChange` read it.
    func testTwoEventsInOneTurnBothArrive() {
        let store = AppState().mailStore
        let recorder = MailEventRecorder(store)

        store.events.post(.removed([inbox]), from: nil)
        store.events.post(.removed([archive]), from: nil)

        XCTAssertEqual(recorder.changes, [.removed([inbox]), .removed([archive])])
    }

    /// An event posted from inside `receive` reaches everyone after the one
    /// being delivered, so no subscriber hears the two in another order.
    func testAnEventPostedWhileDeliveringArrivesAfterTheCurrentOne() {
        let store = AppState().mailStore
        let poster = ReentrantPoster(store: store, follow: .restored(inbox, markUnread: false))
        let recorder = MailEventRecorder(store)

        store.events.post(.removed([inbox]), from: nil)

        let expected: [MailEvent.Change] = [.removed([inbox]), .restored(inbox, markUnread: false)]
        XCTAssertEqual(poster.heard, expected)
        XCTAssertEqual(recorder.changes, expected)
    }

    func testASubscriberThatGoesAwayHearsNothingMore() {
        let store = AppState().mailStore
        let survivor = MailEventRecorder(store)
        var gone: MailEventRecorder? = MailEventRecorder(store)
        weak var weakGone = gone

        gone = nil
        store.events.post(.removed([inbox]), from: nil)

        XCTAssertNil(weakGone, "the store holds its subscribers weakly")
        XCTAssertEqual(survivor.changes, [.removed([inbox])])
    }

    func testSubscribingTwiceDeliversOnce() {
        let store = AppState().mailStore
        let recorder = MailEventRecorder(store)
        store.events.subscribe(recorder)

        store.events.post(.removed([inbox]), from: nil)

        XCTAssertEqual(recorder.changes.count, 1)
    }

    /// The signals dropped these too: no message named, or a compose session
    /// that never reached the server.
    func testAnEmptyChangeIsNotPosted() {
        let store = AppState().mailStore
        let recorder = MailEventRecorder(store)

        store.events.post(.removed([]), from: nil)
        store.events.post(.flagsChanged([], flag: .seen, added: true), from: nil)
        store.events.post(
            .draftReplaced(folderPath: "Drafts", replacement: DraftReplacement(retiredUIDs: [], survivingUID: nil)),
            from: nil
        )

        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - What the store posts with a count

    func testAFlagChangePostsAndMovesTheUnreadCountForSeenOnly() {
        let store = AppState().mailStore
        store.counts.setFolderCounts(folderPath: "INBOX", unread: 3, total: 10)
        let recorder = MailEventRecorder(store)

        store.postFlagChange(inbox, flag: .seen, added: true, from: window)
        XCTAssertEqual(store.counts.folderUnreadCounts["INBOX"], 2)
        store.postFlagChange(inbox, flag: .flagged, added: true, from: window)
        XCTAssertEqual(store.counts.folderUnreadCounts["INBOX"], 2, "a flag other than \\Seen moves no count")
        store.postFlagChange(inbox, flag: .seen, added: false, from: nil)

        XCTAssertEqual(store.counts.folderUnreadCounts["INBOX"], 3)
        XCTAssertEqual(recorder.events, [
            MailEvent(change: .flagsChanged([inbox], flag: .seen, added: true), origin: window),
            MailEvent(change: .flagsChanged([inbox], flag: .flagged, added: true), origin: window),
            MailEvent(change: .flagsChanged([inbox], flag: .seen, added: false), origin: nil),
        ])
    }

    func testAFailedRemovalPostsTheRestoreAndHandsBackTheUnreadItTook() {
        let store = AppState().mailStore
        store.counts.setFolderCounts(folderPath: "Archive", unread: 1, total: 10)
        let recorder = MailEventRecorder(store)

        store.postRemovalFailed(archive, markUnread: true, from: window)
        store.postRemovalFailed(archive, from: window)

        XCTAssertEqual(store.counts.folderUnreadCounts["Archive"], 2, "only the one that had marked it read")
        XCTAssertEqual(recorder.events, [
            MailEvent(change: .restored(archive, markUnread: true), origin: window),
            MailEvent(change: .restored(archive, markUnread: false), origin: window),
        ])
    }

    /// The composer's `\Answered` names no window: compose is not a main
    /// window's reader or list.
    func testMarkAnsweredPostsTheFlagWithNoWindow() async throws {
        let imap = FakeImapClient()
        let store = AppState().mailStore
        let recorder = MailEventRecorder(store)

        store.markAnswered(archive, client: try TestFixtures.makeClient(imap: imap))

        XCTAssertEqual(recorder.events, [
            MailEvent(change: .flagsChanged([archive], flag: .answered, added: true), origin: nil),
        ])
        try await waitUntil { await !imap.flagCalls.isEmpty }
    }
}

/// Posts `follow` from inside its first `receive`, to check that an event
/// posted while another is being delivered waits its turn.
@MainActor
private final class ReentrantPoster: MailEventSubscriber {
    private let store: MailSessionStore
    private var follow: MailEvent.Change?
    private(set) var heard: [MailEvent.Change] = []

    init(store: MailSessionStore, follow: MailEvent.Change) {
        self.store = store
        self.follow = follow
        store.events.subscribe(self)
    }

    func receive(_ event: MailEvent) {
        heard.append(event.change)
        if let follow {
            self.follow = nil
            store.events.post(follow, from: nil)
            XCTAssertEqual(heard.count, 1, "the follow-up waits for the current event to reach everyone")
        }
    }
}
