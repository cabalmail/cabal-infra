import Foundation

/// The cross-client navigation cursor: where the user last was, so a fresh
/// launch (or another device) can land them back in the same folder, on the
/// same message, at the same scroll position.
///
/// Persisted server-side by the `/set_nav_state` Lambda on the caller's
/// `cabal-user-preferences` row and read back by `/get_nav_state`. The server
/// stamps `updatedAt` and echoes the `clientID` so a second client can tell a
/// cursor came from elsewhere (a different `clientID`, a newer `updatedAt`)
/// and offer to follow it rather than silently overwriting it.
///
/// Two kinds share the cursor (resume-session plan, Phase C). A **mail**
/// cursor names a folder — its only required field; a cursor with no folder
/// is no cursor — and optionally a message: `messageID` is the durable
/// identity (RFC 5322 Message-ID), which survives the message being moved
/// between folders by another client, `uid` the fast in-folder hint. A
/// **feed** cursor (`kind == .rss`) names a feed item by `rssItem`
/// (`RssItem.id`, `<feedId>#<sortKey>`) and optionally the list scope it was
/// read from (`rssScope`, an `RssItemScope.token`); its `folder` is empty.
/// Either kind may carry the reading position — `messageAnchor` (element or
/// `f<fraction>` form) and `messageFraction` — best-effort.
public struct NavState: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case mail
        case rss
    }

    public var kind: Kind
    /// The mail folder; empty on a feed cursor.
    public var folder: String
    public var messageID: String?
    public var uid: UInt32?
    public var uidValidity: UInt32?
    public var listScroll: Int?
    /// In-message scroll for a plain-text body — an exact content offset (no
    /// reflow, so a pixel value round-trips faithfully). HTML bodies use
    /// `messageAnchor` instead, which survives WebKit's post-load reflow.
    public var messageScroll: Int?
    /// In-message scroll for an HTML body: a compact structural anchor the
    /// Apple client resolves with `scrollIntoView` (a child-index path to the
    /// top-most visible element plus a small pixel delta). Opaque end to end.
    public var messageAnchor: String?
    /// The same reading position as a 0–1 fraction of the scrollable height,
    /// carried alongside the element anchor so a client that can only apply
    /// a fraction (Android's body view runs with JavaScript off) still can.
    public var messageFraction: Double?
    /// Feed cursor: the item being read (`RssItem.id`).
    public var rssItem: String?
    /// Feed cursor: the list scope it was read from (`RssItemScope.token`).
    public var rssScope: String?
    /// Identifies the install that wrote this cursor. Set by the client on
    /// save; echoed back on load. See `InstallIdentity`.
    public var clientID: String
    /// Server-stamped write time, epoch milliseconds. `nil` on a cursor the
    /// client has built for saving (the server fills it in); non-nil on a
    /// cursor loaded from the server.
    public var updatedAt: Int64?

    public init(
        folder: String,
        messageID: String? = nil,
        uid: UInt32? = nil,
        uidValidity: UInt32? = nil,
        listScroll: Int? = nil,
        messageScroll: Int? = nil,
        messageAnchor: String? = nil,
        messageFraction: Double? = nil,
        clientID: String,
        updatedAt: Int64? = nil
    ) {
        self.kind = .mail
        self.rssItem = nil
        self.rssScope = nil
        self.messageFraction = messageFraction
        self.folder = folder
        self.messageID = messageID
        self.uid = uid
        self.uidValidity = uidValidity
        self.listScroll = listScroll
        self.messageScroll = messageScroll
        self.messageAnchor = messageAnchor
        self.clientID = clientID
        self.updatedAt = updatedAt
    }
}

extension NavState {
    /// A feed cursor for `itemID` (`RssItem.id`), read from `scope`
    /// (an `RssItemScope.token`), at the given reading position.
    public static func feed(
        itemID: String,
        scope: String?,
        anchor: String? = nil,
        fraction: Double? = nil,
        clientID: String,
        updatedAt: Int64? = nil
    ) -> NavState {
        var cursor = NavState(folder: "", messageAnchor: anchor, messageFraction: fraction,
                              clientID: clientID, updatedAt: updatedAt)
        cursor.kind = .rss
        cursor.rssItem = itemID
        cursor.rssScope = scope
        return cursor
    }

