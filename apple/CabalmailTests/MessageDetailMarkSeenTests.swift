import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8: mark-as-read when the reader
/// opens a message.
///
/// With `Preferences.markAsRead == .onOpen`, a successful `load()` spawns an
/// unstructured `setSeen(true)`: the reader flips `isSeen`, and its write
/// through the store's mutation service posts the change for the lists
/// before the STORE and holds the STORE in the record of writes in flight
/// (the lists' pending-flag shield); both are reverted on failure, with the
/// error in `errorMessage`. The server never marks a message read on
/// fetch (`fetch_message` sends `seen=false`), so this is the only path that
/// does. The `.setFlags` hold gate stages the STORE so each step is asserted
/// in order rather than by timing.
///
/// The negative tests (no STORE for `.manual`, an already-seen message, a
/// failed open) prove absence with `MessageDetailLoadFixture.drainMainActor`,
/// which assumes mark-seen is spawned onto the main actor, as it is today.
/// If the refactor moves it to a store actor or a detached task, revisit
/// them (see that helper's doc).
///
/// The reader's raw-source path and `MessageRawSource.bytes` live in
/// `MessageRawSourceTests`.
@MainActor
final class MessageDetailMarkSeenTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!
    private let uid: UInt32 = 7

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// An unread (unless `flags` says otherwise) INBOX/7 reader whose open
    /// succeeds from the network, with its relays recorded.
    private func makeReader(
        imap: FakeImapClient,
        markAsRead: MarkAsReadBehavior,
        flags: Set<Flag> = []
    ) async throws -> (MessageDetailViewModel, RelayRecorder) {
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let model = try await fixture.makeReader(imap: imap, uid: uid, flags: flags, markAsRead: markAsRead)
        try await fixture.seedSnapshot(model)
        let recorder = RelayRecorder(AppState().mailStore)
        recorder.attach(to: model)
        return (model, recorder)
    }

    /// Opens `model` and waits for its mark-seen STORE to park at the
    /// `.setFlags` hold. Throws or returns false, failing the test, when the
    /// open or the STORE didn't happen, so neither can leave the test hanging.
    private func openAndAwaitHeldStore(_ model: MessageDetailViewModel, imap: FakeImapClient) async throws -> Bool {
        await model.load()
        _ = try XCTUnwrap(model.plainText, "the open must succeed for a mark-seen to follow")
        return try await MessageDetailLoadFixture.awaitHeld(.setFlags, in: imap)
    }

    // MARK: - Mark as read on open

    func testOnOpenMarksTheMessageSeenOptimisticallyAndBracketsTheWrite() async throws {
        let imap = FakeImapClient()
        await imap.holdNext(.setFlags)
        let (model, recorder) = try await makeReader(imap: imap, markAsRead: .onOpen)

        guard try await openAndAwaitHeldStore(model, imap: imap) else { return }

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.folder, "INBOX")
        XCTAssertEqual(calls.first?.uids, [uid])
        XCTAssertEqual(calls.first?.flags, [.seen])
        XCTAssertEqual(calls.first?.operation, .add)
        XCTAssertTrue(model.isSeen, "flipped before the server answers")
        XCTAssertEqual(recorder.flagChanges, [RelayRecorder.FlagChange(flag: .seen, added: true)])
        XCTAssertEqual(recorder.writes, [true], "the write is in flight")

        await imap.releaseHeld(.setFlags)
        try await waitUntilOnMainActor { recorder.writes == [true, false] }
        // The reader resumes from its write in a job of its own.
        await MessageDetailLoadFixture.drainMainActor()

        XCTAssertTrue(model.isSeen)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(recorder.flagChanges.count, 1)
    }

    /// The revert writes the error's user copy (`localizedDescription`), as
    /// `load()` does. Before #1814 it wrote `"\(error)"`, the raw enum dump
    /// #940 replaced elsewhere. The body view hides `errorMessage` once a body
    /// has loaded, so today the user sees only the icon revert.
    func testAFailedMarkSeenRevertsAndSetsTheErrorText() async throws {
        let imap = FakeImapClient()
        let failure = CabalmailError.network("offline")
        await imap.scriptFlagResults([.failure(failure)])
        await imap.holdNext(.setFlags)
        let (model, recorder) = try await makeReader(imap: imap, markAsRead: .onOpen)

        guard try await openAndAwaitHeldStore(model, imap: imap) else { return }
        XCTAssertTrue(model.isSeen)
        await imap.releaseHeld(.setFlags)
        try await waitUntilOnMainActor { !model.isSeen }
        XCTAssertEqual(recorder.writes, [true, false], "the write left the record when it answered")

        XCTAssertFalse(model.isSeen)
        XCTAssertEqual(recorder.flagChanges, [
            RelayRecorder.FlagChange(flag: .seen, added: true),
            RelayRecorder.FlagChange(flag: .seen, added: false),
        ])
        XCTAssertEqual(model.errorMessage, failure.localizedDescription)
        XCTAssertEqual(model.errorMessage, "Couldn't reach the server. offline.")
        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain, "the body stays")
    }

    func testTheManualPreferenceSendsNoMarkSeen() async throws {
        let imap = FakeImapClient()
        let (model, recorder) = try await makeReader(imap: imap, markAsRead: .manual)

        await model.load()
        await MessageDetailLoadFixture.drainMainActor()

        XCTAssertNotNil(model.plainText)
        XCTAssertFalse(model.isSeen)
        XCTAssertTrue(recorder.flagChanges.isEmpty)
        let calls = await imap.flagCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAnAlreadySeenMessageSendsNoMarkSeen() async throws {
        let imap = FakeImapClient()
        let (model, recorder) = try await makeReader(imap: imap, markAsRead: .onOpen, flags: [.seen])

        await model.load()
        await MessageDetailLoadFixture.drainMainActor()

        XCTAssertNotNil(model.plainText)
        XCTAssertTrue(model.isSeen)
        XCTAssertTrue(recorder.flagChanges.isEmpty)
        let calls = await imap.flagCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAFailedOpenSendsNoMarkSeen() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.failure(CabalmailError.network("offline"))])
        let model = try await fixture.makeReader(imap: imap, uid: uid, markAsRead: .onOpen)
        try await fixture.seedSnapshot(model)
        let recorder = RelayRecorder(AppState().mailStore)
        recorder.attach(to: model)

        await model.load()
        await MessageDetailLoadFixture.drainMainActor()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isSeen)
        XCTAssertTrue(recorder.flagChanges.isEmpty)
        let calls = await imap.flagCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAnOpenFromTheBodyCacheStillMarksSeen() async throws {
        let imap = FakeImapClient()
        await imap.holdNext(.setFlags)
        let model = try await fixture.makeReader(imap: imap, uid: uid, markAsRead: .onOpen)
        try await fixture.seedSnapshot(model)
        try await fixture.cacheBody(MessageDetailMimeFixture.alternative, for: model)
        let recorder = RelayRecorder(AppState().mailStore)
        recorder.attach(to: model)

        guard try await openAndAwaitHeldStore(model, imap: imap) else { return }

        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.flags), [[.seen]])
        XCTAssertTrue(model.isSeen)
        await imap.releaseHeld(.setFlags)
        // Let the unstructured mark-seen task finish inside this test.
        try await waitUntilOnMainActor { recorder.writes == [true, false] }
        // The reader resumes from its write in a job of its own.
        await MessageDetailLoadFixture.drainMainActor()
        XCTAssertTrue(model.isSeen)
    }

    /// Nothing on the open path writes the envelope cache: the snapshot row
    /// stays unread after the server has marked it read. This is not
    /// specific to the reader: no flag write, from the reader or the list,
    /// updates the snapshot; it catches up at the list's next persist
    /// (which writes the list's in-memory rows, optimistic flags included)
    /// or refresh. A store layer that writes flags through to the snapshot
    /// would change this for both paths together.
    func testOpeningAndMarkingSeenLeavesTheEnvelopeSnapshotUntouched() async throws {
        let imap = FakeImapClient()
        let (model, recorder) = try await makeReader(imap: imap, markAsRead: .onOpen)
        let before = await model.client.envelopeCache.snapshot(for: "INBOX")

        await model.load()
        _ = try XCTUnwrap(model.plainText, "the open must succeed for a mark-seen to follow")
        try await waitUntilOnMainActor { recorder.writes == [true, false] }
        // The reader resumes from its write in a job of its own.
        await MessageDetailLoadFixture.drainMainActor()

        XCTAssertTrue(model.isSeen)
        let after = await model.client.envelopeCache.snapshot(for: "INBOX")
        XCTAssertEqual(after?.envelopes, before?.envelopes)
        XCTAssertEqual(after?.envelopes[uid]?.flags, [])
        XCTAssertEqual(after?.uidValidity, fixture.uidValidity)
        XCTAssertEqual(after?.uidNext, before?.uidNext)
    }

    // MARK: - The list, wired the way the views wire it

    /// A list holding 9, 8, 7 (7 unread) and a reader open on 7, both over
    /// one store, the reader connected to it as `MessageDetailView` connects
    /// it.
    private func makeWiredPair(imap: FakeImapClient) async throws -> WiredPair {
        let envelopes = [9, 8, 7].map { TestFixtures.makeEnvelope(uid: $0, flags: $0 == 7 ? [] : [.seen]) }
        let store = AppState().mailStore
        let list = try TestFixtures.makeModel(imap: imap, envelopes: envelopes, mailStore: store)
        await fixture.track(list.client)
        list.window.totalMessages = 3
        list.unseen = 1
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let reader = try await fixture.makeReader(imap: imap, envelope: envelopes[2], markAsRead: .onOpen)
        try await fixture.seedSnapshot(reader, envelopes: envelopes)
        let recorder = RelayRecorder(store)
        recorder.attach(to: reader)
        return WiredPair(list: list, reader: reader, recorder: recorder)
    }

    func testMarkSeenOnOpenFlipsTheListRowAndItsUnreadCount() async throws {
        let imap = FakeImapClient()
        await imap.holdNext(.setFlags)
        let pair = try await makeWiredPair(imap: imap)

        guard try await openAndAwaitHeldStore(pair.reader, imap: imap) else { return }
        XCTAssertEqual(pair.recorder.writes, [true], "the write is in flight")

        XCTAssertTrue(pair.list.envelopes[2].flags.contains(.seen), "the row reads as read before the STORE lands")
        XCTAssertEqual(pair.list.unseen, 0)
        await imap.releaseHeld(.setFlags)
        try await waitUntilOnMainActor { pair.recorder.writes == [true, false] }
        // The reader resumes from its write in a job of its own.
        await MessageDetailLoadFixture.drainMainActor()
        XCTAssertTrue(pair.list.envelopes[2].flags.contains(.seen))
        XCTAssertEqual(pair.list.unseen, 0)
        XCTAssertEqual(pair.list.envelopes.map(\.uid), [9, 8, 7])
    }

    func testAFailedMarkSeenPutsTheListRowBackToUnread() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(CabalmailError.network("offline"))])
        await imap.holdNext(.setFlags)
        let pair = try await makeWiredPair(imap: imap)

        guard try await openAndAwaitHeldStore(pair.reader, imap: imap) else { return }
        XCTAssertEqual(pair.list.unseen, 0)
        await imap.releaseHeld(.setFlags)
        try await waitUntilOnMainActor { !pair.reader.isSeen }
        XCTAssertEqual(pair.recorder.writes, [true, false], "the write left the record when it answered")

        XCTAssertFalse(pair.list.envelopes[2].flags.contains(.seen))
        XCTAssertEqual(pair.list.unseen, 1)
        XCTAssertFalse(pair.reader.isSeen)
    }
}

