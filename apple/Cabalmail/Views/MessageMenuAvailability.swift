import SwiftUI

/// Which `Message` menu commands can currently do anything.
///
/// The menu's commands dispatch through `AppState` tick counters, and the
/// surfaces that consume them act on `shortcutTargetUIDs` (the multi-select
/// set, else the reading-pane message, else nothing) or — for the reply
/// family — on the open message in `MessageDetailView`. Nothing selected
/// means every one of them is a no-op, so the menu advertised seven live
/// commands that silently did nothing (#985). These two flags mirror those
/// two target rules exactly, so a command is enabled iff it has something to
/// act on.
struct MessageMenuAvailability: Equatable {
    /// Rows the message list has selected. A plain click on a wide layout
    /// counts as one; compact iPhone leaves this at zero and opens the
    /// message instead.
    var selectedCount: Int
    /// Whether a single message is open in the reader, which is what the
    /// reply family and the compact-iPhone fallback act on.
    var hasOpenMessage: Bool

    /// Nothing selected, nothing open: the signed-out and launch state.
    static let none = MessageMenuAvailability(selectedCount: 0, hasOpenMessage: false)

    /// Reply / Reply All / Forward need the open message: they're handled by
    /// `MessageDetailView`, which isn't on screen for a zero- or
    /// multi-message selection.
    var canReply: Bool { hasOpenMessage }

    /// Mark as Read/Unread, Flag/Unflag and Move act on the selection, and
    /// fall back to the open message when the list has no selection of its
    /// own — matching `shortcutTargetUIDs`.
    var canActOnSelection: Bool { selectedCount > 0 || hasOpenMessage }

    /// Which surface installs the window-scoped Cmd+Delete equivalent.
    ///
    /// The chord can't be a menu item (see `MessageMenuCommands`: an app-wide
    /// equivalent would fire from the compose window and steal the text
    /// system's delete-to-line-start), so it rides a window-scoped control —
    /// and exactly one at a time. Two equivalents in one window leave AppKit
    /// to pick a winner, which is how an always-on list button silently did
    /// nothing.
    var disposeChordHost: DisposeChordHost {
        if selectedCount > 1 { return .list }
        if hasOpenMessage { return .reader }
        return .none
    }
}

/// The surface that owns Cmd+Delete right now.
enum DisposeChordHost: Equatable {
    /// A multi-selection: the message list disposes the whole set.
    case list
    /// One message open in the reading pane, which disposes that message.
    case reader
    /// Nothing to dispose, so the chord is installed nowhere.
    case none
}

private struct MessageMenuAvailabilityReporter: ViewModifier {
    @Environment(AppState.self) private var appState
    let availability: MessageMenuAvailability

    func body(content: Content) -> some View {
        content
            .onChange(of: availability, initial: true) { _, new in
                appState.messageMenuAvailability = new
            }
            // A mail surface going away (sign-out, scene teardown) leaves
            // nothing for the commands to act on.
            .onDisappear { appState.messageMenuAvailability = .none }
    }
}

extension View {
    /// Publishes what the `Message` menu can act on from this mail surface.
    /// Applied by the surface that owns both halves of the answer — the list
    /// selection and the reading pane — so the menu validates against the
    /// same targets the commands themselves use.
    func reportsMessageMenuAvailability(selectedCount: Int, hasOpenMessage: Bool) -> some View {
        modifier(MessageMenuAvailabilityReporter(
            availability: MessageMenuAvailability(
                selectedCount: selectedCount,
                hasOpenMessage: hasOpenMessage
            )
        ))
    }
}
