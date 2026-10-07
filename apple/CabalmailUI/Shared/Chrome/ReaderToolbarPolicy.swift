import Foundation

/// The reader toolbar's budgets and placement, for both readers: the mail
/// reader lays its actions out in `ReaderToolbarLayout`, the feed reader in
/// `FeedReaderToolbarLayout`, and both read how much room a bar has and which
/// bar carries the actions from here, so a new SDK's folding is answered in
/// one place.
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
        /// Trailing items of the navigation bar. Compact width, where the
        /// section tab bar owns the bottom edge; and the feed reader at
        /// every width.
        case topBar
        /// A system `.bottomBar` toolbar group (the mail reader at regular
        /// width before iOS 27).
        case bottomBar
        /// The mail reader's own bar pinned under the reading pane (regular
        /// width on iOS 27 and later).
        case ownBar
    }

    /// Which bar carries a reader's touch action set.
    ///
    /// The feed reader always uses the system top bar: its set is three
    /// items, inside `topBarCapacity`, at every width.
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
    static func placement(for medium: Medium, isRegularWidth: Bool, isOS27OrLater: Bool) -> Placement {
        guard medium == .mail, isRegularWidth else { return .topBar }
        return isOS27OrLater ? .ownBar : .bottomBar
    }
}
