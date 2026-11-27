import SwiftUI
import CabalmailKit

/// What a search result's swipes and menu do, as the specs and words each
/// medium's own list uses: a message's follow Settings > Actions and act
/// through the window's search model, as the Mail scope's rows do; an
/// article's follow Settings > Feeds and are written through the feed
/// half. A value with no view in it, so a test can ask what a swipe on a
/// row would do, and do it.
@MainActor
struct SearchRowActions {
    let model: MessageListViewModel
    let place: SearchPlace
    let preferences: Preferences

    var defaultFlag: FlagToggle { FlagToggle.defaultFlag(in: preferences.flagPalette) }

    // MARK: A message

    func mailSwipe(_ action: MailSwipeAction, envelope: Envelope) -> SwipeActionSpec? {
        switch action {
        case .toggleRead: return readSpec(envelope)
        case .toggleFlag: return flagSpec(envelope)
        case .dispose: return disposeSpec(envelope)
        case .disabled: return nil
        }
    }

    func readSpec(_ envelope: Envelope) -> SwipeActionSpec {
        let isSeen = envelope.flags.contains(.seen)
        return SwipeActionSpec(
            systemImage: isSeen ? "envelope.badge" : "envelope.open", title: isSeen ? "Unread" : "Read",
            tint: ColorTokens.infoFill, identifier: "message.swipe.toggleRead"
        ) { [model] in
            Task { await model.toggleSeen(envelope) }
        }
    }

    func flagSpec(_ envelope: Envelope) -> SwipeActionSpec {
        let toggle = defaultFlag
        let isSet = envelope.flags.contains(toggle.flag)
        return SwipeActionSpec(
            systemImage: toggle.systemImage(isSet: isSet), title: toggle.title(isSet: isSet), tint: toggle.tint,
            identifier: "message.swipe.toggleFlag"
        ) { [model] in
            Task { await model.toggleDefaultFlag(envelope) }
        }
    }

    /// The dispose the search surface gives every row: the plain move the
    /// Dispose preference names, as under Mail. Nil where the surface would
    /// delete for good, which is confirmed in the folder's own list.
    func disposeSpec(_ envelope: Envelope) -> SwipeActionSpec? {
        guard case .move(let action) = model.disposeIntent else { return nil }
        return SwipeActionSpec(
            systemImage: action == .archive ? "archivebox" : "trash",
            title: action == .archive ? "Archive" : "Trash", tint: ColorTokens.dangerFill,
            role: .destructive, identifier: "message.swipe.dispose"
        ) { [model] in
            Task { await model.dispose(envelope) }
        }
    }

    // MARK: The open message

    /// The message a Message menu command acts on while the sectioned
    /// results are up: the open one, as the model holds it now, so a second
    /// press undoes the first. Nil under Mail, whose own list answers the
    /// menu on its selection.
    func commandTarget(_ open: Envelope?) -> Envelope? {
        guard place.scope != .mail, let open else { return nil }
        let ref = model.rowRef(for: open)
        return model.envelopes.first { model.rowRef(for: $0) == ref } ?? open
    }

    /// Moves a message to the folder picked for it. True when it has left
    /// the results, which is when a reader showing it closes.
    func move(_ envelope: Envelope, to destination: String) async -> Bool {
        let ref = model.rowRef(for: envelope)
        await model.moveTo(envelope, destination: destination)
        return model.index(of: ref) == nil
    }

    // MARK: An article

    func feedSwipe(_ action: FeedSwipeAction, item: RssItem) -> SwipeActionSpec? {
        switch action {
        case .toggleRead:
            return SwipeActionSpec(
                systemImage: item.isRead ? "envelope.badge" : "envelope.open",
                title: item.isRead ? "Mark unread" : "Mark read", tint: ColorTokens.accentForestFg,
                identifier: "feed.swipe.toggleRead"
            ) {
                Task { await setRead(item, !item.isRead) }
            }
        case .toggleFavorite:
            let toggle = defaultFlag
            let isSet = item.carries(slot: toggle.slot)
            return SwipeActionSpec(
                systemImage: toggle.systemImage(isSet: isSet), title: toggle.title(isSet: isSet),
                tint: toggle.tint, identifier: "feed.swipe.toggleFavorite"
            ) {
                Task { await toggleFlag(slot: toggle.slot, on: item) }
            }
        case .disabled:
            return nil
        }
    }

