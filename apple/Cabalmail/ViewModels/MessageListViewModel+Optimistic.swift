import Foundation
import CabalmailKit

/// Optimistic update primitives for `MessageListViewModel`. Lives in its own
/// file so `MessageListViewModel.swift` stays under SwiftLint's file length
/// cap; same `@MainActor` extension as the rest of the view model.
@MainActor
extension MessageListViewModel {
    /// Optimistic flag toggle. Updates the in-memory envelope before the
    /// server round trip so the swipe action and context-menu commands feel
    /// instant; reverts the change if `setFlags` fails so the row goes back
    /// to the truthful state. Mirrors the same shape used by
    /// `MessageDetailViewModel.setSeen` so a future "mark all" can land on
    /// the same primitive.
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
            errorMessage = "\(error)"
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

    /// Clears a row's disposal phase. Called once the envelope has actually
    /// left `envelopes` (housekeeping — the row is gone) and on the failure
    /// path, where it's the whole revert: the envelope never left, so dropping
    /// the phase snaps the row back to full height and opacity.
    func endRowDisposal(uid: UInt32) {
        rowDisposalPhases[uid] = nil
    }

    /// Reinsert an envelope previously removed by an optimistic move (the
    /// dispose path never removes it until the move has landed, so it has
    /// nothing to reinsert). Tries to restore the original index; falls back
    /// to UID-sorted insertion if the list has shifted (e.g. a refresh fired
    /// during the in-flight move).
    func restoreEnvelope(_ envelope: Envelope, at originalIndex: Int?) {
        guard !envelopes.contains(where: { $0.uid == envelope.uid }) else { return }
        if let originalIndex, originalIndex <= envelopes.count {
            envelopes.insert(envelope, at: originalIndex)
        } else {
            envelopes.append(envelope)
            envelopes.sort { $0.uid > $1.uid }
        }
        // The row is back, so hand the folder total back the slot the
        // optimistic prune took off it.
        adjustTotalMessages(by: 1)
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
            flags: flags,
            internalDate: source.internalDate,
            size: source.size,
            hasAttachments: source.hasAttachments,
            isImportant: source.isImportant
        )
    }
}
