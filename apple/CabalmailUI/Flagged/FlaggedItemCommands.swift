import SwiftUI
import CabalmailKit

/// Answers the window's item commands for the row open in the Flagged
/// view's reader: the Message menu's Mark as Read/Unread, Flag/Unflag and
/// Move for a message, and the Feeds menu's two for a feed item.
///
/// In a folder or a feed these are the list's to answer, on its selection
/// (`MessageListView`, `FeedItemListView`). Neither list is mounted while
/// the window is on the Flagged view, and the menus are told the open row
/// is there to act on (`FlaggedMenuReport`), so without this the commands
/// were live and did nothing. Reply and Forward are the reader's own, and
/// Delete is its toolbar button's chord, so they needed nothing here.
struct FlaggedItemCommands: ViewModifier {
    let model: FlaggedListViewModel?
    /// The row the reader shows.
    let row: FlaggedRow?
    @Environment(AppState.self) private var appState
    @State private var moveCandidate: SelectionMoveCandidate?

    func body(content: Content) -> some View {
        content
            .answersCommand(.toggleSeen) {
                guard let model, let ref = Self.message(row) else { return }
                Task { await model.toggleSeen(ref) }
            }
            .answersCommand(.toggleFlagged) {
                guard let model, let ref = Self.message(row) else { return }
                Task { await model.toggleDefaultFlag(on: ref) }
            }
            .answersCommand(.moveSelection) {
                guard let ref = Self.message(row) else { return }
                moveCandidate = SelectionMoveCandidate(refs: [ref])
            }
            .answersCommands([.feed(.toggleRead), .feed(.toggleFlag)]) { command in
                guard let model, case .feed(let item)? = row else { return }
                Task {
                    if command == .feed(.toggleRead) {
                        await model.toggleRead(item)
                    } else {
                        await model.toggleDefaultFlag(on: item)
                    }
                }
            }
            .sheet(item: $moveCandidate) { candidate in
                moveSheet(for: candidate)
            }
    }

    /// The message a Message menu command acts on: the open row, when it
    /// is one. A feed item's row answers none of them.
    static func message(_ row: FlaggedRow?) -> MessageRef? {
        if case .mail(_, let ref)? = row { return ref }
        return nil
    }

    /// The destination picker, with the message's own folder as the one it
    /// is in.
    @ViewBuilder
    private func moveSheet(for candidate: SelectionMoveCandidate) -> some View {
        if let client = appState.client, let ref = candidate.refs.first {
            MoveToFolderSheet(
                currentFolder: Folder(path: ref.folder),
                client: client,
                onSelect: { destination in
                    moveCandidate = nil
                    guard let model else { return }
                    Task { await model.move(ref, to: destination.path) }
                },
                onCancel: { moveCandidate = nil }
            )
        }
    }
}
