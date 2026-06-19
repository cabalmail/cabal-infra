import Foundation

/// Cabalmail-specific HTTP endpoints fronted by API Gateway + Lambda.
///
/// As of issue #371 the Apple client routes mailbox traffic (folders,
/// envelopes, messages, flags, moves, send) through the same Lambda
/// endpoints the React app uses, replacing the hand-rolled IMAP/SMTP
/// stack. `ApiBackedImapClient` adapts these calls onto the existing
/// `ImapClient` protocol so view-models keep working unchanged.
public protocol ApiClient: Sendable {
    // MARK: Addresses
    func listAddresses() async throws -> [Address]
    func newAddress(
        username: String,
        subdomain: String,
        tld: String,
        comment: String?,
        address: String
    ) async throws
    func revokeAddress(
        address: String,
        subdomain: String,
        tld: String,
        publicKey: String?
    ) async throws

    /// Toggles the caller's favorite flag on an address. Backed by the
    /// `/set_favorite` Lambda, which ADDs/DELETEs the caller's username
    /// from the row's `favorites` string set.
    func setFavorite(address: String, favorite: Bool) async throws

    /// Returns the BIMI logo URL for the sender domain, or nil if the domain
    /// has no BIMI record. The Lambda returns a JSON object shaped
    /// `{"url": "..."}`; a 404 / missing key maps to nil.
    func fetchBimiURL(senderDomain: String) async throws -> URL?

    // MARK: Folders
    func listFolders(host: String) async throws -> ApiFolderList
    func createFolder(host: String, parent: String, name: String) async throws
    func deleteFolder(host: String, name: String) async throws
    func subscribeFolder(host: String, folder: String) async throws
    func unsubscribeFolder(host: String, folder: String) async throws

    /// STATUS for a folder. Powers UIDVALIDITY-based cache invalidation and
    /// the inbox unread badge. Backed by the dedicated `/folder_status`
    /// Lambda (see `lambda/api/folder_status/function.py`). Pass
    /// `flagged: true` to also request a SEARCH FLAGGED count.
    func folderStatus(host: String, folder: String, flagged: Bool) async throws -> ApiFolderStatus

    // MARK: Messages
    /// Sorted UID list for the folder. Sort defaults match the React
    /// client's call site (REVERSE ARRIVAL — most recent first). `page`
    /// requests a server-sliced window of the sorted result (Phase 3 of the
    /// large-mailbox plan); pass `nil` for the full list.
    func listMessageIds(
        host: String,
        folder: String,
        sortOrder: String,
        sortField: String,
        page: MessageIdPage?
    ) async throws -> [UInt32]
    func listEnvelopes(host: String, folder: String, ids: [UInt32]) async throws -> [ApiEnvelope]

    /// Structured search returning envelopes (newest-first) and a pagination
    /// cursor. Backed by the `/search_envelopes` Lambda. When
    /// `query.folder` is nil the search runs across the user's subscribed
    /// folders, excluding Trash by default.
    func searchEnvelopes(host: String, query: SearchQuery) async throws -> ApiSearchResponse
    func fetchMessage(
        host: String,
        folder: String,
        id: UInt32,
        markSeen: Bool
    ) async throws -> ApiMessageBody
    func listAttachments(
        host: String,
        folder: String,
        id: UInt32,
        markSeen: Bool
    ) async throws -> [ApiAttachmentDescriptor]
    func fetchAttachmentURL(_ request: FetchAttachmentRequest) async throws -> URL
    func fetchInlineImageURL(
        host: String,
        folder: String,
        id: UInt32,
        contentId: String,
        markSeen: Bool
    ) async throws -> URL

    // MARK: Operations
    /// Sets or clears one or more flags on the supplied message UIDs.
    /// `request.operation` is `set` or `unset` to match the Lambda's
    /// expected wire value (`lambda/api/set_flag/function.py`).
    func setFlag(_ request: SetFlagRequest) async throws -> [UInt32]
    func moveMessages(_ request: MoveMessagesRequest) async throws

    /// Permanently deletes (flags `\Deleted` + expunges) the given messages.
    /// The `/purge_messages` Lambda only accepts trash folders, so a client
    /// bug can never expunge a non-trash folder server-side.
    func purgeMessages(host: String, folder: String, ids: [UInt32]) async throws

    /// Permanently deletes every message in a trash folder via the
    /// `/empty_trash` Lambda (same trash-only restriction).
    func emptyTrash(host: String, folder: String) async throws

    // MARK: Preferences
    /// Fetches the caller's display-name preference from `/get_preferences`.
    /// The Lambda returns the full preferences row; the other keys
    /// (theme/accent/density) are web-client concerns, so only `name` is
    /// surfaced here. Empty string means "no display name".
    func fetchDisplayName() async throws -> String

    /// Persists the display-name preference via `/set_preferences`. The
    /// Lambda merges per-key, so sending only `name` never clobbers the web
    /// client's theme preferences. The `/send` Lambda reads this value
    /// server-side when composing the From header.
    func updateDisplayName(_ name: String) async throws

