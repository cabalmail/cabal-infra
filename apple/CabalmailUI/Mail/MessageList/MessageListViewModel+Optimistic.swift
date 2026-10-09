import Foundation
import CabalmailKit

/// Optimistic update primitives for `MessageListViewModel`. Lives in its own
/// file so `MessageListViewModel.swift` stays under SwiftLint's file length
/// cap; same `@MainActor` extension as the rest of the view model.
@MainActor
extension MessageListViewModel {
    /// Optimistic flag toggle for one row. Updates the in-memory envelope
    /// before the server round trip so the swipe action and context-menu
    /// commands feel instant, and sends the write through the mutation
    /// service, which shields it, tells every other list and reader, and
    /// moves the unread count when `.seen` flips (in cross-folder search,
    /// the row's own folder's). If the server refuses, the row goes back to
    /// what it was and the service takes back the rest. Selections take
    /// their own path (`setSeen(_:refs:)` and `setFlagged(_:refs:)` in the
    /// bulk extension).
    func setFlag(_ flag: Flag, add: Bool, envelope: Envelope) async {
        let ref = rowRef(for: envelope)
        // Only a real flip moves the count or is taken back: a no-op toggle
        // (the row already in the target state) changes nothing.
        let flips = envelope.flags.contains(flag) != add
        applyOptimisticFlag(ref, flag: flag, add: add)
        // The service records the write until the server answers; this list
        // keeps the row shielded a moment longer, until it has taken its own
        // change back, so a merge in between can't settle the row first.
        mailStore.shields.beginFlagWrite([ref], flag: flag, added: add)
        defer { mailStore.shields.endFlagWrite([ref], flag: flag, added: add) }
        let outcome = await mailStore.mutations.setFlag(
            flag, added: add, on: [ref], changing: flips ? [ref] : [], by: .list(self, through: client)
        ).value
        guard outcome.failed.contains(ref) else { return }
        if flips {
            applyOptimisticFlag(ref, flag: flag, add: !add)
        }
        errorMessage = outcome.message
    }

    /// Flips `flag` on `ref`'s row, if it is loaded. Rows only: the Unread
    /// and Flagged pills are the mail store's counts, which the mutation
    /// service moves once for each write.
    func applyOptimisticFlag(_ ref: MessageRef, flag: Flag, add: Bool) {
        guard let position = index(of: ref) else { return }
        var flags = envelopes[position].flags
        if add { flags.insert(flag) } else { flags.remove(flag) }
        envelopes[position] = rebuildEnvelope(envelopes[position], flags: flags)
    }

    /// Keep the server-sourced folder total in step with an optimistic prune
    /// (or its revert). The index-addressed list renders
    /// `max(totalMessages, loaded rows)` slots and the All filter pill reads
    /// `totalMessages` straight through, so a row removed locally leaves a
    /// loading skeleton behind in its slot — a placeholder that can never
    /// resolve, because the message it points at is gone — plus an inflated
    /// pill, until the next STATUS corrects the count. Unsubscribed folders
    /// (Drafts) get no proactive poll, so that wait runs to minutes rather
    /// than the ~10s STATUS lag elsewhere. Clamped at zero, skipped in
    /// search mode, where the row count comes from the results rather than
    /// STATUS, and a no-op on the search surface, which has no folder total.
    func adjustTotalMessages(by delta: Int) {
        guard !isSearchActive, delta != 0 else { return }
        window?.adjustTotal(by: delta)
    }

    /// Leg of the two-stage row-disposal animation a row is currently in.
    /// `nil` (absent from `rowDisposalPhases`) is the normal, settled state.
    enum RowDisposalPhase: Equatable {
        /// Full height, fading to transparent. Nothing moves yet.
        case fading
        /// Transparent, collapsing from `rowHeight` to zero. This is the leg
        /// that closes the gap and shifts the rows below up.
        case collapsing
    }

