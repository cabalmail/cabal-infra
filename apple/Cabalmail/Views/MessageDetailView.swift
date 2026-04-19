import SwiftUI
import CabalmailKit

/// Message detail pane — headers block, body renderer, attachment strip.
///
/// Body rendering prefers HTML when both alternatives are present (matches
/// the React app). Remote content is gated off by default per the plan's
/// Phase 4 preference; the toolbar button toggles the reload.
///
/// Layout: the header block and attachment strip sit in a fixed-height
/// region at the top; the body fills the remaining height of the detail
/// column with its own scroll. Previously we wrapped everything in a single
/// outer `ScrollView`, which forced the `WKWebView` onto a fixed `minHeight`
/// (the web view has no intrinsic content size for SwiftUI to grow into),
/// so resizing the window had no effect on the reading area.
struct MessageDetailView: View {
    let folder: Folder
    let envelope: Envelope

    @Environment(AppState.self) private var appState
    @State private var model: MessageDetailViewModel?
    @State private var composeSeed: Draft?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock
                .padding(.horizontal)
                .padding(.top)
            if let attachments = model?.attachments, !attachments.isEmpty {
                AttachmentStrip(attachments: attachments)
                    .padding(.vertical, 8)
            }
            Divider()
            if let model {
                body(for: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(envelope.subject ?? "(no subject)")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .sheet(item: $composeSeed) { seed in
            composeSheet(for: seed)
        }
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
    private func composeSheet(for seed: Draft) -> some View {
        if let client = appState.client {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                onClose: { composeSeed = nil }
            ))
            .environment(appState)
        }
    }

    /// Opens compose pre-populated for a `reply` / `replyAll` / `forward`.
    /// Pulls the user's address list so `ReplyBuilder` can pick a default
    /// From by matching the original message's recipients against owned
    /// addresses (per the React app's 0.3.0 behavior).
    private func beginCompose(_ mode: ReplyBuilder.ReplyMode) {
        guard let client = appState.client else { return }
        Task { @MainActor in
            let addresses = (try? await client.addresses()) ?? []
            composeSeed = ReplyBuilder.build(
                from: envelope,
                body: model?.plainText,
                mode: mode,
                userAddresses: addresses
            )
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
                .padding()
        } else if let html = model.htmlBody {
            // WKWebView manages its own scrolling; fill the available space
            // and let it page through tall messages internally.
            HTMLBodyView(
                html: html,
                inlineImages: model.inlineImages,
                allowRemote: model.remoteContentAllowed
            )
        } else if let plain = model.plainText {
            // `.primary` foreground adapts to light/dark mode and gives
            // message text the same contrast as the surrounding chrome.
            ScrollView {
                Text(plain)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else if model.isLoading {
            ProgressView("Fetching message…")
        } else {
            Text("No renderable body.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button {
                    beginCompose(.reply)
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                Button {
                    beginCompose(.replyAll)
                } label: {
                    Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                }
                Button {
                    beginCompose(.forward)
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.forward")
                }
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .accessibilityLabel("Reply")
            }
        }
        ToolbarItem {
            if let model {
                Button {
                    Task { await model.toggleSeen() }
                } label: {
                    // Icon reflects the current state; tap-action is the
                    // inverse. Matches Mail.app: an already-read message
                    // shows "envelope.open" and tapping marks it unread.
                    Image(systemName: model.isSeen ? "envelope.open" : "envelope.badge")
                        .accessibilityLabel(model.isSeen ? "Mark as unread" : "Mark as read")
                }
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
