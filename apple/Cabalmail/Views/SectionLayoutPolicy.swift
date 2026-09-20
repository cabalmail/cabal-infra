import CoreGraphics
import Foundation

/// Which section layout the signed-in root should draw on iOS: the compact
/// bottom tab bar (Mail / Feeds / Addresses / Settings / Search) or the
/// iPad-style single-sidebar split. A pure rule rather than an inline `if` so
/// it can be tested — `SignedInRootView` reads the environment, this doesn't.
///
/// The decision is by **both size classes**: the split needs a regular width
/// *and* a regular height; anything else gets the tabs. Neither the device
/// idiom nor the orientation takes part, which is what Apple asks for on
/// iPhone Duo ("don't use `userInterfaceIdiom` or `UIInterfaceOrientation`
/// for layout decisions").
///
/// The rule used to be idiom first, size class second, and before that size
/// class (width) alone. Width alone is a rotation bug on the Plus / Max
/// iPhones: they report a *regular* horizontal size class in landscape, so
/// turning the phone swapped the whole tab tree for the split view. The two
/// layouts are separate view trees with separate `@State` selections, so the
/// rotation threw away the Feeds tab and whatever was open in it, and landed
/// the user on the mail split's launch landing — the INBOX. Rotating back
/// rebuilt the tabs from scratch, at the resume session's landing rather than
/// where the user had been. The idiom check fixed that, but it also pinned
/// every phone to the tab tree forever — including iPhone Duo's inner display,
/// which reports the phone idiom *and* a regular/regular size class, and
/// which exists precisely to show a sidebar-plus-list-plus-reader split.
/// Requiring both size classes to be regular keeps the Plus / Max fix (their
/// landscape is regular width, *compact* height) and lets Duo's inner display
/// take the split. Nothing else changes: an iPad is regular in both or compact
/// width, and every other iPhone is compact width in every orientation.
///
/// Opening or closing a Duo therefore switches trees (regular/regular inside,
/// compact width outside), which is the same state hand-off problem the
/// rotation bug was. That is deliberate — the alternative is a phone layout
/// on a 7.6-inch display — and the selection hand-off between the trees is
/// tracked separately.
///
/// Keeping the *section* layout on the tabs turned out to be only half of the
/// rotation story. Everything inside the tabs still read the raw size class,
/// and the Mail tab's `NavigationSplitView` expanded into tiled columns
/// whenever a Plus / Max went landscape, then collapsed again on the way
/// back. That expand/collapse cycle is where the "wider screen" bugs live:
/// after it, the collapsed split could stop pushing the reader for a tapped
/// row (the message loaded into a detail column that wasn't on screen), and
/// the addresses inspector hung on the split — a trailing column at regular
/// width, a sheet at compact — could surface as a full-height sheet over the
/// tab bar with no way out but a force quit. So the tab tree also pins the
/// *environment* size class to compact for everything beneath it: the split
/// view never expands, the inspector never changes presentation, and every
/// size-class read below (list drag-to-folder, the reader's action bar) sees
/// the same answer in both orientations. The pin is unconditional inside the
/// tab tree: a regular width can only reach it with a compact height (a
/// Plus / Max in landscape), which is exactly the case it exists for, and a
/// compact-width host (any other phone, Duo's outer display, a narrow iPad
/// window) is compact already. The cost is the two-column list-plus-reader a
/// Max used to show in landscape; the phone reads like a phone in every
/// orientation.
enum SectionLayoutPolicy {
    enum Layout: Equatable {
        /// `CompactSectionTabs`: the bottom tab bar.
        case compactTabs
        /// `MailRootView` alone, with the settings gear and sheet.
        case regularSplit
    }

    /// - Parameters:
    ///   - isCompactWidth: `horizontalSizeClass == .compact`.
    ///   - isCompactHeight: `verticalSizeClass == .compact`.
    static func layout(isCompactWidth: Bool, isCompactHeight: Bool) -> Layout {
        layout(isCompactWidth: isCompactWidth, isCompactHeight: isCompactHeight, measuredWidth: nil)
    }

    /// No iOS window narrower than this carries the regular width class:
    /// the widest compact windows are an 11-inch iPad's half-screen Split
    /// View (507 pt) and iPhone Duo's outer display (466 pt); the narrowest
    /// regular ones are a 12.9-inch iPad's half (683 pt) and a Max iPhone in
    /// landscape (926 pt).
    static let regularWidthFloor: CGFloat = 600

    /// `measuredWidth` is the window width the tree was last laid out at,
    /// nil (or zero) before the first layout. A regular width class paired
    /// with a measurement below `regularWidthFloor` means the traits have
    /// changed before the bounds: iPhone Duo unfolding, or an iPad leaving
    /// Split View, deliver the new size classes first, and a split view
    /// built in that gap decides between tiling its columns and floating the
    /// list over the reader against the old, narrow bounds. UIKit revisits
    /// that decision only on the next size transition, so the reader stayed
    /// under the list until the device was folded again (#1679). Holding the
    /// compact tree for that one layout pass lets the split come up against
    /// the bounds it will actually have.
    static func layout(isCompactWidth: Bool, isCompactHeight: Bool, measuredWidth: CGFloat?) -> Layout {
        if isCompactWidth || isCompactHeight { return .compactTabs }
        if let measuredWidth, measuredWidth > 0, measuredWidth < regularWidthFloor { return .compactTabs }
        return .regularSplit
    }

    /// Whether the reader should hide the section `TabView`'s bar while a
    /// message is open.
    ///
    /// True on iOS: the reader uses the full bottom edge for its action
    /// toolbar, which the compact tab bar would otherwise occlude, and a swipe
    /// back to the message list brings the bar straight back. At regular width
    /// there is no section tab bar at all (those sections live in the Settings
    /// sheet), so hiding it is a no-op.
    ///
    /// False on visionOS, where the same `TabView` is drawn as the window's
    /// leading *ornament* (`VisionSectionView`) rather than a bottom bar: it
    /// competes with nothing, and it is the only route to Folders, Feeds,
    /// Addresses, Settings and Search. Hiding it strands the user in the
    /// reader — the regular-width split always has a reader, there is no
    /// in-app way to get back to "No message selected", and the resume
    /// restore re-opens the message on the next launch, so the tabs stay gone
    /// across a relaunch too.
    ///
    /// - Parameter isVisionOS: whether the host is visionOS
    ///   (`SectionLayoutPolicy.isVisionOS`).
    static func readerHidesSectionTabBar(isVisionOS: Bool) -> Bool {
        !isVisionOS
    }

    /// The host platform, as a value rather than a `#if`, so the rules above
    /// can be exercised for both answers on whichever platform the tests run.
    #if os(visionOS)
    static let isVisionOS = true
    #else
    static let isVisionOS = false
    #endif
}
