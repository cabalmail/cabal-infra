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
        if add { flags.insert(flag) } else { flags.remove(flag) }
        envelopes[index] = rebuildEnvelope(envelopes[index], flags: flags)
    }

    /// Reinsert an envelope previously removed by an optimistic dispose.
    /// Tries to restore the original index; falls back to UID-sorted
    /// insertion if the list has shifted (e.g. a refresh fired during the
    /// in-flight move).
    func restoreEnvelope(_ envelope: Envelope, at originalIndex: Int?) {
        guard !envelopes.contains(where: { $0.uid == envelope.uid }) else { return }
        if let originalIndex, originalIndex <= envelopes.count {
            envelopes.insert(envelope, at: originalIndex)
        } else {
            envelopes.append(envelope)
            envelopes.sort { $0.uid > $1.uid }
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
            flags: flags,
            internalDate: source.internalDate,
            size: source.size,
            hasAttachments: source.hasAttachments,
            isImportant: source.isImportant
        )
    }
}
