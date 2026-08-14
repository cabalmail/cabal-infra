import SwiftUI
import CabalmailKit

// The reader toolbar's dispose control and its option menu. Split from
// `MessageDetailView+Toolbar.swift` so that file stays under SwiftLint's
// file_length cap.

extension MessageDetailView {
    /// The toolbar's dispose control: a `Menu` with a primary action on
    /// every platform. The face runs the current default — the most
    /// recently chosen action + advance pair, also editable in Settings —
    /// and the menu offers every Archive/Delete × after-dispose
    /// combination. macOS renders it as a split button with a chevron
    /// segment; the touch and gaze platforms render the plain button they
    /// had before, with the same menu on touch-and-hold (pinch-and-hold on
    /// visionOS) — the HIG accelerator idiom Mail.app uses on its own
    /// trash/archive button. Because a hold menu is a hidden affordance,
    /// it never becomes the only route: Settings carries the same options
    /// and the overflow menu keeps the alternate dispose action.
    @ViewBuilder
    var disposeButton: some View {
        if let model {
            Menu {
                disposeOptionItems(model: model)
            } label: {
                disposeToolbarLabel(for: model.disposeIntent)
            } primaryAction: {
                runDispose(model: model)
            }
            .menuIndicator(optionMenuIndicator)
            .tint(disposeTint(for: model.disposeIntent))
            .accessibilityIdentifier("reader.dispose")
        }
    }

    /// Cmd+Delete for the open message — the chord Mail.app and most macOS
    /// list apps bind to "remove from list", also fired by iPad/iPhone
    /// hardware keyboards. Routes through dispose so it follows the user's
    /// Archive/Trash preference; in Trash it stages the delete-forever
    /// confirmation rather than acting directly.
    ///
    /// A hidden button rather than the dispose toolbar button's own
    /// `.keyboardShortcut`, which is where it used to live: a key equivalent
    /// riding a toolbar item goes wherever that item goes, and AppKit
    /// collapses the trailing items of a crowded toolbar into its own "more
    /// toolbar items" popup — taking the equivalent with them, so the chord
    /// died in a narrow window with no sign it had (#1047). The same hidden-
    /// button idiom the message list uses for a multi-selection; installed
    /// only while this reader owns the chord (`DisposeChordHost`), because two
    /// equivalents in one window leave AppKit to pick a winner.
    @ViewBuilder
    var disposeChordHost: some View {
        if let model, appState.messageMenuAvailability.disposeChordHost == .reader {
            Button("") { runDispose(model: model) }
                .keyboardShortcut(.delete, modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// Chevron segment on macOS only. On the touch platforms the control
    /// keeps its plain-button footprint — the hold menu is an accelerator,
    /// not a second hit target.
    var optionMenuIndicator: Visibility {
        #if os(macOS)
        return .visible
        #else
        return .hidden
        #endif
    }

    /// Red face for a destructive default on the touch platforms, standing
    /// in for the `.destructive` button role a `Menu` face can't carry.
    /// macOS keeps the system toolbar tint either way, matching the split
    /// button as it shipped.
    private func disposeTint(for intent: DisposeIntent) -> Color? {
        #if os(macOS)
        return nil
        #else
        return intent.isDestructive ? .red : nil
        #endif
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

    /// The option menu: every Archive/Delete × after-dispose combination.
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
}
