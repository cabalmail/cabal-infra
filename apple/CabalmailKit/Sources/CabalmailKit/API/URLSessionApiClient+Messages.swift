import Foundation

// Message, attachment, operation, and send endpoints for the URLSession-
// backed `ApiClient`. Split out from `URLSessionApiClient.swift` to keep
// each file under SwiftLint's `file_length` limit; relies on the wire
// helpers (`get`, `post`, `put`, `delete`, `send`) declared on the actor
// in that file.

// MARK: - Decodable payload wrappers
//
// Kept at file scope rather than nested inside the extension so the
// `CodingKeys` enums sit one level deep (the SwiftLint `nesting` rule
// allows a single level of type nesting and counts the enclosing type
// in the level depth).

private struct MessageIdsPayload: Decodable {
    let messageIds: [UInt32]

    private enum CodingKeys: String, CodingKey {
        case messageIds = "message_ids"
    }
}

/// Response body of the bulk-op Lambdas (`/set_flag`, `/move_messages`).
/// Full success is `{"status": "submitted"}`; a batched partial failure is
/// `{"status": "partial", "flagged_ids"/"moved_ids": [...], "failed_ids":
/// [...]}` (the success key is endpoint-specific, so both are optional
/// here). Older Lambdas returned `{"message_ids": [...]}` — decoding that
/// yields no `status`, which the mapper treats as full success.
private struct BulkOpPayload: Decodable {
    let status: String?
    let flaggedIds: [UInt32]?
    let movedIds: [UInt32]?
    let failedIds: [UInt32]?

    private enum CodingKeys: String, CodingKey {
        case status
        case flaggedIds = "flagged_ids"
        case movedIds = "moved_ids"
        case failedIds = "failed_ids"
    }
}

/// Maps a bulk-op response body onto the requested UID list. Anything
/// other than an explicit `status: "partial"` (including an undecodable
/// body) is full success — a total failure arrives as a non-2xx status
/// and throws inside `send` before reaching this.
private func decodeBulkResult(_ data: Data, requested: [UInt32]) -> BulkOpResult {
    guard let payload = try? JSONDecoder().decode(BulkOpPayload.self, from: data),
          payload.status == "partial" else {
        return BulkOpResult(succeeded: requested, failed: [])
    }
    return BulkOpResult(
        succeeded: payload.flaggedIds ?? payload.movedIds ?? [],
        failed: payload.failedIds ?? []
    )
}

/// Day-granular date formatter matching `/search_envelopes`'s YYYY-MM-DD
/// expectation. UTC so a calendar date chosen in the UI maps to the same
/// IMAP SINCE/BEFORE day server-side regardless of the user's local zone.
private enum SearchDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Decoded `/search_envelopes` body. Lifted to file scope so the nested
/// types stay within SwiftLint's `nesting` rule (one level inside the
/// extension already).
private struct SearchEnvelopesPayload: Decodable {
    let envelopes: [ApiSearchEnvelope]
    let totalEstimate: Int
    let nextCursor: String?
    let foldersSearched: [String]
    let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case envelopes, truncated
        case totalEstimate = "total_estimate"
        case nextCursor = "next_cursor"
        case foldersSearched = "folders_searched"
    }
}

private func searchEnvelopesQueryItems(host: String, query: SearchQuery) -> [URLQueryItem] {
    var items: [URLQueryItem] = [URLQueryItem(name: "host", value: host)]
    func appendIfPresent(_ name: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: value))
    }
    appendIfPresent("folder", query.folder)
    appendIfPresent("text", query.text)
    appendIfPresent("from", query.from)
    appendIfPresent("to", query.to)
    appendIfPresent("subject", query.subject)
    if let since = query.since {
        items.append(URLQueryItem(name: "since", value: SearchDateFormatter.shared.string(from: since)))
    }
    if let before = query.before {
        items.append(URLQueryItem(name: "before", value: SearchDateFormatter.shared.string(from: before)))
    }
    if query.unread { items.append(URLQueryItem(name: "unread", value: "1")) }
    if query.flagged { items.append(URLQueryItem(name: "flagged", value: "1")) }
    if query.hasAttachment { items.append(URLQueryItem(name: "has_attachment", value: "1")) }
    if let limit = query.limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
    appendIfPresent("cursor", query.cursor)
    return items
}

extension URLSessionApiClient {
    // MARK: - Messages

