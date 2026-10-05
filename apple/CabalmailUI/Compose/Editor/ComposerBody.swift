import SwiftUI
import CabalmailKit

/// Dual-mode editor body for the compose form — mirrors the React composer's
/// "Rich Text" / "Markdown" tabbed surface. The model holds the canonical
/// Markdown source and a snapshot of the rich editor's HTML; this view
/// renders whichever pane the user has selected and exposes import buttons so
/// they can copy converted content across the tabs on demand.
///
/// Conversion always happens through `model.editorController` so the marked +
/// turndown rules stay byte-identical to the React side. The view does no
/// markdown / HTML manipulation of its own.
struct ComposerBody: View {
    @Bindable var model: ComposeViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Editor mode", selection: $model.editorMode) {
                Text("Rich Text").tag(ComposeViewModel.EditorMode.rich)
                Text("Markdown").tag(ComposeViewModel.EditorMode.markdown)
            }
            .pickerStyle(.segmented)
            // Keep the label for accessibility only. Outside a Form
            // (the macOS compose layout) SwiftUI would otherwise
            // render "Editor mode" beside the segmented control.
            .labelsHidden()
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .accessibilityIdentifier("compose.body.mode")

            switch model.editorMode {
            case .rich:
                richPane
            case .markdown:
                markdownPane
            }
        }
        .frame(minHeight: 240)
    }

    @ViewBuilder
    private var richPane: some View {
        VStack(spacing: 0) {
            RichTextToolbar(
                controller: model.editorController,
                selection: model.richSelection,
                onImportFromMarkdown: {
                    Task { await model.importFromMarkdown() }
                }
            )
            #if os(macOS)
            Divider()
            #endif
            RichTextEditorView(controller: model.editorController)
                .frame(minHeight: 180)
                // The pane's only addressable descendants are web content,
                // which publishes no identifier and is not hittable. Without
                // an identifier here the body is reachable only by coordinate
                // tap, which is fatal to the test harness on visionOS (#1157).
                .accessibilityIdentifier("compose.body.rich")
                #if os(iOS) || os(visionOS)
                // On iPadOS/visionOS, UIKit resolves ⌘-chords at the
                // key-command layer before web content ever sees a keydown,
                // so the editor page's own ⌘⇧V handler (the macOS path)
                // never fires — this shortcut is the hardware-keyboard
                // route. Mounted only while the editor has focus so the
                // chord stays a text-editing key scoped to the editor.
                .background {
                    if model.editorFocused {
                        Button("Paste and Match Style") {
                            Task { await model.editorController.pastePlainText() }
                        }
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                        .opacity(0)
                        .accessibilityHidden(true)
                    }
                }
                #endif
        }
    }

    @ViewBuilder
    private var markdownPane: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    Task { await model.importFromRichText() }
                } label: {
                    Label("Import from Rich Text", systemImage: "arrow.uturn.right.square")
                }
                .buttonStyle(.borderless)
                .help("Replace Markdown content with converted Rich Text content")
                .accessibilityLabel("Import from Rich Text")
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            TextEditor(text: $model.markdownBody)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                // Same reason as the rich pane: a bare TextEditor lands as an
                // unlabelled, unidentified text view (#1157).
                .accessibilityIdentifier("compose.body.markdown")
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.sentences)
                #endif
        }
    }
}
