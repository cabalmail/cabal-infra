import SwiftUI

#if !os(macOS)
/// The compact-width floating tab bar (iOS 26 glass capsules) reserves a
/// full-width tray at the bottom of the screen but only draws the capsules;
/// the margins around them — the screen edges, the gap between the two
/// capsules, and the strip below — are transparent AND touch-transparent.
/// List rows showing through those margins scroll and open on touch, which
/// reads as a misfire: the tray looks like chrome, so touches there should
/// do nothing.
///
/// `tabBarTrayShield()` overlays a transparent UIKit view over the tab's
/// content that claims (and drops) touches inside the reserved band while
/// passing everything above it through. Rows behind the tray stay visible
/// for context but are no longer interactive.
///
/// Applied per tab INSIDE the `TabView` — the tab bar is system chrome
/// hosted above each tab's content, so the shield can never intercept the
/// capsules or the search morph. An overlay on the `TabView` itself would
/// sit above that chrome and deaden the bar.
extension View {
    func tabBarTrayShield() -> some View {
        overlay { TrayShield().ignoresSafeArea() }
    }
}

/// Full-screen transparent view whose hit test claims only the tab bar's
/// reserved bottom band. UIKit-level rather than a SwiftUI gesture so it
/// beats the list's scroll-view pan recognizer outright — the touch never
/// reaches the collection view at all.
private struct TrayShield: UIViewRepresentable {
    func makeUIView(context: Context) -> TrayShieldUIView { TrayShieldUIView() }
    func updateUIView(_ uiView: TrayShieldUIView, context: Context) {}
}

private final class TrayShieldUIView: UIView {
    /// Claim points inside the tray band; pass everything else through.
    ///
    /// The band is read live from `safeAreaInsets`, so it tracks the bar's
    /// actual reserved height across devices, orientations, and appearance
    /// changes for free. The window comparison keeps the shield inert
    /// wherever the bar is hidden (`MessageDetailView` hides it for the
    /// reader): with no bar, this view's bottom inset collapses to the
    /// window's own home-indicator inset and nothing may be blocked.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let window else { return false }
        let band = safeAreaInsets.bottom
        guard band > window.safeAreaInsets.bottom else { return false }
        return point.y >= bounds.height - band
    }
}
#endif
