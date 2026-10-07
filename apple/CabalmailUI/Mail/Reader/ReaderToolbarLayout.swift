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
/// that goes stale under a new SDK. The budgets and the placement are
/// `ReaderToolbarPolicy`'s, shared with the feed reader; the names below
/// forward to it.
///
/// macOS turned out not to be "unaffected in its roomy top toolbar" after
/// all: below ~1300pt of window AppKit folds the toolbar's *trailing* items
/// into its own "more toolbar items" (») popup, which used to be exactly the
/// dispose button and the `…` menu (#1047). The macOS answer is the inverse
/// of the iOS one — no app-side budget, no app-owned overflow menu; instead
/// `macToolbar` orders every action by reverse demotion priority and lets the
/// system popup do the demoting in exactly that order.
enum ReaderToolbarLayout {
    /// `ReaderToolbarPolicy.capacity`: items the bottom bar draws before the
    /// system starts compacting.
    static let capacity = ReaderToolbarPolicy.capacity

    /// `ReaderToolbarPolicy.topBarCapacity`: items the compact navigation bar
    /// carries beside the back button.
    static let topBarCapacity = ReaderToolbarPolicy.topBarCapacity

    /// What the compact navigation bar gives up to stay inside
    /// `topBarCapacity`, on top of `demotedToOverflow`: the overflow menu
    /// carries them as rows there. Flag goes rather than Read because the
    /// read toggle also drives the after-mark-read navigation, and rather
    /// than Reply or dispose because those are the reader's primary actions.
    static let topBarDemotedToOverflow: [ReaderToolbarAction] = [.toggleFlag]

    /// The two display toggles the bar gave up. Both are inert on plain-text
    /// mail (they disable themselves when there's no HTML body), so they are
    /// the cheapest slots to reclaim. On the pane-scoped bar they return
    /// whenever the pane is wide enough — see `ownBar(leading:paneWidth:)`.
    static let demotedToOverflow: [ReaderToolbarAction] = [.readerMode, .remoteContent]

    /// `ReaderToolbarPolicy.fullSetMinWidth`: the narrowest pane at which
    /// the reader's own bar draws all seven actions.
    static let fullSetMinWidth = ReaderToolbarPolicy.fullSetMinWidth

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

    /// Where the reader's touch action set lives (`ReaderToolbarPolicy`).
    typealias Placement = ReaderToolbarPolicy.Placement

    /// Which bar carries the mail reader's touch action set:
    /// `ReaderToolbarPolicy.placement(for: .mail, ...)`, which explains the
    /// choice.
    static func placement(isRegularWidth: Bool, isOS27OrLater: Bool) -> Placement {
        ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: isRegularWidth, isOS27OrLater: isOS27OrLater)
    }

    /// Compact navigation-bar items, in drawn order. The view draws each as
    /// its own item and ranks them for the system's overflow: the menu above
    /// all (`keepsInBarFirst`) as the only touch route to Move, the display
    /// toggles, Flag, source, headers and Print, and a second home for Reply;
    /// Reply / Edit Draft and dispose next (`keepsInBar`), dispose being
    /// Delete Forever inside Trash; Read unranked, so it folds first.
    static func topBar(leading: LeadingReaderAction) -> [ReaderToolbarAction] {
        [
            leading == .editDraft ? .editDraft : .reply,
            .toggleRead,
            .dispose,
            .overflow
        ]
    }

    /// Bottom-bar items (the regular-width `.bottomBar` group), in drawn
    /// order.
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
