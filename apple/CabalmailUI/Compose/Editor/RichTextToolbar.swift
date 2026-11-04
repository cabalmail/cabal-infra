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
    /// Compose's laptop pose, which counts the link prompt's keyboard as
    /// editing; nil outside the iOS compose form.
    @Environment(\.composeLaptop) private var laptop

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // No spacing and no vertical padding of the bar's own: each
            // button takes that room as its `hitPadding`.
            HStack(spacing: 0) {
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
            .padding(.horizontal, 6 - Self.hitPadding.leading)
        }
        .alert("Add link", isPresented: $showLinkPrompt) {
            TextField("https://example.com", text: $linkUrl)
                .textEntry(.url)
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
        .onChange(of: showLinkPrompt) { _, shown in laptop?.promptEditing(shown) }
    }

    /// What a button takes taps over beyond the face it draws: the gap
    /// around the face, which the bar used to leave as stack spacing (4 pt)
    /// and vertical padding (4 pt). With the `contentShape` that claims it,
    /// a target is 28 x 32 pt over a 24 pt face; without one a button took
    /// taps on its glyph alone (8 x 10 pt for Bold). The faces, the bar's
    /// height and the spacing between faces are where they were. A touch
    /// target wants 36 pt on a Mac and 44 on iOS; reaching either would
    /// spread the bar out, a visible change.
    static let hitPadding = EdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)

    /// The rule between groups. Its padding makes up the stack spacing the
    /// buttons' hit padding no longer reaches, so a group's gap stays 13 pt.
    private var divider: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 4)
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
                .padding(Self.hitPadding)
                .contentShape(Rectangle())
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
                .background(isOn ? ColorTokens.accentForestWash : .clear)
                .cornerRadius(4)
                .padding(Self.hitPadding)
                .contentShape(Rectangle())
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
                .background(isOn ? ColorTokens.accentForestWash : .clear)
                .cornerRadius(4)
                .padding(Self.hitPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
