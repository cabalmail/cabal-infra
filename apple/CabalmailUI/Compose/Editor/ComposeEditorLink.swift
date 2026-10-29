import CabalmailKit

/// Connects a composer to its rich-text editor: the toolbar's selection
/// state, focus, the provenance flag the send path reads, the bridge's
/// health, the inline images the page shows, and the files dropped or
/// pasted onto it. It owns that wiring, which runs once, when the composer
/// is made, and before the page can report anything; every callback holds
/// the composer weakly, since it owns the editor.
@MainActor
enum ComposeEditorLink {
    static func connect(_ editor: RichTextEditorController, to model: ComposeViewModel) {
        editor.onSelectionChanged = { [weak model] selection in
            model?.richSelection = selection
        }
        editor.onEditorFocusChanged = { [weak model] focused in
            model?.editorFocused = focused
        }
        // The user's first character mutates rich-only state; the mirror
        // flag flips and the send logic stops treating the rich pane as a
        // pure echo of the markdown source.
        editor.onContentChanged = { [weak model] in
            model?.richMirrorsMarkdown = false
        }
        // A bridge that dies while bootstrapping never posts `ready`, so
        // the rich pane (and send-time conversion) is out of commission
        // for this compose. Say so instead of failing silently (#734).
        editor.onBridgeError = { [weak model] message in
            model?.noteEditorUnavailable(message)
        }
        // A `ready` that lands after the failure means the boot was merely
        // slow; the controller has already cleared its own failure, so drop
        // the banner and re-enable Send rather than stranding the compose.
        editor.onReady = { [weak model] in
            model?.noteEditorRecovered()
        }
        // The rich pane's inline images load from the composer's own store,
        // and the size warning counts the ones the body still shows.
        editor.inlineImages.provider = { [weak model] contentID in
            model?.inlineImages.image(for: contentID).map { ($0.data, $0.mimeType) }
        }
        editor.inlineImages.onShownChanged = { [weak model] contentIDs in
            model?.inlineImages.shown = contentIDs
        }
        DroppedAttachment.takeEditorDrops(into: model)
    }
}
