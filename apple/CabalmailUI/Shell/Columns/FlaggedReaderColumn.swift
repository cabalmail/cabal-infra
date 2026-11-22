import SwiftUI
import CabalmailKit

/// The reader column while the window is on the Flagged view: the open
/// row's own reader, a message against the folder it is in or a feed item,
/// or the prompt to pick one.
///
/// The prompt's chrome is the shell's to pass, as `MailReaderColumn`'s is:
/// the Mac reserves the mail reader's toolbar slots while nothing is open.
struct FlaggedReaderColumn<PlaceholderChrome: ViewModifier>: View {
    let item: FlaggedRow?
    let placeholderChrome: PlaceholderChrome

    var body: some View {
        switch item {
        case .mail(let envelope, let ref):
            // Against the row's own folder, so the reader's mark-read,
            // flag, move and delete reach the message that was picked.
            MessageDetailView(folder: Folder(path: ref.folder), envelope: envelope)
                .id("\(ref.folder)#\(ref.uid)")
        case .feed(let item):
            FeedItemDetailView(item: item)
                .id(item.id)
        case nil:
            ContentUnavailableView(
                "No item selected",
                systemImage: "flag",
                description: Text("Pick a message or a feed item from the list to read it.")
            )
            .modifier(placeholderChrome)
        }
    }
}

extension FlaggedReaderColumn where PlaceholderChrome == EmptyModifier {
    /// A reader whose prompt carries no chrome of its own.
    init(item: FlaggedRow?) {
        self.init(item: item, placeholderChrome: EmptyModifier())
    }
}

/// What a shell tells the Message and Feeds menus while its window is on
/// the Flagged view: the reader's open row is what a command acts on,
/// whichever medium it is. Off the view, each question falls through to
/// the shell's own answer.
struct FlaggedMenuReport: Equatable {
    let showsFlagged: Bool
    let item: FlaggedRow?

    func hasMessage(else own: Bool) -> Bool {
        guard showsFlagged else { return own }
        if case .mail = item { return true }
        return false
    }

    /// How many messages a Message menu command would act on: the open
    /// one. The Flagged list has no multi-selection.
    func messageCount(else own: Int) -> Int {
        showsFlagged ? (hasMessage(else: false) ? 1 : 0) : own
    }

    func hasFeedItem(else own: Bool) -> Bool {
        guard showsFlagged else { return own }
        if case .feed = item { return true }
        return false
    }
}
