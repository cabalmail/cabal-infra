import Foundation

// Message, attachment, operation, and send endpoints for the URLSession-
// backed `ApiClient`. Split out from `URLSessionApiClient.swift` to keep
// each file under SwiftLint's `file_length` limit; relies on the wire
// helpers (`get`, `post`, `put`, `delete`, `send`) declared on the actor
// in that file.

extension URLSessionApiClient {
    // MARK: - Decodable payload wrappers

    fileprivate struct MessageIdsPayload: Decodable {
        let messageIds: [UInt32]

        private enum CodingKeys: String, CodingKey {
            case messageIds = "message_ids"
        }
    }

    fileprivate struct MessageIdsOptionalPayload: Decodable {
        let messageIds: [UInt32]?

        private enum CodingKeys: String, CodingKey {
            case messageIds = "message_ids"
        }
    }

    // MARK: - Messages

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
        return try JSONDecoder().decode(MessageIdsPayload.self, from: data).messageIds
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

    public func fetchMessage(
        host: String,
        folder: String,
        id: UInt32,
        markSeen: Bool
    ) async throws -> ApiMessageBody {
        let request = try await get("/fetch_message", query: [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "seen", value: markSeen ? "true" : "false"),
        ])
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(ApiMessageBody.self, from: data)
    }

    public func listAttachments(
        host: String,
        folder: String,
        id: UInt32,
        markSeen: Bool
    ) async throws -> [ApiAttachmentDescriptor] {
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

    public func fetchAttachmentURL(_ request: FetchAttachmentRequest) async throws -> URL {
        let httpRequest = try await get("/fetch_attachment", query: [
            URLQueryItem(name: "host", value: request.host),
            URLQueryItem(name: "folder", value: request.folder),
            URLQueryItem(name: "id", value: String(request.id)),
            URLQueryItem(name: "index", value: String(request.index)),
            URLQueryItem(name: "filename", value: request.filename),
            URLQueryItem(name: "seen", value: request.markSeen ? "true" : "false"),
        ])
        let data = try await send(httpRequest, expectedStatuses: 200..<300)
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

    // MARK: - Operations

    public func setFlag(_ request: SetFlagRequest) async throws -> [UInt32] {
        let httpRequest = try await put("/set_flag", json: [
            "host": request.host,
            "folder": request.folder,
            "ids": request.ids.map { Int($0) },
            "flag": request.flag,
            "op": request.operation,
            "sort_order": request.sortOrder,
            "sort_field": request.sortField,
        ])
        let data = try await send(httpRequest, expectedStatuses: 200..<300)
        return (try? JSONDecoder().decode(MessageIdsOptionalPayload.self, from: data).messageIds) ?? []
    }

    public func moveMessages(_ request: MoveMessagesRequest) async throws {
        let httpRequest = try await put("/move_messages", json: [
            "host": request.host,
            "source": request.source,
            "destination": request.destination,
            "ids": request.ids.map { Int($0) },
            "sort_order": request.sortOrder,
            "sort_field": request.sortField,
        ])
        _ = try await send(httpRequest, expectedStatuses: 200..<300)
    }

    // MARK: - Send

    public func sendMessage(_ request: SendMessageRequest) async throws {
        let headersJson: [String: Any] = [
            "message_id": request.otherHeaders.messageId,
            "in_reply_to": request.otherHeaders.inReplyTo,
            "references": request.otherHeaders.references,
        ]
        let httpRequest = try await put("/send", json: [
            "host": request.host,
            "smtp_host": request.smtpHost,
            "sender": request.sender,
            "to_list": request.toList,
            "cc_list": request.ccList,
            "bcc_list": request.bccList,
            "subject": request.subject,
            "other_headers": headersJson,
            "html": request.htmlBody,
            "text": request.textBody,
            "draft": request.draft,
        ])
        _ = try await send(httpRequest, expectedStatuses: 200..<300)
    }

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
}