    /// Duration of each leg of the row-disposal animation, in seconds. Fast
    /// enough not to slow triage down, long enough for the eye to register
    /// that something left the list.
    static let rowFadeDuration: TimeInterval = 0.15
    static let rowCollapseDuration: TimeInterval = 0.15

    /// Dispose target is the current `Preferences.disposeAction` — Archive
    /// or Trash. The preference is read on every invocation so a user who
    /// toggles the setting mid-session sees the swipe behavior change
    /// immediately.
    ///
    /// Also matches the React webmail behavior by marking the message
    /// `\Seen` before the move: archived == read. The move carries
    /// `markSeen`, so the server sets the flag while the UID still exists in
    /// the source and moves it in the same call — one round trip instead of
    /// a STORE followed by a MOVE.
    ///
    /// Optimistic UI: the row is disposed of locally before the server round
    /// trip so the swipe feels instant, but it leaves the list on the two-leg
    /// fade-then-collapse animation rather than blinking out (see
    /// `beginRowDisposal`), and it leaves `envelopes` the moment that
    /// animation ends -- not when the server answers. The offline caches
    /// forget the message only once the server confirms (the mutation
    /// service), so a transient failure can't leave the persistent snapshot
    /// disagreeing with the server.
    ///
    /// Why the row can't wait for the server: once the collapse has played,
    /// the disposed slot is zero height and the next message sits under the
    /// user's pointer or thumb, yet under the index-addressed list it still
    /// belongs to the slot BELOW. A swipe begun there attaches to that lower
    /// slot, and when the envelope finally leaves, every slot re-points one
    /// message up -- so the swipe's reveal lands on the row under the one the
    /// user aimed at. Dropping the row as the collapse ends makes the
    /// re-pointing invisible (the incoming message was already drawn exactly
    /// there), and `DisposingRow` refuses new hits until then.
    ///
    /// A move that fails while the row is still fading stops the collapse
    /// and the row simply comes back where it stands; one that fails after
    /// the row has left is re-inserted at its old index.
    ///
    /// Either way the row is replaced as the animation ends, not just
    /// re-pointed or restored: a full swipe that got here holds its row slid
    /// open for the deletion it announced, and only a new row lets go of that
    /// (see `replaceRows(showing:)`).
    func dispose(_ envelope: Envelope) async {
        let ref = rowRef(for: envelope)
        // A message already on its way out short-circuits: a duplicate
        // rapid-swipe tap here, preventing re-entrant `ForEach(model.envelopes)`
        // diffing while several in-flight moves are still returning, or a
        // removal another list or the reader already has out. In that case
        // this row isn't fading, and a full swipe that got here holds it slid
        // open for the deletion it announced; only a new row lets go of that
        // (`replaceRows(showing:)`).
        guard !mailStore.shields.isRemoving(ref) else {
            if rowDisposalPhases[ref] == nil {
                replaceRows(showing: [ref])
            }
            return
        }
        // The service records the removal until the server answers. The row
        // stays in `envelopes` until its animation ends, which on a fast
        // network is later, so this list holds the removal in the record
        // until then as well: a refresh must not pull the leaving row out
        // under the animation, paging must not count it, and a second swipe
        // must not reach it.
        mailStore.shields.beginRemoval([ref])
        defer { mailStore.shields.endRemoval([ref]) }
        let destination = preferences.disposeAction.destinationFolder
        let wasUnread = !envelope.flags.contains(.seen)
        // Where the swipe happened. A refresh that adds mail above the row
        // during the animation moves the message down a slot, but the row
        // that was swiped -- and held open -- stays where it was.
        let swipedSlot = slotIndex(of: ref)
        // Start the row animation but deliberately DON'T await it before the
        // move: a swipe landing just as the app is backgrounded has only a
        // brief window to reach the network, so the request goes out first and
        // the animation plays alongside it. Until the envelope leaves, the row
        // renders transparent / collapsed and takes no hits, so it can't be
        // swiped twice, and holding it in place keeps every absolute row index
        // stable -- the index-addressed list would otherwise shift the rows
        // below instantly.
        let disposal = beginRowDisposal(ref)
        // Mark-seen + move in one round trip (the Lambda adds `\Seen` before
        // moving). Collapsing the old STORE-then-MOVE pair matters when the
        // swipe lands just as the app is being backgrounded: there's only a
        // brief window to reach the network, so halving the calls makes the
        // archive far likelier to commit in time. The service records the
        // removal, drops the row from every other list, and takes one off
        // the source folder's unread count for an unread message: the
        // dispose marks it read AND moves it out, and one -1 covers both. In
        // cross-folder search mode the row's own folder's count moves.
        let removal = mailStore.mutations.remove(
            [ref], .move(to: destination, markingSeen: wasUnread),
            unread: wasUnread ? [ref] : [], flagged: envelope.flags.contains(.flagged) ? [ref] : [],
            by: .list(self, through: client)
        )
        // An early failure stops the collapse, so a row that is staying never
        // closes its gap; a confirmed removal drops a staged bottom window at
        // once (`removalsConfirmed`).
        Task {
            let outcome = await removal.value
            if outcome.failed.contains(ref) { disposal.cancel() }
            if outcome.confirmed.contains(ref) { removalsConfirmed() }
        }
        await disposal.value

        // All of it in one synchronous step so the list sees a single update:
        // the row is replaced, the envelope is gone AND the phase is cleared,
        // which leaves the vacated slot rendering the next envelope at full
        // height, in a row of its own rather than the swiped one. A disposal
        // cancelled mid-fade never reached `.collapsing`; its message stays,
        // in a new row, and clearing the phase brings it back.
        let originalIndex = index(of: ref)
        let dropped = rowDisposalPhases[ref] == .collapsing && originalIndex != nil
        replaceRows(showing: [ref], alsoAt: swipedSlot.map { [$0] } ?? [])
        if dropped, let originalIndex {
            envelopes.remove(at: originalIndex)
            adjustTotalMessages(by: -1)
        }
        endRowDisposal(ref)

        let outcome = await removal.value
        guard outcome.failed.contains(ref) else { return }
        if dropped {
            restoreEnvelope(envelope, at: originalIndex)
        }
        errorMessage = outcome.message
    }

