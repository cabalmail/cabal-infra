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
    ///
    /// Two guards, because they answer different questions. `#available`
    /// is a runtime check on the device; it does not stop the compiler from
    /// needing the symbol. `visibilityPriority` first exists in the iOS 27 /
    /// macOS 26.1 SDKs, and CI's release legs build with the runner's stable
    /// Xcode — 26.6 with the iOS 26.5 SDK as of this writing — which has no
    /// such member, so the call must also be compiled out of older
    /// toolchains. Xcode 27 is the first to ship Swift 6.4, hence the
    /// compiler-version test; when the stable Xcode is 27, the `#if` is
    /// always true and can go.
    @ToolbarContentBuilder
    func keepsInBar() -> some ToolbarContent {
        #if (os(iOS) || os(macOS)) && compiler(>=6.4)
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

extension ToolbarContent {
    /// Like `keepsInBar()`, but ranked above every `keepsInBar()` item: the
    /// one control the bar must keep even when the frequent actions
    /// overflow. Used for the addresses inspector's `@` toggle while the
    /// inspector is open — on an iPhone Duo the column beside an open
    /// inspector is narrow enough that Compose and `@` both fold into the
    /// system overflow, which is inert on the 27.1 beta, and the inspector
    /// then cannot be closed until the device folds (#1670). Same guards as
    /// `keepsInBar()`, for the same reasons — except that the relative
    /// initialiser is macOS 27, a release later than the fixed priorities.
    @ToolbarContentBuilder
    func keepsInBarFirst() -> some ToolbarContent {
        #if (os(iOS) || os(macOS)) && compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *) {
            self.visibilityPriority(ToolbarItemVisibilityPriority(higherThan: .high))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
