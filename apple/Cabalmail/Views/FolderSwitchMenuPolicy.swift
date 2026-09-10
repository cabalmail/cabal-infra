import Foundation
import CabalmailKit

/// What the message list's folder-switch menu offers — the menu behind the
/// folder name at the top of the list — and the identity SwiftUI needs to
/// redraw it.
///
/// Two groups: the subscribed folders at the top level, and the rest under
/// an "Other folders" submenu. Subscription is the user's signal about
/// attention, so the folders they have said they care about are one tap
/// away and everything else is one tap further — the same split as the
/// sidebar's Subscribed / All folders sections, and its fallback: with
/// nothing subscribed the split would leave the top level empty, so every
/// folder is listed at the top level instead.
///
/// A pure rule, for the reason `SortMenuPolicy` is: the rows can be tested
/// directly, and the macOS menu identity (#1329, #1337) is built from the
/// same rows the menu draws, so the two can never disagree.
enum FolderSwitchMenuPolicy {
    /// The menu's two groups. Exactly one row across both is checked: the
    /// folder the list is showing.
    struct Groups {
        /// Top-level rows: subscribed folders (or every folder, when
        /// nothing is subscribed).
        let subscribed: [ReaderMenuRow<Folder>]
        /// The "Other folders" submenu: unsubscribed folders. Empty when
        /// there are none — the submenu is then not drawn.
        let other: [ReaderMenuRow<Folder>]
    }

    /// Label for the submenu that holds the unsubscribed folders.
    static let otherFoldersLabel = "Other folders"

    /// The rows the menu offers for `folders`, with `current` checked.
    ///
    /// `\Noselect` containers are dropped — they can't be opened, and the
    /// folders under them are listed in their own right. The order is the
    /// shared sidebar order (`FolderTree.sidebarOrder`), so the menu never
    /// surprises against the sidebar. Until the folder list arrives (or if
    /// `current` is somehow not in it) the menu still shows the folder the
    /// list is on, checked, so the affordance never reads as empty.
    static func groups(folders: [Folder], current: Folder) -> Groups {
        let openable = FolderTree.sidebarOrder(
            folders.filter { !$0.attributes.contains("\\Noselect") }
        )
        let listed = openable.contains { $0.path == current.path }
        let placeholder = listed ? [] : [current]
        let subscribed = openable.filter(\.isSubscribed)
        let other = openable.filter { !$0.isSubscribed }
        // With nothing subscribed the split has no top level; list
        // everything there, as the sidebar does.
        let topLevel = subscribed.isEmpty ? openable : subscribed
        let submenu = subscribed.isEmpty ? [] : other
        return Groups(
            subscribed: (placeholder + topLevel).map { row($0, current: current) },
            other: submenu.map { row($0, current: current) }
        )
    }

    /// The row's title: the folder's name, or its full path when it is
    /// nested — a flat menu has no indentation to tell two "Alpha"
    /// folders apart.
    static func label(for folder: Folder) -> String {
        FolderTree.depth(for: folder) > 0 ? folder.path : folder.name
    }

    /// Identity for the macOS `Menu`, covering everything either group
    /// draws so any visible change replaces the menu.
    static func identity(_ groups: Groups) -> String {
        ReaderOptionMenuPolicy.identity(groups.subscribed)
            + "\u{1D}"
            + ReaderOptionMenuPolicy.identity(groups.other)
    }

    private static func row(_ folder: Folder, current: Folder) -> ReaderMenuRow<Folder> {
        ReaderMenuRow(
            option: folder,
            key: "folder.\(folder.path)",
            label: label(for: folder),
            isOn: folder.path == current.path
        )
    }
}
