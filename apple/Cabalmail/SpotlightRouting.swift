import Foundation
import CoreSpotlight
import CabalmailKit

// Routes a tapped Spotlight result to the message it names.
//
// Both app entries attach `.onContinueUserActivity(CSSearchableItemActionType)`
// and forward the activity here. The searchable item's identifier encodes
// (folder, uid); the durable Message-ID is recovered from the envelope cache
// at routing time so the existing `navigateRequest` machinery can fall back
// to its Message-ID match if another client has since moved the message.
// Compiled into the iOS/visionOS and macOS app targets (listed explicitly in
// the CabalmailMac sources — see project.yml).
extension AppState {
    /// Entry point for `.onContinueUserActivity(CSSearchableItemActionType)`.
    func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard
            let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let ref = SpotlightMessageRef(string: identifier)
        else { return }
        routeSpotlightRef(ref)
    }

    /// Drives the same `navigateRequest` machinery as a push-notification
    /// tap. Before the session is wired (cold launch from a Spotlight
    /// result) the ref parks on `pendingSpotlightRef` and `wireSession`
    /// re-routes it — `MailRootView` drains a pre-mount request from its
    /// `.task`, so parking works even before any view exists.
    func routeSpotlightRef(_ ref: SpotlightMessageRef) {
        guard let coordinator = navCoordinator, let client else {
            pendingSpotlightRef = ref
            return
        }
        Task { @MainActor in
            let messageID = await client.envelopeCache
                .snapshot(for: ref.folder)?
                .envelopes[ref.uid]?
                .messageId
            coordinator.navigateRequest = NavState(
                folder: ref.folder,
                messageID: messageID,
                uid: ref.uid,
                clientID: coordinator.clientID
            )
        }
    }

    /// Replays a Spotlight tap that arrived before sign-in / restore
    /// completed. Called at the end of `wireSession`.
    func routePendingSpotlightOpen() {
        guard let ref = pendingSpotlightRef else { return }
        pendingSpotlightRef = nil
        routeSpotlightRef(ref)
    }
}
