import SwiftUI
import CabalmailKit

/// Formatting toolbar above the rich-text editor surface. Mirrors the React
/// `MenuBar` button set: bold/italic/underline/strikethrough, H1-H4,
/// bullet/ordered list, alignment, link, horizontal rule, undo/redo, plus an
/// "Import from Markdown" entry the host wires up to the dual-mode tabs.
///
/// The buttons forward straight to `RichTextEditorController.execute(_:)`,
/// which calls into `editor-bridge.js` -> `document.execCommand`. State (which
/// buttons are highlighted) reads from `controller.selection`, the bridge's
/// latest snapshot.
struct RichTextToolbar: View {
    let controller: RichTextEditorController
    let selection: RichTextEditorController.Selection
    let onImportFromMarkdown: () -> Void

    @State private var showLinkPrompt = false
    @State private var linkUrl = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                toolbarButton(
                    "Import from Markdown",
                    systemImage: "arrow.uturn.left.square",
                    action: onImportFromMarkdown
                )
                divider
                toggle("Bold", systemImage: "bold", isOn: selection.bold) {
                    Task { await controller.execute(.bold) }
                }
                toggle("Italic", systemImage: "italic", isOn: selection.italic) {
                    Task { await controller.execute(.italic) }
                }
                toggle("Underline", systemImage: "underline", isOn: selection.underline) {
                    Task { await controller.execute(.underline) }
                }
                toggle("Strikethrough", systemImage: "strikethrough", isOn: selection.strikethrough) {
                    Task { await controller.execute(.strikethrough) }
                }
                divider
                ForEach(1...4, id: \.self) { level in
                    toggle(
                        "Heading \(level)",
                        label: "H\(level)",
                        isOn: selection.headingLevel == level
                    ) {
                        Task { await controller.execute(.heading(level: level)) }
                    }
                }
                divider
                toggle("Bullet list", systemImage: "list.bullet", isOn: selection.bulletList) {
                    Task { await controller.execute(.bulletList) }
                }
                toggle("Numbered list", systemImage: "list.number", isOn: selection.orderedList) {
                    Task { await controller.execute(.orderedList) }
                }
                divider
                toggle("Align left", systemImage: "text.alignleft", isOn: selection.alignment == .left) {
                    Task { await controller.execute(.alignLeft) }
                }
                toggle("Align center", systemImage: "text.aligncenter", isOn: selection.alignment == .center) {
                    Task { await controller.execute(.alignCenter) }
                }
                toggle("Align right", systemImage: "text.alignright", isOn: selection.alignment == .right) {
                    Task { await controller.execute(.alignRight) }
                }
                divider
                toggle("Link", systemImage: "link", isOn: selection.link) {
                    linkUrl = ""
                    showLinkPrompt = true
                }
                toolbarButton(
                    "Remove link",
                    systemImage: "link.badge.plus",
                    enabled: selection.link
                ) {
                    Task { await controller.execute(.unlink) }
                }
                toolbarButton(
                    "Horizontal rule",
                    systemImage: "minus",
                    action: { Task { await controller.execute(.horizontalRule) } }
                )
                divider
                toolbarButton(
                    "Undo",
                    systemImage: "arrow.uturn.backward",
                    enabled: selection.canUndo
                ) {
                    Task { await controller.execute(.undo) }
                }
                toolbarButton(
                    "Redo",
                    systemImage: "arrow.uturn.forward",
                    enabled: selection.canRedo
                ) {
                    Task { await controller.execute(.redo) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .alert("Add link", isPresented: $showLinkPrompt) {
            TextField("https://example.com", text: $linkUrl)
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let trimmed = linkUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task { await controller.execute(.createLink(url: trimmed)) }
            }
        } message: {
            Text("URL to link the selected text to.")
        }
    }

    private var divider: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func toolbarButton(
        _ help: String,
        systemImage: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func toggle(
        _ help: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 24, minHeight: 24)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear)
                .cornerRadius(4)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func toggle(
        _ help: String,
        label: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 26, minHeight: 24)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear)
                .cornerRadius(4)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
