import SwiftUI
import CabalmailKit

/// The feed reader column: the open item, or the "pick an item" prompt. The
/// prompt's chrome is the shell's to pass, as `MailReaderColumn`'s is.
struct FeedReaderColumn<PlaceholderChrome: ViewModifier>: View {
    let item: RssItem?
    let placeholderChrome: PlaceholderChrome

    var body: some View {
        if let item {
            FeedItemDetailView(item: item)
                .id(item.id)
        } else {
            ContentUnavailableView(
                "No item selected",
                systemImage: "doc.text",
                description: Text("Pick an item from the list to read it.")
            )
            .modifier(placeholderChrome)
        }
    }
}

extension FeedReaderColumn where PlaceholderChrome == EmptyModifier {
    /// A reader whose prompt carries no chrome of its own.
    init(item: RssItem?) {
        self.init(item: item, placeholderChrome: EmptyModifier())
    }
}
