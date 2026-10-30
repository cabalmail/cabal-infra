import Foundation

/// The reader toolbar's budgets and placement, for both readers. The mail
/// reader lays its actions out in `ReaderToolbarLayout`, which sizes its bars
/// from the budgets here; the feed reader lays its out in
/// `FeedReaderToolbarLayout`, whose touch bar is held to `topBarCapacity` by
/// test. Both readers ask `placement(for:...)` which bar carries their actions,
/// and `bodyRunsUnderBottomBar(for:isRegularWidth:)` whether their body runs
/// under the bottom bar, which follows the width alone. A new SDK's folding is
/// answered here, in one place.
///
/// On the touch platforms the bar sizes itself to its content, and past a
/// certain item count the system takes over: on the iOS 27 SDK it silently
/// folds the tail into its own `ToolbarOverflowBarButtonItem`, which swallowed
/// Reader view and Archive/Delete Forever outright and nested our `…` menu a
/// tap deeper. Seven items fit on the iOS 26 SDK with about 2pt to spare at
/// 402pt (measured), so the previous ceiling was never a ceiling — it was the
/// bar being exactly full. Demoting to `capacity` keeps every action
/// addressable regardless of which SDK compacts at what width.
enum ReaderToolbarPolicy {
    /// Items the bottom bar draws before the system starts compacting —
    /// measured on the iOS 27 SDK at 402pt, where four app buttons plus the
    /// system's overflow control were what rendered. Bottom bar only: the
    /// compact navigation bar also seats the back button and has its own
    /// budget, `topBarCapacity`.
    static let capacity = 5

    /// Items the compact navigation bar carries beside the back button.
    /// Not measured on a device: derived from the bottom bar's five slots at
    /// 402pt on the iOS 27 SDK, less one for the back button, and from the
    /// feed reader, whose three items plus a title are known to fit. The iOS
    /// 27 SDK pads each bar item wider than 26 did, and anything past the
    /// budget folds into a system overflow that this repo has found inert
    /// (#1626, #1670), so the set stays at four rather than reusing the
    /// bottom bar's five.
    static let topBarCapacity = 4

    /// Narrowest pane at which the mail reader's own bar draws all seven
    /// actions. Derived from the density that shipped on the iPhone system
    /// bar — five items across the measured 402pt is ~80pt of bar per item —
    /// so seven items must have at least that much room before the demoted
    /// toggles come back.
    static let fullSetMinWidth: CGFloat = 560

    /// Which reader the actions belong to.
    enum Medium: Equatable {
        case mail
        case feeds
    }

    /// Where a reader's touch action set lives.
    enum Placement: Equatable {
        /// Trailing items of the navigation bar. Compact width with
        /// horizontal bars, where the section tab bar owns the bottom edge;
        /// and the feed reader everywhere but a tall window on iOS 27.
        case topBar
        /// A system `.bottomBar` toolbar group (the mail reader at regular
        /// width before iOS 27).
        case bottomBar
        /// A reader's own bar pinned under the reading pane: the mail reader
        /// at regular width on iOS 27 and later, and the feed reader where it
        /// fills a tall window there.
        case ownBar
        /// The reader's actions as separate system `.bottomBar` items, each
        /// ranked for the overflow: where the system draws the window's bars
        /// in a strip down one side, which they join near the thumb and the
        /// tabs (iPhone Duo).
        case bottomItems
    }

    /// Which bar carries a reader's touch action set.
    ///
    /// The feed reader uses the system top bar except in a tall window
    /// (below): its touch set is three items, inside `topBarCapacity`, at
    /// every width (macOS and visionOS draw its wider set in the window's
    /// own toolbar).
    ///
    /// The mail reader at compact width puts its actions in the navigation
    /// bar so the section tab bar can stay on screen while a message is
    /// open, matching the feed reader. The reader used to hide the tab bar
    /// and take the bottom edge for a `.bottomBar` group, which left the
    /// reader as the one screen without the Mail / Feeds / Addresses /
    /// Settings tabs.
    ///
    /// At regular width there is no section tab bar, and the bottom edge
    /// stays the mail actions' home. A `.bottomBar` group in a
    /// `NavigationSplitView`'s detail column attaches to that column's
    /// navigation container on the iOS 26 SDK and to the *window* on iOS 27
    /// (measured both ways; an explicit `NavigationStack` around the column
    /// does not move it back). That spreads the reader's actions across the
    /// list column too, so Reply and Mark-as-read render under the message
    /// list they don't act on; iOS 27 therefore draws the pane-scoped bar.
    ///
    /// Where the system draws the window's bars in a strip down one side
    /// (`barsAreVertical`: iPhone Duo's outer display, and its inner display
    /// in a wide window), the mail reader's actions are system bottom items
    /// instead, so the strip carries them near the thumb and the tabs (the
    /// Duo spec: "Prefer the bottom toolbar for Reply, Archive, Flag and
    /// Read … Bottom items overflow first by default, so Reply and Archive
    /// need explicit high priority").
    ///
    /// A laptop fold changes nothing: the window is tall, so its bars are
    /// horizontal, and a system bottom bar there spans the window, under the
    /// list too, as above (measured on the Duo simulator, 2026-10-27). The
    /// reader's own pane bar already sits below the crease.
    ///
    /// The feed reader keeps the system top bar, except where it fills a
    /// window taller than wide on iOS 27 with horizontal bars
    /// (`fillsTallWindow`, the iPhone Duo upright or in laptop pose, an iPad
    /// in portrait): there it draws its own bar under its pane, as the mail
    /// reader does, with the page buttons and Compose (the Duo spec's
    /// "every tall window"), where the list's bar, with Compose, is behind
    /// the article.
    static func placement(
        for medium: Medium,
        isRegularWidth: Bool,
        isOS27OrLater: Bool,
        barsAreVertical: Bool = false,
        fillsTallWindow: Bool = false
    ) -> Placement {
        guard medium == .mail else {
            let ownsBar = fillsTallWindow && isRegularWidth && isOS27OrLater && !barsAreVertical
            return ownsBar ? .ownBar : .topBar
        }
        if barsAreVertical { return .bottomItems }
        guard isRegularWidth else { return .topBar }
        return isOS27OrLater ? .ownBar : .bottomBar
    }

    /// Whether a reader's HTML body runs under the bottom chrome: at
    /// compact width only, for both readers, never by the strip or the
    /// window's shape. `underBottomGlass(_:)` replaces the web view's host
    /// when this flips (the Decision 9 spike), and the strip and the tall
    /// bar come and go with each turn of an open iPhone Duo or an iPad,
    /// which swaps no shell; a width change swaps the shells, which rebuild
    /// the reader anyway. At regular width a body never runs under its
    /// pane's own bar, a SwiftUI inset that a bridged web view does not see,
    /// so the end of an article would stay stuck under it.
    static func bodyRunsUnderBottomBar(for medium: Medium, isRegularWidth: Bool) -> Bool {
        !isRegularWidth
    }
}
