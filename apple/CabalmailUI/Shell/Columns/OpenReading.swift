import Foundation
import CabalmailKit

/// What a wide split's reader has open, as a key that changes whenever a
/// different item opens: the split's floating list goes away when it turns
/// non-nil and comes back when nothing is open (`ListOverlay`).
///
/// An article open from a search comes first: a search holds the columns
/// over whatever the window is on, so the feed item or the Flagged row
/// beneath is not what the reader shows. A message is keyed by its folder
/// too, so a search result with another folder's UID is a new open.
struct OpenReading {
    /// The article open from a search's feed results.
    var searchArticle: RssItem?
    /// Whether the columns show the Flagged view, and the row open in it.
    var flaggedShown = false
    var flaggedItem: FlaggedRow?
    /// Whether the reader shows feeds rather than mail, and each one's item.
    var readerShowsFeeds = false
    var feedItem: RssItem?
    var envelope: Envelope?

    var key: String? {
        if let searchArticle { return "article:\(searchArticle.id)" }
        if flaggedShown { return flaggedItem.map { "flagged:\($0.ref)" } }
        if readerShowsFeeds { return feedItem.map { "item:\($0.id)" } }
        return envelope.map { "message:\($0.folder ?? "")#\($0.uid)" }
    }
}
