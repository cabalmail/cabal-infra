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
    func revokeAddress(address: String, subdomain: String, tld: String, publicKey: String?) async throws

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
    func listMessageIds(host: String, folder: String, sortOrder: String, sortField: String) async throws -> [UInt32]
    func listEnvelopes(host: String, folder: String, ids: [UInt32]) async throws -> [ApiEnvelope]
    func fetchMessage(host: String, folder: String, id: UInt32, markSeen: Bool) async throws -> ApiMessageBody
    func listAttachments(host: String, folder: String, id: UInt32, markSeen: Bool) async throws -> [ApiAttachmentDescriptor]
    func fetchAttachmentURL(host: String, folder: String, id: UInt32, index: Int, filename: String, markSeen: Bool) async throws -> URL
    func fetchInlineImageURL(host: String, folder: String, id: UInt32, contentId: String, markSeen: Bool) async throws -> URL

    // MARK: Operations
    /// Sets or clears one or more flags on the supplied message UIDs.
    /// `op` is `set` or `unset` to match the Lambda's expected wire value
    /// (`lambda/api/set_flag/function.py`).
    func setFlag(
        host: String,
        folder: String,
        ids: [UInt32],
        flag: String,
        op: String,
        sortOrder: String,
        sortField: String
    ) async throws -> [UInt32]
    func moveMessages(
        host: String,
        source: String,
        destination: String,
        ids: [UInt32],
        sortOrder: String,
        sortField: String
    ) async throws

    // MARK: Send
    /// Submits an outgoing message via the Lambda send pipeline (Outbox
    /// APPEND -> SMTP -> Sent move). Mirrors `react/admin/src/ApiClient.js
    /// sendMessage` byte-for-byte.
    func sendMessage(
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
    ) async throws

    /// Downloads raw bytes from a presigned URL returned by `/fetch_message`
    /// or `/fetch_attachment`. Bypasses the Cognito Authorization header —
    /// presigned URLs already carry their own credentials in the query
    /// string, and S3 rejects requests with both a Bearer header and a
    /// signed URL.
    func fetchPresignedData(url: URL) async throws -> Data
}

// MARK: - Wire types

/// `/list_folders` response. The Lambda returns two flat string arrays:
/// every folder, plus the subset that's currently subscribed.
public struct ApiFolderList: Sendable, Codable, Hashable {
    public let folders: [String]
    public let subFolders: [String]

    private enum CodingKeys: String, CodingKey {
        case folders
        case subFolders = "sub_folders"
    }
}

public struct ApiFolderStatus: Sendable, Codable, Hashable {
    public let messages: Int?
    public let unseen: Int?
    public let uidValidity: UInt32?
    public let uidNext: UInt32?

    private enum CodingKeys: String, CodingKey {
        case messages
        case unseen
        case uidValidity = "uid_validity"
        case uidNext = "uid_next"
    }
}

/// One envelope as returned by `/list_envelopes`.
///
/// The Lambda flattens RFC 3501 ENVELOPE into stringified `mailbox@host`
/// addresses (no display names), a stringified date, a flag list, and the
/// raw BODYSTRUCTURE tree. Display name is unavailable on the wire — we
/// surface what we have and let the UI fall back to mailbox-only rendering
/// for messages that came through the API path.
public struct ApiEnvelope: Sendable, Codable, Hashable {
    public let id: UInt32
    public let date: String?
    public let subject: String?
    public let from: [String]
    public let to: [String]
    public let cc: [String]
    public let flags: [String]
    /// BODYSTRUCTURE expressed as a recursive list of strings / numbers.
    /// Decoded as JSON `Any`-equivalent and walked at the call site to
    /// detect attachments. Stored as a typed enum so it stays Sendable.
    public let structure: BodyStructureNode?
    public let priority: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, date, subject, from, to, cc, flags, priority
        case structure = "struct"
    }
}

