import SwiftUI

#if os(macOS)
extension View {
    /// The Mac's `brandMarkTitle`: nothing. A Mac window has no navigation
    /// title for the Cabalmail mark to stand in for — the desktop shell heads
    /// its sidebar with the mark instead — so the shared sidebar column's
    /// call compiles here and draws what it always has (`SidebarBranding.swift`
    /// draws the touch platforms' mark).
    func brandMarkTitle(size: CGFloat, accessibilityTitle: String = "Folders") -> some View {
        self
    }
}
#endif
