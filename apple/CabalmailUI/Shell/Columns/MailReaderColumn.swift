import SwiftUI
import CabalmailKit

/// What a mail reader column shows. Pure, so every shell's reader is tested
/// on the Mac host.
enum MailReaderChoice: Equatable {
    /// Rows selected in the list with no one message to read: two or more,
    /// or any number checked in Select mode, whose checkboxes never open a
    /// message (#2032). The column says how many, as Mail does.
    case selection(count: Int)
    /// The open message, against its own folder.
    case reader(folder: Folder, envelope: Envelope)
    /// Nothing to show.
    case empty

    /// A multi-selection wins over an open message; the open message reads
    /// against the folder it was listed from, so a cross-folder search result
    /// opens against its true mailbox (`MessageFolderPolicy`), and against
    /// the sidebar's folder otherwise.
    static func choose(selectionCount: Int, envelope: Envelope?, sidebarFolder: Folder?) -> MailReaderChoice {
        if selectionCount >= 2 { return .selection(count: selectionCount) }
        if let envelope, let folder = MessageFolderPolicy.folder(for: envelope, in: sidebarFolder) {
            return .reader(folder: folder, envelope: envelope)
        }
        // One row selected and no message to show is Select mode's single
        // checked box (#2032): the count stands in for it rather than the
        // empty prompt, which would say nothing is selected while the action
        // bar below the list says one row is.
        if selectionCount == 1 { return .selection(count: 1) }
        return .empty
    }

    /// The placeholder's title for `count` selected rows. One is reachable
    /// from Select mode, so the count agrees in number (#2032).
    static func selectionTitle(count: Int) -> String {
        count == 1 ? "1 Message Selected" : "\(count) Messages Selected"
    }
}

/// The mail reader column every shell shows: "N Messages Selected", the
/// reader, or the empty prompt (`MailReaderChoice`).
///
/// The placeholders' chrome is the shell's to pass: the Mac reserves the
/// reader's toolbar slots while no message is open (`EmptyDetailToolbar`),
/// and every other shell passes nothing. A `ViewModifier` rather than toolbar
/// content because a toolbar builder has no empty form to pass for "none".
struct MailReaderColumn<PlaceholderChrome: ViewModifier>: View {
    let selectionCount: Int
    let envelope: Envelope?
    let sidebarFolder: Folder?
    let placeholderChrome: PlaceholderChrome

    var body: some View {
        let choice = MailReaderChoice.choose(
            selectionCount: selectionCount, envelope: envelope, sidebarFolder: sidebarFolder
        )
        switch choice {
        case .selection(let count):
            // Bulk actions live in the action bar beneath the message list.
            ContentUnavailableView(
                MailReaderChoice.selectionTitle(count: count),
                systemImage: "envelope.badge",
                description: Text("Use the action bar below the list to act on them together.")
            )
            .modifier(placeholderChrome)
        case let .reader(folder, envelope):
            MessageDetailView(folder: folder, envelope: envelope)
                .id("\(folder.path)#\(envelope.uid)")
        case .empty:
            ContentUnavailableView(
                "No message selected",
                systemImage: "envelope",
                description: Text("Pick a message from the list to read it.")
            )
            .modifier(placeholderChrome)
        }
    }
}

extension MailReaderColumn where PlaceholderChrome == EmptyModifier {
    /// A reader whose placeholders carry no chrome of their own.
    init(selectionCount: Int, envelope: Envelope?, sidebarFolder: Folder?) {
        self.init(
            selectionCount: selectionCount, envelope: envelope, sidebarFolder: sidebarFolder,
            placeholderChrome: EmptyModifier()
        )
    }
}

/// Reserves a reader column's toolbar slots while it shows a placeholder, so
/// the list column's toolbar stays anchored above the list rather than
/// packing toward the window's trailing edge (the Mac's `EmptyDetailToolbar`
/// and `EmptyFeedDetailToolbar`).
struct ReaderPlaceholderToolbar<Items: ToolbarContent>: ViewModifier {
    let items: Items

    func body(content: Content) -> some View {
        content.toolbar { items }
    }
}
