import CoreGraphics

/// Where the app-wide status banners (offline, toasts, the launch resume
/// offer) hang from the top of the window. Pure, so the one number that
/// decides whether they clear the navigation bar is testable and carries its
/// measurement with it.
///
/// The banners are an overlay on the whole section layout, so their top edge
/// is the window's, not the navigation container's — they float in front of
/// whatever the navigation bar draws there. At compact width that is the bar's
/// centre title slot, which is exactly where a banner belongs: the back
/// chevron and the trailing buttons sit clear of it. At regular width the bar
/// spreads its trailing items across the same band, and a banner capped at 70%
/// of a 1194pt window covers all of them — on iPad the launch resume offer hid
/// New Message, Addresses and the search field for its whole ~60s life (#931).
/// Regular width therefore drops the banners below the bar, where they float
/// over the top of the list instead of over the controls.
enum StatusBannerPlacement {
    /// Compact iPhone, visionOS and macOS. macOS needs no allowance at all —
    /// its toolbar is window chrome above this overlay — and compact width
    /// wants the banner in the empty title slot, so both take the plain gap.
    static let defaultTopInset: CGFloat = 6

    /// Regular width (iPad, and an iPhone Plus/Max in landscape, which renders
    /// the same layout). Measured from the frames on #931: the trailing
    /// toolbar items occupy y 36…72pt, and the overlay's own origin sits at
    /// the top safe area, so 62 puts the capsule's top just below the bar with
    /// a few points to spare. Being a little out only moves a floating banner;
    /// it can't clip anything.
    static let regularWidthTopInset: CGFloat = 62

    static func topInset(isRegularWidth: Bool) -> CGFloat {
        isRegularWidth ? regularWidthTopInset : defaultTopInset
    }
}
