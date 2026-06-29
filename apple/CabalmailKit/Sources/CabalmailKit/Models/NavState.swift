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
/// `folder` is the only required field — a cursor with no folder is no cursor.
/// `messageID` is the durable message identity (RFC 5322 Message-ID), which
/// survives the message being moved between folders by another client; `uid`
/// is the fast in-folder hint. Scroll offsets are best-effort.
public struct NavState: Sendable, Equatable {
    public var folder: String
    public var messageID: String?
    public var uid: UInt32?
    public var uidValidity: UInt32?
    public var listScroll: Int?
    public var messageScroll: Int?
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
        clientID: String,
        updatedAt: Int64? = nil
    ) {
        self.folder = folder
        self.messageID = messageID
        self.uid = uid
        self.uidValidity = uidValidity
        self.listScroll = listScroll
        self.messageScroll = messageScroll
        self.clientID = clientID
        self.updatedAt = updatedAt
    }
}

extension NavState: Decodable {
    private enum CodingKeys: String, CodingKey {
        case folder
        case messageID = "message_id"
        case uid
        case uidValidity = "uid_validity"
        case listScroll = "list_scroll"
        case messageScroll = "msg_scroll"
        case clientID = "client_id"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `folder` is required: its absence is how `/get_nav_state` signals
        // "no cursor yet" (it returns `{}`), so a missing key here surfaces as
        // a decode failure that `loadNavState` maps to nil.
        self.folder = try container.decode(String.self, forKey: .folder)
        self.messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        self.uid = try container.decodeIfPresent(UInt32.self, forKey: .uid)
        self.uidValidity = try container.decodeIfPresent(UInt32.self, forKey: .uidValidity)
        self.listScroll = try container.decodeIfPresent(Int.self, forKey: .listScroll)
        self.messageScroll = try container.decodeIfPresent(Int.self, forKey: .messageScroll)
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
        var body: [String: Any] = ["folder": folder, "client_id": clientID]
        if let messageID { body["message_id"] = messageID }
        if let uid { body["uid"] = Int(uid) }
        if let uidValidity { body["uid_validity"] = Int(uidValidity) }
        if let listScroll { body["list_scroll"] = listScroll }
        if let messageScroll { body["msg_scroll"] = messageScroll }
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
/// NOT in the iCloud-synced preference store, because each install must be
/// distinguishable (two devices sharing one identifier would each think the
/// other's cursor was their own and never offer the cross-device jump).
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
