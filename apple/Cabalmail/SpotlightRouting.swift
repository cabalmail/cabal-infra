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

/// Bridges the AppKit `application(_:continue:restorationHandler:)` callback
/// to `AppState` on macOS. SwiftUI's `.onContinueUserActivity` never fires
/// for `CSSearchableItemActionType` on macOS (Apple Developer Forums thread
/// 760522; also observed in the 2026-08-12 probe — only the AppKit delegate
/// callback delivered the activity), so the macOS `AppDelegate` branch hands
/// activities here. The SwiftUI modifier stays attached in both app entries:
/// it is the working path on iOS/visionOS and harmless redundancy on macOS.
///
/// A singleton (like `PushRegistrar` / `IntentBridge`) because the delegate
/// exists before the SwiftUI tree: an activity from a cold Spotlight-result
/// launch can arrive before `attach(_:)` runs, so it parks here; AppState's
/// own `pendingSpotlightRef` covers the later not-yet-signed-in window.
@MainActor
final class SpotlightRouter {
    static let shared = SpotlightRouter()

    private(set) weak var appState: AppState?
    private var pendingActivity: NSUserActivity?

    /// Called from the app entry's `.task` as soon as the root AppState
    /// exists; replays a parked cold-launch activity.
    func attach(_ appState: AppState) {
        self.appState = appState
        guard let activity = pendingActivity else { return }
        pendingActivity = nil
        appState.handleSpotlightActivity(activity)
    }

    func handle(_ activity: NSUserActivity) {
        guard let appState else {
            pendingActivity = activity
            return
        }
        appState.handleSpotlightActivity(activity)
    }
}
