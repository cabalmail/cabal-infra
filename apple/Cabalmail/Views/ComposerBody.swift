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
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.sentences)
                #endif
        }
    }
}
