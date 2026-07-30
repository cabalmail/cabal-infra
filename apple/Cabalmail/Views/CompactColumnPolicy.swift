import SwiftUI

/// Which column the collapsed (iPhone-compact) navigation should show after
/// the read message changed. A pure rule rather than an inline `if` so it can
/// be tested directly — `MailRootView`'s `@State` isn't reachable from a unit
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
}
