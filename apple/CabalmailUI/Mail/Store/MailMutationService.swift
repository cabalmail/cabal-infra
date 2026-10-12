import Foundation
import CabalmailKit

/// Who is making a write through `MailMutationService`, through which
/// session's client, and how its events name it (`MailEvent.origin`,
/// `.sender`, `.advances`).
struct MailWriter {
    /// The client the write goes out through: the writer's own, so a write
    /// a session started is judged by that session when it answers.
    let client: CabalmailClient
    /// The main window whose user action it is (`commandWindowID`), or nil.
    let window: UUID?
    /// The view model making the write. It shows the change on its own rows
    /// or toolbar, and reverts it there, so it isn't sent the events.
    let sender: AnyObject?
    /// Whether another list's selection on the rows may move on.
    let advances: Bool

    /// A message list. It moved its own selection, if any; no other list's
    /// moves, and a list doesn't know its window (every window shares the
    /// search surface's).
    static func list(_ list: AnyObject, through client: CabalmailClient) -> MailWriter {
        MailWriter(client: client, window: nil, sender: list, advances: false)
    }

    /// A reader in `window`: the lists there advance past a message it
    /// removes, per the user's preference; lists elsewhere let go of the row.
    static func reader(_ reader: AnyObject, in window: UUID?, through client: CabalmailClient) -> MailWriter {
        MailWriter(client: client, window: window, sender: reader, advances: true)
    }

    /// The composer (a reply's `\Answered`), which no main window started
    /// and which shows nothing of its own.
    static func composer(through client: CabalmailClient) -> MailWriter {
        MailWriter(client: client, window: nil, sender: nil, advances: true)
    }
}

/// The one place the app's writes to mail go through: flags and read state,
/// moves, disposes and purges, from every list, the reader and the composer,
/// and Mark All as Read and Empty Trash, which change a whole folder. (A
/// notification's Mark as Read and Archive still write on their own: #1973.)
///
/// For each write to messages (a flag change or a removal) it records the
/// write in flight (`MessageShields`), posts the change for every list and
/// reader (`MailEvents`), and moves the folder counts once (`MailCounts`),
/// all before the request goes out; then it makes the server call through
/// the writer's client and, when that answers, either confirms the write (a
/// removal is recorded as confirmed and the message forgotten in the offline
/// caches, #1869) or takes it back (the reverse change is posted and the
/// counts put back). The writer still shows the change on its own rows or
/// toolbar, and reverts it there from the outcome: it is the events' sender,
/// and isn't sent them. The two whole-folder writes act only once the server
/// has answered: they set the folder's counts and ask every list to reload.
///
/// A write to messages is taken only from the session signed in, and
/// everything done once the server has answered is done only if that
/// session still is
/// (`acceptsAnswer(from:)`, the store's `acceptsCounts(from:)`, checked here
/// rather than by every caller): a late answer would otherwise write the
/// last account's counts, shields or cache prunes into the next one's
/// (#1848, #1851, #1892).
///
/// Part of `MailSessionStore` (`mutations`).
@MainActor
final class MailMutationService {
    private let counts: MailCounts
    private let shields: MessageShields
    private let events: MailEvents
    private let teardownGate: SessionTeardownGate

    init(counts: MailCounts, shields: MessageShields, events: MailEvents, teardownGate: SessionTeardownGate) {
        self.counts = counts
        self.shields = shields
        self.events = events
        self.teardownGate = teardownGate
    }

    /// A service whose record, events and counts nobody reads: what a reader
    /// writes through before it is connected to the signed-in store (a
    /// test's reader), so it still makes its server calls.
    static func unconnected() -> MailMutationService {
        MailMutationService(
            counts: MailCounts(), shields: MessageShields(), events: MailEvents(),
            teardownGate: SessionTeardownGate()
        )
    }

    private func acceptsAnswer(from client: CabalmailClient) -> Bool {
        !teardownGate.hasEnded(client)
    }

    // MARK: - Flags

    /// What became of a flag write.
    struct FlagOutcome: Sendable {
        /// The messages the server didn't change. Their change is taken back
        /// in every other list and in the counts; the writer takes it back on
        /// its own rows.
        let failed: Set<MessageRef>
        /// What to tell the user, nil when every message changed: the
        /// error, or for a group the server changed in part, how many of it
        /// changed. The last group's, when several failed, as before.
        let message: String?
    }

