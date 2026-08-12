import SwiftUI
import CabalmailKit

// The reader toolbar's mark-read control and its macOS option menu. A
// sibling of `MessageDetailView+DisposeOptions.swift` (same split-button
// pattern, same file-length reasoning).

extension MessageDetailView {
    /// The toolbar's read/unread control. On macOS it is a split button:
    /// the button face toggles `\Seen` — marking read additionally moves
    /// the reading pane per the current default, the most recently chosen
    /// option below, also editable in Settings — and the chevron opens the
    /// mark-read-and-go-to combinations. The options only apply to an
    /// unread message (a mark-unread never navigates), so they are disabled
    /// while the message reads as seen; the control stays a split button in
    /// both states so it never changes footprint under the pointer. Touch
    /// (and gaze) platforms keep the plain toggle — a split target this
    /// small doesn't work under a finger — so their option lives in
    /// Settings.
    @ViewBuilder
    var seenButton: some View {
        if let model {
            #if os(macOS)
            Menu {
                seenOptionItems(model: model)
            } label: {
                seenToolbarLabel(isSeen: model.isSeen)
            } primaryAction: {
                runToggleSeen(model: model)
            }
            .menuIndicator(.visible)
            // Cmd+Shift+U — Mail.app's mark-unread shortcut. We toggle
            // both ways from the same chord; the icon labels which
            // direction the next press goes.
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .accessibilityIdentifier("reader.toggleRead")
            #else
            Button {
                runToggleSeen(model: model)
            } label: {
                seenToolbarLabel(isSeen: model.isSeen)
            }
            // Cmd+Shift+U for hardware keyboards — see the macOS branch.
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .accessibilityIdentifier("reader.toggleRead")
            #endif
        }
    }

    /// Icon reflects the current state; tap-action is the inverse. Matches
    /// Mail.app: an already-read message shows "envelope.open" and tapping
    /// marks it unread.
    @ViewBuilder
    private func seenToolbarLabel(isSeen: Bool) -> some View {
        Image(systemName: isSeen ? "envelope.open" : "envelope.badge")
            .accessibilityLabel(isSeen ? "Mark as unread" : "Mark as read")
    }

    /// Runs the toggle the control's face advertises — shared by the plain
    /// button and the macOS split control's primary action. Marking read
    /// follows the user's after-mark-read preference; marking unread never
    /// navigates.
    func runToggleSeen(model: MessageDetailViewModel) {
        if model.isSeen {
            Task { await model.setSeen(false) }
        } else {
            markRead(model: model, advance: preferences.markReadAdvance)
        }
    }

    /// Marks the open message read and asks the list to move the selection
    /// per `advance`. The advance signal fires optimistically alongside the
    /// `\Seen` write, matching the dispose flow — a failed STORE reverts the
    /// flag but leaves the user on the message they navigated to.
    private func markRead(model: MessageDetailViewModel, advance: MarkReadAdvance) {
        Task { await model.setSeen(true) }
        appState.signalReadAdvance(
            folderPath: folder.path,
            uid: envelope.uid,
            advance: advance
        )
    }

    #if os(macOS)
    /// The chevron menu: mark read × where to go next. Rendered as menu
    /// toggles so the row whose option is the button face's current default
    /// carries the native checkmark; choosing a row persists that option —
    /// making it the default and what Settings shows — then marks the open
    /// message read with it.
    @ViewBuilder
    func seenOptionItems(model: MessageDetailViewModel) -> some View {
        ForEach(MarkReadAdvance.allCases) { advance in
            Toggle(isOn: Binding(
                get: { preferences.markReadAdvance == advance },
                set: { _ in
                    preferences.markReadAdvance = advance
                    markRead(model: model, advance: advance)
                }
            )) {
                Text("Mark Read and \(seenAdvanceDescription(for: advance))")
            }
            // The options are one-way: they mark read. On a read message
            // the face's next press means unread, where "and move to…"
            // has nothing to do, so the rows grey out (still showing the
            // checked default) rather than acting.
            .disabled(model.isSeen)
        }
    }

    private func seenAdvanceDescription(for advance: MarkReadAdvance) -> String {
        switch advance {
        case .stay:           return "Stay Here"
        case .nextUnread:     return "Move to Next Unread"
        case .previousUnread: return "Move to Previous Unread"
        case .firstUnread:    return "Move to First Unread"
        }
    }
    #endif
}
