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

    /// Compact width (iPhone portrait), where `CompactSectionTabs` draws the tab bar
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

    // MARK: - Folding hosts

    /// How an iPhone Duo is being held, read off its active fold region.
    enum FoldPose: Equatable {
        /// No active fold: flat, closed, or not a folding host. Banners hang
        /// full-width at the bottom as everywhere else.
        case none
        /// Held like a book: the hinge runs top to bottom, the two pages sit
        /// side by side. Banners belong on the trailing page, where the HIG
        /// puts alerts — nearer where they will reappear on the outer display.
        case book
        /// Propped like a laptop: the hinge runs left to right, the top panel
        /// is the one seen at a distance. Banners belong there, just above
        /// the hinge, and off the bottom panel that holds the controls.
        case laptop
    }

    /// The pose, from the fold's frame in the window. Only an *active* fold
    /// counts: `reservedRegions` reports the flat device's hinge as an
    /// inactive, zero-width region, and a flat device is not a pose.
    static func pose(fold: CGRect?) -> FoldPose {
        guard let fold, fold.width > 0 || fold.height > 0 else { return .none }
        return fold.height >= fold.width ? .book : .laptop
    }

    /// Extra insets that keep the bottom-anchored banner off the fold
    /// (#1648): in book pose it is confined to the trailing page, in laptop
    /// pose it is lifted above the hinge onto the top panel. Zero elsewhere.
    /// The rest of the banner's placement (its horizontal margin, the
    /// tab-bar clearance) is unchanged and applies inside these.
    struct FoldInsets: Equatable {
        var leading: CGFloat = 0
        var bottom: CGFloat = 0
        /// The banner's width cap in book pose: the trailing page less the
        /// banner's own horizontal margins. Nil keeps the banner's default
        /// container-relative cap, which measures the whole window and would
        /// push the capsule back across the fold.
        var maxWidth: CGFloat?
    }

    /// The banner's horizontal margin, applied on both sides (`statusBanners`).
    static let horizontalMargin: CGFloat = 12

    static func foldInsets(fold: CGRect?, windowSize: CGSize) -> FoldInsets {
        guard let fold else { return FoldInsets() }
        switch pose(fold: fold) {
        case .none:
            return FoldInsets()
        case .book:
            return FoldInsets(
                leading: fold.maxX,
                maxWidth: max(0, windowSize.width - fold.maxX - 2 * horizontalMargin)
            )
        case .laptop:
            return FoldInsets(bottom: max(0, windowSize.height - fold.minY))
        }
    }
}