    func setRead(_ item: RssItem, _ isRead: Bool) async {
        await place.feeds.setRead(item, isRead, in: place.feedStore)
    }

    func toggleFlag(slot: String, on item: RssItem) async {
        await place.feeds.toggleFlag(slot: slot, on: item, in: place.feedStore)
    }

    /// Opening an article marks it read when the feed reader's own
    /// preference says so, as opening it from its feed's list does.
    func didOpen(_ item: RssItem) async {
        guard preferences.rssMarkAsRead == .onOpen, !item.isRead else { return }
        await setRead(item, true)
    }
}

/// A message among a search's sectioned results: the mail list's own row
/// with its folder named, since the rows come from every folder.
struct SearchMailResultRow: View {
    let envelope: Envelope
    let ref: MessageRef
    let actions: SearchRowActions
    @Environment(Preferences.self) private var preferences

    var body: some View {
        let leading = actions.mailSwipe(preferences.swipeLeading, envelope: envelope)
        let trailing = actions.mailSwipe(preferences.swipeTrailing, envelope: envelope)
        FlaggedMailRow(envelope: envelope, folderPath: ref.folder, palette: preferences.flagPalette)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let leading { leading.revealedButton }
            }
            .swipeActions(edge: .trailing) {
                if let trailing { trailing.revealedButton }
            }
            .contextMenu { menu }
            // `.contain` keeps the row's children (and its revealed swipe
            // buttons) reachable; a bare identifier would be stamped on
            // every one of them.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search.message.\(ref.folder)#\(ref.uid)")
    }

    @ViewBuilder
    private var menu: some View {
        let read = actions.readSpec(envelope)
        Button(envelope.flags.contains(.seen) ? "Mark as Unread" : "Mark as Read", action: read.perform)
        let flag = actions.flagSpec(envelope)
        Button(flag.title, action: flag.perform)
        if let dispose = actions.disposeSpec(envelope) {
            Divider()
            Button(dispose.title, role: dispose.role, action: dispose.perform)
        }
    }
}

/// An article among a search's results: the feed list's own row, with its
/// feed named, since the rows come from every feed.
struct SearchFeedResultRow: View {
    let item: RssItem
    let actions: SearchRowActions
    @Environment(Preferences.self) private var preferences

    var body: some View {
        let feeds = actions.place.feeds
        let leading = actions.feedSwipe(preferences.rssSwipeLeading, item: item)
        let trailing = actions.feedSwipe(preferences.rssSwipeTrailing, item: item)
        FeedItemRow(
            item: item, feedName: feeds.feedName(for: item), isPending: feeds.pendingIDs.contains(item.id),
            palette: preferences.flagPalette
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let leading { leading.revealedButton }
        }
        .swipeActions(edge: .trailing) {
            if let trailing { trailing.revealedButton }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.item.\(item.id)")
    }

    /// As the feed list's own row menu reads.
    @ViewBuilder
    private var menu: some View {
        Button(item.isRead ? "Mark as unread" : "Mark as read") {
            Task { await actions.setRead(item, !item.isRead) }
        }
        let toggle = actions.defaultFlag
        Button(toggle.title(isSet: item.carries(slot: toggle.slot))) {
            Task { await actions.toggleFlag(slot: toggle.slot, on: item) }
        }
        let rows = FlagMenuPolicy.rows(
            palette: preferences.flagPalette,
            taggedSlots: Set(FlagPalette.slots(in: item.paletteFlags, palette: preferences.flagPalette))
        )
        if !rows.isEmpty {
            Menu("Flags") {
                FlagMenuToggles(rows: rows) { row in
                    Task { await actions.toggleFlag(slot: row.slot, on: item) }
                }
            }
        }
        if let url = URL(string: item.url) {
            Link("Open in browser", destination: url)
        }
    }
}