/// JSON-tree representation of an IMAP BODYSTRUCTURE response. The Lambda
/// emits a recursive list-of-lists with leaves that are strings or
/// integers; this enum mirrors that shape so we can walk the tree and
/// detect attachments without parsing IMAP grammar on the client side.
public enum BodyStructureNode: Sendable, Codable, Hashable {
    case string(String)
    case integer(Int)
    case list([BodyStructureNode])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode([BodyStructureNode].self) {
            self = .list(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// True if the structure tree contains a part with disposition or
    /// content-type indicating an attachment. Heuristic only — used to
    /// drive the paperclip badge in the message list.
    public var hasAttachments: Bool {
        switch self {
        case .string(let value):
            let lower = value.lowercased()
            return lower == "attachment" || lower == "application"
        case .list(let children):
            return children.contains { $0.hasAttachments }
        case .integer, .null:
            return false
        }
    }
}

/// `/fetch_message` response. The raw RFC 822 lives behind `messageRaw`
/// (a presigned S3 URL); the Lambda also returns decoded text and HTML
/// bodies for the convenience of the React reader, which we keep in case
/// callers want to skip the second round-trip.
public struct ApiMessageBody: Sendable, Codable, Hashable {
    public let messageRaw: String?
    public let messageBodyPlain: String?
    public let messageBodyHtml: String?
    public let recipient: String?
    public let messageId: [String]?
    public let inReplyTo: [String]?
    public let references: [String]?

    private enum CodingKeys: String, CodingKey {
        case messageRaw = "message_raw"
        case messageBodyPlain = "message_body_plain"
        case messageBodyHtml = "message_body_html"
        case recipient
        case messageId = "message_id"
        case inReplyTo = "in_reply_to"
        case references
    }
}

public struct ApiAttachmentDescriptor: Sendable, Codable, Hashable {
    public let name: String?
    public let type: String?
    public let size: Int?
    public let id: Int
}

/// `other_headers` sub-object carried by `/send`. Keys mirror the React
/// client's call shape so the Lambda stays a single endpoint.
public struct ApiSendOtherHeaders: Sendable, Codable, Hashable {
    public let messageId: [String]
    public let inReplyTo: [String]
    public let references: [String]

    public init(messageId: [String] = [], inReplyTo: [String] = [], references: [String] = []) {
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
    }

    private enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case inReplyTo = "in_reply_to"
        case references
    }
}

// MARK: - URLSession-backed implementation

/// URLSession-backed implementation. Token attachment and 401 retry logic
/// live here so every endpoint benefits, matching the React app's axios
/// interceptor pattern.
public actor URLSessionApiClient: ApiClient {
    private let configuration: Configuration
    private let authService: AuthService
    private let transport: HTTPTransport

    public init(
        configuration: Configuration,
        authService: AuthService,
        transport: HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.configuration = configuration
        self.authService = authService
        self.transport = transport
    }

    // MARK: Addresses

    public func listAddresses() async throws -> [Address] {
        let request = try await get("/list")
        let data = try await send(request, expectedStatuses: 200..<300)
        // The `/list` Lambda actually returns `{"Items": [...]}` — a thin
        // wrapper over the DynamoDB scan output (see
        // `lambda/api/list/function.py`). Check that first, with the plain
        // array and `{"addresses": [...]}` kept as fallbacks in case the
        // Lambda wire changes.
        if let wrapped = try? JSONDecoder().decode(ItemsWrapper.self, from: data) {
            return wrapped.Items
        }
        if let direct = try? JSONDecoder().decode([Address].self, from: data) {
            return direct
        }
        return try JSONDecoder().decode(LowercaseAddressesWrapper.self, from: data).addresses
    }

    // The `Items` key is PascalCase because the Lambda emits the shape
    // DynamoDB's scan response uses; the struct name is uppercased to match
    // so Codable finds the key without a custom CodingKeys map.
    private struct ItemsWrapper: Decodable {
        // swiftlint:disable:next identifier_name
        let Items: [Address]
    }

    private struct LowercaseAddressesWrapper: Decodable {
        let addresses: [Address]
    }

    public func newAddress(
        username: String,
        subdomain: String,
        tld: String,
        comment: String?,
        address: String
    ) async throws {
        let body: [String: Any?] = [
            "username": username,
            "subdomain": subdomain,
            "tld": tld,
            "comment": comment,
            "address": address,
        ]
        let request = try await post("/new", json: body.compactMapValues { $0 })
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func revokeAddress(
        address: String,
        subdomain: String,
        tld: String,
        publicKey: String?
    ) async throws {
        let body: [String: Any?] = [
            "address": address,
            "subdomain": subdomain,
            "tld": tld,
            "public_key": publicKey,
        ]
        let request = try await delete("/revoke", json: body.compactMapValues { $0 })
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    // MARK: BIMI

    public func fetchBimiURL(senderDomain: String) async throws -> URL? {
        let request = try await get("/fetch_bimi", query: [URLQueryItem(name: "sender_domain", value: senderDomain)])
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let url: String? }
        let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        guard let raw = decoded?.url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    // MARK: Folders

    public func listFolders(host: String) async throws -> ApiFolderList {
        let request = try await get("/list_folders", query: [URLQueryItem(name: "host", value: host)])
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(ApiFolderList.self, from: data)
    }

    public func createFolder(host: String, parent: String, name: String) async throws {
        let request = try await put("/new_folder", json: [
            "host": host,
            "parent": parent,
            "name": name,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func deleteFolder(host: String, name: String) async throws {
        let request = try await delete("/delete_folder", json: [
            "host": host,
            "name": name,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func subscribeFolder(host: String, folder: String) async throws {
        let request = try await put("/subscribe_folder", json: [
            "host": host,
            "folder": folder,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func unsubscribeFolder(host: String, folder: String) async throws {
        let request = try await put("/unsubscribe_folder", json: [
            "host": host,
            "folder": folder,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func folderStatus(host: String, folder: String) async throws -> ApiFolderStatus {
        let request = try await get("/folder_status", query: [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(ApiFolderStatus.self, from: data)
    }

    // MARK: Messages

    public func listMessageIds(
        host: String,
        folder: String,
        sortOrder: String,
        sortField: String
    ) async throws -> [UInt32] {
        let request = try await get("/list_messages", query: [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "sort_order", value: sortOrder),
            URLQueryItem(name: "sort_field", value: sortField),
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let message_ids: [UInt32] }
        return try JSONDecoder().decode(Payload.self, from: data).message_ids
    }

    public func listEnvelopes(host: String, folder: String, ids: [UInt32]) async throws -> [ApiEnvelope] {
        guard !ids.isEmpty else { return [] }
        let idsJson = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let request = try await get("/list_envelopes", query: [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "ids", value: idsJson),
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        // The Lambda returns `{"envelopes": {"42": {...}, "43": {...}}}` —
        // a UID-keyed dictionary, not an array. Sort the result by UID
        // descending here so callers get a stable, most-recent-first list
        // matching how the React client displays the same data.
        struct Payload: Decodable { let envelopes: [String: ApiEnvelope] }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return decoded.envelopes.values.sorted { $0.id > $1.id }
    }

    public func fetchMessage(host: String, folder: String, id: UInt32, markSeen: Bool) async throws -> ApiMessageBody {
        let request = try await get("/fetch_message", query: [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "seen", value: markSeen ? "true" : "false"),
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(ApiMessageBody.self, from: data)
    }

    public func listAttachments(host: String, folder: String, id: UInt32, markSeen: Bool) async throws -> [ApiAttachmentDescriptor] {
        let request = try await get("/list_attachments", query: [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "seen", value: markSeen ? "true" : "false"),
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let attachments: [ApiAttachmentDescriptor] }
        return try JSONDecoder().decode(Payload.self, from: data).attachments
    }

    public func fetchAttachmentURL(
        host: String,
        folder: String,
        id: UInt32,
        index: Int,
        filename: String,
        markSeen: Bool
    ) async throws -> URL {
        let request = try await get("/fetch_attachment", query: [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "index", value: String(index)),
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "seen", value: markSeen ? "true" : "false"),
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let url: String }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard let url = URL(string: decoded.url) else {
            throw CabalmailError.decoding("fetch_attachment returned invalid url")
        }
        return url
    }

    public func fetchInlineImageURL(
        host: String,
        folder: String,
        id: UInt32,
        contentId: String,
        markSeen: Bool
    ) async throws -> URL {
        // React passes `<cid>` literally — see
        // `react/admin/src/ApiClient.js` `fetchImage`. Match that shape.
        let wrappedCid = contentId.hasPrefix("<") ? contentId : "<\(contentId)>"
        let request = try await get("/fetch_inline_image", query: [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "index", value: wrappedCid),
            URLQueryItem(name: "seen", value: markSeen ? "true" : "false"),
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let url: String }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard let url = URL(string: decoded.url) else {
            throw CabalmailError.decoding("fetch_inline_image returned invalid url")
        }
        return url
    }

    // MARK: Operations

    public func setFlag(
        host: String,
        folder: String,
        ids: [UInt32],
        flag: String,
        op: String,
        sortOrder: String,
        sortField: String
    ) async throws -> [UInt32] {
        let request = try await put("/set_flag", json: [
            "host": host,
            "folder": folder,
            "ids": ids.map { Int($0) },
            "flag": flag,
            "op": op,
            "sort_order": sortOrder,
            "sort_field": sortField,
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let message_ids: [UInt32]? }
        return (try? JSONDecoder().decode(Payload.self, from: data).message_ids) ?? []
    }

    public func moveMessages(
        host: String,
        source: String,
        destination: String,
        ids: [UInt32],
        sortOrder: String,
        sortField: String
    ) async throws {
        let request = try await put("/move_messages", json: [
            "host": host,
            "source": source,
            "destination": destination,
            "ids": ids.map { Int($0) },
            "sort_order": sortOrder,
            "sort_field": sortField,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    // MARK: Send

    public func sendMessage(
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
    ) async throws {
        let headersJson: [String: Any] = [
            "message_id": otherHeaders.messageId,
            "in_reply_to": otherHeaders.inReplyTo,
            "references": otherHeaders.references,
        ]
        let request = try await put("/send", json: [
            "host": host,
            "smtp_host": smtpHost,
            "sender": sender,
            "to_list": toList,
            "cc_list": ccList,
            "bcc_list": bccList,
            "subject": subject,
            "other_headers": headersJson,
            "html": htmlBody,
            "text": textBody,
            "draft": draft,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    // MARK: Presigned URL fetch

    public func fetchPresignedData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await transport.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CabalmailError.server(
                code: String(response.statusCode),
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    // MARK: - Wire helpers

    private func endpointURL(_ path: String) -> URL {
        // `invokeUrl` is the API Gateway stage URL; paths in the Lambda layer
        // sit directly under it (see `terraform/infra/modules/app/apigw.tf`).
        configuration.invokeUrl.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        var components = URLComponents(url: endpointURL(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await attachAuth(request)
    }

    private func post(_ path: String, json: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await attachAuth(request)
    }

    private func put(_ path: String, json: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await attachAuth(request)
    }

    private func delete(_ path: String, json: [String: Any] = [:]) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "DELETE"
        if !json.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await attachAuth(request)
    }

    private func attachAuth(_ base: URLRequest) async throws -> URLRequest {
        var request = base
        let token = try await authService.currentIdToken()
        request.setValue(token, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Sends a request with automatic one-shot retry on HTTP 401. The first
    /// 401 forces a token refresh via `AuthService.currentIdToken()` and
    /// replays the request with the new token attached; a second 401 surfaces
    /// as `.authExpired` so the UI can send the user back to the sign-in view.
    private func send(_ request: URLRequest, expectedStatuses: Range<Int>) async throws -> Data {
        let (data, response) = try await transport.perform(request)
        if response.statusCode == 401 {
            var replayed = request
            // Drop the stale token before asking for a fresh one so a cached
            // hit doesn't reattach the token the server just rejected.
            replayed.setValue(nil, forHTTPHeaderField: "Authorization")
            let refreshed = try await authService.currentIdToken()
            replayed.setValue(refreshed, forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await transport.perform(replayed)
            if retryResponse.statusCode == 401 {
                throw CabalmailError.authExpired
            }
            guard expectedStatuses.contains(retryResponse.statusCode) else {
                throw CabalmailError.server(
                    code: String(retryResponse.statusCode),
                    message: String(data: retryData, encoding: .utf8) ?? ""
                )
            }
            return retryData
        }
        guard expectedStatuses.contains(response.statusCode) else {
            throw CabalmailError.server(
                code: String(response.statusCode),
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}