    // MARK: Send
    /// Submits an outgoing message via the Lambda send pipeline (Outbox
    /// APPEND -> SMTP -> Sent move). Mirrors `react/admin/src/ApiClient.js
    /// sendMessage` byte-for-byte.
    func sendMessage(_ request: SendMessageRequest) async throws

    // MARK: Drafts
    /// Saves (or atomically replaces) a draft via the `/save_draft` Lambda
    /// and returns the new copy's UIDPLUS coordinates. When the request
    /// carries `replacesUid` / `replacesUidValidity`, the Lambda appends
    /// the new copy first and only then expunges the old one, guarded by
    /// UIDVALIDITY — a guard miss keeps both copies and reports
    /// `replaced: false`, never a lost draft.
    func saveDraft(_ request: SaveDraftRequest) async throws -> ApiSaveDraftResponse

    /// Discards one server-side draft copy (`/save_draft` with
    /// `op: discard`). Returns whether the copy was actually expunged;
    /// false means the UIDVALIDITY guard declined (the coordinates are
    /// stale), which callers treat as already-gone rather than an error.
    func discardDraft(host: String, uid: UInt32, uidValidity: UInt32) async throws -> Bool

    /// Requests one presigned S3 PUT URL per outbound attachment. Used to
    /// bypass API Gateway's 10 MB request ceiling on /send — clients PUT
    /// each body to the returned URL and then pass the `key` back via
    /// `SendMessageRequest.attachments`.
    func requestAttachmentUploads(
        host: String,
        files: [AttachmentUploadSlot]
    ) async throws -> [AttachmentUpload]

    /// Uploads raw bytes to a presigned PUT URL returned by
    /// `/upload_url`. The presigned URL carries its own signature, so
    /// no Authorization header is sent.
    func uploadAttachment(url: URL, mimeType: String, data: Data) async throws

    /// Downloads raw bytes from a presigned URL returned by `/fetch_message`
    /// or `/fetch_attachment`. Bypasses the Cognito Authorization header —
    /// presigned URLs already carry their own credentials in the query
    /// string, and S3 rejects requests with both a Bearer header and a
    /// signed URL.
    func fetchPresignedData(url: URL) async throws -> Data
}

/// A server-sliced page of the sorted message-id list: the `limit` UIDs
/// starting at `offset`. Bundled into one parameter so `listMessageIds` stays
/// within the parameter-count budget and the page reads as one concept.
public struct MessageIdPage: Sendable, Hashable {
    public let offset: UInt32
    public let limit: UInt32
    public init(offset: UInt32, limit: UInt32) {
        self.offset = offset
        self.limit = limit
    }
}

public extension ApiClient {
    /// Convenience overload — the cheap STATUS-only call (no flagged count),
    /// for the badge/idle/sidebar paths that don't need it.
    func folderStatus(host: String, folder: String) async throws -> ApiFolderStatus {
        try await folderStatus(host: host, folder: folder, flagged: false)
    }

    /// Convenience overload: the full, unpaginated sorted UID list. Lets
    /// callers that genuinely need every UID (e.g. the legacy UID-range
    /// `envelopes`) stay terse while the paginated requirement carries the
    /// `page` slice.
    func listMessageIds(
        host: String,
        folder: String,
        sortOrder: String,
        sortField: String
    ) async throws -> [UInt32] {
        try await listMessageIds(
            host: host,
            folder: folder,
            sortOrder: sortOrder,
            sortField: sortField,
            page: nil
        )
    }
}

/// One entry in the `/upload_url` request. Carries only the metadata the
/// Lambda needs to mint a key — bodies do not flow through API Gateway.
public struct AttachmentUploadSlot: Sendable, Hashable {
    public let filename: String
    public let mimeType: String

