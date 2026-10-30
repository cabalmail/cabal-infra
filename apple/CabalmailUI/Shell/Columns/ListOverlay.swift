import SwiftUI

/// The list floating over a full-width reader in a window taller than wide:
/// the iPhone Duo open upright and an iPad in portrait (the spec's open
/// portrait choice, #1686). The message takes the window's width, and the
/// list slides over it from the reader's Messages button or the leading
/// edge, shown first when nothing is open. A window wider than tall tiles
/// the two as before and never hides the list.
///
/// Pure, so the rule is tested on the Mac host; `SplitShell` keeps one in
/// state and reads the split's columns from it.
struct ListOverlay: Equatable, Sendable {
    /// Whether the list is over the reader, while the split overlays.
    private(set) var isShown = true
    /// Whether a message is open in the reader.
    private(set) var messageIsOpen = false

    /// The split's columns: both while the split tiles or the list is shown,
    /// the reader alone otherwise.
    func visibility(overlays: Bool) -> NavigationSplitViewVisibility {
        !overlays || isShown ? .doubleColumn : .detailOnly
    }

    /// What the split asks for: the reader alone once a tap on it or a
    /// swipe has put the list away, both once the system has brought it
    /// back. Ignored while the split tiles, where the list stays, and while
    /// no message is open, when there is nothing behind the list to show:
    /// UIKit puts the floating column away on its own when the split turns
    /// to overlaying, which left an upright Duo on an empty reader.
    mutating func splitAsked(for visibility: NavigationSplitViewVisibility, overlays: Bool) {
        guard overlays else { return }
        if visibility == .detailOnly, !messageIsOpen { return }
        isShown = visibility != .detailOnly
    }

    /// A message opened, or the open one closed: the list gives way to a
    /// message, and comes back when none is open.
    mutating func messageChanged(isOpen: Bool) {
        messageIsOpen = isOpen
        isShown = !isOpen
    }

    /// The reader's Messages button.
    mutating func show() {
        isShown = true
    }

    /// Whether the reader offers its Messages button: while the split
    /// overlays and the list is away.
    func offersMessagesButton(overlays: Bool) -> Bool {
        overlays && !isShown
    }
}
