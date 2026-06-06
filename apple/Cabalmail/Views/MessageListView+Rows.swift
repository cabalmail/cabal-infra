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
    /// True on layouts where the sidebar and the message list are visible at
    /// once (iPad regular width, macOS, visionOS) - the only place a message-
    /// to-folder drag makes sense. macOS has no size class and is always
    /// wide; everywhere else reads the environment size class set on the
    /// main struct.
    var isWideLayout: Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    @ViewBuilder
    func row(
        for envelope: Envelope,
        model: MessageListViewModel,
        isSelected: Bool
    ) -> some View {
        let bulkMode = model.bulkMode
        let isChecked = model.selectedUIDs.contains(envelope.uid)
        let items = dragItems(for: envelope, model: model)
        withMessageDrag(items: items, subject: envelope.subject) {
            Group {
                if isWideLayout {
                    // Native multi-select list: tag by UID so the list's
                    // `Set<UInt32>` selection binding owns selection and the
                    // system draws the highlight (and selection circles in iPad
                    // edit mode). No checkbox Button - that's the compact path.
                    // `isSelected` here is set membership, used only to keep the
                    // unread dot legible against the selection highlight.
                    MessageRow(envelope: envelope, isSelected: isSelected, isChecked: false, bulkMode: false)
                        .tag(envelope.uid)
                } else if bulkMode {
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
    }

    /// The drag payload for a row. When a multi-selection exists and this row
    /// is part of it, dragging carries the whole selection; dragging a row that
    /// isn't part of the selection (or when nothing/just one is selected)
    /// carries just that message - matching Finder / Mail, where grabbing an
    /// unselected item drags only it. This now covers both the native multi-
    /// select highlight (shift / command-click) and the touch checkbox flow,
    /// since both populate `selectedUIDs`. Each item is tagged with its owning
    /// mailbox via `sourceFolder(for:)` so a cross-folder search selection
    /// still routes every UID back to the right source folder on drop.
    private func dragItems(for envelope: Envelope, model: MessageListViewModel) -> [MessageDragItem] {
        if model.selectedUIDs.count > 1, model.selectedUIDs.contains(envelope.uid) {
            return model.envelopes
                .filter { model.selectedUIDs.contains($0.uid) }
                .map { MessageDragItem(uid: $0.uid, sourceFolder: model.sourceFolder(for: $0)) }
        }
        return [MessageDragItem(uid: envelope.uid, sourceFolder: model.sourceFolder(for: envelope))]
    }

    /// Wraps a row in `.draggable` on wide layouts so it can be dragged onto a
    /// sidebar folder. On compact iPhone the modifier is skipped entirely
    /// (see `isWideLayout`): there's nowhere to drop, and the long-press drag
    /// would fight the row's context menu.
    ///
    /// `.draggable` (not `.onDrag`) so a plain click still selects the row -
    /// `.onDrag` on a `List(selection:)` row swallows clicks on the rendered
    /// content on macOS. `.onDrag`'s drag-start closure was where the sidebar
    /// got flipped to reveal folders; `.draggable` has no such hook, so the
    /// flip rides two drag-start signals for robustness: the payload
    /// autoclosure (evaluated when the drag lifts) and the preview's
    /// `.onAppear` (fired when the drag image is built). `beginMessageDrag()`
    /// is idempotent, so firing both is harmless.
    @ViewBuilder
    private func withMessageDrag(
        items: [MessageDragItem],
        subject: String?,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if isWideLayout, !items.isEmpty {
            content()
                .draggable(dragPayload(items)) {
                    MessageDragPreview(count: items.count, subject: subject)
                        .onAppear { appState.beginMessageDrag() }
                }
        } else {
            content()
        }
    }

    /// Builds the drag payload and flips the sidebar's drag flag. Called from
    /// `.draggable`'s `@autoclosure` payload, so the side effect lands exactly
    /// when the drag begins.
    private func dragPayload(_ items: [MessageDragItem]) -> MessageDragPayload {
        appState.beginMessageDrag()
        return MessageDragPayload(items: items)
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

    @Environment(AppState.self) private var appState
    @State private var contactName: String?

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
        .task(id: senderKey) { await hydrateContactName() }
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

    /// Display priority: the envelope's own RFC 5322 phrase first
    /// (sender's choice), then the user's own name from Contacts, then
    /// the bare mailbox. Contacts hydration is `nil` until the async
    /// lookup in `.task(id:)` resolves, so a fresh row paints with the
    /// envelope or mailbox and updates in place when the contact match
    /// arrives.
    private var senderLabel: String {
        if let envelopeName = envelope.from.first?.displayName, !envelopeName.isEmpty {
            return envelopeName
        }
        if let contactName, !contactName.isEmpty {
            return contactName
        }
        return envelope.from.first?.mailbox ?? "unknown"
    }

    /// Cache-friendly identifier for `.task(id:)`. Empty when the
    /// envelope has no `From`, which short-circuits the hydration call.
    private var senderKey: String {
        guard let sender = envelope.from.first else { return "" }
        return "\(sender.mailbox.lowercased())@\(sender.host.lowercased())"
    }

    private func hydrateContactName() async {
        contactName = nil
        guard let sender = envelope.from.first else { return }
        if let envelopeName = sender.displayName, !envelopeName.isEmpty { return }
        contactName = await appState.contactsStore.displayName(for: sender)
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
