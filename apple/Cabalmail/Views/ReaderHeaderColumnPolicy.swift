import CoreGraphics

/// Whether the reader's header sets its date, authentication chips, and
/// custom-flag chips in a trailing column beside the sender lines instead of
/// stacked under them. On a short, wide pane (an iPhone in landscape) the
/// stacked rows are height the message body never gets back. A pure rule, like
/// `ReaderHeaderHeightPolicy`, so it can be tested without a view hierarchy.
enum ReaderHeaderColumnPolicy {
    /// The narrowest pane that gets the trailing column, at the default type
    /// size: about three times the width of a standard three-chip
    /// authentication row. A fixed ruler rather than a measurement of the live
    /// chips — those change width with the verdict ("pass" / "softfail") and
    /// are absent entirely for "Not verified", which would move the break
    /// point from one message to the next in the same pane. The view scales
    /// this with Dynamic Type (`@ScaledMetric`) before asking.
    static let baseMinPaneWidth: CGFloat = 650

    /// The most of the pane the trailing column may claim. The date and the
    /// authentication chips never get near it; it exists for a message
    /// carrying many custom flags, whose chips wrap at this width instead of
    /// squeezing the recipient lines.
    static let trailingColumnMaxFraction: CGFloat = 0.4

    /// - Parameters:
    ///   - paneWidth: the width available to the whole reader; `<= 0` means
    ///     it hasn't been laid out yet.
    ///   - minPaneWidth: `baseMinPaneWidth`, scaled for the current type size.
    static func usesTrailingColumn(paneWidth: CGFloat, minPaneWidth: CGFloat) -> Bool {
        paneWidth > 0 && paneWidth >= minPaneWidth
    }

    static func trailingColumnMaxWidth(paneWidth: CGFloat) -> CGFloat {
        max(paneWidth, 0) * trailingColumnMaxFraction
    }
}
