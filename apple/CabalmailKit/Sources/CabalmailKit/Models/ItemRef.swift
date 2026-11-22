import Foundation

/// The identity of one thing the app reads: a mail message or a feed item.
///
/// Each medium already has an identity of its own. A message is a
/// `MessageRef` (its folder and UID). A feed item is the pair the resume
/// session and a window's route store: the feed it came from and its sort
/// key, which is unique within the feed. This is the one value that can
/// name either, for the places that hold both: a list that mixes the two
/// media, and a window opened on one item.
///
/// A value, not a protocol: a mixed list keys its rows by it and switches
/// on the case to open the right reader.
///
/// `Codable` for in-process values that carry it (a window's presentation
/// value). No stored or wire format embeds it: a window's route, the resume
/// session and the Spotlight identifier each keep their own shape and
/// convert at the boundary, as they do for `MessageRef`.
public enum ItemRef: Hashable, Sendable, Codable {
    case mail(MessageRef)
    case feed(feedID: String, sortKey: String)

    /// The message, when this names one.
    public var message: MessageRef? {
        if case .mail(let ref) = self { return ref }
        return nil
    }
}

extension RssItem {
    /// The item's identity among everything the app reads.
    public var ref: ItemRef {
        .feed(feedID: feedId, sortKey: sortKey)
    }
}
