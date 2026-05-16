import Foundation
import Observation
import CabalmailKit

/// Shared `MessageDetailViewModel` cache scoped to `MailRootView`. Exists
/// to dedupe the body fetch when SwiftUI materialises `MessageDetailView`
/// twice on iPhone (see #403 follow-up): `NavigationSplitView`'s compact-
/// collapse adapter creates two phantom view instances per tap and each
/// has its own `@State`. Both phantoms route through this store from
/// `.onAppear`, so they end up referencing the same model and the second
/// `startLoadIfNeeded()` is gated by `loadTask != nil`. One fetch instead
/// of two.
///
/// Holds at most one entry — the model for the currently-selected
/// `(folder, uid)`. When the user picks a different message the previous
/// entry is replaced and dropped; ARC tears down the old model.
@Observable
@MainActor
final class MessageDetailModelStore {
    struct Key: Hashable {
        let folderPath: String
        let uid: UInt32
    }

    private var current: (key: Key, model: MessageDetailViewModel)?

    /// Returns the cached model for `(folder, envelope)`, building it on
    /// miss. The `onFlagChanged` closure is only installed on the first
    /// (cache-miss) call; cache-hit callers receive the model with the
    /// closure already wired so their `@State`-driven setup path doesn't
    /// have to know whether the model is fresh.
    func model(
        for folder: Folder,
        envelope: Envelope,
        client: CabalmailClient,
        preferences: Preferences,
        onFlagChanged: @escaping @MainActor (Flag, Bool) -> Void
    ) -> MessageDetailViewModel {
        let key = Key(folderPath: folder.path, uid: envelope.uid)
        if let current, current.key == key { return current.model }
        let model = MessageDetailViewModel(
            folder: folder,
            envelope: envelope,
            client: client,
            preferences: preferences
        )
        model.onFlagChanged = onFlagChanged
        current = (key, model)
        return model
    }

    /// Drops the cached entry. Called from `MailRootView` when the
    /// envelope selection clears (e.g. user switches folders) so a
    /// stale model isn't held forever.
    func clear() {
        current = nil
    }
}
