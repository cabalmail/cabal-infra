import SwiftUI

extension ToolbarContent {
    /// Marks a toolbar item as one the bar should give up last.
    ///
    /// A bar that runs out of room folds items into an overflow menu; on
    /// iPhone Duo the bars are vertical strips shared with the status bar,
    /// so that happens far sooner than on a horizontal bar — most of all on
    /// the outer display in landscape, or with the keyboard up — and items
    /// overflow bottom-to-top with no regard for how often they are used.
    /// `visibilityPriority(.high)` is the system's knob for "keep this one";
    /// it is what Apple's Duo guidance prescribes for the frequent actions
    /// (Compose, Reply) and for badged status items. On macOS 26.1+ the same
    /// priority steers the "more toolbar items" (») popup, which is the
    /// crowding #1047 dealt with by ordering.
    ///
    /// A no-op before iOS 27 / macOS 26.1, and on visionOS, where the
    /// priority values are unavailable — the item simply keeps its default.
    @ToolbarContentBuilder
    func keepsInBar() -> some ToolbarContent {
        #if os(iOS) || os(macOS)
        if #available(iOS 27.0, macOS 26.1, *) {
            self.visibilityPriority(.high)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
