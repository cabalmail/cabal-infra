import Foundation

/// What a mail list row's swipe does. One binding per edge, named for
/// layout direction (leading / trailing) rather than left / right so the
/// same value means the same gesture under RTL. `dispose` follows
/// `DisposeAction` and the in-Trash / in-Archive overrides the row already
/// applies; `disabled` (wire `none`) leaves that edge without a swipe.
public enum MailSwipeAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case toggleRead = "toggle_read"
    case toggleFlag = "toggle_flag"
    case dispose
    case disabled = "none"

    public var id: String { rawValue }
}

/// What a feed item row's swipe does; the feed twin of `MailSwipeAction`.
public enum FeedSwipeAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case toggleRead = "toggle_read"
    case toggleFavorite = "toggle_favorite"
    case disabled = "none"

    public var id: String { rawValue }
}

/// The swipe bindings' wire handling: four keys (`swipe_leading`,
/// `swipe_trailing`, `rss_swipe_leading`, `rss_swipe_trailing`) that ride
/// the synced `app` map together, gated the way `rss_mark_as_read` is —
/// never pushed to a server that has not shown it accepts them.
extension Preferences {
    static let swipeLeadingWireKey = "swipe_leading"
    static let swipeTrailingWireKey = "swipe_trailing"
    static let rssSwipeLeadingWireKey = "rss_swipe_leading"
    static let rssSwipeTrailingWireKey = "rss_swipe_trailing"

    /// True when every binding still has its historical value (leading
    /// toggles read, trailing disposes / favorites).
    var swipeBindingsAreDefault: Bool {
        swipeLeading == .toggleRead && swipeTrailing == .dispose
            && rssSwipeLeading == .toggleRead && rssSwipeTrailing == .toggleFavorite
    }

    /// The `app`-map entries the payload carries for the swipe bindings:
    /// all four, once any is syncable (the server accepts them as a set).
    func swipeWireEntries() -> [String: String] {
        guard !swipeBindingsAreDefault || swipeBindingsSyncable else { return [:] }
        return [
            Self.swipeLeadingWireKey: swipeLeading.rawValue,
            Self.swipeTrailingWireKey: swipeTrailing.rawValue,
            Self.rssSwipeLeadingWireKey: rssSwipeLeading.rawValue,
            Self.rssSwipeTrailingWireKey: rssSwipeTrailing.rawValue,
        ]
    }

    /// `applyRemote`'s arm for the swipe bindings. Any of the four keys in
    /// the fetched map proves the server knows them; an unrecognized value
    /// leaves the current binding untouched, like every other key.
    func applyRemoteSwipe(_ remote: [String: String]) {
        let keys = [Self.swipeLeadingWireKey, Self.swipeTrailingWireKey,
                    Self.rssSwipeLeadingWireKey, Self.rssSwipeTrailingWireKey]
        guard keys.contains(where: { remote[$0] != nil }) else { return }
        swipeBindingsSyncable = true
        if let value = remote[Self.swipeLeadingWireKey].flatMap(MailSwipeAction.init(rawValue:)) {
            swipeLeading = value
        }
        if let value = remote[Self.swipeTrailingWireKey].flatMap(MailSwipeAction.init(rawValue:)) {
            swipeTrailing = value
        }
        if let value = remote[Self.rssSwipeLeadingWireKey].flatMap(FeedSwipeAction.init(rawValue:)) {
            rssSwipeLeading = value
        }
        if let value = remote[Self.rssSwipeTrailingWireKey].flatMap(FeedSwipeAction.init(rawValue:)) {
            rssSwipeTrailing = value
        }
    }
}
