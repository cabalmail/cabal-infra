#if os(macOS)
import SwiftUI

/// Disabled stand-ins for `MessageDetailView`'s eleven top-toolbar buttons,
/// shown while the reading pane has no message (see the call sites in
/// `DesktopShell`'s reader for why the slots must be reserved at all).
///
/// Derived from `ReaderToolbarLayout.macToolbar` — the same order the real
/// toolbar draws — so the reserved slots and the live toolbar can't drift
/// apart, and opening a message never shifts a button under the pointer.
/// Icons and labels mirror each real button's quiescent default; we don't
/// bother reading Preferences for the dispose icon — `.archive` is the
/// default and a one-frame icon flip when the real toolbar takes over is
/// cheap.
///
/// Each stand-in is built as the *kind* of control its live twin is, from
/// `ReaderToolbarLayout.macControlShape` — a chevron segment costs real
/// points, so a plain-button stand-in for the Reply menu or the dispose,
/// read and Flag split buttons is narrower than what replaces it, and every
/// slot after it slides sideways when a message opens (#2016). A split
/// button's stand-in also carries as many menu rows as its twin's menu
/// (`ReaderToolbarLayout.macStandInMenuRows`), which decides whether it
/// draws in a glass capsule of its own or shares its neighbours'.
struct EmptyDetailToolbar: ToolbarContent {
    /// How many rows the flag control's palette menu will offer. Zero
    /// makes its live twin the plain button it is with an empty palette
    /// (`flagButton`), any more a split button with that many rows. Read
    /// from `Preferences` by the shell that installs these stand-ins — a
    /// `ToolbarContent` has no reader model to ask.
    let flagMenuRowCount: Int

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
        ToolbarStandIn(
            title: action.quiescentTitle,
            symbol: action.quiescentSymbol,
            shape: ReaderToolbarLayout.macControlShape(
                for: action,
                flagMenuHasRows: flagMenuRowCount > 0
            ),
            menuRows: ReaderToolbarLayout.macStandInMenuRows(
                for: action,
                flagMenuRowCount: flagMenuRowCount
            )
        )
    }
}

/// One disabled stand-in for a reader toolbar slot, drawn as the kind of
/// control that will replace it — used by both stand-in sets
/// (`EmptyDetailToolbar` here, `EmptyFeedDetailToolbar` for the feed
/// reader), and living inside this file's `#if os(macOS)` rather than
/// beside `ReaderToolbarControlShape` because the shared app layer's
/// platform-conditional ratchet may not grow a row
/// (`scripts/check-platform-conditionals.py`).
///
/// The menu shapes carry inert rows rather than no rows at all: AppKit
/// draws a `Menu` with an empty content block as a plain button, which is
/// the very footprint these stand-ins exist to avoid. How many is
/// `menuRows`, because a split button's row count decides whether liquid
/// glass gives it a capsule of its own (see
/// `ReaderToolbarLayout.macStandInMenuRows`). Nothing can open them — the
/// whole control is disabled — so the rows are never seen.
struct ToolbarStandIn: View {
    let title: String
    let symbol: String
    let shape: ReaderToolbarControlShape
    /// Inert rows in a menu shape's menu; a plain button ignores it.
    var menuRows = 1

    var body: some View {
        switch shape {
        case .button:
            Button {} label: { face }
                .disabled(true)
        case .menu:
            Menu { placeholderRows } label: { face }
                .disabled(true)
        case .splitButton:
            Menu { placeholderRows } label: { face } primaryAction: {}
                .menuIndicator(.visible)
                .disabled(true)
        }
    }

    private var face: some View {
        Label(title, systemImage: symbol)
    }

    private var placeholderRows: some View {
        ForEach(0..<max(menuRows, 1), id: \.self) { _ in
            Button {} label: { face }
        }
    }
}
#endif
