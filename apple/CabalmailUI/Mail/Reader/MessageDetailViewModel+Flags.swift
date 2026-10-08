import Foundation
import CabalmailKit

// `\Seen` / `\Flagged` toggles and the auto-mark-as-read scheduler for
// `MessageDetailViewModel`. Lifted into a sibling extension so the main
// view-model file stays under SwiftLint's type-body cap; same `@MainActor`
// extension as the rest of the view model.
//
// Each toggle is optimistic: flip the in-memory flag, then send the write
// through the mutation service, which tells every list before the STORE,
// shields it from a refresh that lands before it resolves (see
// `MessageShields` and `MessageListViewModel.shieldFetched`), and moves the
// unread count for `\Seen`. If the server refuses, the service takes the
// change back everywhere else and the reader flips its own flag back.
@MainActor
extension MessageDetailViewModel {
    /// Toggles the server's `\Seen` flag. Drives both the toolbar button's
    /// manual path and the `.onOpen` mark-as-read preference.
    func toggleSeen() async {
        await setSeen(!isSeen)
    }

    func setSeen(_ shouldBeSeen: Bool) async {
        let previous = isSeen
        isSeen = shouldBeSeen
        if await writeFlag(.seen, added: shouldBeSeen, flips: previous != shouldBeSeen) {
            isSeen = previous
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
    /// failure mirrors `setSeen(_:)`; the change reaches every list, so the
    /// row's flag indicator appears or disappears without a refresh.
    func toggleFlagged() async {
        let previous = isFlagged
        isFlagged = !previous
        if await writeFlag(.flagged, added: !previous, flips: true) {
            isFlagged = previous
        }
    }

    /// Flip one custom-flag slot (rules-composition plan, Phase 4). Same
    /// optimistic shape as `toggleFlagged`; the change carries the keyword
    /// `Flag`, which the list's `applyFlagChange` handles like any other
    /// (pills untouched via its `default` arm).
    func toggleKeyword(_ slot: String) async {
        let wasTagged = keywordSlots.contains(slot)
        setKeyword(slot, !wasTagged)
        if await writeFlag(.keyword(slot), added: !wasTagged, flips: true) {
            setKeyword(slot, wasTagged)
        }
    }

    private func setKeyword(_ slot: String, _ tagged: Bool) {
        if tagged { keywordSlots.insert(slot) } else { keywordSlots.remove(slot) }
    }

    /// Writes `flag` on the open message through the mutation service.
    /// True when the server refused, so the caller flips its own state back;
    /// the refusal's text is in `errorMessage`.
    private func writeFlag(_ flag: Flag, added: Bool, flips: Bool) async -> Bool {
        let outcome = await mutations.setFlag(
            flag, added: added, on: [ref], changing: flips ? [ref] : [], by: writer
        ).value
        guard outcome.failed.contains(ref) else { return false }
        errorMessage = outcome.message
        return true
    }

    /// Another list or reader changed a flag on the open message: show it.
    func applyFlagChange(_ flag: Flag, added: Bool) {
        switch flag {
        case .seen: isSeen = added
        case .flagged: isFlagged = added
        case .keyword(let slot): setKeyword(slot, added)
        default: break
        }
    }
}

extension MessageDetailViewModel: MailEventSubscriber {
    /// Follows flag changes other lists and readers make to the open
    /// message (its own writes aren't sent back to it).
    func receive(_ event: MailEvent) {
        guard case .flagsChanged(let refs, let flag, let added) = event.change, refs.contains(ref) else { return }
        applyFlagChange(flag, added: added)
    }
}
