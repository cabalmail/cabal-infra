import Foundation

/// IMAP folder, surfaced to UI code with `/` as the path delimiter.
///
/// Dovecot separates hierarchy with `.` on the wire; `ImapClient` translates
/// to and from `/` at the package boundary so views never have to special-case
/// the delimiter (mirroring the existing Lambda's `.replace("/", ".")` pattern
/// in `lambda/api/python/python/helper.py`).
public struct Folder: Sendable, Codable, Hashable, Identifiable {
    /// Canonical, `/`-delimited path.
    public let path: String

    /// LIST attributes as returned by the server (e.g. `\HasChildren`, `\Noselect`).
    public let attributes: [String]

    /// True when the folder appears in the LSUB list.
    public let isSubscribed: Bool

    public var id: String { path }

    /// Last path segment; convenient for list-view rendering.
    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public init(path: String, attributes: [String] = [], isSubscribed: Bool = false) {
        self.path = path
        self.attributes = attributes
        self.isSubscribed = isSubscribed
    }
}

/// STATUS reply attributes (`UNSEEN`, `MESSAGES`, `UIDVALIDITY`, `UIDNEXT`).
///
/// All fields optional because a `STATUS` command can request any subset.
public struct FolderStatus: Sendable, Codable, Hashable {
    public let messages: Int?
    public let unseen: Int?
    /// Flagged (and not-deleted) message count. Only populated when the status
    /// request asked for it; nil on the cheap STATUS-only path. See
    /// `ApiFolderStatus.flagged`.
    public let flagged: Int?
    /// Not-deleted message count: the set `/list_messages` sorts, and so the
    /// numbering its positions are in. Only populated when the status request
    /// asked for it (the same opt-in as `flagged`); nil on the cheap
    /// STATUS-only path. Read it through `listedMessages`.
    public let undeleted: Int?
    public let recent: Int?
    public let uidValidity: UInt32?
    public let uidNext: UInt32?

    /// The count the folder's list positions are in: `undeleted` when the
    /// reply carried it, else `messages`.
    ///
    /// `MESSAGES` counts messages flagged `\Deleted` but not yet expunged,
    /// which `/list_messages` leaves out of its `NOT DELETED` sort. Addressing
    /// a position by `messages` therefore lands one row off per such message
    /// until the expunge lowers the count (#1836), so everything that treats
    /// the total as a position -- the window anchor, the pagination gate, the
    /// top page's offset -- reads this instead. Counts shown as counts (the
    /// sidebar's total, the unread badge) keep reading `messages`: they answer
    /// "how much mail is in there", not "where is row n".
    public var listedMessages: Int? { undeleted ?? messages }

    public init(
        messages: Int? = nil,
        unseen: Int? = nil,
        flagged: Int? = nil,
        undeleted: Int? = nil,
        recent: Int? = nil,
        uidValidity: UInt32? = nil,
        uidNext: UInt32? = nil
    ) {
        self.messages = messages
        self.unseen = unseen
        self.flagged = flagged
        self.undeleted = undeleted
        self.recent = recent
        self.uidValidity = uidValidity
        self.uidNext = uidNext
    }
}
