#if os(macOS)
import SwiftUI

/// Disabled stand-ins for `MessageDetailView`'s eleven top-toolbar buttons,
/// shown while the reading pane has no message (see the call sites in
/// `MailRootView.detailColumn` for why the slots must be reserved at all).
///
/// Derived from `ReaderToolbarLayout.macToolbar` — the same order the real
/// toolbar draws — so the reserved slots and the live toolbar can't drift
/// apart, and opening a message never shifts a button under the pointer.
/// Icons and labels mirror each real button's quiescent default; we don't
/// bother reading Preferences for the dispose icon — `.archive` is the
/// default and a one-frame icon flip when the real toolbar takes over is
/// cheap.
struct EmptyDetailToolbar: ToolbarContent {
    private let actions = ReaderToolbarLayout.macToolbar(leading: .reply)

    // Split in two because a result-builder block takes at most ten children
    // and there are eleven slots.
    var body: some ToolbarContent {
        leadingStandIns
        trailingStandIns
    }

    @ToolbarContentBuilder
    private var leadingStandIns: some ToolbarContent {
        ToolbarItem { standIn(for: actions[0]) }
        ToolbarItem { standIn(for: actions[1]) }
        ToolbarItem { standIn(for: actions[2]) }
        ToolbarItem { standIn(for: actions[3]) }
        ToolbarItem { standIn(for: actions[4]) }
        ToolbarItem { standIn(for: actions[5]) }
    }

    @ToolbarContentBuilder
    private var trailingStandIns: some ToolbarContent {
        ToolbarItem { standIn(for: actions[6]) }
        ToolbarItem { standIn(for: actions[7]) }
        ToolbarItem { standIn(for: actions[8]) }
        ToolbarItem { standIn(for: actions[9]) }
        ToolbarItem { standIn(for: actions[10]) }
    }

    private func standIn(for action: ReaderToolbarAction) -> some View {
        Button {} label: {
            Label(title(for: action), systemImage: symbol(for: action))
        }
        .disabled(true)
    }

    // Exhaustive one-case-per-action lookups; the branch count IS the point.
    // swiftlint:disable:next cyclomatic_complexity
    private func symbol(for action: ReaderToolbarAction) -> String {
        switch action {
        case .reply:         return "arrowshape.turn.up.left"
        case .editDraft:     return "square.and.pencil"
        case .dispose:       return "archivebox"
        case .toggleRead:    return "envelope.badge"
        case .remoteContent: return "eye.slash"
        case .toggleFlag:    return "flag"
        case .readerMode:    return "doc.richtext"
        case .move:          return "folder"
        case .plainText:     return "doc.plaintext"
        case .viewSource:    return "chevron.left.forwardslash.chevron.right"
        case .viewHeaders:   return "list.bullet.rectangle"
        case .printMessage:  return "printer"
        case .overflow:      return "ellipsis.circle"
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func title(for action: ReaderToolbarAction) -> String {
        switch action {
        case .reply:         return "Reply"
        case .editDraft:     return "Edit Draft"
        case .dispose:       return "Archive"
        case .toggleRead:    return "Mark as read"
        case .remoteContent: return "Show remote content"
        case .toggleFlag:    return "Flag"
        case .readerMode:    return "Show reader view"
        case .move:          return "Move to folder…"
        case .plainText:     return "Show plain text"
        case .viewSource:    return "View source"
        case .viewHeaders:   return "View headers"
        case .printMessage:  return "Print…"
        case .overflow:      return "More actions"
        }
    }
}
#endif
