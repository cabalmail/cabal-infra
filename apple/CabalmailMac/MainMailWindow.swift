import AppKit

/// AppKit-level lookup for the main mail window (the `WindowGroup` scene
/// `CabalmailMacApp` declares with `mainWindowID`). Shared by the menu-bar
/// extra's "Open Cabalmail" item and the Settings window's end-of-session
/// handler, both of which want "bring the existing window forward, only
/// spawn a new one when none exists" rather than `openWindow(id:)`'s
/// unconditional new-window behavior on a `WindowGroup`.
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
}