    /// Adds or removes `flag` on `refs`. `changing` are the refs whose flag
    /// the write actually flips, as the writer shows them: only those move
    /// the unread count (for `\Seen`) or the flagged count (for `\Flagged`)
    /// and are flipped back if the write fails, so a mark-read over a message
    /// already read moves nothing.
    ///
    /// The record, the event and the count change happen before this
    /// returns; the returned task makes the server call, one per folder, and
    /// settles the write.
    @discardableResult
    func setFlag(
        _ flag: Flag,
        added: Bool,
        on refs: [MessageRef],
        changing: Set<MessageRef>,
        by writer: MailWriter
    ) -> Task<FlagOutcome, Never> {
        let client = writer.client
        // A write from a session that has ended (a reader whose load
        // outlived it, marking read on open) changes nothing here and goes
        // nowhere; the writer takes back its own change.
        guard acceptsAnswer(from: client) else {
            return Task { FlagOutcome(failed: Set(refs), message: nil) }
        }
        shields.beginFlagWrite(refs, flag: flag, added: added)
        post(.flagsChanged(refs, flag: flag, added: added), by: writer)
        let moves = CountMoves(counts: counts, folders: changing.map(\.folder))
        moves.move(flag, added: added, for: changing)
        return Task {
            defer { shields.endFlagWrite(refs, flag: flag, added: added) }
            var failed: Set<MessageRef> = []
            var message: String?
            for (folder, uids) in refs.uidsByFolder() {
                do {
                    try await client.imapClient.setFlags(
                        folder: folder, uids: uids, flags: [flag], operation: added ? .add : .remove
                    )
                } catch CabalmailError.bulkPartialFailure(let succeeded, let refused) {
                    failed.formUnion(refused.map { MessageRef(folder: folder, uid: $0) })
                    message = "Updated \(succeeded.count) of \(uids.count) messages. "
                        + "\(refused.count) could not be updated."
                } catch {
                    failed.formUnion(uids.map { MessageRef(folder: folder, uid: $0) })
                    message = error.localizedDescription
                }
            }
            let reverted = refs.filter { failed.contains($0) && changing.contains($0) }
            if !reverted.isEmpty, acceptsAnswer(from: client) {
                post(.flagsChanged(reverted, flag: flag, added: !added), by: writer)
                // A message removed since (in flight, or confirmed gone) took
                // its count with it; giving the flag's count back too would
                // count it twice.
                let stillThere = reverted.filter { !shields.isRemoving($0) && shields.confirmedRemovals[$0] == nil }
                moves.move(flag, added: !added, for: stillThere)
            }
            return FlagOutcome(failed: failed, message: message)
        }
    }

    // MARK: - Removals

    /// How messages leave their folders.
    enum Removal: Sendable {
        /// Moved to `destination`. `markingSeen` (a dispose: archived means
        /// read) has the server mark each read as it moves it, so an unread
        /// message's count leaves the source without arriving anywhere; a
        /// plain move carries the unread state, and the count, with it.
        case move(to: String, markingSeen: Bool)
        /// Deleted for good (out of Trash).
        case purge
    }

    /// What became of a removal.
    struct RemovalOutcome: Sendable {
        /// The messages the server confirmed gone.
        let confirmed: Set<MessageRef>
        /// The messages it didn't remove. They are back in every other list
        /// and in the counts; the writer puts its own rows back.
        let failed: Set<MessageRef>
        /// Of `failed`, the ones a partly failed dispose had already marked
        /// read on the server: back, but read.
        let markedRead: Set<MessageRef>
        /// What to tell the user, nil when every message went (see
        /// `FlagOutcome.message`).
        let message: String?
        /// The last error the server answered with, for a caller that words
        /// its own toast.
        let error: (any Error)?
    }

