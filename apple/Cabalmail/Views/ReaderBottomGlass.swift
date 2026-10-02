import SwiftUI

extension View {
    /// Runs reader content under the bottom bar so the Liquid Glass shows it
    /// through, instead of the strip of window background that otherwise sits
    /// behind the bar. Applied to a `WKWebView` host: WebKit insets the
    /// scroll content by the view's UIKit safe area, so the last line still
    /// scrolls clear of a UIKit bar (the compact tab bar). Never use it under
    /// a SwiftUI `safeAreaInset` bar, which a bridged web view does not see.
    ///
    /// iOS 26 and later only. Before 26 the bars keep their transparent
    /// scroll-edge look, because UIKit cannot find the web view's scroll view
    /// to track, so the tab icons would draw straight over the text. macOS
    /// and visionOS have no bottom bar for content to run under.
    ///
    /// A runtime check, not a compile-time one: one binary serves iOS 18
    /// through 27.
    @ViewBuilder
    func underBottomGlass(_ enabled: Bool) -> some View {
        #if os(iOS)
        if enabled, #available(iOS 26.0, *) {
            ignoresSafeArea(.container, edges: .bottom)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
