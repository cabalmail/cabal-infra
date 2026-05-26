import SwiftUI
import CabalmailKit

// Row rendering and per-row affordances for `MessageListView`. Lives in
// a same-module extension so the primary view body stays under
// SwiftLint's `type_body_length` cap. Holds:
//   - `row(for:model:isSelected:)` — list-row content + swipe actions
//   - `rowContextMenu` — right-click / long-press menu mirroring swipes
//   - `disposeActionLabel` / `markReadLabel` — shared icons for both
//   - `addressFilterChip` — the in-list banner when `addressFilter` is
//     set (used by `Messages` view's address-tap surface)
//   - `filteredEnvelopes` — case-insensitive `To`/`Cc` substring filter
//     applied above the list when an address filter is active.
extension MessageListView {
    @ViewBuilder
    func row(
        for envelope: Envelope,
        model: MessageListViewModel,
        isSelected: Bool
    ) -> some View {
        let bulkMode = model.bulkMode
        let isChecked = model.selectedUIDs.contains(envelope.uid)
        Group {
            if bulkMode {
                // No .tag() while in bulk mode — the list's selection
                // binding drives the detail pane, and we don't want a
                // checkbox tap to also pop the reader.
                Button {
                    model.toggleSelection(envelope)
                } label: {
                    MessageRow(envelope: envelope, isSelected: isChecked, isChecked: isChecked, bulkMode: true)
                }
                .buttonStyle(.plain)
            } else {
                MessageRow(envelope: envelope, isSelected: isSelected, isChecked: false, bulkMode: false)
                    .tag(envelope)
            }
        }
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
    func rowContextMenu(
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
        Button {
            envelopeToMove = envelope
        } label: {
            Label("Move to folder…", systemImage: "folder")
        }
        Button(role: .destructive) {
            Task { await model.dispose(envelope) }
        } label: {
            disposeActionLabel(for: model.disposeAction)
        }
    }

    @ViewBuilder
    func disposeActionLabel(for action: DisposeAction) -> some View {
        switch action {
        case .archive: Label("Archive", systemImage: "archivebox")
        case .trash:   Label("Trash", systemImage: "trash")
        }
    }

    @ViewBuilder
    func markReadLabel(for envelope: Envelope) -> some View {
        if envelope.flags.contains(.seen) {
            Label("Unread", systemImage: "envelope.badge")
        } else {
            Label("Read", systemImage: "envelope.open")
        }
    }

    @ViewBuilder
    func addressFilterChip(_ address: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.tint)
            Text("Filtered to ")
                .foregroundStyle(.secondary)
            + Text(address)
                .fontWeight(.medium)
            Spacer()
            Button {
                onClearAddressFilter()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear address filter")
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    func filteredEnvelopes(_ envelopes: [Envelope]) -> [Envelope] {
        let tab = model?.filterTab ?? .all
        let needle = addressFilter?.lowercased() ?? ""
        return envelopes.filter { envelope in
            guard tab.includes(envelope) else { return false }
            guard !needle.isEmpty else { return true }
            let recipients = envelope.to + envelope.cc
            return recipients.contains { recipient in
                "\(recipient.mailbox)@\(recipient.host)".lowercased().contains(needle)
            }
        }
    }
}

private struct MessageRow: View {
    let envelope: Envelope
    let isSelected: Bool
    let isChecked: Bool
    let bulkMode: Bool

    var body: some View {
        HStack(alignment: .top) {
            if bulkMode {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                    .accessibilityLabel(isChecked ? "Selected" : "Not selected")
            }
            Circle()
                .fill(unreadDotColor)
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
                    if envelope.isImportant {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("High importance")
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Read/unread indicator. We deliberately avoid `Color.accentColor` here:
    // on iOS the accent is system blue, which is also the row-selection
    // highlight, so the dot becomes invisible the moment the user picks the
    // message. A fixed `.blue` keeps the conventional look against the list
    // background, and switching to `.white` when the row is selected keeps
    // the dot legible against the highlight on every platform.
    private var unreadDotColor: Color {
        guard !envelope.flags.contains(.seen) else { return .clear }
        return isSelected ? .white : .blue
    }

    private var senderLabel: String {
        envelope.from.first?.displayName ?? envelope.from.first?.mailbox ?? "unknown"
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
