import Foundation

// Draft-lifecycle endpoints for the URLSession-backed `ApiClient` —
// `/save_draft` save / replace / discard (Phase 3 of
// `docs/0.10.x/draft-sync-and-threading-headers-plan.md`). In their own
// file, mirroring the `+Messages` split, so each file stays under
// SwiftLint's `file_length` limit.

extension URLSessionApiClient {
    public func saveDraft(_ request: SaveDraftRequest) async throws -> ApiSaveDraftResponse {
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
            "sender": request.sender,
            "to_list": request.toList,
            "cc_list": request.ccList,
            "bcc_list": request.bccList,
            "subject": request.subject,
            "other_headers": headersJson,
            "html": request.htmlBody,
            "text": request.textBody,
            "attachments": attachmentsJson,
        ]
        if let uid = request.replacesUid, let validity = request.replacesUidValidity {
            json["replaces_uid"] = Int(uid)
            json["replaces_uidvalidity"] = Int(validity)
        }
        let httpRequest = try await put("/save_draft", json: json)
        let data = try await send(httpRequest, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(ApiSaveDraftResponse.self, from: data)
    }

    public func discardDraft(host: String, uid: UInt32, uidValidity: UInt32) async throws -> Bool {
        let httpRequest = try await put("/save_draft", json: [
            "host": host,
            "op": "discard",
            "replaces_uid": Int(uid),
            "replaces_uidvalidity": Int(uidValidity),
        ])
        let data = try await send(httpRequest, expectedStatuses: 200..<300)
        struct Payload: Decodable { let discarded: Bool? }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.discarded ?? false
    }
}
