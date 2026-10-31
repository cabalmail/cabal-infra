import SwiftUI

extension ToolbarItemPlacement {
    /// The bar along the bottom edge of a navigation stack: iOS and
    /// visionOS's bottom bar. macOS has none; nothing draws there (compose's
    /// bottom bar is laptop pose's, `ComposeToolbar`), but the toolbar that
    /// names it compiles everywhere.
    static var bottomEdge: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .bottomBar
        #endif
    }
}
