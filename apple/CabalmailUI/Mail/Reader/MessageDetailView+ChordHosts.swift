import SwiftUI
import CabalmailKit

// Window-scoped keyboard equivalents for the reader's actions, hosted on
// hidden always-present buttons instead of the visible toolbar controls: a
// chord riding a toolbar item goes wherever the item goes, and AppKit folds a
// crowded toolbar's trailing items into its "more toolbar items" (») popup —
// which silently killed Cmd+Delete in a narrow window (#1047). The same
// hidden-button idiom as `disposeChordHost` (which stays separate in
// `+DisposeOptions` because it needs cross-surface arbitration with the
// message list; these chords have no second host to arbitrate with). Also
// what fires the chords from iPad/iPhone hardware keyboards.

extension MessageDetailView {
    /// One hidden host per chord, mirroring the disabled conditions of the
    /// visible control so a chord can't reach an action its button couldn't.
    @ViewBuilder
    var readerChordHosts: some View {
        if let model {
            Group {
                // Cmd+Shift+U — Mail.app's mark-unread chord. Toggles both
                // ways; the seen control's face labels which direction the
                // next press goes.
                Button("") { runToggleSeen(model: model) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                // Cmd+Shift+L — Mail.app's flag chord.
                Button("") { Task { await model.toggleFlagged() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("") { model.toggleRemoteContent() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.htmlBody == nil)
                Button("") { moveSheetPresented = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("") { sourceSheetTab = .full }
                    .keyboardShortcut("u", modifiers: .command)
                Button("") { model.requestPrint() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(model.htmlBody == nil && model.plainText == nil)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}