    /// Removes `refs` from their folders. `unread` are the ones the writer
    /// shows unread, whose count moves with them; `flagged`, the ones it
    /// shows flagged, whose count leaves the source folder. (A flagged
    /// message moving in doesn't raise the destination's flagged count until
    /// its next STATUS.)
    ///
    /// The record, the event and the count change happen before this
    /// returns; the returned task makes the server call, one per source
    /// folder, and settles the removal.
    @discardableResult
    func remove(
        _ refs: [MessageRef],
        _ removal: Removal,
        unread: Set<MessageRef>,
        flagged: Set<MessageRef> = [],
        by writer: MailWriter
    ) -> Task<RemovalOutcome, Never> {
        let client = writer.client
        guard acceptsAnswer(from: client) else {
            return Task {
                RemovalOutcome(confirmed: [], failed: Set(refs), markedRead: [], message: nil, error: nil)
            }
        }
        shields.beginRemoval(refs)
        let plan = RemovalPlan(
            refs: refs, removal: removal,
            unread: unread.intersection(refs), flagged: flagged.intersection(refs),
            moves: CountMoves(counts: counts, folders: refs.map(\.folder) + [removal.destination].compactMap { $0 }),
            writer: writer
        )
        // A plain move of unread messages raises the destination's count
        // now, so a STATUS of it asked before the move lands is bounded too.
        let arrival = removal.destination(carrying: plan.unread).flatMap { plan.moves.movesUnread(in: $0) ? $0 : nil }
        if let arrival { shields.beginArrival(into: arrival) }
        post(.removed(refs), by: writer)
        moveCounts(of: plan.unread, flagged: plan.flagged, for: plan, by: 1)
        return Task {
            defer {
                shields.endRemoval(refs)
                if let arrival { shields.endArrival(into: arrival) }
            }
            var settled = SettledRemoval()
            for (folder, uids) in refs.uidsByFolder() {
                await send(removal, folder: folder, uids: uids, through: client, into: &settled)
            }
            guard acceptsAnswer(from: client) else { return settled.outcome }
            // Everything that touches the store first, in this one step: the
            // cache forget below awaits, and the session may end meanwhile.
            let confirmed = refs.filter { settled.confirmed.contains($0) }
            if !confirmed.isEmpty {
                shields.recordConfirmedRemovals(confirmed)
            }
            restore(settled, of: plan)
            if !confirmed.isEmpty {
                await client.forgetRemovedMessages(confirmed)
            }
            return settled.outcome
        }
    }

    /// A removal as it went out: what it takes back if refused.
    private struct RemovalPlan {
        let refs: [MessageRef]
        let removal: Removal
        /// The refs the writer shows unread.
        let unread: Set<MessageRef>
        /// The refs the writer shows flagged.
        let flagged: Set<MessageRef>
        /// The folders whose counts it moves.
        let moves: CountMoves
        let writer: MailWriter
    }

    /// A removal's folders, as they settled.
    private struct SettledRemoval {
        var confirmed: Set<MessageRef> = []
        var failed: Set<MessageRef> = []
        var markedRead: Set<MessageRef> = []
        var message: String?
        var error: (any Error)?

        var outcome: RemovalOutcome {
            RemovalOutcome(
                confirmed: confirmed, failed: failed, markedRead: markedRead, message: message, error: error
            )
        }
    }

    private func send(
        _ removal: Removal,
        folder: String,
        uids: [UInt32],
        through client: CabalmailClient,
        into settled: inout SettledRemoval
    ) async {
        let refs = uids.map { MessageRef(folder: folder, uid: $0) }
        do {
            switch removal {
            case .move(let destination, let markingSeen):
                try await client.imapClient.move(
                    folder: folder, uids: uids, destination: destination, markSeen: markingSeen
                )
            case .purge:
                try await client.imapClient.purge(folder: folder, uids: uids)
            }
            settled.confirmed.formUnion(refs)
        } catch CabalmailError.bulkPartialFailure(let succeeded, let refused) where !removal.isPurge {
            // Only the refused rows come back. A dispose had the server mark
            // them read before the move failed, so they come back read.
            settled.confirmed.formUnion(succeeded.map { MessageRef(folder: folder, uid: $0) })
            let back = refused.map { MessageRef(folder: folder, uid: $0) }
            settled.failed.formUnion(back)
            if removal.marksSeen { settled.markedRead.formUnion(back) }
            settled.message = "Moved \(succeeded.count) of \(uids.count) messages. "
                + "\(refused.count) could not be moved."
            settled.error = CabalmailError.bulkPartialFailure(succeeded: succeeded, failed: refused)
        } catch {
            settled.failed.formUnion(refs)
            settled.message = error.localizedDescription
            settled.error = error
        }
    }

