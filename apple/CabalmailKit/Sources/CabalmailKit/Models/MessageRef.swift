import Foundation

/// The identity of one mail message: the folder it lives in plus its UID
/// there.
///
/// An IMAP UID is unique only *within* a folder, so a bare UID cannot name a
/// message once rows from more than one folder share a list: a cross-folder
/// search routinely returns Archive UID 1 next to `zeta` UID 1, and mail you
/// send yourself can sit in INBOX and Sent under the same UID. Every place
/// the app keys a message — selection, the optimistic-write shields, drag,
/// Spotlight, push, the nav restore — keys it by this instead.
///
/// Identity is `(folder, uid)`. `uidValidity` and `messageId` ride along as
/// hints and take no part in `==` or `hash`: search rows, Spotlight
/// identifiers, push payloads and the resume record never carry a
/// UIDVALIDITY, while a folder list knows its folder's, so a ref that counted
/// it would make one message unequal to itself depending on which surface
/// minted the ref. A UID space that starts over is handled where it is
/// detected (the list drops the folder's rows and shields when STATUS reports
/// a new UIDVALIDITY); `conflicts(withUIDValidity:)` is the explicit check
/// for a ref that outlived one.
///
/// Codable for in-process routes that want to carry it. No stored or wire
/// format embeds it: `SpotlightMessageRef`, `NavState`, `ResumeSession`,
/// `DraftServerRef` and the drag payload each keep their own shape and
/// convert at the boundary.
public struct MessageRef: Sendable, Codable {
    /// The folder path, in the form the API takes (`INBOX`, `Archive/2024`).
    public let folder: String
    public let uid: UInt32
    /// The folder's UIDVALIDITY when the producer knew it. Never 0: RFC 3501
    /// makes it non-zero, and the app writes 0 where it means "unknown", so
    /// the initializer folds 0 into nil.
    public let uidValidity: UInt32?
    /// The RFC 5322 Message-ID when the producer had it. A hint for
    /// resolving a ref whose message has moved; not part of identity.
    public let messageId: String?

    public init(folder: String, uid: UInt32, uidValidity: UInt32? = nil, messageId: String? = nil) {
        self.folder = folder
        self.uid = uid
        self.uidValidity = uidValidity == 0 ? nil : uidValidity
        self.messageId = messageId
    }

    /// True only when this ref and `current` both know a UIDVALIDITY and the
    /// two differ: the ref was minted against a UID space the folder has
    /// since replaced, so its UID may now name a different message. An
    /// unknown value on either side is not a conflict.
    public func conflicts(withUIDValidity current: UInt32?) -> Bool {
        guard let uidValidity, let current, current != 0 else { return false }
        return uidValidity != current
    }

    /// A copy that carries `uidValidity` (folded like the initializer's).
    public func withUIDValidity(_ uidValidity: UInt32?) -> MessageRef {
        MessageRef(folder: folder, uid: uid, uidValidity: uidValidity, messageId: messageId)
    }
}

extension MessageRef: Hashable {
    public static func == (lhs: MessageRef, rhs: MessageRef) -> Bool {
        lhs.uid == rhs.uid && lhs.folder == rhs.folder
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(folder)
        hasher.combine(uid)
    }
}

extension MessageRef: CustomStringConvertible {
    public var description: String { "\(folder)#\(uid)" }
}

extension Sequence where Element == MessageRef {
    /// The refs' UIDs grouped by folder, in first-seen order within each
    /// folder: the shape every per-folder wire call (`setFlags`, `move`,
    /// `purge`) takes.
    public func uidsByFolder() -> [String: [UInt32]] {
        var grouped: [String: [UInt32]] = [:]
        for ref in self { grouped[ref.folder, default: []].append(ref.uid) }
        return grouped
    }
}
