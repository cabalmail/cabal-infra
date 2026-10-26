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
///
/// On a folded iPhone Duo the bottom of the window is not always the place:
/// `slot(in:column:hasControls:)` keeps every banner off the crease.
enum StatusBannerPlacement {
    /// Regular width (the iPad split, macOS, visionOS) — none of these draws
    /// a bottom tab bar in the overlay's band, so the banner takes the plain
    /// gap above the safe area.
    static let defaultBottomInset: CGFloat = 6

    /// Compact width (iPhone portrait), where `TabShell` draws the tab bar
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

    /// The inset on a window's layout shell. Only the tabs draw a bar across
    /// the bottom band — including an iPhone Plus / Max in landscape, whose
    /// width is regular but whose shell is still the tabs. visionOS's tab bar
    /// is a leading ornament, clear of the band.
    static func bottomInset(in layout: ShellLayout) -> CGFloat {
        bottomInset(isRegularWidth: layout != .tabs)
    }

    /// The part of a window a status banner hangs from the bottom of.
    enum Slot: Hashable, Sendable {
        /// The whole overlay: no fold crosses it.
        case whole
        /// The leading piece of a book fold (the list's).
        case leadingPiece
        /// The trailing piece of a book fold (the reader's).
        case trailingPiece
        /// Above a laptop fold.
        case aboveCrease
        /// Below a laptop fold.
        case belowCrease
    }

    /// Where a banner goes under the iPhone Duo spec's fold rule: nothing
    /// Cabalmail draws sits on the crease, a floating element sits with the
    /// column that raised it, and nothing tappable sits above a laptop fold.
    ///
    /// - With no fold across the overlay, the whole of it, as always.
    /// - A vertical crease (book pose): the piece of the column that raised
    ///   the banner. The list is the split's leading column, so its piece is
    ///   the leading one; the reader's, and that of every banner that belongs
    ///   to the window rather than a column (`column` nil), is the trailing
    ///   one.
    /// - A horizontal crease (laptop pose): below it for a banner with
    ///   anything to tap (an action, or a close button), above it for one
    ///   that only reports a state (offline).
    ///
    /// - Parameters:
    ///   - pieces: the overlay's bounds less the window's fold, once settled
    ///     (`onFoldPiecesChange(_:)`).
    ///   - column: the column that raised the banner, or nil for the
    ///     window's own.
    ///   - hasControls: the banner has a button or can be swiped away.
    static func slot(in pieces: FoldPieces, column: Toast.Column?, hasControls: Bool) -> Slot {
        switch pieces {
        case .whole: return .whole
        case .sideBySide: return column == .list ? .leadingPiece : .trailingPiece
        case .stacked: return hasControls ? .belowCrease : .aboveCrease
        }
    }

    /// The frame of `slot` in the overlay's own coordinates, or nil when
    /// `pieces` has no such part.
    static func frame(of slot: Slot, in pieces: FoldPieces) -> CGRect? {
        switch (slot, pieces) {
        case (.whole, .whole(let bounds)): return bounds
        case (.leadingPiece, .sideBySide(let leading, _)): return leading
        case (.trailingPiece, .sideBySide(_, let trailing)): return trailing
        case (.aboveCrease, .stacked(let top, _)): return top
        case (.belowCrease, .stacked(_, let bottom)): return bottom
        default: return nil
        }
    }

    /// The gap under banners that sit on a horizontal crease: the plain gap,
    /// since no bar comes between them and the fold. Everywhere else the
    /// banners' bottom is the window's, and `bottomInset(in:)` holds.
    static func bottomInset(of slot: Slot, windowBottomInset: CGFloat) -> CGFloat {
        slot == .aboveCrease ? defaultBottomInset : windowBottomInset
    }
}
