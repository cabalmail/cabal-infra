import Foundation
import CabalmailKit
@testable import CabalmailUI

/// Hears every mail event a store posts (`MailSessionStore.events`), in the
/// order posted, for tests that check what a sender posted. The store holds
/// its subscribers weakly, so a test keeps the recorder for as long as it
/// should listen.
@MainActor
final class MailEventRecorder: MailEventSubscriber {
    private(set) var events: [MailEvent] = []

    init(_ store: MailSessionStore) {
        store.events.subscribe(self)
    }

    func receive(_ event: MailEvent) {
        events.append(event)
    }

    /// What each event changed, without its origin.
    var changes: [MailEvent.Change] { events.map(\.change) }

    /// The refs of every `.flagsChanged` heard, in order.
    var flagChangeRefs: [[MessageRef]] {
        changes.compactMap {
            guard case let .flagsChanged(refs, _, _) = $0 else { return nil }
            return refs
        }
    }
}

extension MessageListViewModel {
    /// Each loaded row's ref, in list order.
    var rowRefs: [MessageRef] { envelopes.map { rowRef(for: $0) } }
}

/// One view's hold on a list's selection, applying the list's selection
/// reactions the way `MessageListView.applySelectionReactions` does: from its
/// own place in them, through `MailEventSelectionPolicy.update`, resolving
/// the message its reader shows against the list's rows. `shown` stands in
/// for the view's `selection` binding; on a wide layout the list's
/// `selectedRefs` is the selection the reader follows.
@MainActor
final class ListViewSelection {
    let list: MessageListViewModel
    let window: UUID?
    let isWideLayout: Bool
    private(set) var applied: Int
    var shown: MessageRef?

    /// A view in `window` that has just been given `list`. A wide view's
    /// reader starts on the list's one selected row, if it has one.
    init(_ list: MessageListViewModel, in window: UUID?, isWideLayout: Bool = true, shown: MessageRef? = nil) {
        self.list = list
        self.window = window
        self.isWideLayout = isWideLayout
        self.applied = list.selectionReactions.tick
        self.shown = shown ?? (isWideLayout && list.selectedRefs.count == 1 ? list.selectedRefs.first : nil)
    }

    func apply() {
        let reactions = list.selectionReactions.since(applied)
        applied = list.selectionReactions.tick
        guard let update = MailEventSelectionPolicy.update(
            after: reactions, selectedRefs: list.selectedRefs, shown: shown,
            isWideLayout: isWideLayout, in: window
        ) else { return }
        let resolved = update.shown.flatMap(list.envelope(for:)).map(list.rowRef(for:))
        if isWideLayout {
            list.selectedRefs = update.shown != nil && resolved == nil ? [] : update.selectedRefs
        }
        shown = resolved
    }
}
