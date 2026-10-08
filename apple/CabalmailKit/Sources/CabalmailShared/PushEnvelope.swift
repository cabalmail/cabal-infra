import Foundation

/// The `/push_envelope` reply: the sender, subject and snippet the push
/// deliberately leaves out, and `uid`, the message's uid as the server found
/// it: by the payload's `msg_id` when that finds it, otherwise the uid hint
/// it was sent (the payload's own uid is only a pre-delivery hint). Callers
/// stamp it back into the notification's `msgRef` so Mark as Read, Archive
/// and Open act on the message the notification shows.
///
/// CabalmailKit decodes it strictly (`fetchPushEnvelope`); the Notification
/// Service Extension decodes it with a plain `JSONDecoder` and falls back to
/// "New mail" when that fails.
public struct PushEnvelope: Decodable, Equatable, Sendable {
    public let from: String
    public let subject: String
    public let snippet: String
    public let uid: UInt32?

    public init(from: String, subject: String, snippet: String, uid: UInt32?) {
        self.from = from
        self.subject = subject
        self.snippet = snippet
        self.uid = uid
    }
}