    /// Starts the two-stage disposal animation for a row and hands back the
    /// task driving it, so the caller can keep the envelope in `envelopes`
    /// until both legs have played out — or cancel it if the write fails and
    /// the row has to come back.
    ///
    /// Fade first, collapse second, deliberately sequential: the row goes
    /// transparent at full height (nothing moves, so the eye catches the
    /// change), and only then does the gap close. Removing the envelope
    /// outright reads as though nothing happened — under the index-addressed
    /// list it isn't even a row removal, just every slot below re-pointing at
    /// the next envelope, with no transition of any kind — which invites a
    /// second swipe on whatever slid into the vacated position.
    func beginRowDisposal(_ ref: MessageRef) -> Task<Void, Never> {
        rowDisposalPhases[ref] = .fading
        return Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.rowFadeDuration))
            // A cancellation here means the write failed and the caller is
            // restoring the row, so the collapse must not fire. `endRowDisposal`
            // owns clearing the phase.
            guard !Task.isCancelled, let self else { return }
            rowDisposalPhases[ref] = .collapsing
            try? await Task.sleep(for: .seconds(Self.rowCollapseDuration))
        }
    }

    /// True while any row is playing its disposal animation. `DisposingRow`
    /// refuses taps and swipes on every row until it clears: under the
    /// index-addressed list the rows below a leaving one re-point to the next
    /// envelope when it goes, so a gesture that began on one of them would
    /// land its reveal a row further down than the user aimed.
    var isDisposingRow: Bool { !rowDisposalPhases.isEmpty }

    /// Clears a row's disposal phase. Called once the envelope has actually
    /// left `envelopes` (housekeeping — the row is gone) and on the failure
    /// path, where it's the whole revert: the envelope never left, so dropping
    /// the phase snaps the row back to full height and opacity.
    func endRowDisposal(_ ref: MessageRef) {
        rowDisposalPhases[ref] = nil
    }

    /// Reinsert an envelope previously removed by an optimistic move or
    /// dispose whose server write then failed. Tries to restore the original
    /// index; falls back to re-sorting by the active order if the list has
    /// shifted (e.g. a refresh fired during the in-flight move).
    func restoreEnvelope(_ envelope: Envelope, at originalIndex: Int?) {
        guard index(of: rowRef(for: envelope)) == nil else { return }
        if let originalIndex, originalIndex <= envelopes.count {
            envelopes.insert(envelope, at: originalIndex)
        } else {
            envelopes.append(envelope)
            envelopes.sort(by: envelopeOrder)
        }
        // The row is back, so hand the folder total back the slot the
        // optimistic prune took off it.
        adjustTotalMessages(by: 1)
    }

    /// Keeps a row `pruneEnvelope(_:)` is about to drop, with the index it
    /// held before its removal pruned anything (`index`), if the removal
    /// behind it (the reader's, or another list's) is still in flight, so
    /// `restorePrunedEnvelope` can bring it back should the removal fail.
    /// Entries whose removal has since resolved are dropped here, which
    /// keeps the stash to removals in flight. A prune with no removal behind
    /// it (a send-from-draft) isn't kept.
    func stashForReaderRevert(_ envelope: Envelope, at index: Int) {
        let inFlight = mailStore.shields.pendingMoveRefs
        readerPrunedEnvelopes = readerPrunedEnvelopes.filter { inFlight.contains($0.key) }
        let ref = rowRef(for: envelope)
        guard inFlight.contains(ref) else { return }
        readerPrunedEnvelopes[ref] = (envelope, index)
    }

    /// Undo `pruneEnvelope(_:)` after a dispose, move or purge made by the
    /// reader or another list failed on the server: the row comes back where
    /// it was, with the folder total the prune took. A removal that named several of this list's rows stashed each at
    /// the index it held before any of them left, and they come back in any
    /// order, so each goes in ahead of the rows from that removal still
    /// stashed (still on their way back, or gone for good). `markUnread` is
    /// set when the dispose had marked an unread message read; the row comes
    /// back unread. Carried here rather than as a separate flag change so it
    /// can't land before the row is back.
    ///
    /// A failure for a row this list still has, with nothing stashed (a list
    /// built while the removal was out, or a failure that reached the list
    /// first), is remembered in `readerFailedRefs`, so a prune of that
    /// message with no removal in flight behind it is skipped. A message
    /// this list never had loaded is left alone, as its prune left the
    /// counts alone.
    func restorePrunedEnvelope(_ ref: MessageRef, markUnread: Bool = false) {
        if let stashed = readerPrunedEnvelopes.removeValue(forKey: ref) {
            guard index(of: ref) == nil else { return }
            var envelope = stashed.envelope
            if markUnread {
                envelope = rebuildEnvelope(envelope, flags: envelope.flags.subtracting([.seen]))
            }
            let inFlight = mailStore.shields.pendingMoveRefs
            readerPrunedEnvelopes = readerPrunedEnvelopes.filter { inFlight.contains($0.key) }
            let stillOut = readerPrunedEnvelopes.values.filter { $0.index < stashed.index }.count
            restoreEnvelope(envelope, at: max(0, stashed.index - stillOut))
            invalidateBottomPrefetch()
        } else if index(of: ref) != nil {
            readerFailedRefs.insert(ref)
            if markUnread {
                applyOptimisticFlag(ref, flag: .seen, add: false)
            }
        }
    }

    /// Rebuilds an `Envelope` value with a different flag set, keeping
    /// every other field — the row's folder included, so the rebuilt row
    /// still names its own message. The cost is only paid on flag toggles
    /// and the call site keeps `setFlag` readable.
    func rebuildEnvelope(_ source: Envelope, flags: Set<Flag>) -> Envelope {
        source.withFlags(flags)
    }
}