    public func listMessageIds(
        host: String,
        folder: String,
        sortOrder: String,
        sortField: String,
        page: MessageIdPage?
    ) async throws -> [UInt32] {
        var items = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "sort_order", value: sortOrder),
            URLQueryItem(name: "sort_field", value: sortField),
        ]
        // Only send the pagination params when set; omitting them asks the
        // Lambda for the full sorted list (its pre-pagination behavior).
        if let page {
            items.append(URLQueryItem(name: "offset", value: String(page.offset)))
            items.append(URLQueryItem(name: "limit", value: String(page.limit)))
        }
        let request = try await get("/list_messages", query: items)
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(MessageIdsPayload.self, from: data).messageIds
    }

    public func searchEnvelopes(host: String, query: SearchQuery) async throws -> ApiSearchResponse {
        let request = try await get(
            "/search_envelopes",
            query: searchEnvelopesQueryItems(host: host, query: query)
        )
        let data = try await send(request, expectedStatuses: 200..<300)
        let decoded = try JSONDecoder().decode(SearchEnvelopesPayload.self, from: data)
        return ApiSearchResponse(
            envelopes: decoded.envelopes,
            totalEstimate: decoded.totalEstimate,
            nextCursor: decoded.nextCursor,
            foldersSearched: decoded.foldersSearched,
            truncated: decoded.truncated
        )
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

    public func setFlag(_ request: SetFlagRequest) async throws -> BulkOpResult {
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
        return decodeBulkResult(data, requested: request.ids)
    }

    public func moveMessages(_ request: MoveMessagesRequest) async throws -> BulkOpResult {
        let httpRequest = try await put("/move_messages", json: [
            "host": request.host,
            "source": request.source,
            "destination": request.destination,
            "ids": request.ids.map { Int($0) },
            "mark_seen": request.markSeen,
            "sort_order": request.sortOrder,
            "sort_field": request.sortField,
        ])
        let data = try await send(httpRequest, expectedStatuses: 200..<300)
        return decodeBulkResult(data, requested: request.ids)
    }

    public func purgeMessages(host: String, folder: String, ids: [UInt32]) async throws {
        let httpRequest = try await delete("/purge_messages", json: [
            "host": host,
            "folder": folder,
            "ids": ids.map { Int($0) },
        ])
        _ = try await send(httpRequest, expectedStatuses: 200..<300)
    }

    public func emptyTrash(host: String, folder: String) async throws {
        let httpRequest = try await delete("/empty_trash", json: [
            "host": host,
            "folder": folder,
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
        let attachmentsJson: [[String: Any]] = request.attachments.map { attachment in
            [
                "filename": attachment.filename,
                "mime_type": attachment.mimeType,
                "s3_key": attachment.s3Key,
            ]
        }
        var json: [String: Any] = [
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
            "attachments": attachmentsJson,
        ]
        // Send-from-draft cleanup; the pair only means anything together
        // (the Lambda's expunge is UIDVALIDITY-guarded).
        if let uid = request.discardDraftUid, let validity = request.discardDraftUidValidity {
            json["discard_draft_uid"] = Int(uid)
            json["discard_draft_uidvalidity"] = Int(validity)
        }
        let httpRequest = try await put("/send", json: json)
        do {
            _ = try await send(httpRequest, expectedStatuses: 200..<300)
        } catch let error as CabalmailError {
            throw sendInFlightError(error)
        }
    }

    public func requestAttachmentUploads(
        host: String,
        files: [AttachmentUploadSlot]
    ) async throws -> [AttachmentUpload] {
        guard !files.isEmpty else { return [] }
        let filesJson: [[String: Any]] = files.map { slot in
            [
                "filename": slot.filename,
                "mime_type": slot.mimeType,
            ]
        }
        let httpRequest = try await put("/upload_url", json: [
            "host": host,
            "files": filesJson,
        ])
        let data = try await send(httpRequest, expectedStatuses: 200..<300)
        struct Entry: Decodable { let key: String; let url: String }
        struct Payload: Decodable { let uploads: [Entry] }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard decoded.uploads.count == files.count else {
            throw CabalmailError.decoding(
                "upload_url returned \(decoded.uploads.count) entries for \(files.count) files"
            )
        }
        return try decoded.uploads.map { entry in
            guard let url = URL(string: entry.url) else {
                throw CabalmailError.decoding("upload_url returned an invalid URL")
            }
            return AttachmentUpload(key: entry.key, url: url)
        }
    }

    public func uploadAttachment(url: URL, mimeType: String, data: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(mimeType.isEmpty ? "application/octet-stream" : mimeType,
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (respData, response) = try await transport.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CabalmailError.server(
                code: String(response.statusCode),
                message: String(data: respData, encoding: .utf8) ?? ""
            )
        }
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

/// Shape of `/send`'s already-claimed response
/// (`lambda/api/send/function.py` `_duplicate_response`).
private struct DuplicateInFlightBody: Decodable {
    let status: String
}

/// Maps `409 {"status":"duplicate_in_flight"}` onto `.sendInFlight`.
///
/// /send holds a dedupe claim on the Message-Id across the SMTP handoff. It
/// answers a duplicate it can prove delivered with the same 200 a fresh
/// delivery gets — but one it cannot (still in flight, or orphaned by a
/// handler that died) now answers 409, because the outbox was deleting those
/// queued messages as sent when nothing had been delivered (#1019). Any other
/// error passes through unchanged.
private func sendInFlightError(_ error: CabalmailError) -> CabalmailError {
    guard case .server(let code, let message) = error,
          code == "409",
          let data = message.data(using: .utf8),
          let body = try? JSONDecoder().decode(DuplicateInFlightBody.self, from: data),
          body.status == "duplicate_in_flight" else {
        return error
    }
    return .sendInFlight
}
