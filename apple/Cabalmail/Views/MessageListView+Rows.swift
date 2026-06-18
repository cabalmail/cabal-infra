import SwiftUI
import CabalmailKit

// Row rendering and per-row affordances for `MessageListView`. Lives in
// a same-module extension so the primary view body stays under
// SwiftLint's `type_body_length` cap. Holds:
//   - `row(for:model:isSelected:)` — list-row content (drag + tag)
//   - `rowContextMenu` — the per-row long-press / right-click menu
//   - `disposeSwipe` / `toggleReadSwipe` — `SwipeActionSpec`s the
//     `SwipeActionRow` wrapper reveals on a trailing / leading swipe
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
        isSelected: Bool,
        orderedVisible: [Envelope]
    ) -> some View {
        let bulkMode = model.bulkMode
        let isChecked = model.selectedUIDs.contains(envelope.uid)
        withRowContextMenu(for: envelope, model: model) {
            Group {
                if isWideLayout {
                    wideRow(
                        for: envelope,
                        isSelected: isSelected,
                        model: model,
                        orderedVisible: orderedVisible
                    )
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
            // Swipe-to-dispose / toggle-read are hand-rolled in
            // `SwipeActionRow` (applied by `messageRow`), and drag-to-folder
            // is applied OUTSIDE that wrapper by `draggableRow` -- both have
            // to sit outside the per-row `List` that `SwipeActionRow` embeds
            // for its native `.swipeActions`, or the embedded List swallows
            // them (the drag never lifts; the swipe modifier no-ops).
        }
    }

    /// Compact iPhone keeps the per-row long-press menu (single-
    /// selection flow). Wide layouts must NOT carry a row-level
    /// `.contextMenu` — it would intercept the right-click before the
    /// List-level `contextMenu(forSelectionType:)` (see `wideList`)
    /// could offer the menu for the whole multi-selection.
    @ViewBuilder
    private func withRowContextMenu(
        for envelope: Envelope,
        model: MessageListViewModel,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if isWideLayout {
            content()
        } else {
            content()
                .contextMenu { rowContextMenu(for: envelope, model: model) }
        }
    }

    /// The wide-layout (native multi-select) row: a UID-tagged `MessageRow` so
    /// the list's `Set<UInt32>` binding owns selection and the system draws the
    /// highlight (and selection circles in iPad edit mode). `isSelected` is set
    /// membership, used only to keep the unread dot legible. On iOS it also
    /// carries the hardware-keyboard shift / command-click handling SwiftUI
    /// doesn't wire into the native list there; plain taps fall through to the
    /// list. Kept beside `MessageRow` (which is file-private) and out of
    /// `row(for:)` so that function stays under SwiftLint's body-length cap.
    @ViewBuilder
    func wideRow(
        for envelope: Envelope,
        isSelected: Bool,
        model: MessageListViewModel,
        orderedVisible: [Envelope]
    ) -> some View {
        MessageRow(envelope: envelope, isSelected: isSelected, isChecked: false, bulkMode: false)
            .tag(envelope.uid)
            #if os(iOS)
            .gesture(ModifierClickGesture { kind in
                switch kind {
                case .toggle:
                    applyToggleSelection(envelope, model: model)
                case .range:
                    applyRangeSelection(to: envelope, model: model, ordered: orderedVisible)
                }
            })
            #endif
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

    /// Wraps a virtualized row in `.draggable` on wide layouts so it can be
    /// dragged onto a sidebar folder. On compact iPhone the modifier is
    /// skipped entirely (see `isWideLayout`): there's nowhere to drop, and the
    /// long-press drag would fight the row's context menu.
    ///
    /// Applied by `messageRow` OUTSIDE the per-row `SwipeActionRow` (i.e.
    /// outside the single-row `List` that wrapper embeds for its native
    /// `.swipeActions`). A `.draggable` placed inside that List row is
    /// swallowed on macOS and never lifts, so the drag has to sit on the row
    /// container instead. Because the wrapper already fills the fixed row
    /// height, this only adds `.contentShape` (so a drag can start on the row's
    /// empty space, not just the text) -- no frame expansion, unlike the old
    /// inner version.
    ///
    /// `.draggable` (not `.onDrag`) so a plain click still selects the row.
    /// `.onDrag`'s drag-start closure was where the sidebar got flipped to
    /// reveal folders; `.draggable` has no such hook, so the flip rides two
    /// drag-start signals for robustness: the payload autoclosure (evaluated
    /// when the drag lifts) and the preview's `.onAppear` (fired when the drag
    /// image is built). `beginMessageDrag()` is idempotent, so firing both is
    /// harmless. Internal (not `private`) so `messageRow` in `+Selection` can
    /// wrap the `SwipeActionRow` with it.
    @ViewBuilder
    func draggableRow(
        for envelope: Envelope,
        model: MessageListViewModel,
        @ViewBuilder content: () -> some View
    ) -> some View {
        // Drag-to-folder is macOS-only for now. On touch the row-level
        // `.draggable` is the prime suspect for the iPad leading-swipe lag
        // (a rightward swipe competing with the drag lift); macOS swipe is a
        // separate two-finger trackpad gesture, so drag never conflicts there.
        // Touch keeps "Move to folder..." in the row / selection menu. If iPad
        // confirms this is the cause, restore touch drag via the native path:
        // `.draggable` INSIDE the row's List, where the List arbitrates swipe
        // vs drag (like Mail) rather than the drag wrapping the List from
        // outside.
        #if os(macOS)
        let items = dragItems(for: envelope, model: model)
        if !items.isEmpty {
            content()
                .contentShape(Rectangle())
                .draggable(dragPayload(items)) {
                    MessageDragPreview(count: items.count, subject: envelope.subject)
                        .onAppear { appState.beginMessageDrag() }
                }
        } else {
            content()
        }
        #else
        content()
        #endif
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
        // Both dispose destinations, not just the configured default —
        // the swipe action keeps honoring the dispose preference; the
        // menu is where the user reaches for the other one. Inside Trash
        // "move to Trash" is meaningless, so the destructive item becomes
        // Delete Forever and stages the same confirmation as the swipe;
        // Archive stays available as the rescue path.
        Button {
            Task { await model.disposeMessages(uids: [envelope.uid], action: .archive) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        if model.isTrashFolder {
            Button(role: .destructive) {
                purgeCandidate = PurgeCandidate(uids: [envelope.uid])
            } label: {
                purgeActionLabel
            }
        } else {
            Button(role: .destructive) {
                Task { await model.disposeMessages(uids: [envelope.uid], action: .trash) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Trailing destructive swipe spec: dispose (Archive/Trash) everywhere
    /// except inside Trash, where delete means gone forever and stages the
    /// confirmation dialog instead of acting directly. Same decision as the
    /// context menu's destructive item; consumed by `SwipeActionRow`.
    func disposeSwipe(for envelope: Envelope, model: MessageListViewModel) -> SwipeActionSpec {
        if model.isTrashFolder {
            return SwipeActionSpec(
                systemImage: "trash.slash",
                title: "Delete Forever",
                tint: .red,
                role: .destructive
            ) {
                purgeCandidate = PurgeCandidate(uids: [envelope.uid])
            }
        }
        let action = model.disposeAction
        return SwipeActionSpec(
            systemImage: action == .archive ? "archivebox" : "trash",
            title: action == .archive ? "Archive" : "Trash",
            tint: .red,
            role: .destructive
        ) {
            Task { await model.dispose(envelope) }
        }
    }

    /// Leading swipe spec: flip `\Seen`. Mirrors Mail's single read/unread
    /// toggle gesture rather than offering two.
    func toggleReadSwipe(for envelope: Envelope, model: MessageListViewModel) -> SwipeActionSpec {
        let isSeen = envelope.flags.contains(.seen)
        return SwipeActionSpec(
            systemImage: isSeen ? "envelope.badge" : "envelope.open",
            title: isSeen ? "Unread" : "Read",
            tint: .blue
        ) {
            Task { await model.toggleSeen(envelope) }
        }
    }

    /// Delete affordance label inside the Trash folder, where the action
    /// permanently deletes (after confirmation) instead of moving. Still
    /// used by the row / selection context menus.
    @ViewBuilder
    var purgeActionLabel: some View {
        Label("Delete Forever", systemImage: "trash.slash")
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
                    // "source -> destination" on one line. `maxWidth: .infinity`
                    // takes the place of the old Spacer (push the date right);
                    // `.middle` truncation keeps both the sender start and the
                    // destination-address end legible when the line overflows.
                    routeText
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The row's first line: `source -> destination`. The destination is the
    /// address the message was delivered to -- the key triage signal in
    /// Cabalmail, where a distinct address is handed to each vendor -- and is
    /// dimmed so the sender stays the primary read. When there's no
    /// resolvable destination (e.g. a draft) the arrow drops and only the
    /// source shows.
    private var routeText: Text {
        let seen = envelope.flags.contains(.seen)
        let source = Text(sourceText).fontWeight(seen ? .regular : .semibold)
        guard let destinationText else { return source }
        return source
            + Text(" → ").foregroundStyle(.secondary)
            + Text(destinationText).foregroundStyle(.secondary)
    }

    /// Sender side of the route. Display priority: the envelope's own RFC
    /// 5322 phrase (sender's choice), then the user's Contacts match, then
    /// the bare `mailbox@host`. Contacts hydration is `nil` until the async
    /// `.task(id:)` lookup resolves, so a fresh row paints with the envelope
    /// or address and updates in place when the contact match arrives.
    private var sourceText: String {
        if let envelopeName = envelope.from.first?.displayName, !envelopeName.isEmpty {
            return envelopeName
        }
        if let contactName, !contactName.isEmpty {
            return contactName
        }
        guard let from = envelope.from.first else { return "unknown" }
        return "\(from.mailbox)@\(from.host)"
    }

    /// Destination side of the route: the address this message was delivered
    /// to. A message can carry several recipients, so prefer the one on one
    /// of the deployment's own mail domains (the address that actually caught
    /// it -- matched subdomain-aware, since Cabalmail addresses live on
    /// subdomains); fall back to the first To/Cc. `nil` when there are no
    /// recipients, which drops the arrow and shows the source alone.
    private var destinationText: String? {
        let recipients = envelope.to + envelope.cc
        guard !recipients.isEmpty else { return nil }
        let domains = appState.client?.configuration.domains.map(\.domain) ?? []
        let owned = recipients.first { addr in
            domains.contains { addr.host == $0 || addr.host.hasSuffix(".\($0)") }
        }
        guard let dest = owned ?? recipients.first else { return nil }
        return "\(dest.mailbox)@\(dest.host)"
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
