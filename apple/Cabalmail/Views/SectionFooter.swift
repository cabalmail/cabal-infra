import SwiftUI

extension View {
    /// Lets a `Section` footer wrap instead of truncating mid-sentence.
    ///
    /// Two things clamp a footer to one line on macOS, and clearing either
    /// alone leaves it truncated (measured, #1300): the row applies a
    /// single-line limit, and it proposes a single line's height. So the
    /// footer needs both — `lineLimit(nil)` to be allowed more than one line,
    /// and `fixedSize` to report the ideal height those lines need rather
    /// than accepting the row's proposal. The rules list's footer measured
    /// 528x14 with neither and 503x28 with both, on macOS 26 and 27 alike.
    ///
    /// Applied to every section footer rather than only the ones that
    /// overflow today: whether a string fits is a fact about the container's
    /// width, and the macOS Settings window is size-locked, so a footer that
    /// fits is one wording away from not fitting.
    func sectionFooter() -> some View {
        lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}
