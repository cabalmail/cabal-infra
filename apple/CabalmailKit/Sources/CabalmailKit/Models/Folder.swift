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
    public let recent: Int?
    public let uidValidity: UInt32?
    public let uidNext: UInt32?

    public init(
        messages: Int? = nil,
        unseen: Int? = nil,
        recent: Int? = nil,
        uidValidity: UInt32? = nil,
        uidNext: UInt32? = nil
    ) {
        self.messages = messages
        self.unseen = unseen
        self.recent = recent
        self.uidValidity = uidValidity
        self.uidNext = uidNext
    }
}
