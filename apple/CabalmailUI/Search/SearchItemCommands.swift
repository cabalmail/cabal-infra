import SwiftUI
import CabalmailKit

/// Answers the window's item commands for what is open from a search's
/// sectioned results: the Message menu's Mark as Read/Unread, Flag/Unflag
/// and Move for a message, and the Feeds menu's two for an article.
///
/// In a folder, a feed or the Mail scope these are the list's to answer,
/// on its selection (`MessageListView`, `FeedItemListView`). Neither list
/// is mounted under All or Feeds, and the menus are told the open item is
/// there to act on, so without this the commands were live and did
/// nothing. Reply and Forward are the reader's own, and Delete is its
/// toolbar button's chord, so they need nothing here.
struct SearchItemCommands: ViewModifier {
    let model: MessageListViewModel
    let place: SearchPlace
    /// The message the reader shows.
    @Binding var message: Envelope?
    /// The article the reader shows.
    let article: RssItem?
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @State private var moving: Envelope?

    private var actions: SearchRowActions {
        SearchRowActions(model: model, place: place, preferences: preferences)
    }

    func body(content: Content) -> some View {
        content
            .answersCommand(.toggleSeen) {
                guard let target = actions.commandTarget(message) else { return }
                Task { await model.toggleSeen(target) }
            }
            .answersCommand(.toggleFlagged) {
                guard let target = actions.commandTarget(message) else { return }
                Task { await model.toggleDefaultFlag(target) }
            }
            .answersCommand(.moveSelection) {
                moving = actions.commandTarget(message)
            }
            .answersCommands([.feed(.toggleRead), .feed(.toggleFlag)]) { command in
                guard let article else { return }
                let slot = actions.defaultFlag.slot
                Task {
                    if command == .feed(.toggleRead) {
                        await place.feeds.toggleRead(article, in: place.feedStore)
                    } else {
                        await place.feeds.toggleFlag(slot: slot, on: article, in: place.feedStore)
                    }
                }
            }
            .sheet(item: $moving) { envelope in
                moveSheet(for: envelope)
            }
    }

    /// The destination picker, with the message's own folder as the one it
    /// is in. A message that has gone leaves the reader with it.
    @ViewBuilder
    private func moveSheet(for envelope: Envelope) -> some View {
        if let client = appState.client {
            let ref = model.rowRef(for: envelope)
            MoveToFolderSheet(
                currentFolder: Folder(path: ref.folder),
                client: client,
                onSelect: { destination in
                    moving = nil
                    Task {
                        guard await actions.move(envelope, to: destination.path) else { return }
                        if let message, model.rowRef(for: message) == ref { self.message = nil }
                    }
                },
                onCancel: { moving = nil }
            )
        }
    }
}
