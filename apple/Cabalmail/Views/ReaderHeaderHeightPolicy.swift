import CoreGraphics

/// How tall the reader's scrollable header block may be, given what it
/// actually needs and how much room the pane has. A pure rule rather than an
/// inline `.frame(maxHeight:)` so it can be tested directly — the view's
/// geometry isn't reachable from a unit test, this is.
enum ReaderHeaderHeightPolicy {
    /// The most of the pane the header may claim. Beyond this the reading
    /// area starts to disappear, so a pathological header (a subject that
    /// wraps five times, a sprawling Cc list) scrolls inside the block
    /// instead of pushing the body off screen.
    static let maxPaneFraction: CGFloat = 0.45

    /// - Parameters:
    ///   - contentHeight: the header's measured ideal height; `<= 0` means
    ///     it hasn't been measured yet.
    ///   - paneHeight: the height available to the whole reader.
    static func height(contentHeight: CGFloat, paneHeight: CGFloat) -> CGFloat {
        // No pane to divide up yet: ask for exactly what the content needs.
        guard paneHeight > 0 else { return max(contentHeight, 0) }
        let cap = paneHeight * maxPaneFraction
        // Before the first measurement, take the cap rather than zero — a
        // zero-height header would collapse the block on the first layout
        // pass.
        guard contentHeight > 0 else { return cap }
        return min(contentHeight, cap)
    }
}
