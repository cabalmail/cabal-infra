import SwiftUI

extension View {
    /// Places the sheet this view is the content of on the presenting
    /// window's trailing side while `trailing`, and where the system puts it
    /// otherwise.
    ///
    /// `presentationPlacement(_:)` is iOS 27.0, and its `.trailing` does not
    /// exist on macOS or visionOS (the SDK marks it unavailable there), hence
    /// the `os(iOS)` and the compiler test (docs/apple.md, "Where Duo API
    /// code may live"). Before iOS 27, and on every other platform, the
    /// sheet keeps the system's placement. The modifier is always applied
    /// and only its value changes, so a window turning from wide to tall
    /// moves the sheet without rebuilding what it holds.
    ///
    /// On the iPhone Duo's inner display a trailing sheet's bar is vertical,
    /// a strip down its outer edge, where a centred one keeps a horizontal
    /// bar (Apple's "Raise the bar with iPhone Duo").
    func sheetPlacement(trailing: Bool) -> some View {
        modifier(SheetPlacementModifier(trailing: trailing))
    }
}

private struct SheetPlacementModifier: ViewModifier {
    let trailing: Bool

    func body(content: Content) -> some View {
        #if os(iOS) && compiler(>=6.4)
        if #available(iOS 27.0, *) {
            content.presentationPlacement(trailing ? .trailing : .automatic)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
