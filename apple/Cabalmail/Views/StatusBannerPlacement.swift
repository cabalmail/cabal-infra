import CoreGraphics

/// Where the app-wide status banners (offline, toasts, the launch resume
/// offer) hang from the top of the window. Pure, so the one number that
/// decides whether they clear the navigation bar is testable and carries its
/// measurement with it.
///
/// The banners are an overlay on the whole section layout, so their top edge
/// is the window's, not the navigation container's — they float in front of
/// whatever the navigation bar draws there. At regular width the bar spreads
/// its trailing items across that band, and a banner capped at 70% of a
/// 1194pt window covers all of them — on iPad the launch resume offer hid New
/// Message, Addresses and the search field for its whole ~60s life (#931). At
/// compact width the band holds the centre title slot, which carries the
/// current folder name: the banner hid it for its whole life on iPhone, so on
/// landing you could not tell which folder you were in (#958).
///
/// Both iOS widths therefore drop the banners below the bar, where they float
/// over the top of the list instead of over the bar's contents.
enum StatusBannerPlacement {
    /// visionOS and macOS, neither of which draws a navigation bar in this
    /// overlay's band — macOS's toolbar is window chrome above it — so both
    /// take the plain gap.
    static let defaultTopInset: CGFloat = 6

    /// Compact width (iPhone portrait). Measured from the frames on #958: the
    /// overlay's origin is the top safe area (y 62 on an iPhone 16 Pro, where
    /// the 6pt gap put the capsule's top at 68) and the navigation bar runs
    /// from there to y 116, so 60 clears the bar by the same few points the
    /// regular-width inset leaves. The number is the bar's height plus that
    /// gap, not a per-device constant: the bar starts at the safe area on
    /// every compact screen, so the two move together.
    static let compactWidthTopInset: CGFloat = 60

    /// Regular width (iPad, and an iPhone Plus/Max in landscape, which renders
    /// the same layout). Measured from the frames on #931: the trailing
    /// toolbar items occupy y 36…72pt, and the overlay's own origin sits at
    /// the top safe area, so 62 puts the capsule's top just below the bar with
    /// a few points to spare. Being a little out only moves a floating banner;
    /// it can't clip anything.
    static let regularWidthTopInset: CGFloat = 62

    static func topInset(isRegularWidth: Bool) -> CGFloat {
        isRegularWidth ? regularWidthTopInset : compactWidthTopInset
    }
}
