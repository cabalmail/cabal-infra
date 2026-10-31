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
    /// Laptop pose (`ComposeLaptopArrangement`): the body's height above the
    /// fold, the formatting controls folded away at rest, and Edit Message.
    /// Nil outside the iOS compose form, where every value is today's.
    @Environment(\.composeLaptop) private var laptop
    @FocusState private var markdownFocused: Bool

    /// The picker and formatting controls fold away at rest in laptop pose.
    private var formattingHidden: Bool {
        ComposeLaptopPolicy.formattingHidden(
            host: laptop?.host ?? .navigationBar,
            editorFocused: model.editorFocused,
            markdownFocused: markdownFocused
        )
    }

    /// The editors' own floor, which under a laptop height gives way to the
    /// controls coming back rather than overflow the row.
    private var editorFloor: CGFloat {
        laptop?.bodyFrame.height == nil ? 180 : 0
    }

    /// The body's own floor, which a laptop height replaces
    /// (`ComposeLaptopPolicy.bodyFloor`).
    private var bodyFloor: CGFloat {
        laptop?.bodyFrame.height == nil ? 240 : 0
    }

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
            .collapsed(formattingHidden)

            switch model.editorMode {
            case .rich:
                richPane
            case .markdown:
                markdownPane
            }
        }
        .frame(minHeight: bodyFloor)
        .composeLaptopBody(laptop)
        .onChange(of: laptop?.editRequests) { _, _ in resumeEditing() }
        .onChange(of: markdownFocused) { _, focused in laptop?.markdownEditing(focused) }
    }

    /// Edit Message: the caret back where it was, the keyboard up.
    private func resumeEditing() {
        switch model.editorMode {
        case .rich:
            Task { await model.editorController.focusRestoringCaret() }
        case .markdown:
            markdownFocused = true
        }
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
            .collapsed(formattingHidden)
            #if os(macOS)
            Divider()
            #endif
            RichTextEditorView(controller: model.editorController)
                .frame(minHeight: editorFloor)
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
            .collapsed(formattingHidden)

            TextEditor(text: $model.markdownBody)
                .font(.body.monospaced())
                .frame(minHeight: editorFloor)
                .focused($markdownFocused)
                .takesDroppedAttachments(into: model)
                // Same reason as the rich pane: a bare TextEditor lands as an
                // unlabelled, unidentified text view (#1157).
                .accessibilityIdentifier("compose.body.markdown")
                .textEntry(.sentences)
        }
    }
}
