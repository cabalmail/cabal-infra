import SwiftUI
import CabalmailKit

/// Message detail pane — headers block, body renderer, attachment strip.
///
/// Body rendering prefers HTML when both alternatives are present (matches
/// the React app). Remote content is gated off by default per the plan's
/// Phase 4 preference; the toolbar button toggles the reload.
struct MessageDetailView: View {
    let folder: Folder
    let envelope: Envelope

    @Environment(AppState.self) private var appState
    @State private var model: MessageDetailViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerBlock
                Divider()
                if let model {
                    body(for: model)
                } else {
                    ProgressView()
                }
            }
            .padding()
        }
        .navigationTitle(envelope.subject ?? "(no subject)")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .task {
            if model == nil, let client = appState.client {
                model = MessageDetailViewModel(
                    folder: folder,
                    envelope: envelope,
                    client: client
                )
                await model?.load()
            }
        }
    }

    @ViewBuilder
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let from = envelope.from.first {
                Text(from.formatted)
                    .font(.headline)
            }
            if !envelope.to.isEmpty {
                Text("To: \(envelope.to.map(\.formatted).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !envelope.cc.isEmpty {
                Text("Cc: \(envelope.cc.map(\.formatted).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let date = envelope.date ?? envelope.internalDate {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func body(for model: MessageDetailViewModel) -> some View {
        if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if let html = model.htmlBody {
            HTMLBodyView(
                html: html,
                inlineImages: model.inlineImages,
                allowRemote: model.remoteContentAllowed
            )
            .frame(minHeight: 400)
        } else if let plain = model.plainText {
            Text(plain)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.isLoading {
            ProgressView("Fetching message…")
        } else {
            Text("No renderable body.")
                .foregroundStyle(.secondary)
        }
        if !model.attachments.isEmpty {
            Divider().padding(.vertical, 4)
            AttachmentStrip(attachments: model.attachments)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await model?.markAsRead() }
            } label: {
                Image(systemName: "envelope.open")
                    .accessibilityLabel("Mark as read")
            }
        }
        ToolbarItem {
            if let model, model.htmlBody != nil {
                Button {
                    model.toggleRemoteContent()
                } label: {
                    Image(systemName: model.remoteContentAllowed
                          ? "eye.fill"
                          : "eye.slash")
                        .accessibilityLabel(
                            model.remoteContentAllowed
                            ? "Hide remote content"
                            : "Show remote content"
                        )
                }
            }
        }
    }
}
