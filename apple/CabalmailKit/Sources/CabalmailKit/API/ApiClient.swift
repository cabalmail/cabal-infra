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
    /// Lambda (see `lambda/api/folder_status/function.py`).
    func folderStatus(host: String, folder: String) async throws -> ApiFolderStatus

    // MARK: Messages
    /// Sorted UID list for the folder. Sort defaults match the React
    /// client's call site (REVERSE ARRIVAL — most recent first).
    func listMessageIds(
        host: String,
        folder: String,
        sortOrder: String,
        sortField: String
    ) async throws -> [UInt32]
    func listEnvelopes(host: String, folder: String, ids: [UInt32]) async throws -> [ApiEnvelope]
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

    // MARK: Send
    /// Submits an outgoing message via the Lambda send pipeline (Outbox
    /// APPEND -> SMTP -> Sent move). Mirrors `react/admin/src/ApiClient.js
    /// sendMessage` byte-for-byte.
    func sendMessage(_ request: SendMessageRequest) async throws

    /// Downloads raw bytes from a presigned URL returned by `/fetch_message`
    /// or `/fetch_attachment`. Bypasses the Cognito Authorization header —
    /// presigned URLs already carry their own credentials in the query
    /// string, and S3 rejects requests with both a Bearer header and a
    /// signed URL.
    func fetchPresignedData(url: URL) async throws -> Data
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
/// HTML and text body parts, the threading headers, and a `draft` flag in
/// a single request.
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
        draft: Bool
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