    /// Puts what a removal took back for the messages it didn't remove: their
    /// rows in every other list, unread again where a dispose's read mark
    /// didn't land, and the counts.
    private func restore(_ settled: SettledRemoval, of plan: RemovalPlan) {
        let back = plan.refs.filter { settled.failed.contains($0) }
        guard !back.isEmpty else { return }
        for ref in back {
            let wasUnread = plan.unread.contains(ref) && !settled.markedRead.contains(ref)
            post(.restored(ref, markUnread: plan.removal.marksSeen && wasUnread), by: plan.writer)
        }
        let readNow = back.filter { settled.markedRead.contains($0) && plan.unread.contains($0) }
        if !readNow.isEmpty {
            post(.flagsChanged(readNow, flag: .seen, added: true), by: plan.writer)
        }
        let returning = Set(back).intersection(plan.unread).subtracting(settled.markedRead)
        moveCounts(of: returning, flagged: Set(back).intersection(plan.flagged), for: plan, by: -1)
    }

    // MARK: - Whole folders

    /// Hard-reloads every mounted message list after a change made behind
    /// them; the store points it at its own request
    /// (`MailSessionStore.requestListRefresh()`).
    var onListRefreshRequested: @MainActor () -> Void = {}

    /// Marks every unseen message in `folderPath` read in one server call
    /// (`/mark_folder_read`, cross-media plan decision 6), then brings the
    /// client's own state into line: the folder's envelope-cache snapshot is
    /// marked read to match, the sidebar badge zeroes its unread while
    /// keeping the total, and the mounted lists hard-reload so the rows
    /// re-render read. The snapshot is rewritten rather than dropped:
    /// dropped, a folder not on screen had no saved list until it was next
    /// opened online, so offline it showed no messages (#1850). Returns how
    /// many messages the server flipped; throws the server's error for the
    /// caller to show.
    @discardableResult
    func markFolderRead(_ folderPath: String, through client: CabalmailClient) async throws -> Int {
        let flipped = try await client.imapClient.markFolderRead(folder: folderPath)
        try? await client.envelopeCache.markAllSeen(folder: folderPath)
        guard acceptsAnswer(from: client) else { return flipped }
        if let total = counts.folderTotalCounts[folderPath] {
            counts.setFolderCounts(folderPath: folderPath, unread: 0, total: total)
        } else {
            // No STATUS yet for this folder: zero the unread alone rather
            // than invent a total the badge would then draw as `0/0`.
            counts.setUnreadCount(folderPath: folderPath, count: 0)
        }
        onListRefreshRequested()
        return flipped
    }

    /// Deletes everything in Trash for good, once the user has confirmed.
    /// On success Trash's envelope snapshot is dropped, its badge zeroes and
    /// the mounted lists hard-reload. Throws the server's error.
    func emptyTrash(through client: CabalmailClient) async throws {
        let path = FolderTree.trashPath
        try await client.imapClient.emptyTrash(folder: path)
        try? await client.envelopeCache.invalidate(folder: path)
        guard acceptsAnswer(from: client) else { return }
        counts.setFolderCounts(folderPath: path, unread: 0, total: 0)
        counts.setFlaggedCount(folderPath: path, count: 0)
        onListRefreshRequested()
    }

    // MARK: - Counts

    /// Moves the counts of messages leaving their folders (`direction` 1) or
    /// coming back (`-1`): `unread`'s unread count out of their folders and,
    /// for a plain move, into the destination; `flagged`'s flagged count out
    /// of their folders.
    private func moveCounts(
        of unread: Set<MessageRef>,
        flagged: Set<MessageRef>,
        for plan: RemovalPlan,
        by direction: Int
    ) {
        plan.moves.moveUnread(unread, by: -direction)
        if case .move(let destination, markingSeen: false) = plan.removal {
            plan.moves.moveUnread(unread, into: destination, by: direction)
        }
        plan.moves.moveFlagged(flagged, by: -direction)
    }

    private func post(_ change: MailEvent.Change, by writer: MailWriter) {
        events.post(change, from: writer.window, sender: writer.sender, advances: writer.advances)
    }
}

private extension MailMutationService.Removal {
    var marksSeen: Bool {
        if case .move(_, markingSeen: true) = self { return true }
        return false
    }

    var isPurge: Bool {
        if case .purge = self { return true }
        return false
    }

    /// Where a move takes the messages; nil for a purge.
    var destination: String? {
        if case .move(let destination, _) = self { return destination }
        return nil
    }

    /// The folder whose unread count a plain move of `unread` raises, if
    /// any.
    func destination(carrying unread: Set<MessageRef>) -> String? {
        guard case .move(let destination, markingSeen: false) = self, !unread.isEmpty else { return nil }
        return destination
    }
}
