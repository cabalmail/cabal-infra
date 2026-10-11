import AppKit
import SwiftUI
import CabalmailUI

/// AppKit-level lookup for the main mail window (the `WindowGroup` scene
/// `CabalmailMacApp` declares with `mainWindowID`). Shared by the menu-bar
/// extra's "Open Cabalmail" item, the Settings window's end-of-session
/// handler and the deep-link router's opener, all of which want "bring the
/// existing window forward, only spawn a new one when none exists" rather
/// than `openWindow(id:)`'s unconditional new-window behavior on a
/// `WindowGroup`.
@MainActor
enum MainMailWindow {
    /// Look for an already-open main window and, if found, deminiaturize
    /// (if needed) and bring it forward. SwiftUI names WindowGroup
    /// windows with a `<id>-AppWindow-<n>` identifier — matched here by
    /// the group-id prefix, with an exact match as a defensive fallback
    /// in case the naming convention changes in a future SDK. Returns
    /// false when no main window exists (the user closed the last one),
    /// in which case the caller falls back to `openWindow(id:)`.
    static func bringToFront() -> Bool {
        for window in NSApp.windows {
            guard let identifier = window.identifier?.rawValue else { continue }
            guard identifier == mainWindowID
                || identifier.hasPrefix("\(mainWindowID)-") else { continue }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    /// Brings the main window forward, or opens one when the user has closed
    /// the last, and brings the app to the front.
    static func show(using openWindow: OpenWindowAction) {
        if !bringToFront() {
            openWindow(id: mainWindowID)
        }
        NSApp.activate()
    }

    /// Makes a link that arrives with every main window closed (a Spotlight
    /// result, a notification click) open a main window the way "Open
    /// Cabalmail" does, rather than wait for the next window the user opens
    /// (#2018). The router parks the link and calls this; the new window's
    /// navigator takes the link as it registers.
    static func opensForDeepLinks(using openWindow: OpenWindowAction) {
        DeepLinkRouter.shared.opensMainWindow = { MainMailWindow.show(using: openWindow) }
    }
}
