import Foundation
import CabalmailKit

/// Compose-routing + onboarding helpers split out of `AppState.swift`
/// so that file stays under the SwiftLint length cap. Storage stays on
/// `AppState` — only the helper methods live here.
///
/// The compose-seed helpers (`requestCompose(seed:)` /
/// `consumePendingComposeSeed`) plumb a pre-filled draft from the
/// `mailto:` URL handler through to `MessageListView`'s receiver
/// without bypassing the existing `composeRequestTick` mechanism that
/// macOS menu shortcuts already use. The contacts-access helper
/// kicks off the system permission prompt during sign-in / restore.
@MainActor
extension AppState {
    /// Variant of `requestCompose` that pairs an explicit seed with
    /// the request. Used by the mailto: URL handler; menu shortcuts
    /// and toolbar buttons continue to call the zero-arg form, which
    /// leaves `pendingComposeSeed` nil and lets the receiver fall
    /// back to a fresh draft.
    func requestCompose(seed: Draft) {
        pendingComposeSeed = seed
        composeRequestTick += 1
    }

    /// Reads and clears the pending compose seed. Called by the
    /// compose-request receiver in `MessageListView` both on
    /// `.onChange(of: composeRequestTick)` (warm path) and on the
    /// view's initial `.task` (cold-launch mailto: arrived before the
    /// view was in the hierarchy).
    func consumePendingComposeSeed() -> Draft? {
        defer { pendingComposeSeed = nil }
        return pendingComposeSeed
    }

    /// Kick off a one-shot contacts authorization request,
    /// fire-and-forget. `CNContactStore.requestAccess` no-ops after
    /// the user has already responded, so calling this on every
    /// sign-in / restore is harmless. We prompt at sign-in (rather
    /// than lazily on first compose / message open) so the request
    /// lands while the user is already in onboarding mode and the
    /// message list that immediately follows shows hydrated names
    /// from the first paint.
    func requestContactsAccessIfNeeded() {
        let store = contactsStore
        Task {
            _ = await store.requestAccess()
        }
    }
}
