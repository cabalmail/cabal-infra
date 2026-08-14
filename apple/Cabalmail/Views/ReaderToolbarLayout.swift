import Foundation

/// One control in the reader's action set, identified by the accessibility
/// identifier its button carries.
enum ReaderToolbarAction: String, CaseIterable {
    case reply = "reader.reply"
    case editDraft = "reader.editDraft"
    case toggleRead = "reader.toggleRead"
    case toggleFlag = "reader.toggleFlag"
    case remoteContent = "reader.remoteContent"
    case readerMode = "reader.readerMode"
    case dispose = "reader.dispose"
    case overflow = "reader.overflow"
    case move = "reader.move"
    case plainText = "reader.plainText"
    case viewSource = "reader.viewSource"
    case viewHeaders = "reader.viewHeaders"
    case printMessage = "reader.print"
}

/// Which reader actions each platform's bar draws and which ones ride a menu.
/// Pure, so the layout policy is an enforced invariant instead of a comment
/// that goes stale under a new SDK.
///
/// On the touch platforms the bar sizes itself to its content, and past a
/// certain item count the system takes over: on the iOS 27 SDK it silently
/// folds the tail into its own `ToolbarOverflowBarButtonItem`, which swallowed
/// Reader view and Archive/Delete Forever outright and nested our `…` menu a
/// tap deeper. Seven items fit on the iOS 26 SDK with about 2pt to spare at
/// 402pt (measured), so the previous ceiling was never a ceiling — it was the
/// bar being exactly full. Demoting to `capacity` keeps every action
/// addressable regardless of which SDK compacts at what width.
///
/// macOS turned out not to be "unaffected in its roomy top toolbar" after
/// all: below ~1300pt of window AppKit folds the toolbar's *trailing* items
/// into its own "more toolbar items" (») popup, which used to be exactly the
/// dispose button and the `…` menu (#1047). The macOS answer is the inverse
/// of the iOS one — no app-side budget, no app-owned overflow menu; instead
/// `macToolbar` orders every action by reverse demotion priority and lets the
/// system popup do the demoting in exactly that order.
enum ReaderToolbarLayout {
    /// Items the bottom bar draws before the system starts compacting —
    /// measured on the iOS 27 SDK at 402pt, where four app buttons plus the
    /// system's overflow control were what rendered.
    static let capacity = 5

    /// The two display toggles the bar gave up. Both are inert on plain-text
    /// mail (they disable themselves when there's no HTML body), so they are
    /// the cheapest slots to reclaim. On the pane-scoped bar they return
    /// whenever the pane is wide enough — see `ownBar(leading:paneWidth:)`.
    static let demotedToOverflow: [ReaderToolbarAction] = [.readerMode, .remoteContent]

    /// Narrowest pane at which the reader's own bar draws all seven actions.
    /// Derived from the density that shipped on the iPhone system bar — five
    /// items across the measured 402pt is ~80pt of bar per item — so seven
    /// items must have at least that much room before the demoted toggles
    /// come back.
    static let fullSetMinWidth: CGFloat = 560

    /// Actions that are first-class toolbar buttons on macOS but menu rows in
    /// the reader's own `…` menu on the touch platforms, which have no room
    /// for eleven buttons.
    static let touchOverflowOnly: [ReaderToolbarAction] = [
        .move, .plainText, .viewSource, .viewHeaders, .printMessage
    ]

    /// The macOS top toolbar, in drawn order: every reader action as its own
    /// button, no app-owned overflow menu, ordered by *reverse demotion
    /// priority* (#1047). AppKit folds a crowded toolbar's trailing items
    /// into its "more toolbar items" (») popup first, so the drawn order IS
    /// the demotion policy: Print gives way first, the filing actions last.
    /// Every button face is a `Label` because the popup flattens buttons into
    /// menu rows, and a row with no title reads as blank.
    static func macToolbar(leading: LeadingReaderAction) -> [ReaderToolbarAction] {
        [
            leading == .editDraft ? .editDraft : .reply,
            .dispose,
            .toggleRead,
            .remoteContent,
            .toggleFlag,
            .readerMode,
            .move,
            .plainText,
            .viewSource,
            .viewHeaders,
            .printMessage
        ]
    }

    /// Whether the reader draws the action set itself, in a bar pinned under
    /// the reading pane, instead of handing it to a `.bottomBar` toolbar
    /// group.
    ///
    /// A `.bottomBar` group in a `NavigationSplitView`'s detail column
    /// attaches to that column's navigation container on the iOS 26 SDK and
    /// to the *window* on iOS 27 (measured both ways; an explicit
    /// `NavigationStack` around the column does not move it back). At regular
    /// width that spreads the reader's actions across the list column too, so
    /// Reply and Mark-as-read render under the message list they don't act
    /// on. Compact width has one column, so the two containers coincide and
    /// the system bar stays correct there.
    static func usesOwnActionBar(isRegularWidth: Bool, isOS27OrLater: Bool) -> Bool {
        isRegularWidth && isOS27OrLater
    }

    /// Bottom-bar items, in drawn order.
    static func bottomBar(leading: LeadingReaderAction) -> [ReaderToolbarAction] {
        [
            leading == .editDraft ? .editDraft : .reply,
            .toggleRead,
            .toggleFlag,
            .dispose,
            .overflow
        ]
    }

    /// Items for the reader's own pane-scoped bar, in drawn order. `capacity`
    /// exists because the *system* bar compacts past five items at iPhone
    /// width; the pane-scoped bar is our own `HStack`, so no compaction
    /// applies and the real budget is the pane's measured width — which on
    /// iPad the user can change by dragging the split divider, so this is
    /// re-evaluated live as the pane resizes. Wide panes restore the demoted
    /// display toggles in their macOS position (between flag and dispose):
    /// promotion grows the middle of the bar, so Reply keeps the leading edge
    /// and dispose/overflow the trailing one, and resizing never moves the
    /// endpoint hit targets. Narrow panes draw the same five as the system
    /// bar.
    static func ownBar(
        leading: LeadingReaderAction,
        paneWidth: CGFloat
    ) -> [ReaderToolbarAction] {
        guard paneWidth >= fullSetMinWidth else {
            return bottomBar(leading: leading)
        }
        return [
            leading == .editDraft ? .editDraft : .reply,
            .toggleRead,
            .toggleFlag,
            .remoteContent,
            .readerMode,
            .dispose,
            .overflow
        ]
    }
}
