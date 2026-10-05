import SwiftUI
import CabalmailKit

// The reader actions promoted from the overflow menu to first-class toolbar
// buttons in the #1047 rework. Referenced from the macOS top toolbar only
// (`ReaderToolbarLayout.macToolbar`) — the touch platforms keep the same
// actions as rows in `overflowMenuButton` — but compiled everywhere, like the
// rest of the `toolbarButton(for:)` set. A sibling of
// `MessageDetailView+Toolbar.swift`, split out for the same file-length
// reason.

extension MessageDetailView {
    #if os(macOS)
    // The macOS top toolbar's two halves (referenced from `toolbarContent`):
    // individual `ToolbarItem`s, deliberately not a `ToolbarItemGroup` —
    // AppKit evicts a group as one unit, which would demote a whole run of
    // buttons at once instead of one at a time in priority order. Split in
    // two because a result-builder block takes at most ten children and
    // there are eleven slots.
    private var macToolbarActions: [ReaderToolbarAction] {
        ReaderToolbarLayout.macToolbar(leading: model?.leadingToolbarAction ?? .reply)
    }

    @ToolbarContentBuilder
    var macToolbarLeading: some ToolbarContent {
        let actions = macToolbarActions
        ToolbarItem { toolbarButton(for: actions[0]) }
        ToolbarItem { toolbarButton(for: actions[1]) }
        ToolbarItem { toolbarButton(for: actions[2]) }
        ToolbarItem { toolbarButton(for: actions[3]) }
        ToolbarItem { toolbarButton(for: actions[4]) }
        ToolbarItem { toolbarButton(for: actions[5]) }
    }

    @ToolbarContentBuilder
    var macToolbarTrailing: some ToolbarContent {
        let actions = macToolbarActions
        ToolbarItem { toolbarButton(for: actions[6]) }
        ToolbarItem { toolbarButton(for: actions[7]) }
        ToolbarItem { toolbarButton(for: actions[8]) }
        ToolbarItem { toolbarButton(for: actions[9]) }
        ToolbarItem { toolbarButton(for: actions[10]) }
    }
    #endif

    /// Move the open message to a chosen folder. Cmd+Shift+M rides
    /// `readerChordHosts`.
    @ViewBuilder
    var moveButton: some View {
        Button {
            moveSheetPresented = true
        } label: {
            Label("Move to folder…", systemImage: "folder")
        }
        .accessibilityIdentifier("reader.move")
    }

    /// Toggle between the HTML and plain-text alternatives. The menu row
    /// twin suppresses itself when a message doesn't carry both parts; a
    /// toolbar button that came and went would shift its neighbours'
    /// positions, so this one stays put and disables instead — the same
    /// stable-footprint treatment as `remoteContentButton`.
    @ViewBuilder
    var plainTextButton: some View {
        if let model {
            Button {
                model.forcePlainText.toggle()
            } label: {
                Label(
                    model.forcePlainText ? "Show HTML" : "Show plain text",
                    systemImage: model.forcePlainText ? "doc.richtext" : "doc.plaintext"
                )
            }
            .disabled(model.htmlBody == nil || model.plainText == nil)
            .accessibilityIdentifier("reader.plainText")
        }
    }

    /// Raw RFC 5322 source of the message the reader has already fetched.
    /// Cmd+U rides `readerChordHosts`.
    @ViewBuilder
    var viewSourceButton: some View {
        Button {
            sourceSheetTab = .full
        } label: {
            Label("View source", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .accessibilityIdentifier("reader.viewSource")
    }

    /// The headers slice of the same source sheet.
    @ViewBuilder
    var viewHeadersButton: some View {
        Button {
            sourceSheetTab = .headers
        } label: {
            Label("View headers", systemImage: "list.bullet.rectangle")
        }
        .accessibilityIdentifier("reader.viewHeaders")
    }

    /// Print the rendered message. Cmd+P rides `readerChordHosts`. Disabled
    /// until a body has loaded — printing an empty WKWebView is a non-action.
    @ViewBuilder
    var printButton: some View {
        if let model {
            Button {
                model.requestPrint()
            } label: {
                Label("Print…", systemImage: "printer")
            }
            .disabled(model.htmlBody == nil && model.plainText == nil)
            .accessibilityIdentifier("reader.print")
        }
    }
}