    public init(filename: String, mimeType: String) {
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// One entry in the `/upload_url` response. The caller PUTs the file body
/// to `url` and then references the file by `key` in `SendMessageRequest`.
public struct AttachmentUpload: Sendable, Hashable {
    public let key: String
    public let url: URL

    public init(key: String, url: URL) {
        self.key = key
        self.url = url
    }
}

// MARK: - Request types

/// Parameters for `/set_flag`. Bundled into a struct so the call site
/// stays under SwiftLint's `function_parameter_count` limit while keeping
/// every wire field explicit. `operation` carries the wire field name
/// `op` (`set` / `unset`).
public struct SetFlagRequest: Sendable {
    public let host: String
    public let folder: String
    public let ids: [UInt32]
    public let flag: String
    public let operation: String
    public let sortOrder: String
    public let sortField: String

    public init(
        host: String,
        folder: String,
        ids: [UInt32],
        flag: String,
        operation: String,
        sortOrder: String,
        sortField: String
    ) {
        self.host = host
        self.folder = folder
        self.ids = ids
        self.flag = flag
        self.operation = operation
        self.sortOrder = sortOrder
        self.sortField = sortField
    }
}

/// Parameters for `/move_messages`.
public struct MoveMessagesRequest: Sendable {
    public let host: String
    public let source: String
    public let destination: String
    public let ids: [UInt32]
    public let sortOrder: String
    public let sortField: String

    public init(
        host: String,
        source: String,
        destination: String,
        ids: [UInt32],
        sortOrder: String,
        sortField: String
    ) {
        self.host = host
        self.source = source
        self.destination = destination
        self.ids = ids
        self.sortOrder = sortOrder
        self.sortField = sortField
    }
}

/// Parameters for `/send`. The Lambda accepts every recipient list, the
/// HTML and text body parts, the threading headers, a `draft` flag, and an
/// optional attachment list in a single request.
public struct SendMessageRequest: Sendable {
    public let host: String
    public let smtpHost: String
    public let sender: String
    public let toList: [String]
    public let ccList: [String]
    public let bccList: [String]
    public let subject: String
    public let otherHeaders: ApiSendOtherHeaders
    public let htmlBody: String
    public let textBody: String
    public let draft: Bool
    public let attachments: [ApiSendAttachment]
    /// Send-from-draft cleanup: when set, the Lambda best-effort expunges
    /// this Drafts-folder copy after successful SMTP delivery (guarded by
    /// UIDVALIDITY, so stale coordinates simply leave the copy in place).
    public let discardDraftUid: UInt32?
    public let discardDraftUidValidity: UInt32?

    public init(
        host: String,
        smtpHost: String,
        sender: String,
        toList: [String],
        ccList: [String],
        bccList: [String],
        subject: String,
        otherHeaders: ApiSendOtherHeaders,
        htmlBody: String,
        textBody: String,
        draft: Bool,
        attachments: [ApiSendAttachment] = [],
        discardDraftUid: UInt32? = nil,
        discardDraftUidValidity: UInt32? = nil
    ) {
        self.host = host
        self.smtpHost = smtpHost
        self.sender = sender
        self.toList = toList
        self.ccList = ccList
        self.bccList = bccList
        self.subject = subject
        self.otherHeaders = otherHeaders
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.draft = draft
        self.attachments = attachments
        self.discardDraftUid = discardDraftUid
        self.discardDraftUidValidity = discardDraftUidValidity
    }
}

/// Parameters for `/save_draft` (op: save). The compose payload is the
/// `/send` shape minus SMTP concerns; `replacesUid` / `replacesUidValidity`
/// name the prior server copy this save supersedes (both or neither).
public struct SaveDraftRequest: Sendable {
    public let host: String
    public let sender: String
    public let toList: [String]
    public let ccList: [String]
    public let bccList: [String]
    public let subject: String
    public let otherHeaders: ApiSendOtherHeaders
    public let htmlBody: String
    public let textBody: String
    public let attachments: [ApiSendAttachment]
    public let replacesUid: UInt32?
    public let replacesUidValidity: UInt32?

    public init(
        host: String,
        sender: String,
        toList: [String],
        ccList: [String],
        bccList: [String],
        subject: String,
        otherHeaders: ApiSendOtherHeaders,
        htmlBody: String,
        textBody: String,
        attachments: [ApiSendAttachment] = [],
        replacesUid: UInt32? = nil,
        replacesUidValidity: UInt32? = nil
    ) {
        self.host = host
        self.sender = sender
        self.toList = toList
        self.ccList = ccList
        self.bccList = bccList
        self.subject = subject
        self.otherHeaders = otherHeaders
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.attachments = attachments
        self.replacesUid = replacesUid
        self.replacesUidValidity = replacesUidValidity
    }
}

/// Wire-shape for a single outbound attachment. The body has already been
/// uploaded to S3 via `/upload_url`; `s3Key` is the staging key the /send
/// Lambda fetches from. `URLSessionApiClient.sendMessage` forwards this
/// shape to the Lambda verbatim.
public struct ApiSendAttachment: Sendable, Hashable {
    public let filename: String
    public let mimeType: String
    public let s3Key: String

    public init(filename: String, mimeType: String, s3Key: String) {
        self.filename = filename
        self.mimeType = mimeType
        self.s3Key = s3Key
    }
}

/// Parameters for `/fetch_attachment`. The Lambda needs the message
/// coordinates plus the attachment index and original filename so it can
/// produce a presigned S3 URL.
public struct FetchAttachmentRequest: Sendable {
    public let host: String
    public let folder: String
    public let id: UInt32
    public let index: Int
    public let filename: String
    public let markSeen: Bool

    public init(
        host: String,
        folder: String,
        id: UInt32,
        index: Int,
        filename: String,
        markSeen: Bool
    ) {
        self.host = host
        self.folder = folder
        self.id = id
        self.index = index
        self.filename = filename
        self.markSeen = markSeen
    }
}
