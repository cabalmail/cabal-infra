import Foundation
import CoreSpotlight
import CabalmailKit

// Routes a tapped Spotlight result to the message it names, in one window
// (`DeepLinkRouter`). The searchable item's identifier encodes (folder, uid);
// the window that takes the result recovers the durable Message-ID from the
// envelope cache, so the list can still find a message another client has
// since moved.
//
// iOS and visionOS receive the result in a main window's
// `.onContinueUserActivity`, which knows its window. macOS never delivers it
// there (Apple Developer Forums thread 760522; the 2026-08-12 probe saw only
// the AppKit delegate callback), so the Mac `AppDelegate` opens it with no
// window, and it goes to the window last used.
extension AppState {
    /// Entry point for `.onContinueUserActivity(CSSearchableItemActionType)`.
    /// - Parameter window: the main window that received the result.
    public func handleSpotlightActivity(_ activity: NSUserActivity, in window: UUID? = nil) {
        guard let ref = SpotlightMessageRef(activity: activity) else { return }
        routeSpotlightRef(ref, in: window)
    }

    /// Opens a Spotlight result in `window`, else the window last used.
    /// Before a window can take it (a cold launch from search, or before
    /// sign-in) it parks in the router for the first window to open; a
    /// sign-out or another account's sign-in drops it.
    func routeSpotlightRef(_ ref: SpotlightMessageRef, in window: UUID? = nil) {
        deepLinks.open(.spotlight(ref), in: window)
    }
}

extension SpotlightMessageRef {
    /// The message a Spotlight result activity names; nil for an activity
    /// that is not one of ours.
    public init?(activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        self.init(string: identifier)
    }
}
