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
        let storeID = String(UInt(bitPattern: ObjectIdentifier(self)), radix: 16)
        // Log entry state so we can distinguish "current was nil at entry"
        // from "current.key != lookup key". The previous diagnostic only
        // logged the *post-write* key, which couldn't tell those apart.
        let entryKey = current.map { "\($0.key.folderPath)#\($0.key.uid)" } ?? "nil"
        let entryModelID = current.map { String(UInt(bitPattern: ObjectIdentifier($0.model)), radix: 16) } ?? "nil"
        BodyFetchLog.storeEntry(uid: envelope.uid, storeID: storeID,
                                lookupKey: "\(key.folderPath)#\(key.uid)",
                                entryKey: entryKey, entryModelID: entryModelID)
        if let current, current.key == key {
            let modelID = String(UInt(bitPattern: ObjectIdentifier(current.model)), radix: 16)
            BodyFetchLog.storeLookup(
                uid: envelope.uid, storeID: storeID, hit: true,
                modelID: modelID, currentKey: "\(current.key.folderPath)#\(current.key.uid)"
            )
            return current.model
        }
        let model = MessageDetailViewModel(
            folder: folder,
            envelope: envelope,
            client: client,
            preferences: preferences
        )
        model.onFlagChanged = onFlagChanged
        current = (key, model)
        let modelID = String(UInt(bitPattern: ObjectIdentifier(model)), radix: 16)
        let currentKey = "\(key.folderPath)#\(key.uid)"
        BodyFetchLog.storeLookup(
            uid: envelope.uid, storeID: storeID, hit: false,
            modelID: modelID, currentKey: currentKey
        )
        return model
    }

    /// Drops the cached entry. Called from `MailRootView` when the
    /// envelope selection clears (e.g. user switches folders) so a
    /// stale model isn't held forever.
    func clear() {
        current = nil
    }
}
