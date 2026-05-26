import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import CabalmailKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// "View source" sheet — shows the raw RFC 5322 source of a message with
/// segmented tabs for Full / Headers / Body. Mirrors the React webmail's
/// View Source modal so the Apple clients reach parity on what was a
/// reader-overflow gap.
///
/// The sheet asks `MessageDetailViewModel.rawSourceBytes()` for the bytes,
/// which goes through the same body cache as the in-pane render. First
/// open is a fetch; subsequent opens hit the cache populated by the body
/// fetch that drew the reading view.
struct MessageSourceSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case full
        case headers
        case body

        var id: String { rawValue }
        var label: String {
            switch self {
            case .full:    return "Full"
            case .headers: return "Headers"
            case .body:    return "Body"
            }
        }
    }

    let model: MessageDetailViewModel
    let initialTab: Tab
    let onClose: () -> Void

    @State private var tab: Tab
    @State private var raw: String?
    @State private var errorMessage: String?
    @State private var isLoading = true

    init(
        model: MessageDetailViewModel,
        initialTab: Tab = .full,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.initialTab = initialTab
        self.onClose = onClose
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Message source")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading source…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(currentText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: onClose)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    copyCurrent()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(raw == nil)
                if let raw {
                    ShareLink(
                        item: MessageSourceFile(raw: raw, subject: model.envelope.subject),
                        preview: SharePreview(emlFilename(for: model.envelope.subject))
                    ) {
                        Label("Share .eml", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("Source actions")
            }
            .disabled(raw == nil)
        }
    }

    private var currentText: String {
        guard let raw else { return "" }
        switch tab {
        case .full:
            return raw
        case .headers:
            return MessageSource.split(raw).headers
        case .body:
            return MessageSource.split(raw).body
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let bytes = try await model.rawSourceBytes()
            raw = MessageSource.decode(bytes)
        } catch {
            errorMessage = "Couldn't load message source: \(error.localizedDescription)"
        }
    }

    private func copyCurrent() {
        let text = currentText
        guard !text.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Transferable wrapper so ShareLink can offer "Share .eml" with the raw
/// bytes encoded as a UTF-8 .eml document. The .eml UTI is the standard
/// for RFC 5322 source on Apple platforms; downstream apps (Mail, Files)
/// recognize it.
private struct MessageSourceFile: Transferable {
    let raw: String
    let subject: String?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .emailMessage) { item in
            Data(item.raw.utf8)
        }
        .suggestedFileName { item in emlFilename(for: item.subject) }
    }
}

private func emlFilename(for subject: String?) -> String {
    let base = (subject ?? "message")
        .replacingOccurrences(of: "/", with: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let safe = base.isEmpty ? "message" : base
    return "\(safe).eml"
}
