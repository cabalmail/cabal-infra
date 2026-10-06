import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 (the CabalmailUI module split,
/// the AppState split, the mail store layer and the focused-window commands).
/// It pins how a folder refresh reconciles the list, the envelope snapshot
/// and the body cache with the server's STATUS and top page today
/// (`refresh()` -> `applyStatusCounts` -> `applyRefreshPage`), so a mail
/// store that takes this over shows any change in behaviour explicitly.
///
/// Protects #939 and e5ccbb0a (when a refresh may prune, and that a blank or
/// uncorroborated page and a flaky UIDVALIDITY wipe nothing), 37973866 (the
/// folder shrank below the loaded window), 64794213 (a trimmed window leaves
/// the top page alone), #1064 (the list's STATUS feeds the sidebar badge) and
/// both halves of the flag-write shield (the list's own toggles and the
/// reader's). A test whose name ends in `Weakness` pins a known shortcoming
/// on purpose so the refactor can flip it deliberately. The shared set-up
/// lives in `RefreshCharacterizationFixture.swift`.
@MainActor
final class MessageListReconcileCharacterizationTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!

    override func setUp() async throws {
        fixture = RefreshCharacterizationFixture()
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
    }

    // MARK: - The top page fits the window

    func testNewMailOnTopMergesIntoAListThatFitsTheTopPage() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 5, page: [5, 4, 3, 2, 1], unseen: 2, flagged: 1, uidNext: 6)

        await model.refresh()

        XCTAssertEqual(model.envelopes.map(\.uid), [5, 4, 3, 2, 1])
        XCTAssertEqual(model.totalMessages, 5)
        XCTAssertEqual(model.allCount, 5)
        XCTAssertEqual(model.unseen, 2)
        XCTAssertEqual(model.flagged, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        let path = fixture.folderPath
        let counts = fixture.appState.mailStore.counts
        XCTAssertEqual(counts.folderUnreadCounts[path], 2, "the sidebar badge takes the same reply")
        XCTAssertEqual(counts.folderTotalCounts[path], 5)
        let snapshot = await fixture.snapshot(model)
        XCTAssertEqual(snapshot?.uidValidity, 7)
        XCTAssertEqual(snapshot?.uidNext, 6)
        XCTAssertEqual(snapshot.map { Set($0.envelopes.keys) }, [5, 4, 3, 2, 1])
        let statuses = await fixture.statusCalls()
        let tops = await fixture.topPageCalls()
        let pages = await fixture.pageCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"])
        XCTAssertEqual(tops, ["Work limit=50 total=5 dateReceived/descending"])
        XCTAssertTrue(pages.isEmpty)
    }

    func testAMessageRemovedElsewhereIsPrunedFromTheListAndBothCaches() async throws {
        let model = try await fixture.makeModel()
        try await fixture.seedSnapshot(model, uids: [3, 2, 1])
        try await fixture.storeBody(model, uid: 3)
        try await fixture.storeBody(model, uid: 2)
        await fixture.scriptRefresh(messages: 2, page: [2, 1])

        await model.loadInitial()

        XCTAssertEqual(model.envelopes.map(\.uid), [2, 1])
        let cached = await fixture.snapshotUIDs(model)
        XCTAssertEqual(cached, [2, 1])
        let removedBody = await fixture.cachedBody(model, uid: 3)
        let keptBody = await fixture.cachedBody(model, uid: 2)
        XCTAssertNil(removedBody, "the departed message's body goes too")
        XCTAssertNotNil(keptBody, "and only that one")
    }

    /// The same prune when the folder is larger than the loaded top page: the
    /// page doesn't span the folder, but the window still fits one top page,
    /// so a row the page lacks is gone. (The test above prunes through the
    /// other licence, a page that spans the whole folder.)
    func testAMessageRemovedFromTheTopOfALargerFolderIsPruned() async throws {
        let loaded = fixture.newestFirst(100, through: 51)
        let page = fixture.newestFirst(100, through: 50).filter { $0 != 70 }
        let model = try await fixture.makeModel(loaded: loaded, total: 100)
        try await fixture.seedSnapshot(model, uids: loaded)
        try await fixture.storeBody(model, uid: 70)
        await fixture.scriptRefresh(messages: 99, page: page)

        await model.refresh()

        XCTAssertEqual(model.envelopes.map(\.uid), page)
        XCTAssertEqual(model.totalMessages, 99)
        let cached = await fixture.snapshotUIDs(model)
        XCTAssertEqual(cached, Set(page))
        let removedBody = await fixture.cachedBody(model, uid: 70)
        XCTAssertNil(removedBody)
    }

    /// e5ccbb0a: an empty page is never read as "everything vanished" unless
    /// STATUS says the folder is empty (#939 covers 0 and a missing count).
    func testABlankTopPageWithMessagesPrunesNothing() async throws {
        let model = try await fixture.makeModel()
        try await fixture.seedSnapshot(model, uids: [3, 2, 1])
        await fixture.scriptRefresh(messages: 3, page: [])

        await model.loadInitial()

        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1])
        let cached = await fixture.snapshotUIDs(model)
        XCTAssertEqual(cached, [3, 2, 1])
        XCTAssertEqual(model.totalMessages, 3)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Paginated past the top page

    /// Once the list has paged past the top page, a refresh still never
    /// prunes against the top page alone: that collapsed a scrolled list to
    /// the top, and a refactor must not bring it back. A message removed
    /// elsewhere is caught by the counts instead. STATUS is one short of what
    /// the window's anchor expects with no new UID to explain it, so the
    /// window is read again by position: the dead row leaves the list and the
    /// snapshot, and the next page starts where the server's rows do, so the
    /// row at the old page boundary (UID 40) is loaded rather than skipped.
    /// Fixed in #1817; this test pinned the skip until then.
    func testAPaginatedListDropsARowRemovedElsewhereAndTheNextPageSkipsNothing() async throws {
        let loaded = fixture.newestFirst(100, through: 41)
        let remaining = fixture.newestFirst(100, through: 1).filter { $0 != 70 }
        let model = try await fixture.makeModel(loaded: loaded, total: 100)
        // The STATUS these rows were paged in against, as paging leaves it.
        model.alignment.anchor = WindowAnchor(total: 100, uidNext: 101)
        try await fixture.seedSnapshot(model, uids: loaded)
        await fixture.scriptRefresh(messages: 99, page: Array(remaining.prefix(50)))
        await fixture.imap.scriptFolderContents(fixture.rows(remaining))

        await model.refresh()

        XCTAssertEqual(model.totalMessages, 99)
        XCTAssertEqual(model.envelopes.count, 60)
        XCTAssertFalse(model.envelopes.contains { $0.uid == 70 }, "UID 70 left the folder and the list")
        let cached = await fixture.snapshotUIDs(model)
        XCTAssertEqual(cached?.contains(70), false, "and the snapshot")

        model.ensureLoaded(around: 59)
        await fixture.awaitLoadMore(model)
        // Cancels the debounced snapshot write the page scheduled.
        await model.stopWatching()

        let pages = await fixture.pageCalls()
        let read = "Work offset=0 limit=60 dateReceived/descending"
        XCTAssertEqual(pages, [read, "Work offset=60 limit=200 dateReceived/descending"])
        let listed = Set(model.envelopes.map(\.uid))
        XCTAssertEqual(listed.count, 99)
        XCTAssertTrue(listed.contains(40), "the real message at the old page boundary is loaded")
        XCTAssertTrue(listed.contains(39))
    }

    /// 37973866: when STATUS reports no more messages than the top page just
    /// returned, that page is the whole folder, so a loaded row it lacks is
    /// provably gone, however far the list had paged.
    func testAFolderThatShrankBelowTheLoadedWindowPrunesTheStaleRows() async throws {
        let kept = fixture.newestFirst(60, through: 38)
        let model = try await fixture.makeModel()
        try await fixture.seedSnapshot(model, uids: fixture.newestFirst(60, through: 1))
        await fixture.scriptRefresh(messages: 23, page: kept)

        await model.loadInitial()

        XCTAssertEqual(model.envelopes.map(\.uid), kept)
        XCTAssertEqual(model.totalMessages, 23)
        let cached = await fixture.snapshotUIDs(model)
        XCTAssertEqual(cached, Set(kept), "the 37 stale rows leave the snapshot too")
    }

    /// The control: a page shorter than the STATUS total is not the whole
    /// folder, so a paginated list prunes nothing against it.
    func testAPaginatedFetchShorterThanTheStatusTotalPrunesNothing() async throws {
        let model = try await fixture.makeModel()
        try await fixture.seedSnapshot(model, uids: fixture.newestFirst(60, through: 1))
        await fixture.scriptRefresh(messages: 23, page: fixture.newestFirst(60, through: 41))

        await model.loadInitial()

        XCTAssertEqual(model.envelopes.count, 60)
        let cached = await fixture.snapshotUIDs(model)
        XCTAssertEqual(cached?.count, 60)
    }

    /// 64794213: once the window's front is trimmed the rows no longer start
    /// at the top, so a refresh takes the counts but not the top page.
    func testATrimmedWindowRefreshesItsCountsButNotItsRows() async throws {
        let model = try await fixture.makeModel(loaded: [300, 299, 298], total: 500)
        fixture.trimFront(model, to: 200)
        model.errorMessage = "stale"
        await fixture.scriptRefresh(messages: 510, page: fixture.newestFirst(510, through: 461), unseen: 4, flagged: 2)

        await model.refresh()

        XCTAssertEqual(model.envelopes.map(\.uid), [300, 299, 298])
        XCTAssertEqual(model.envelope(at: 200)?.uid, 300, "the rows stay where the list draws them")
        XCTAssertNil(model.envelope(at: 0), "and the top of the folder stays unloaded")
        XCTAssertEqual(fixture.windowStart(model), 200)
        XCTAssertEqual(model.totalMessages, 510)
        XCTAssertEqual(model.unseen, 4)
        XCTAssertEqual(model.flagged, 2)
        XCTAssertNil(model.errorMessage)
        let statuses = await fixture.statusCalls()
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(statuses.count, 1)
        XCTAssertTrue(tops.isEmpty, "no top page for a trimmed window")
    }

    // MARK: - UIDVALIDITY

    func testAChangedUidValidityRebuildsTheListAndBothCaches() async throws {
        let model = try await fixture.makeModel()
        try await fixture.seedSnapshot(model, uids: [3, 2, 1], uidValidity: 7)
        try await fixture.storeBody(model, uid: 3, uidValidity: 7)
        fixture.appState.recordConfirmedRemovals([fixture.ref(10)])
        await fixture.scriptRefresh(messages: 2, page: [11, 10], uidValidity: 9)
        await fixture.imap.holdNext(.status)

        let load = Task { await model.loadInitial() }
        await fixture.imap.awaitHeld(.status)
        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1], "the cached rows paint before the server answers")
        await fixture.imap.holdNext(.topEnvelopes)
        await fixture.imap.releaseHeld(.status)
        await fixture.imap.awaitHeld(.topEnvelopes)

        // The wipe runs as soon as STATUS answers, before the new top page.
        XCTAssertTrue(model.envelopes.isEmpty)
        let wipedSnapshot = await fixture.snapshot(model)
        XCTAssertNil(wipedSnapshot, "the old UID space's snapshot is dropped, not merged over later")
        let oldBody = await fixture.cachedBody(model, uid: 3, uidValidity: 7)
        XCTAssertNil(oldBody)
        await fixture.imap.releaseHeld(.topEnvelopes)
        await load.value

        XCTAssertEqual(
            model.envelopes.map(\.uid), [11, 10],
            "UID 10 shows: the old UID space's confirmed removals were cleared"
        )
        XCTAssertTrue(fixture.appState.confirmedRemovalRefs(folderPath: fixture.folderPath).isEmpty)
        let snapshot = await fixture.snapshot(model)
        XCTAssertEqual(snapshot?.uidValidity, 9)
        XCTAssertEqual(snapshot.map { Set($0.envelopes.keys) }, [11, 10])
    }

    /// e5ccbb0a: a zero UIDVALIDITY from a flaky STATUS is not a change.
    func testAZeroUidValidityWipesNothing() async throws {
        try await assertCachedListSurvives(statusUidValidity: 0)
    }

    func testAMissingUidValidityWipesNothing() async throws {
        try await assertCachedListSurvives(statusUidValidity: nil)
    }

    /// A list that never learned a UIDVALIDITY (no snapshot) takes the first
    /// one as learned, not changed; a different one after that is a change,
    /// and rebuilds even a trimmed window from the top.
    func testTheFirstUidValidityIsLearnedAndALaterChangeRebuilds() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        try await fixture.storeBody(model, uid: 3, uidValidity: 9)
        fixture.appState.recordConfirmedRemovals([fixture.ref(10)])
        await fixture.scriptRefresh(messages: 3, page: [], uidValidity: 9)

        await model.refresh()

        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1], "nothing was known, so nothing is wiped")
        let keptBody = await fixture.cachedBody(model, uid: 3, uidValidity: 9)
        XCTAssertNotNil(keptBody)
        XCTAssertEqual(fixture.appState.confirmedRemovalRefs(folderPath: fixture.folderPath), [fixture.ref(10)])

        fixture.trimFront(model, to: 200)
        await fixture.scriptRefresh(messages: 2, page: [21, 20], uidValidity: 11)
        await model.refresh()

        XCTAssertEqual(model.envelopes.map(\.uid), [21, 20])
        XCTAssertEqual(model.envelope(at: 0)?.uid, 21, "the rebuilt window starts at the top again")
        XCTAssertEqual(fixture.windowStart(model), 0)
        let wipedBody = await fixture.cachedBody(model, uid: 3, uidValidity: 9)
        XCTAssertNil(wipedBody)
        XCTAssertTrue(fixture.appState.confirmedRemovalRefs(folderPath: fixture.folderPath).isEmpty)
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(tops.count, 2, "the rebuilt window is top-anchored again, so its top page is fetched")
    }

    /// Opens a list over a cached folder (UIDVALIDITY 7) whose STATUS reports
    /// `reading` and a blank top page: had it wiped, the rows would be gone.
    private func assertCachedListSurvives(
        statusUidValidity reading: UInt32?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try await fixture.makeModel()
        try await fixture.seedSnapshot(model, uids: [3, 2, 1], uidValidity: 7)
        try await fixture.storeBody(model, uid: 3, uidValidity: 7)
        fixture.appState.recordConfirmedRemovals([fixture.ref(10)])
        await fixture.scriptRefresh(messages: 3, page: [], uidValidity: reading)

        await model.loadInitial()

        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1], file: file, line: line)
        let snapshot = await fixture.snapshot(model)
        XCTAssertEqual(snapshot?.uidValidity, 7, file: file, line: line)
        let body = await fixture.cachedBody(model, uid: 3, uidValidity: 7)
        XCTAssertNotNil(body, file: file, line: line)
        let removals = fixture.appState.confirmedRemovalRefs(folderPath: fixture.folderPath)
        XCTAssertEqual(removals, [fixture.ref(10)], file: file, line: line)
    }

    // MARK: - The flag-write shield

    /// The list's own half (`pendingFlagRefs`, set by the swipe, menu and
    /// bulk read/flag toggles): a refresh landing while the list's write is
    /// in flight keeps the optimistic flags, in memory and on disk.
    func testAListFlagWriteInFlightKeepsItsLocalFlagsThroughARefresh() async throws {
        let model = try await fixture.makeModel(loaded: [1], total: 1)
        let row = try XCTUnwrap(model.envelopes.first)
        await fixture.imap.holdNext(.setFlags)
        let write = Task { await model.markRead(row) }
        await fixture.imap.awaitHeld(.setFlags)
        XCTAssertEqual(model.envelopes.first?.flags, [.seen], "the optimistic flag is up")
        // The server still answers with the message as it was before the write.
        await fixture.scriptRefresh(messages: 1, page: [1], unseen: 1)

        await model.refresh()

        XCTAssertEqual(model.envelopes.first?.flags, [.seen])
        let cached = await fixture.snapshot(model)?.envelopes[1]
        XCTAssertEqual(cached?.flags, [.seen], "the snapshot keeps the local flags too")
        await fixture.imap.releaseHeld(.setFlags)
        await write.value
        let writes = await fixture.imap.flagCalls
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(model.envelopes.first?.flags, [.seen])
    }

    /// The reader's half (`AppState.pendingFlagWriteRefs`, set while the
    /// message view writes \Seen or \Flagged): the list keeps its local
    /// flags through a refresh in the same way.
    func testAReaderFlagWriteInFlightKeepsTheListsLocalFlagsThroughARefresh() async throws {
        let model = try await fixture.makeModel(loaded: [1], flags: [.seen], total: 1)
        fixture.appState.setFlagWrite(fixture.ref(1), inFlight: true)
        // The server still answers with the message as it was before the write.
        await fixture.scriptRefresh(messages: 1, page: [1], unseen: 1)

        await model.refresh()

        XCTAssertEqual(model.envelopes.first?.flags, [.seen])
        let cached = await fixture.snapshot(model)?.envelopes[1]
        XCTAssertEqual(cached?.flags, [.seen], "the snapshot keeps the local flags too")
    }

    func testWithNoFlagWriteInFlightTheServerFlagsWin() async throws {
        let model = try await fixture.makeModel(loaded: [1], flags: [.seen], total: 1)
        await fixture.scriptRefresh(messages: 1, page: [1], unseen: 1)

        await model.refresh()

        XCTAssertEqual(model.envelopes.first?.flags, [])
        let cached = await fixture.snapshot(model)?.envelopes[1]
        XCTAssertEqual(cached?.flags, [])
    }
}
