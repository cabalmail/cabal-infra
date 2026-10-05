import Foundation
import CabalmailKit

/// Optimistic update primitives for `MessageListViewModel`. Lives in its own
/// file so `MessageListViewModel.swift` stays under SwiftLint's file length
/// cap; same `@MainActor` extension as the rest of the view model.
@MainActor
extension MessageListViewModel {
    /// Optimistic flag toggle for one row. Updates the in-memory envelope
    /// before the server round trip so the swipe action and context-menu
    /// commands feel instant; reverts the change, and any unread-badge
    /// delta, if `setFlags` fails so the row goes back to the truthful
    /// state. Selections take their own path (`setSeen(_:uids:)` and
    /// `setFlagged(_:uids:)` in the bulk extension).
    func setFlag(_ flag: Flag, add: Bool, envelope: Envelope) async {
        let source = sourceFolder(for: envelope)
        applyOptimisticFlag(uid: envelope.uid, flag: flag, add: add)
        // Shield the optimistic flag from a concurrent refresh until our own
        // write resolves; the next refresh after that carries server truth.
        pendingFlagUIDs.insert(envelope.uid)
        defer { pendingFlagUIDs.remove(envelope.uid) }
        // Mirror the optimistic flag flip onto the source folder's unread
        // count when `.seen` changes — adding `.seen` to an unread message
        // drops one from the badge, removing it adds one back. Only fires
        // when the message wasn't already in the target state to avoid
        // double-counting a no-op toggle. In cross-folder search mode the
        // source folder is per-row, so the badge update reaches the right
        // mailbox.
        let unreadDelta: Int
        if flag == .seen, envelope.flags.contains(.seen) != add {
            unreadDelta = add ? -1 : 1
            appState.applyUnreadDelta(folderPath: source, delta: unreadDelta)
        } else {
            unreadDelta = 0
        }
        do {
            try await client.imapClient.setFlags(
                folder: source,
                uids: [envelope.uid],
                flags: [flag],
                operation: add ? .add : .remove
            )
        } catch {
            applyOptimisticFlag(uid: envelope.uid, flag: flag, add: !add)
            if unreadDelta != 0 {
                appState.applyUnreadDelta(folderPath: source, delta: -unreadDelta)
            }
            errorMessage = error.localizedDescription
        }
    }

    func applyOptimisticFlag(uid: UInt32, flag: Flag, add: Bool) {
        guard let index = envelopes.firstIndex(where: { $0.uid == uid }) else { return }
        var flags = envelopes[index].flags
        let flipped = flags.contains(flag) != add
        if add { flags.insert(flag) } else { flags.remove(flag) }
        envelopes[index] = rebuildEnvelope(envelopes[index], flags: flags)
        // Keep the Unread/Flagged pill counts in step with the optimistic row
        // state — STATUS only corrects them on the next refresh, so without
        // this the pills lag every flag/read change until a server round trip.
        // Every optimistic flag path (list toggle, detail-view signal, bulk,
        // and their reverts) funnels through here, so adjusting on a real flip
        // only can't double-count.
        guard flipped else { return }
        switch flag {
        case .seen:
            unseen = max(0, unseen + (add ? -1 : 1))
        case .flagged:
            flagged = max(0, flagged + (add ? 1 : -1))
        default:
            break
        }
    }