/// What a reader's writes reported through the store it is connected to,
/// in order: the flag changes posted for the lists, and the write's place in
/// the record of writes in flight (`true` once it is out, then `false` once
/// it has answered).
@MainActor
private final class RelayRecorder: MailEventSubscriber {
    struct FlagChange: Equatable {
        let flag: Flag
        let added: Bool
    }

    let store: MailSessionStore
    private var ref: MessageRef?
    private(set) var flagChanges: [FlagChange] = []
    private var begun = false

    init(_ store: MailSessionStore) {
        self.store = store
        store.events.subscribe(self)
    }

    /// Connects `model` to the store, as `MessageDetailView` does.
    func attach(to model: MessageDetailViewModel) {
        ref = model.ref
        MessageDetailView.relayOutcomes(of: model, to: store)
    }

    var writes: [Bool] {
        guard begun, let ref else { return [] }
        return store.shields.isWritingFlags(ref) ? [true] : [true, false]
    }

    func receive(_ event: MailEvent) {
        guard case .flagsChanged(let refs, let flag, let added) = event.change,
              let ref, refs.contains(ref) else { return }
        // The service records the write just before it posts the change, so
        // a change posted with no write in the record isn't one.
        if store.shields.isWritingFlags(ref) { begun = true }
        flagChanges.append(FlagChange(flag: flag, added: added))
    }
}

/// A list and a reader open on one of its rows.
@MainActor
private struct WiredPair {
    let list: MessageListViewModel
    let reader: MessageDetailViewModel
    let recorder: RelayRecorder
}