    /// A feed cursor's item as the pair `RssStore.item(feedId:sortKey:)`
    /// looks up — split at the first `#` (a sort key may itself contain one).
    public var rssItemParts: (feedID: String, sortKey: String)? {
        guard kind == .rss, let rssItem, let hash = rssItem.firstIndex(of: "#") else { return nil }
        let feedID = String(rssItem[..<hash])
        let sortKey = String(rssItem[rssItem.index(after: hash)...])
        guard !feedID.isEmpty, !sortKey.isEmpty else { return nil }
        return (feedID, sortKey)
    }
}

extension NavState: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case rssItem = "rss_item"
        case rssScope = "rss_scope"
        case messageFraction = "msg_fraction"
        case folder
        case messageID = "message_id"
        case uid
        case uidValidity = "uid_validity"
        case listScroll = "list_scroll"
        case messageScroll = "msg_scroll"
        case messageAnchor = "msg_anchor"
        case clientID = "client_id"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decodeIfPresent(String.self, forKey: .kind)
        self.kind = kindRaw == Kind.rss.rawValue ? .rss : .mail
        if kind == .rss {
            // A feed cursor's identity is its item; no item, no cursor.
            self.rssItem = try container.decode(String.self, forKey: .rssItem)
            self.rssScope = try container.decodeIfPresent(String.self, forKey: .rssScope)
            self.folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        } else {
            // `folder` is required on a mail cursor: its absence is how
            // `/get_nav_state` signals "no cursor yet" (it returns `{}`), so a
            // missing key surfaces as a decode failure that `loadNavState`
            // maps to nil.
            self.rssItem = nil
            self.rssScope = nil
            self.folder = try container.decode(String.self, forKey: .folder)
        }
        self.messageFraction = try container.decodeIfPresent(Double.self, forKey: .messageFraction)
        self.messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        self.uid = try container.decodeIfPresent(UInt32.self, forKey: .uid)
        self.uidValidity = try container.decodeIfPresent(UInt32.self, forKey: .uidValidity)
        self.listScroll = try container.decodeIfPresent(Int.self, forKey: .listScroll)
        self.messageScroll = try container.decodeIfPresent(Int.self, forKey: .messageScroll)
        self.messageAnchor = try container.decodeIfPresent(String.self, forKey: .messageAnchor)
        // Older rows (or a hand-written one) might omit client_id; treat it as
        // "unknown origin" rather than failing the whole decode.
        self.clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        self.updatedAt = try container.decodeIfPresent(Int64.self, forKey: .updatedAt)
    }
}

extension NavState {
    /// The `/set_nav_state` request body. Only non-nil fields are sent, and
    /// `updatedAt` is deliberately omitted — the server stamps recency so a
    /// client cannot forge it. `uid`/`uidValidity` go out as `Int` because
    /// `JSONSerialization` has no unsigned type.
    public var requestBody: [String: Any] {
        var body: [String: Any] = ["client_id": clientID]
        if kind == .rss, let rssItem {
            body["kind"] = Kind.rss.rawValue
            body["rss_item"] = rssItem
            if let rssScope { body["rss_scope"] = rssScope }
        } else {
            body["folder"] = folder
        }
        if let messageFraction { body["msg_fraction"] = messageFraction }
        if let messageID { body["message_id"] = messageID }
        if let uid { body["uid"] = Int(uid) }
        if let uidValidity { body["uid_validity"] = Int(uidValidity) }
        if let listScroll { body["list_scroll"] = listScroll }
        if let messageScroll { body["msg_scroll"] = messageScroll }
        if let messageAnchor { body["msg_anchor"] = messageAnchor }
        return body
    }

    /// Whether this cursor was written by a *different* install than `clientID`
    /// and is therefore a candidate for the "pick up where you left off"
    /// prompt. A cursor this install wrote is never offered back to it.
    public func isForeign(to localClientID: String) -> Bool {
        !clientID.isEmpty && clientID != localClientID
    }
}

/// A stable, per-install identifier used as `NavState.clientID`.
///
/// Generated once on first use and persisted in `UserDefaults` — deliberately
/// NOT in the account-scoped, server-synced preferences, because each install
/// must be distinguishable (two devices sharing one identifier would each
/// think the other's cursor was their own and never offer the cross-device
/// jump).
public enum InstallIdentity {
    /// `UserDefaults` key for the persisted identifier.
    public static let defaultsKey = "cabalmail.install.clientId"

    /// Returns the persisted identifier, minting and storing one on first call.
    public static func clientID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: defaultsKey)
        return minted
    }
}
