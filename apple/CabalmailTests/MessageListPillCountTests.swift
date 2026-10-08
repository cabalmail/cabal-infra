import XCTest
import CabalmailKit
@testable import CabalmailUI

// Regression tests for #737: the All/Unread/Flagged filter-pill counts read
// `unseen` / `flagged`, which only STATUS used to write — so a flag or read
// change (row swipe, detail-view toolbar, mark-as-read on open) updated the
// row's own indicators but left the pill counts stale until the next server
// refetch. The pills are now the mail store's counts for the folder, which
// the mutation service moves once for every write that actually flips a flag
// or removes an unread message (list toggle, reader, bulk, and their error
// reverts), the same numbers the sidebar shows. The reader's writes go
// through the service here as the reader sends them.
@MainActor
final class MessageListPillCountTests: XCTestCase {

    private func makeModel(imap: FakeImapClient = FakeImapClient()) throws -> MessageListViewModel {
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [
                TestFixtures.makeEnvelope(uid: 1),                  // unread
                TestFixtures.makeEnvelope(uid: 2, flags: [.seen]),  // read
            ]
        )
        // Server-sourced STATUS counts as of the last refresh.
        model.totalMessages = 2
        model.unseen = 1
        model.flagged = 0
        return model
    }

    /// The identity of INBOX's `uid`, the folder every model here shows.
    private func ref(_ uid: UInt32) -> MessageRef {
        MessageRef(folder: "INBOX", uid: uid)
    }

    /// A reader in no particular window writing through `model`'s store, as
    /// a reader on one of its messages does.
    private func reader(for model: MessageListViewModel) -> MailWriter {
        .reader(ReaderStandIn(), in: nil, through: model.client)
    }

    func testDetailOriginatedFlagToggleUpdatesFlaggedPill() async throws {
        let model = try makeModel()
        let mutations = model.mailStore.mutations
        // The reader's flag toggle goes through the mutation service.
        await mutations.setFlag(.flagged, added: true, on: [ref(2)], changing: [ref(2)], by: reader(for: model)).value
        XCTAssertEqual(model.flagged, 1, "flagging from the reader bumps the Flagged pill")
        // A duplicate for an already-flagged message flips nothing, and must not double-count.
        await mutations.setFlag(.flagged, added: true, on: [ref(2)], changing: [], by: reader(for: model)).value
        XCTAssertEqual(model.flagged, 1)
        await mutations.setFlag(.flagged, added: false, on: [ref(2)], changing: [ref(2)], by: reader(for: model)).value
        XCTAssertEqual(model.flagged, 0)
    }

    func testDetailOriginatedMarkAsReadUpdatesUnreadPill() async throws {
        let model = try makeModel()
        let mutations = model.mailStore.mutations
        // Mark-as-read on open goes the same way.
        await mutations.setFlag(.seen, added: true, on: [ref(1)], changing: [ref(1)], by: reader(for: model)).value
        XCTAssertEqual(model.unseen, 0, "reading from the reader drops the Unread pill")
        await mutations.setFlag(.seen, added: false, on: [ref(1)], changing: [ref(1)], by: reader(for: model)).value
        XCTAssertEqual(model.unseen, 1)
    }

    func testListToggleUpdatesAndFailureReverts() async throws {
        let imap = FakeImapClient()
        let model = try makeModel(imap: imap)
        // Successful swipe/context-menu toggle adjusts the pill...
        await model.setFlag(.seen, add: true, envelope: model.envelopes[0])
        XCTAssertEqual(model.unseen, 0)
        // ...and a failed write reverts the count along with the row.
        await imap.scriptFlagResults([.failure(CabalmailError.protocolError("boom"))])
        await model.setFlag(.flagged, add: true, envelope: model.envelopes[1])
        XCTAssertEqual(model.flagged, 0, "failed flag write reverts the Flagged pill")
    }

    func testUnrelatedFlagLeavesPillsAlone() async throws {
        let model = try makeModel()
        model.flagged = 1
        await model.mailStore.mutations.setFlag(
            .answered, added: true, on: [ref(1)], changing: [ref(1)], by: reader(for: model)
        ).value
        XCTAssertEqual(model.unseen, 1)
        XCTAssertEqual(model.flagged, 1)
    }

    func testKeywordToggleLeavesPillsAloneAndTagsTheRow() async throws {
        // Custom-flag slots (Phase 4) ride the same optimistic path but are
        // not what the Unread/Flagged pills count.
        let model = try makeModel()
        model.flagged = 1
        await model.toggleKeyword(model.envelopes[0], slot: "cabal-flag-01")
        XCTAssertEqual(model.unseen, 1)
        XCTAssertEqual(model.flagged, 1)
        XCTAssertTrue(model.envelopes[0].flags.contains(.keyword("cabal-flag-01")))
    }

    func testOptimisticRebuildPreservesThreadingAndAuthResults() throws {
        // Regression: `rebuildEnvelope` dropped `references` and
        // `authResults`, so every optimistic flag toggle silently stripped
        // the threading chain and the auth verdict from the row. Phase 4
        // makes the rebuild hotter (keyword toggles), so pin it.
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [
                Envelope(
                    uid: 9,
                    subject: "keep my fields",
                    references: ["<a@example.com>", "<b@example.com>"],
                    flags: [],
                    authResults: AuthResults(spf: "pass", dkim: "pass", dmarc: "pass")
                ),
            ]
        )
        model.applyFlagChange(ref(9), flag: .keyword("cabal-flag-02"), added: true)
        XCTAssertEqual(model.envelopes[0].references,
                       ["<a@example.com>", "<b@example.com>"])
        XCTAssertNotNil(model.envelopes[0].authResults)
    }

    // MARK: - #850: a row disposed from the reader

    func testDisposedUnreadRowDropsTheUnreadPill() async throws {
        let model = try makeModel()
        // The reader archives an unread message: the `\Seen` marking rides
        // along with the move server-side, and the removal is all the list
        // hears before the row is gone.
        await model.mailStore.mutations.remove(
            [ref(1)], .move(to: "Archive", markingSeen: true), unread: [ref(1)], by: reader(for: model)
        ).value
        XCTAssertEqual(
            model.unseen, 0,
            "a message archived from the reader left the folder unread — the pill must follow"
        )
    }

    func testDisposedReadRowLeavesTheUnreadPill() async throws {
        let model = try makeModel()
        // The reader shows message 2 read, so its removal names no unread.
        await model.mailStore.mutations.remove(
            [ref(2)], .move(to: "Archive", markingSeen: false), unread: [], by: reader(for: model)
        ).value
        XCTAssertEqual(model.unseen, 1, "the read row was never in the Unread count")
        XCTAssertEqual(model.envelopes.map(\.uid), [1], "and it left")
    }

    func testFlagSignalAndPruneCountTheDisposedRowOnce() async throws {
        let model = try makeModel()
        // The reader marks the message read, then archives it: by the
        // archive it is read, so only the mark-read moved the count.
        let mutations = model.mailStore.mutations
        await mutations.setFlag(.seen, added: true, on: [ref(1)], changing: [ref(1)], by: reader(for: model)).value
        await mutations.remove(
            [ref(1)], .move(to: "Archive", markingSeen: false), unread: [], by: reader(for: model)
        ).value
        XCTAssertEqual(model.unseen, 0, "the departed message must be subtracted exactly once")
    }

    func testPruneOfAnUnloadedUIDLeavesTheUnreadPill() throws {
        let model = try makeModel()
        // A removal posted with no write behind it (a compose session's send
        // from Drafts) moves no count; only a write the service makes does.
        model.mailStore.events.post(.removed([ref(99)]), from: nil)
        XCTAssertEqual(
            model.unseen, 1,
            "a signal for a UID we never had loaded says nothing about the unread count"
        )
    }
}

/// Stands in for the reader making a write: the events' sender, which isn't
/// sent them.
private final class ReaderStandIn {}
