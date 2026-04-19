import SwiftUI
import CabalmailKit

/// Envelope list for a single folder. Selection is lifted to the parent so
/// the split view can bind the detail pane to it.
struct MessageListView: View {
    let folder: Folder
    @Binding var selection: Envelope?

    @Environment(AppState.self) private var appState
    @State private var model: MessageListViewModel?

    var body: some View {
        Group {
            if let model {
                content(for: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(folder.name)
        .task {
            if model == nil, let client = appState.client {
                model = MessageListViewModel(folder: folder, client: client)
                await model?.loadInitial()
            }
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
                MessageRow(envelope: envelope)
                    .tag(envelope)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await model.dispose(envelope) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await model.toggleFlag(envelope) }
                        } label: {
                            Label("Flag", systemImage: "flag")
                        }
                        .tint(.orange)
                    }
                    .task {
                        await model.loadMoreIfNeeded(currentItem: envelope)
                    }
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
