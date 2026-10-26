import SwiftUI

extension EnvironmentValues {
    /// Whether the system draws this window's bars in a vertical strip at
    /// one side, as an iPhone built against the iOS 27.1 SDK does on iPhone
    /// Duo's outer display, and on its inner display in a window wider than
    /// tall. Published by `verticalBars()` at a main window's root; false
    /// everywhere else, and on every host and SDK without vertical bars.
    ///
    /// A layout reads this, never the device: the strip comes and goes with
    /// the window's shape, and an app on the left of Split View gets it on
    /// the left (the spec's "read the bar edge, never assume right").
    @Entry var barsAreVertical = false
    /// The edge the strip is on while `barsAreVertical`, in the layout's own
    /// terms (it stays on the hardware's side in a right-to-left language,
    /// which is then the leading edge); nil otherwise.
    @Entry var verticalBarEdge: HorizontalEdge?
}

extension View {
    /// Publishes `\.barsAreVertical` and `\.verticalBarEdge` to everything
    /// beneath. Applied once, at the root of a main window
    /// (`SignedInRootView`), from the system's own reading of where its bars
    /// go (`toolbarVerticalEdge`, iOS 27.1), behind the same guards as the
    /// fold adapter (`FoldAPI`).
    func verticalBars() -> some View {
        modifier(VerticalBarsModifier())
    }
}

#if os(iOS) && canImport(SwiftUICore, _version: 8.0.85)
private struct VerticalBarsModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(VerticalBarsReader())
        } else {
            content
        }
    }
}

/// A stored property can't be marked `@available`, so the 27.1 environment
/// read lives in a type that is.
@available(iOS 27.1, *)
private struct VerticalBarsReader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge

    func body(content: Content) -> some View {
        content
            .environment(\.barsAreVertical, edge != nil)
            .environment(\.verticalBarEdge, edge)
    }
}
#else
/// No vertical bars on this SDK or platform.
private struct VerticalBarsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}
#endif
