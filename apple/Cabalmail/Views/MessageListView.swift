import SwiftUI
import CabalmailKit

/// Envelope list for a single folder. Selection is lifted to the parent so
/// the split view can bind the detail pane to it.
struct MessageListView: View {
    let folder: Folder
    @Binding var selection: Envelope?

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @State private var model: MessageListViewModel?
    @State private var composeSeed: Draft?

    var body: some View {
        Group {
            if let model {
                content(for: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem {
                Button {
                    composeSeed = ReplyBuilder.newDraft()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .accessibilityLabel("New Message")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $composeSeed) { seed in
            composeSheet(for: seed)
        }
        .task {
            if model == nil, let client = appState.client {
                model = MessageListViewModel(
                    folder: folder,
                    client: client,
                    preferences: preferences
                )
                await model?.loadInitial()
                await model?.startWatching()
            }
        }
        .onDisappear {
            // Tear down the IDLE watcher when the folder drops off-screen.
            // The view is rebuilt (via `.id(folder.path)` in MailRootView)
            // when the user picks another folder, so `startWatching` in the
            // new instance's `.task` starts a fresh IDLE session against the
            // new mailbox.
            let model = model
            Task { await model?.stopWatching() }
        }
        // macOS Commands menu (File → New Message, Mailbox → Refresh) and
        // keyboard shortcuts route through `AppState` tick counters. The
        // view lifted into view reacts by opening compose / kicking a
        // refresh. Using the currently-displayed list as the refresh target
        // matches every desktop mail client's convention.
        .onChange(of: appState.composeRequestTick) { _, _ in
            composeSeed = ReplyBuilder.newDraft()
        }
        .onChange(of: appState.refreshRequestTick) { _, _ in
            Task { await model?.refresh() }
        }
        .onChange(of: appState.lastDisposedEnvelope) { _, signal in
            // Detail view archived / trashed the current message. Advance
            // the split-view selection to the next unread envelope (so the
            // user can keep triaging without bouncing back to the list),
            // then prune the matching row so it disappears immediately.
            // Other folders ignore the signal.
            guard let signal, signal.folderPath == folder.path else { return }
            let current = model?.envelopes.first { $0.uid == signal.uid }
            selection = current.flatMap { model?.nextUnreadEnvelope(after: $0) }
            model?.pruneEnvelope(uid: signal.uid)
        }
    }

    @ViewBuilder
    private func composeSheet(for seed: Draft) -> some View {
        if let client = appState.client {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                preferences: preferences,
                onClose: { composeSeed = nil }
            ))
            .environment(appState)
            .environment(preferences)
        }
    }

    @ViewBuilder
    private func content(for model: MessageListViewModel) -> some View {
        @Bindable var model = model
        List(selection: $selection) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if model.isLoading && model.envelopes.isEmpty {
                ProgressView("Fetching messages…")
            }
            ForEach(model.envelopes) { envelope in
                row(for: envelope, model: model)
            }
            if model.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $model.searchQuery, prompt: "Search mailbox")
        .onSubmit(of: .search) {
            Task { await model.runSearch() }
        }
        .refreshable {
            await model.refresh()
        }
    }

    @ViewBuilder
    private func row(for envelope: Envelope, model: MessageListViewModel) -> some View {
        MessageRow(envelope: envelope)
            .tag(envelope)
            #if os(visionOS)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            #endif
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    Task { await model.dispose(envelope) }
                } label: {
                    disposeActionLabel(for: model.disposeAction)
                }
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task { await model.toggleSeen(envelope) }
                } label: {
                    markReadLabel(for: envelope)
                }
                .tint(.blue)
            }
            .contextMenu { rowContextMenu(for: envelope, model: model) }
            .task {
                await model.loadMoreIfNeeded(currentItem: envelope)
            }
    }

    @ViewBuilder
    private func rowContextMenu(
        for envelope: Envelope,
        model: MessageListViewModel
    ) -> some View {
        Button {
            Task { await model.toggleFlag(envelope) }
        } label: {
            Label(
                envelope.flags.contains(.flagged) ? "Unflag" : "Flag",
                systemImage: envelope.flags.contains(.flagged) ? "flag.slash" : "flag"
            )
        }
        Button {
            Task { await model.toggleSeen(envelope) }
        } label: {
            Label(
                envelope.flags.contains(.seen) ? "Mark as Unread" : "Mark as Read",
                systemImage: envelope.flags.contains(.seen) ? "envelope.badge" : "envelope.open"
            )
        }
        Button(role: .destructive) {
            Task { await model.dispose(envelope) }
        } label: {
            disposeActionLabel(for: model.disposeAction)
        }
    }

    @ViewBuilder
    private func disposeActionLabel(for action: DisposeAction) -> some View {
        switch action {
        case .archive: Label("Archive", systemImage: "archivebox")
        case .trash:   Label("Trash", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func markReadLabel(for envelope: Envelope) -> some View {
        if envelope.flags.contains(.seen) {
            Label("Unread", systemImage: "envelope.badge")
        } else {
            Label("Read", systemImage: "envelope.open")
        }
    }
}

private struct MessageRow: View {
    let envelope: Envelope

    var body: some View {
        HStack(alignment: .top) {
            Circle()
                .fill(envelope.flags.contains(.seen) ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(senderLabel)
                        .font(.subheadline)
                        .fontWeight(envelope.flags.contains(.seen) ? .regular : .semibold)
                    Spacer()
                    if envelope.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if envelope.flags.contains(.flagged) {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(dateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(envelope.subject ?? "(no subject)")
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var senderLabel: String {
        envelope.from.first?.name ?? envelope.from.first?.mailbox ?? "unknown"
    }

    private var dateLabel: String {
        guard let date = envelope.date ?? envelope.internalDate else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        if Calendar.current.isDateInToday(date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }
}
