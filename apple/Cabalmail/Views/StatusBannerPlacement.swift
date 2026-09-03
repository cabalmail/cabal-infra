import CoreGraphics

/// Where the app-wide status banners (offline, toasts, the launch resume
/// offer) hang. Pure, so the one number that decides what they can cover is
/// testable and carries its measurement with it.
///
/// They used to hang from the *top*, and the whole history of this type is
/// what that cost. The banners are an overlay on the entire section layout, so
/// their edge is the window's, not the navigation container's — at regular
/// width the navigation bar spreads its trailing items across the top band and
/// a banner capped at 70% of a 1194pt window covered all of them (#931: the
/// resume offer hid New Message, Addresses and the search field for its whole
/// life); at compact width that band holds the centre title slot carrying the
/// current folder name (#958: on landing you could not tell which folder you
/// were in). Both were fixed by dropping the banners below the bar, and then
/// #1426 reported the next thing down: the banner covered the filter pills and
/// clipped the top of the first message row — the message the user opened the
/// app to read.
///
/// So the banners now hang from the **bottom**, as they do on the Android
/// client, where a user reading the top of a list can ignore them. That closes
/// #931 and #958 by construction rather than by arithmetic: nothing the app
/// draws in the top band can be covered by a banner that is not there.
///
/// The one thing the bottom band does hold is the compact-width tab bar, which
/// is what these numbers now clear.
enum StatusBannerPlacement {
    /// Regular width (iPad, macOS, visionOS, and an iPhone Plus/Max in
    /// landscape) — none of these draws a bottom tab bar in the overlay's
    /// band, so the banner takes the plain gap above the safe area.
    static let defaultBottomInset: CGFloat = 6

    /// Compact width (iPhone portrait), where `compactTabs` draws the tab bar
    /// across the bottom of the window. Measured live on an iPhone 17 (window
    /// 874pt tall): the tab bar occupies {{0, 791}, {402, 83}}, and with this
    /// inset applied the banner's own close button lands at
    /// {{314.7, 741.7}, {15, 15}} — so the capsule ends around y 765, roughly
    /// 26pt clear of the bar. That puts the overlay's own bottom edge at about
    /// y 822 rather than at the window's bottom safe area, which is why the
    /// number is not simply the bar's height: read it as "measured to clear the
    /// bar", not as arithmetic. Being a little generous only floats the banner
    /// higher, and it cannot clip anything.
    static let compactWidthBottomInset: CGFloat = 57

    static func bottomInset(isRegularWidth: Bool) -> CGFloat {
        isRegularWidth ? defaultBottomInset : compactWidthBottomInset
    }
}
