import Foundation
import CabalmailKit

// `\Seen` / `\Flagged` toggles and the auto-mark-as-read scheduler for
// `MessageDetailViewModel`. Lifted into a sibling extension so the main
// view-model file stays under SwiftLint's type-body cap; same `@MainActor`
// extension as the rest of the view model.
//
// Each toggle is optimistic: flip the in-memory flag and signal the list
// before the STORE, revert both on failure. `onFlagWriteInFlight` brackets
// the round trip so the list can shield the optimistic flag from a refresh
// that lands before the write resolves (see `AppState.setFlagWrite` and
// `MessageListViewModel.shieldFetched`).
@MainActor
extension MessageDetailViewModel {
    /// Toggles the server's `\Seen` flag. Drives both the toolbar button's
    /// manual path and the `.onOpen` mark-as-read preference.
    func toggleSeen() async {
        await setSeen(!isSeen)
    }

    func setSeen(_ shouldBeSeen: Bool) async {
        // Optimistic flip: update the toolbar icon and signal the list
        // before the server round trip so the user sees the change land
        // instantly. On STORE failure we revert the flag and the cross-
        // view signal so the row goes back to its truthful state.
        let previous = isSeen
        isSeen = shouldBeSeen
        onFlagChanged?(.seen, shouldBeSeen)
        onFlagWriteInFlight?(true)
        defer { onFlagWriteInFlight?(false) }
        do {
            try await client.imapClient.setFlags(
                folder: folder.path,
                uids: [envelope.uid],
                flags: [.seen],
                operation: shouldBeSeen ? .add : .remove
            )
        } catch {
            isSeen = previous
            onFlagChanged?(.seen, previous)
            errorMessage = "\(error)"
        }
    }

    func scheduleMarkAsReadIfNeeded() {
        guard !isSeen else { return }
        switch preferences.markAsRead {
        case .manual:
            return
        case .onOpen:
            Task { await setSeen(true) }
        }
    }

    /// Flip the server's `\Flagged` bit. Optimistic update with revert-on-
    /// failure mirrors `setSeen(_:)`; the cross-view signal lets the list
    /// row's flag indicator appear or disappear without a refresh.
    func toggleFlagged() async {
        let previous = isFlagged
        let shouldBeFlagged = !previous
        isFlagged = shouldBeFlagged
        onFlagChanged?(.flagged, shouldBeFlagged)
        onFlagWriteInFlight?(true)
        defer { onFlagWriteInFlight?(false) }
        do {
            try await client.imapClient.setFlags(
                folder: folder.path,
                uids: [envelope.uid],
                flags: [.flagged],
                operation: shouldBeFlagged ? .add : .remove
            )
        } catch {
            isFlagged = previous
            onFlagChanged?(.flagged, previous)
            errorMessage = "\(error)"
        }
    }

    /// Flip one custom-flag slot (rules-composition plan, Phase 4). Same
    /// optimistic shape as `toggleFlagged`; the cross-view signal carries
    /// the keyword `Flag`, which the list's `applyFlagChange` handles like
    /// any other (pills untouched via its `default` arm).
    func toggleKeyword(_ slot: String) async {
        let wasTagged = keywordSlots.contains(slot)
        let shouldBeTagged = !wasTagged
        if shouldBeTagged { keywordSlots.insert(slot) } else { keywordSlots.remove(slot) }
        onFlagChanged?(.keyword(slot), shouldBeTagged)
        onFlagWriteInFlight?(true)
        defer { onFlagWriteInFlight?(false) }
        do {
            try await client.imapClient.setFlags(
                folder: folder.path,
                uids: [envelope.uid],
                flags: [.keyword(slot)],
                operation: shouldBeTagged ? .add : .remove
            )
        } catch {
            if wasTagged { keywordSlots.insert(slot) } else { keywordSlots.remove(slot) }
            onFlagChanged?(.keyword(slot), wasTagged)
            errorMessage = "\(error)"
        }
    }
}
