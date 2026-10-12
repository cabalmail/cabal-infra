import SwiftUI

/// Which column the collapsed (iPhone-compact) navigation should show after
/// the read message changed. A pure rule rather than an inline `if` so it can
/// be tested directly — a shell's `@State` isn't reachable from a unit
/// test, this is.
enum CompactColumnPolicy {
    static func column(
        hasSelectedMessage: Bool,
        current: NavigationSplitViewColumn
    ) -> NavigationSplitViewColumn {
        if hasSelectedMessage { return .detail }
        // The message being read is gone — pruned by a send, archive or move
        // from the reader itself. A collapsed navigation has no list beside
        // the reader to fall back on, so leaving the column on `.detail`
        // strands the user on the empty-selection placeholder, whose "pick a
        // message from the list" copy is addressed to a layout that isn't on
        // screen. Pop back to the list instead. A selection cleared while the
        // reader ISN'T up (a folder switch clearing both at once) leaves the
        // column where it is.
        return current == .detail ? .content : current
    }

    /// The column a folder change leaves the collapsed navigation on: the
    /// new folder's list, or the folder list when the folder cleared. Any
    /// open message went with the old folder, so never the reader.
    static func afterFolderChange(hasFolder: Bool) -> NavigationSplitViewColumn {
        hasFolder ? .content : .sidebar
    }

    /// Whether moving to `column` drops the open message. Anything but the
    /// reader does: navigating back out by hand clears the selection, so the
    /// same row can be opened again.
    static func dropsMessage(movingTo column: NavigationSplitViewColumn) -> Bool {
        column != .detail
    }
}
