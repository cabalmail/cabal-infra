import Foundation

/// The `msgRef` dictionary the push-dispatch Lambda puts in every APNs
/// payload, `{"folder": "INBOX", "uid": 4271, "msg_id": "<...>"}`, which is
/// also the body `/push_envelope` takes. `uid` is a best-effort hint stamped
/// before delivery; `msg_id` is the durable identity the server resolves the
/// real uid from (see `docs/push-notifications.md`).
///
/// The Notification Service Extension reads it to enrich a push and patches
/// the resolved uid back in; the app reads it for the notification actions
/// and, on macOS, writes it into the notifications it posts itself.
public struct PushMessageCoordinates: Equatable, Sendable {
    /// The payload's key names.
    public enum Key {
        public static let msgRef = "msgRef"
        public static let folder = "folder"
        public static let uid = "uid"
        public static let messageID = "msg_id"
    }

    public let folder: String
    public let uid: UInt32?
    public let messageID: String?

    /// Takes the values as given, so a caller's arguments reach the request
    /// body unchanged. The dispatch sentinels (a uid of 0, an empty `msg_id`)
    /// are read by `init?(userInfo:)`, and a resolved uid of 0 by
    /// `resolving(_:)` and `patching(_:resolvedUID:)`.
    public init(folder: String, uid: UInt32?, messageID: String?) {
        self.folder = folder
        self.uid = uid
        self.messageID = messageID
    }

    /// Parses a notification's `userInfo`. Nil when there is no `msgRef`
    /// dictionary or its folder is missing or empty.
    ///
    /// A uid of 0 is the dispatch Lambda's explicit "no hint" sentinel
    /// (procmail could not read Dovecot's next uid), so it reads as nil, as
    /// a missing uid does; the notification actions then skip cleanly rather
    /// than flag or move UID 0, which the API rejects. An empty `msg_id`
    /// reads as nil too.
    public init?(userInfo: [AnyHashable: Any]) {
        guard
            let ref = userInfo[Key.msgRef] as? [String: Any],
            let folder = ref[Key.folder] as? String, !folder.isEmpty
        else { return nil }
        let rawUid = (ref[Key.uid] as? NSNumber)?.uint32Value
        let rawMessageID = ref[Key.messageID] as? String
        self.init(
            folder: folder,
            uid: rawUid == 0 ? nil : rawUid,
            messageID: (rawMessageID?.isEmpty ?? true) ? nil : rawMessageID
        )
    }

    /// The `/push_envelope` request body, which is also a fresh `msgRef`:
    /// the folder, plus the uid (as a JSON integer) and `msg_id` only when
    /// set. A missing value is omitted, never sent as null.
    public var requestBody: [String: Any] {
        var body: [String: Any] = [Key.folder: folder]
        if let uid { body[Key.uid] = Int(uid) }
        if let messageID { body[Key.messageID] = messageID }
        return body
    }

    /// A fresh `userInfo` carrying these coordinates, for a notification the
    /// app posts itself. Nothing else from the original push comes along.
    public var userInfo: [AnyHashable: Any] {
        [Key.msgRef: requestBody]
    }

    /// These coordinates with the uid `/push_envelope` resolved, when it
    /// resolved one; nil or 0 keeps the payload's hint.
    public func resolving(_ resolvedUID: UInt32?) -> PushMessageCoordinates {
        PushMessageCoordinates(
            folder: folder,
            uid: (resolvedUID == 0 ? nil : resolvedUID) ?? uid,
            messageID: messageID
        )
    }

    /// `userInfo` with only its `msgRef` uid replaced by `resolvedUID`, or
    /// nil, meaning leave the notification as it is, when `resolvedUID` is
    /// nil or 0 or there is no `msgRef` dictionary. Everything else in
    /// `userInfo` and in `msgRef` survives, which is why the extension
    /// patches the delivered payload rather than rebuilding it.
    public static func patching(
        _ userInfo: [AnyHashable: Any],
        resolvedUID: UInt32?
    ) -> [AnyHashable: Any]? {
        guard
            let resolvedUID, resolvedUID != 0,
            var ref = userInfo[Key.msgRef] as? [String: Any]
        else { return nil }
        ref[Key.uid] = Int(resolvedUID)
        var patched = userInfo
        patched[Key.msgRef] = ref
        return patched
    }
}
