import SwiftUI

/// Where the global search field is hosted on a given layout.
enum GlobalSearchFieldHost: Equatable {
    /// Nowhere: compact iPhone reaches search through its own bottom tab
    /// (`SignedInRootView`'s `Tab(role: .search)`), so the wide-layout field
    /// isn't mounted at all.
    case none
    /// Right-aligned in the message-list column's toolbar section, sized by
    /// `ToolbarSearchFieldWidth`.
    case toolbar
    /// A header row inside the message-list column, above the list itself —
    /// the field is drawn as content rather than as a toolbar item.
    case columnHeader
}

/// Decides which host the global search field gets.
///
/// The #1047 rework moved the field from the reading pane's toolbar to the
/// message-list column's, whose results it drives. That is right on macOS,
/// where a window-wide toolbar has room for it beside the column's buttons.
/// It is not right on iPadOS, where the column draws its *own* UIKit
/// navigation bar at column width: the list column is 360pt by default and
/// already carries four fixed buttons (folder-panel toggle, Settings, Compose,
/// Addresses), so a field of any usable width overruns the section and UIKit
/// silently folds the trailing items into a system overflow — which, measured
/// on iPadOS 26.5, never presents. The field and the Addresses button were
/// both unreachable as a result (#1052/#1058).
///
/// So a column-scoped bar doesn't host the field at all; it moves into the
/// column's content, where it gets the column's full width, keeps its
/// magnifier and whole placeholder, and costs the bar nothing. The choice is
/// deliberately width-independent: the list column is user-resizable (360pt
/// through its cap), and a field that jumped between the bar and a header row
/// mid-drag would be a moving hit target.
enum GlobalSearchFieldPlacement {
    /// - Parameters:
    ///   - isWideSidebar: whether this is a wide layout (macOS, regular-width
    ///     iPad) rather than compact iPhone.
    ///   - columnScopedToolbar: whether the message-list column draws its own
    ///     navigation bar at column width (UIKit's split controller) rather
    ///     than sharing a window-wide one.
    static func host(isWideSidebar: Bool, columnScopedToolbar: Bool) -> GlobalSearchFieldHost {
        guard isWideSidebar else { return .none }
        return columnScopedToolbar ? .columnHeader : .toolbar
    }

    /// The host on a window's layout shell: the desktop's window-wide toolbar,
    /// a header row in the split's list column, and nothing on the tab
    /// layouts, which reach search through a tab of its own.
    static func host(in layout: ShellLayout, on platform: HostPlatform = .current) -> GlobalSearchFieldHost {
        host(isWideSidebar: layout.isWideSplit, columnScopedToolbar: platform.columnScopedToolbar)
    }

    /// Whether the running platform gives the message-list column its own
    /// column-width navigation bar (`HostPlatform.columnScopedToolbar`).
    static var platformColumnScopedToolbar: Bool {
        HostPlatform.current.columnScopedToolbar
    }
}
