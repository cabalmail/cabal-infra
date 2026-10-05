import SwiftUI

/// Where the folder-switch affordance is hosted on a given layout.
enum FolderSwitchHost: Equatable {
    /// The system's own title menu (`toolbarTitleMenu`): the navigation title
    /// gains the platform chevron and a tap opens the folder list. Compact
    /// iPhone and visionOS, whose bars are not scoped to a narrow column.
    case titleMenu
    /// A header row inside the message-list column, above the list — drawn as
    /// content rather than as bar furniture, exactly like the global search
    /// field beside it (`GlobalSearchFieldHost.columnHeader`).
    case columnHeader
}

/// Decides which host the folder switch gets on the touch platforms.
///
/// A column-scoped navigation bar has a fixed occupant budget, and #1058,
/// #1626 and #1670 are all the same failure of it: the bar runs out of room,
/// UIKit folds its trailing items into a system `OverflowBarButtonItem`, and
/// that item never presents on iPadOS — so a folded item is not a second tap
/// away, it is gone. The two casualties on #1626 were Compose and the `@`
/// toggle, which is the only control that closes the addresses inspector.
///
/// Evicting an occupant buys width but not the property: #1626's first fix
/// moved the Settings gear out and the slot was immediately spent by the More
/// menu that had landed days earlier, and the bar overflowed again at the
/// column's 300 pt floor — one drag of the resize handle away.
///
/// So the folder switch follows the global search field out of the bar and
/// into the column's content (`GlobalSearchFieldPlacement` argues the same
/// case for the same bar). It costs the bar both the title menu's width and
/// the title region it is charged against, and what is left in the bar is
/// either ranked to stay (`ToolbarContent.keepsInBar()`) or has a second home:
/// Mark All as Read is on the folder list's context menu and ⌥⌘T, so the More
/// menu is the only item the system overflow can ever receive.
///
/// macOS is not a case here: it draws the switch as a `.navigation` toolbar
/// item because it never materializes a title menu at all, and its toolbar
/// spans the window rather than a column (`MessageListView+FolderSwitch`).
enum FolderSwitchPlacement {
    /// - Parameters:
    ///   - isWideSidebar: whether this is a wide layout (regular-width iPad,
    ///     visionOS) rather than compact iPhone.
    ///   - columnScopedToolbar: whether the message-list column draws its own
    ///     navigation bar at column width (UIKit's split controller) rather
    ///     than sharing a window-wide or ornament-hosted one.
    static func host(isWideSidebar: Bool, columnScopedToolbar: Bool) -> FolderSwitchHost {
        guard isWideSidebar, columnScopedToolbar else { return .titleMenu }
        return .columnHeader
    }
}
