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
}

/// Which reader actions the iPhone/iPad bottom bar draws and which ones the
/// app's own overflow menu carries. Pure, so the width budget is an enforced
/// invariant instead of a comment that goes stale under a new SDK.
///
/// The bar sizes itself to its content, and past a certain item count the
/// system takes over: on the iOS 27 SDK it silently folds the tail into its
/// own `ToolbarOverflowBarButtonItem`, which swallowed Reader view and
/// Archive/Delete Forever outright and nested our `…` menu a tap deeper. Seven
/// items fit on the iOS 26 SDK with about 2pt to spare at 402pt (measured), so
/// the previous ceiling was never a ceiling — it was the bar being exactly
/// full. Demoting to `capacity` keeps every action addressable regardless of
/// which SDK compacts at what width; macOS is unaffected and keeps all seven in
/// its roomy top toolbar.
enum ReaderToolbarLayout {
    /// Items the bottom bar draws before the system starts compacting —
    /// measured on the iOS 27 SDK at 402pt, where four app buttons plus the
    /// system's overflow control were what rendered.
    static let capacity = 5

    /// The two display toggles the bar gave up. Both are inert on plain-text
    /// mail (they disable themselves when there's no HTML body), so they are
    /// the cheapest slots to reclaim.
    static let demotedToOverflow: [ReaderToolbarAction] = [.readerMode, .remoteContent]

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
}