    /// Keep the server-sourced folder total in step with an optimistic prune
    /// (or its revert). The index-addressed list renders
    /// `max(totalMessages, loaded rows)` slots and the All filter pill reads
    /// `totalMessages` straight through, so a row removed locally leaves a
    /// loading skeleton behind in its slot — a placeholder that can never
    /// resolve, because the message it points at is gone — plus an inflated
    /// pill, until the next STATUS corrects the count. Unsubscribed folders
    /// (Drafts) get no proactive poll, so that wait runs to minutes rather
    /// than the ~10s STATUS lag elsewhere. Clamped at zero, and skipped in
    /// search mode, where the row count comes from the results rather than
    /// STATUS.
    func adjustTotalMessages(by delta: Int) {
        guard !isSearchActive, delta != 0 else { return }
        totalMessages = UInt32(max(0, Int(totalMessages) + delta))
        // The removal is this list's own, so the next STATUS mustn't read it
        // as a change made elsewhere (`WindowAnchor`).
        if let anchor = alignment.anchor {
            alignment.anchor?.total = UInt32(max(0, Int(anchor.total) + delta))
        }
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
    /// animation ends -- not when the server answers. Cache pruning still
    /// waits for server confirmation, so a transient failure can't leave the
    /// persistent snapshot disagreeing with the server.
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
        guard pendingRemovedUIDs.insert(envelope.uid).inserted else { return }
        defer { pendingRemovedUIDs.remove(envelope.uid) }

        let destination = preferences.disposeAction.destinationFolder
        let source = sourceFolder(for: envelope)
        let wasUnread = !envelope.flags.contains(.seen)
        // Where the swipe happened. A refresh that adds mail above the row
        // during the animation moves the message down a slot, but the row
        // that was swiped -- and held open -- stays where it was.
        let swipedSlot = slotIndex(of: envelope.uid)
        // Start the row animation but deliberately DON'T await it before the
        // move: a swipe landing just as the app is backgrounded has only a
        // brief window to reach the network, so the request goes out first and
        // the animation plays alongside it. Until the envelope leaves, the row
        // renders transparent / collapsed and takes no hits, so it can't be
        // swiped twice, and holding it in place keeps every absolute row index
        // stable -- the index-addressed list would otherwise shift the rows
        // below instantly.
        let disposal = beginRowDisposal(uid: envelope.uid)
        // Optimistic count drop for the source folder: the dispose path
        // marks the message `\Seen` before moving, so an unread message
        // both loses its unread state AND leaves the folder. One -1 covers
        // both — the post-move STATUS walk will fix it if the server
        // disagrees. In cross-folder search mode `source` may differ from
        // `folder.path`; the unread delta routes to the row's true mailbox.
        if wasUnread {
            appState.applyUnreadDelta(folderPath: source, delta: -1)
        }

        // Mark-seen + move in one round trip (the Lambda adds `\Seen` before
        // moving). Collapsing the old STORE-then-MOVE pair matters when the
        // swipe lands just as the app is being backgrounded: there's only a
        // brief window to reach the network, so halving the calls makes the
        // archive far likelier to commit in time.
        let client = self.client
        let uid = envelope.uid
        let move = Task {
            try await client.imapClient.move(
                folder: source, uids: [uid], destination: destination, markSeen: wasUnread
            )
        }
        // An early failure stops the collapse, so a row that is staying never
        // closes its gap.
        Task {
            if case .failure = await move.result { disposal.cancel() }
        }
        await disposal.value

        // All of it in one synchronous step so the list sees a single update:
        // the row is replaced, the envelope is gone AND the phase is cleared,
        // which leaves the vacated slot rendering the next envelope at full
        // height, in a row of its own rather than the swiped one. A disposal
        // cancelled mid-fade never reached `.collapsing`; its message stays,
        // in a new row, and clearing the phase brings it back.
        let originalIndex = envelopes.firstIndex { $0.uid == uid }
        let dropped = rowDisposalPhases[uid] == .collapsing && originalIndex != nil
        replaceRows(showing: [uid], alsoAt: swipedSlot.map { [$0] } ?? [])
        if dropped {
            envelopes.removeAll { $0.uid == uid }
            adjustTotalMessages(by: -1)
        }
        endRowDisposal(uid: uid)

        do {
            try await move.value
            await confirmRemoval(from: source, uids: [uid])
        } catch {
            if dropped {
                restoreEnvelope(envelope, at: originalIndex)
            }
            if wasUnread {
                appState.applyUnreadDelta(folderPath: source, delta: 1)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// The server confirmed `uids` gone from `folder` (a dispose, move or
    /// purge succeeded): record it so a refresh that was already in flight
    /// can't bring them back (see `AppState.confirmedRemovals`), then prune
    /// the caches. Called only on success, while the UIDs are still in
    /// `pendingRemovedUIDs`, so the two shields overlap rather than leave a
    /// gap between them.
    func confirmRemoval(from folder: String, uids: [UInt32]) async {
        appState.recordConfirmedRemovals(folderPath: folder, uids: uids)
        await pruneCachesAfter(move: folder, uids: uids)
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
    func beginRowDisposal(uid: UInt32) -> Task<Void, Never> {
        rowDisposalPhases[uid] = .fading
        return Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.rowFadeDuration))
            // A cancellation here means the write failed and the caller is
            // restoring the row, so the collapse must not fire. `endRowDisposal`
            // owns clearing the phase.
            guard !Task.isCancelled, let self else { return }
            rowDisposalPhases[uid] = .collapsing
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
    func endRowDisposal(uid: UInt32) {
        rowDisposalPhases[uid] = nil
    }

    /// Reinsert an envelope previously removed by an optimistic move or
    /// dispose whose server write then failed. Tries to restore the original
    /// index; falls back to re-sorting by the active order if the list has
    /// shifted (e.g. a refresh fired during the in-flight move).
    func restoreEnvelope(_ envelope: Envelope, at originalIndex: Int?) {
        guard !envelopes.contains(where: { $0.uid == envelope.uid }) else { return }
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

    /// Keeps a row `pruneEnvelope(uid:)` is about to drop, if the reader's
    /// move for it is still in flight, so `restorePrunedEnvelope` can bring
    /// it back should the move fail. Entries whose move has since resolved
    /// are dropped here, which keeps the stash to in-flight moves. A prune
    /// with no move behind it (a send-from-draft) isn't kept.
    func stashForReaderRevert(_ envelope: Envelope, at index: Int) {
        let inFlight = appState.pendingMoveUIDs[folder.path] ?? []
        readerPrunedEnvelopes = readerPrunedEnvelopes.filter { inFlight.contains($0.key) }
        guard inFlight.contains(envelope.uid) else { return }
        readerPrunedEnvelopes[envelope.uid] = (envelope, index)
    }

    /// Undo `pruneEnvelope(uid:)` after the reader's dispose, move or purge
    /// failed on the server: the row comes back where it was, with the
    /// folder total and Unread pill adjustments the prune made. `markUnread`
    /// is set when the reader's dispose had marked an unread message read;
    /// the row comes back unread. Carried here rather than as a separate
    /// flag signal so it can't land before the row is back.
    ///
    /// The failure normally arrives after the prune. If it beat it (both
    /// signals in one update), the row is still here: it is remembered in
    /// `readerFailedUIDs` so the prune skips it. A UID this list never had
    /// loaded is left alone, as its prune left the counts alone.
    func restorePrunedEnvelope(uid: UInt32, markUnread: Bool = false) {
        if let stashed = readerPrunedEnvelopes.removeValue(forKey: uid) {
            guard !envelopes.contains(where: { $0.uid == uid }) else { return }
            var envelope = stashed.envelope
            if markUnread {
                envelope = rebuildEnvelope(envelope, flags: envelope.flags.subtracting([.seen]))
            }
            restoreEnvelope(envelope, at: stashed.index)
            if !envelope.flags.contains(.seen) {
                unseen += 1
            }
            invalidateBottomPrefetch()
        } else if envelopes.contains(where: { $0.uid == uid }) {
            readerFailedUIDs.insert(uid)
            if markUnread {
                applyOptimisticFlag(uid: uid, flag: .seen, add: false)
            }
        }
    }

    /// Rebuilds an `Envelope` value with a different flag set. `Envelope`
    /// has no mutating accessor, so we copy every field through the public
    /// initializer; the cost is only paid on flag toggles and the call
    /// site keeps `setFlag` readable.
    func rebuildEnvelope(_ source: Envelope, flags: Set<Flag>) -> Envelope {
        Envelope(
            uid: source.uid,
            messageId: source.messageId,
            date: source.date,
            subject: source.subject,
            from: source.from,
            sender: source.sender,
            replyTo: source.replyTo,
            to: source.to,
            cc: source.cc,
            bcc: source.bcc,
            inReplyTo: source.inReplyTo,
            references: source.references,
            flags: flags,
            internalDate: source.internalDate,
            size: source.size,
            hasAttachments: source.hasAttachments,
            isImportant: source.isImportant,
            authResults: source.authResults
        )
    }
}
