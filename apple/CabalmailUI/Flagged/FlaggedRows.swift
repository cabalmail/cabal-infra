import SwiftUI
import CabalmailKit

/// The Flagged entry of a sidebar list: the row the Mac's and the iPad
/// split's one sidebar, the Mail tab's folder list and visionOS's Folders
/// tab select (`SidebarSelectionList`), and the label of the Feeds tab's
/// button (`FlaggedEntryButton`).
struct FlaggedSidebarRow: View {
    let isSelected: Bool

    var body: some View {
        SidebarTreeRowLabel(
            title: SmartView.flagged.title, systemImage: "flag", depth: 0, disclosure: nil, hasUnread: false,
            isSelected: isSelected, titleLineLimit: 1
        ) {
            EmptyView()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.flagged")
    }
}

/// The Flagged entry as a sidebar that cannot select it is handed it:
/// whether the window is on the view, and what a press does.
struct FlaggedEntry {
    let isSelected: Bool
    let open: () -> Void
}

/// The Flagged entry where the list beside it selects something else: the
/// Feeds tab's sidebar, whose selection is a feed scope. A button, drawn as
/// that list's rows are, and tinted while the view is up.
struct FlaggedEntryButton: View {
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            FlaggedSidebarRow(isSelected: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) : nil
        )
    }
}

/// A message's row in the Flagged view: the mail list's own row, with the
/// folder the message is in named under it, since the rows here come from
/// every folder.
struct FlaggedMailRow: View {
    let envelope: Envelope
    let folderPath: String
    let palette: [FlagPaletteEntry]

    /// Where the row's text starts: past the unread dot and the avatar, as
    /// `MessageRow` lays them out.
    private static let textInset: CGFloat = 8 + 8 + MessageListView.avatarSize + 8

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MessageRow(envelope: envelope, isChecked: false, bulkMode: false, palette: palette)
            Text(Folder(path: folderPath).name)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, Self.textInset)
                .accessibilityLabel("In \(Folder(path: folderPath).name)")
        }
        .padding(.vertical, 2)
    }
}

/// The glyph that tells a row's medium at the trailing edge of a Flagged
/// row: an envelope for a message, the feed mark for a feed item.
struct FlaggedMediumGlyph: View {
    let source: FlaggedSource

    var body: some View {
        Image(systemName: source == .mail ? "envelope" : "dot.radiowaves.up.forward")
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 3)
            .accessibilityLabel(source == .mail ? "Message" : "Feed item")
    }
}

/// What a Flagged row's swipes and menu do, as the specs and words each
/// medium's own list uses: a message's follow Settings > Actions and a feed
/// item's Settings > Feeds. A value with no view in it, so a test can ask
/// what a swipe on a row would do, and do it.
@MainActor
struct FlaggedRowActions {
    let model: FlaggedListViewModel

    // MARK: A message

    /// The spec a swipe edge bound to `action` reveals for the message
    /// `ref` names; nil for a disabled edge, and for a dispose that has
    /// nowhere to go.
    func mailSwipe(_ action: MailSwipeAction, envelope: Envelope, ref: MessageRef) -> SwipeActionSpec? {
        switch action {
        case .toggleRead: return readSpec(envelope, ref)
        case .toggleFlag: return flagSpec(envelope, ref)
        case .dispose: return disposeSpec(ref)
        case .disabled: return nil
        }
    }

    func readSpec(_ envelope: Envelope, _ ref: MessageRef) -> SwipeActionSpec {
        let isSeen = envelope.flags.contains(.seen)
        return SwipeActionSpec(
            systemImage: isSeen ? "envelope.badge" : "envelope.open", title: isSeen ? "Unread" : "Read",
            tint: ColorTokens.infoFill, identifier: "message.swipe.toggleRead"
        ) { [model] in
            Task { await model.toggleSeen(ref) }
        }
    }

    func flagSpec(_ envelope: Envelope, _ ref: MessageRef) -> SwipeActionSpec {
        let toggle = model.defaultFlag
        let isSet = envelope.flags.contains(toggle.flag)
        return SwipeActionSpec(
            systemImage: toggle.systemImage(isSet: isSet), title: toggle.title(isSet: isSet), tint: toggle.tint,
            identifier: "message.swipe.toggleFlag"
        ) { [model] in
            Task { await model.toggleDefaultFlag(on: ref) }
        }
    }

    /// The dispose a row offers, resolved against the row's own folder
    /// (`FlaggedListViewModel.disposeIntent`): Restore inside Archive under
    /// an archiving preference, Archive or Trash elsewhere. Nil inside
    /// Trash, which the view never lists: deleting for good is confirmed in
    /// the folder's own list.
    func disposeSpec(_ ref: MessageRef) -> SwipeActionSpec? {
        let perform: () -> Void = { [model] in
            Task { await model.dispose(ref) }
        }
        switch model.disposeIntent(for: ref) {
        case .purge:
            return nil
        case .restore:
            return SwipeActionSpec(
                systemImage: "tray.and.arrow.up", title: "Restore", tint: ColorTokens.infoFill,
                identifier: "message.swipe.dispose", perform: perform
            )
        case .move(let action):
            return SwipeActionSpec(
                systemImage: action == .archive ? "archivebox" : "trash",
                title: action == .archive ? "Archive" : "Trash", tint: ColorTokens.dangerFill,
                role: .destructive, identifier: "message.swipe.dispose", perform: perform
            )
        }
    }

    // MARK: A feed item

    /// The spec a swipe edge bound to `action` reveals for `item`; nil for
    /// a disabled edge.
    func feedSwipe(_ action: FeedSwipeAction, item: RssItem) -> SwipeActionSpec? {
        switch action {
        case .toggleRead:
            return SwipeActionSpec(
                systemImage: item.isRead ? "envelope.badge" : "envelope.open",
                title: item.isRead ? "Mark unread" : "Mark read", tint: ColorTokens.accentForestFg,
                identifier: "feed.swipe.toggleRead"
            ) { [model] in
                Task { await model.setRead(item, !item.isRead) }
            }
        case .toggleFavorite:
            let toggle = model.defaultFlag
            let isSet = item.carries(slot: toggle.slot)
            return SwipeActionSpec(
                systemImage: toggle.systemImage(isSet: isSet), title: toggle.title(isSet: isSet),
                tint: toggle.tint, identifier: "feed.swipe.toggleFavorite"
            ) { [model] in
                Task { await model.toggleDefaultFlag(on: item) }
            }
        case .disabled:
            return nil
        }
    }
}
