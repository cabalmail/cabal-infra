import Foundation
import Observation
import CabalmailKit

/// What keeps a message list's refresh from undoing a write made elsewhere:
/// the reader's flag writes and moves still in flight, and the removals the
/// server has confirmed, which a refresh already in flight when they landed
/// may not know about yet. `MessageListViewModel.shieldFetched` and its
/// refresh read these at merge time; the reader brackets its writes through
/// them (`MessageDetailView.relayOutcomes`), and the list's and the reader's
/// removal paths record a removal once the server confirms it.
///
/// Part of `MailSessionStore` (`shields`). Read at merge time only, never
/// from a view body, so observation tracking is irrelevant here.
@Observable
@MainActor
final class MessageShields {
    /// Messages with a flag write in flight from the detail view (keyed by
    /// ref: IMAP UIDs are only unique within a mailbox, so a bare UID set
    /// would let a pending write in one folder shield an unrelated row with
    /// the same UID in another). `MessageListViewModel.shieldFetched` reads
    /// this so a refresh that lands mid-write can't revert the detail view's
    /// optimistic flag - the cross-view analogue of the list's own
    /// `pendingFlagRefs`. The detail view brackets each write via
    /// `setFlagWrite(_:inFlight:)`.
    private(set) var pendingFlagWriteRefs: Set<MessageRef> = []

    /// Messages the detail view has optimistically removed (archive / trash /
    /// move) but whose server move is still in flight. The detail view prunes
    /// the list row up front (its `.removed` event); without this
    /// `MessageListViewModel.shieldFetched` would let a refresh that lands
    /// before the move completes resurrect the row (the source folder still
    /// returns the UID). The cross-view analogue of the list's own
    /// `pendingRemovedRefs`; bracketed via `setMoveInFlight(_:inFlight:)`.
    private(set) var pendingMoveRefs: Set<MessageRef> = []

    /// Messages the server has confirmed gone from their folder -- a list or
    /// reader dispose, move or purge landed -- with when that was confirmed.
    /// The shields above end when a move resolves, but a refresh already in
    /// flight can still answer with the folder as it was before the move and
    /// put the message back (the list then shifts under the user's pointer).
    /// IMAP never reuses a UID within a mailbox, so a fetch that still
    /// carries one of these is stale by definition, and
    /// `MessageListViewModel.shieldFetched` drops it. Entries age out after
    /// `confirmedRemovalWindow`, longer than any request can stay in flight.
    private(set) var confirmedRemovals: [MessageRef: ContinuousClock.Instant] = [:]

    /// How long a confirmed removal keeps shielding its message. A request
    /// can't be in flight this long (the API gateway gives up after 29 s),
    /// so by then no fetch issued before the removal can still land.
    static let confirmedRemovalWindow: Duration = .seconds(60)

    init() {}

    /// Mark a detail-view flag write as in flight (`true`, when the STORE is
    /// dispatched) or resolved (`false`, on success or failure). While a
    /// message is in flight the list's merge keeps the optimistic flag
    /// instead of the fetched one; clearing it lets the next refresh carry
    /// server truth. Safe to call `false` for a message that was never
    /// inserted (a no-op removal).
    func setFlagWrite(_ ref: MessageRef, inFlight: Bool) {
        if inFlight {
            pendingFlagWriteRefs.insert(ref)
        } else {
            pendingFlagWriteRefs.remove(ref)
        }
    }

    /// Mark a detail-view archive / trash / move as in flight (`true`, before
    /// the server move) or resolved (`false`, on success or failure). While a
    /// message is in flight the list's merge keeps the optimistically-pruned
    /// row gone; clearing it lets the next refresh re-add the row if the move
    /// failed, or confirm its absence if it succeeded. Safe to call `false`
    /// for a message that was never inserted (a no-op removal).
    func setMoveInFlight(_ ref: MessageRef, inFlight: Bool) {
        if inFlight {
            pendingMoveRefs.insert(ref)
        } else {
            pendingMoveRefs.remove(ref)
        }
    }

    /// True while a detail-view move out of `folderPath` is in flight: a
    /// STATUS of that folder may still count the message.
    func hasMoveInFlight(folderPath: String) -> Bool {
        pendingMoveRefs.contains { $0.folder == folderPath }
    }

    /// Record that the server confirmed `refs` gone from their folders.
    /// Entries past the window are dropped for the folders recorded into,
    /// as they always were; other folders' entries are left for their own
    /// next record.
    func recordConfirmedRemovals(
        _ refs: some Sequence<MessageRef>,
        at now: ContinuousClock.Instant = .now
    ) {
        let refs = Array(refs)
        let folders = Set(refs.map(\.folder))
        confirmedRemovals = confirmedRemovals.filter {
            !folders.contains($0.key.folder) || now - $0.value < Self.confirmedRemovalWindow
        }
        for ref in refs { confirmedRemovals[ref] = now }
    }

    /// The messages confirmed gone from `folderPath` within the window.
    func confirmedRemovalRefs(folderPath: String, now: ContinuousClock.Instant = .now) -> Set<MessageRef> {
        Set(confirmedRemovals.compactMap { ref, confirmedAt in
            ref.folder == folderPath && now - confirmedAt < Self.confirmedRemovalWindow ? ref : nil
        })
    }

    /// True when a removal from `folderPath` was confirmed after `instant` --
    /// that is, while a request issued at `instant` may have been answered
    /// from the folder as it stood before the removal.
    func removalConfirmed(folderPath: String, after instant: ContinuousClock.Instant) -> Bool {
        confirmedRemovals.contains { $0.key.folder == folderPath && $0.value > instant }
    }

    /// Forget a folder's confirmed removals: a changed UIDVALIDITY starts the
    /// UID space over, so the old numbers say nothing about the new ones.
    func clearConfirmedRemovals(folderPath: String) {
        confirmedRemovals = confirmedRemovals.filter { $0.key.folder != folderPath }
    }

    /// Sign-out's share of `MailSessionStore.forgetAccount()`: nothing the
    /// last account had in flight or confirmed shields the next account's
    /// lists. A late write from its reader can still land here afterwards,
    /// as before the move.
    func reset() {
        confirmedRemovals = [:]
        pendingFlagWriteRefs = []
        pendingMoveRefs = []
    }
}
