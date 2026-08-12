import SwiftUI
import CabalmailKit

// The reader toolbar's dispose control and its macOS option menu. Split
// from `MessageDetailView+Toolbar.swift` so that file stays under
// SwiftLint's file_length cap.

extension MessageDetailView {
    /// The toolbar's dispose control. On macOS it is a split button: the
    /// button face runs the current default — the most recently chosen
    /// action + advance pair, also editable in Settings — and the chevron
    /// opens every Archive/Delete × after-dispose combination. Touch (and
    /// gaze) platforms keep the plain button — a split target this small
    /// doesn't work under a finger — so their options live in Settings.
    @ViewBuilder
    var disposeButton: some View {
        if let model {
            #if os(macOS)
            Menu {
                disposeOptionItems(model: model)
            } label: {
                disposeToolbarLabel(for: model.disposeIntent)
            } primaryAction: {
                runDispose(model: model)
            }
            .menuIndicator(.visible)
            // Cmd+Delete — the same chord Mail.app and most macOS list
            // apps bind to "remove from list." Routes through dispose so
            // it follows the user's Archive/Trash preference rather than
            // hard-coding one or the other. In Trash the chord stages the
            // delete-forever confirmation instead of acting directly.
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityIdentifier("reader.dispose")
            #else
            let intent = model.disposeIntent
            Button(role: intent.isDestructive ? .destructive : nil) {
                runDispose(model: model)
            } label: {
                disposeToolbarLabel(for: intent)
            }
            // Cmd+Delete for hardware keyboards — see the macOS branch.
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityIdentifier("reader.dispose")
            #endif
        }
    }

    /// Runs the dispose the control's face advertises, per
    /// `model.disposeIntent` — shared by the plain button and the macOS
    /// split control's primary action.
    func runDispose(model: MessageDetailViewModel) {
        switch model.disposeIntent {
        case .purge:
            // In Trash, delete means gone forever — confirm first.
            purgeConfirmPresented = true
        case .restore:
            Task { await performMove(to: FolderTree.inboxPath) }
        case .move(let action):
            Task { await performDispose(model: model, action: action) }
        }
    }

    #if os(macOS)
    /// The chevron menu: every Archive/Delete × after-dispose combination.
    /// Rendered as menu toggles so the pair currently in effect — the
    /// button face's default — carries the native checkmark. Choosing a row
    /// persists the pair — making it the default and what Settings shows —
    /// then disposes the open message with it.
    @ViewBuilder
    func disposeOptionItems(model: MessageDetailViewModel) -> some View {
        ForEach(Array(DisposeAction.allCases.enumerated()), id: \.element) { index, action in
            if index > 0 { Divider() }
            ForEach(DisposeAdvance.allCases) { advance in
                disposeOptionItem(model: model, action: action, advance: advance)
            }
        }
    }

    @ViewBuilder
    private func disposeOptionItem(
        model: MessageDetailViewModel,
        action: DisposeAction,
        advance: DisposeAdvance
    ) -> some View {
        // The verb comes from the reconciled intent, not the raw action, so
        // the rows read true in the special folders: Delete Forever inside
        // Trash, Restore inside Archive.
        let intent = model.intent(for: action)
        Toggle(isOn: Binding(
            get: { preferences.disposeAction == action && preferences.disposeAdvance == advance },
            set: { _ in
                preferences.disposeAction = action
                preferences.disposeAdvance = advance
                switch intent {
                case .purge:
                    purgeConfirmPresented = true
                case .restore:
                    Task { await performMove(to: FolderTree.inboxPath) }
                case .move(let destination):
                    Task { await performDispose(model: model, action: destination) }
                }
            }
        )) {
            Text("\(disposeVerb(for: intent)) and \(advanceDescription(for: advance))")
        }
    }

    private func advanceDescription(for advance: DisposeAdvance) -> String {
        switch advance {
        case .next:           return "Move to Next Message"
        case .nextUnread:     return "Move to Next Unread"
        case .previousUnread: return "Move to Previous Unread"
        case .firstUnread:    return "Move to First Unread"
        }
    }
    #endif
}
