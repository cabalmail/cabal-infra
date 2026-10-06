import Foundation

// Conversions between `MessageRef` and the older (folder, uid) shapes that
// each own a stored or wire format. Every one is computed: none of these
// types gains a stored property, so the Spotlight identifier, the
// `/set_nav_state` cursor, the resume record and drafts on disk encode
// exactly as before.

extension SpotlightMessageRef {
    /// The Spotlight identity of `ref`. The identifier string has no room
    /// for UIDVALIDITY or a Message-ID, so both hints are dropped.
    public init(_ ref: MessageRef) {
        self.init(folder: ref.folder, uid: ref.uid)
    }

    /// The message this identifier names.
    public var messageRef: MessageRef {
        MessageRef(folder: folder, uid: uid)
    }
}

extension NavState {
    /// The message a mail cursor names, when it names one by UID. A cursor
    /// that carries only a Message-ID, or a feed cursor, names none.
    public var messageRef: MessageRef? {
        guard kind == .mail, let uid else { return nil }
        return MessageRef(folder: folder, uid: uid, uidValidity: uidValidity, messageId: messageID)
    }
}

extension ResumeSession {
    /// The open message, when the session recorded one by UID. The record
    /// has no UIDVALIDITY, so neither does the ref.
    public var messageRef: MessageRef? {
        guard let folder, let uid else { return nil }
        return MessageRef(folder: folder, uid: uid, messageId: messageID)
    }

    /// Records `ref` as the open message: its folder, UID and Message-ID go
    /// into the record's own fields.
    public mutating func setMessage(_ ref: MessageRef) {
        folder = ref.folder
        uid = ref.uid
        messageID = ref.messageId
    }
}

extension ReadingPositionKey {
    /// The key for `ref`'s reading position: its Message-ID when known,
    /// else its folder and UID — the same string
    /// `mail(messageID:folder:uid:)` builds.
    public static func mail(_ ref: MessageRef) -> String {
        mail(messageID: ref.messageId, folder: ref.folder, uid: ref.uid)
    }
}

extension DraftServerRef {
    /// The Drafts copy `ref` names, when the ref knows its folder's
    /// UIDVALIDITY. The server only replaces or discards a copy named by
    /// both halves, so a ref without one names no copy it can act on: nil,
    /// and a save that has none saves a fresh copy.
    public init?(_ ref: MessageRef) {
        guard let uidValidity = ref.uidValidity else { return nil }
        self.init(uid: ref.uid, uidValidity: uidValidity)
    }

    /// The copy as a message in `folder` (Drafts unless told otherwise).
    public func messageRef(in folder: String = FolderTree.draftsPath) -> MessageRef {
        MessageRef(folder: folder, uid: uid, uidValidity: uidValidity)
    }
}

extension Draft {
    /// The message this draft replies to, when it recorded one.
    public var replySource: MessageRef? {
        guard let replySourceFolder, let replySourceUid else { return nil }
        return MessageRef(folder: replySourceFolder, uid: replySourceUid)
    }
}
