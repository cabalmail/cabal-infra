import Foundation
import Observation
import CabalmailKit

/// Backs `MessageDetailView`. Fetches the raw RFC 5322 bytes (consulting the
/// `MessageBodyCache` first), hands them to `MimeParser`, and exposes the
/// pieces the view needs: headers, a plain / HTML body, an attachment list,
/// and a `cid:` → local file URL map for inline images.
@Observable
@MainActor
final class MessageDetailViewModel {
    let folder: Folder
    let envelope: Envelope
    private let client: CabalmailClient

    var isLoading = false
    var errorMessage: String?
    var plainText: String?
    var htmlBody: String?
    var attachments: [Attachment] = []
    var inlineImages: [String: URL] = [:]

    /// Mirrors the server's `\Seen` state so the toolbar button can flip its
    /// icon and label between "Mark as read" and "Mark as unread". Initial
    /// value comes from the envelope; updated in place after every toggle
    /// so the UI stays coherent without a full refresh.
    var isSeen: Bool

    /// Gate for remote-content loading in the `WKWebView`. Starts off per the
    /// plan (reading preferences default: Off); the user can flip it per-
    /// message from the toolbar.
    var remoteContentAllowed = false

    struct Attachment: Identifiable, Hashable {
        let id: String
        let filename: String
        let mimeType: String
        let size: Int
        let fileURL: URL
    }

    init(folder: Folder, envelope: Envelope, client: CabalmailClient) {
        self.folder = folder
        self.envelope = envelope
        self.client = client
        self.isSeen = envelope.flags.contains(.seen)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let bytes = try await fetchBodyBytes()
            let tree = MimeParser.parse(bytes)
            try await hydrate(from: tree)
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggles the server's `\Seen` flag. Phase 4 default is "manual", so the
    /// detail view does not auto-mark on open — the user drives this via the
    /// toolbar button, which also flips its own icon based on `isSeen`.
    func toggleSeen() async {
        let shouldBeSeen = !isSeen
        do {
            try await client.imapClient.setFlags(
                folder: folder.path,
                uids: [envelope.uid],
                flags: [.seen],
                operation: shouldBeSeen ? .add : .remove
            )
            isSeen = shouldBeSeen
        } catch {
            errorMessage = "\(error)"
        }
    }

    func toggleRemoteContent() {
        remoteContentAllowed.toggle()
    }

    // MARK: - Internals

    private func fetchBodyBytes() async throws -> Data {
        let uidValidity = try await currentUIDValidity()
        if let cached = await client.bodyCache.fetch(
            folder: folder.path,
            uidValidity: uidValidity,
            uid: envelope.uid
        ) {
            return cached
        }
        try await client.imapClient.connectAndAuthenticate()
        let raw = try await client.imapClient.fetchBody(folder: folder.path, uid: envelope.uid)
        try await client.bodyCache.store(
            folder: folder.path,
            uidValidity: uidValidity,
            uid: envelope.uid,
            bytes: raw.bytes
        )
        return raw.bytes
    }

    private func currentUIDValidity() async throws -> UInt32 {
        if let snapshot = await client.envelopeCache.snapshot(for: folder.path) {
            return snapshot.uidValidity
        }
        let status = try await client.imapClient.status(path: folder.path)
        return status.uidValidity ?? 0
    }

    private func hydrate(from root: MimePart) async throws {
        if let plain = root.firstPart(where: { $0.contentType.mimeType == "text/plain" }) {
            plainText = plain.textContent()
        }
        if let html = root.firstPart(where: { $0.contentType.mimeType == "text/html" }) {
            htmlBody = html.textContent()
        }
        var attachmentList: [Attachment] = []
        var inlineMap: [String: URL] = [:]
        for leaf in root.leafParts where isAttachmentLike(leaf) {
            let filename = leaf.contentDisposition?.filename
                ?? leaf.contentType.name
                ?? "attachment-\(UUID().uuidString).bin"
            let url = try writeToTmp(data: leaf.decodedBody, filename: filename)
            if let contentID = leaf.contentID,
               leaf.contentType.type == "image" {
                inlineMap[contentID] = url
                continue
            }
            attachmentList.append(Attachment(
                id: leaf.contentID ?? url.lastPathComponent,
                filename: filename,
                mimeType: leaf.contentType.mimeType,
                size: leaf.decodedBody.count,
                fileURL: url
            ))
        }
        attachments = attachmentList
        inlineImages = inlineMap
    }

    private func isAttachmentLike(_ part: MimePart) -> Bool {
        if part.contentDisposition?.isAttachment == true { return true }
        if part.contentType.isText, part.contentType.subtype == "plain" { return false }
        if part.contentType.isText, part.contentType.subtype == "html" { return false }
        return !part.contentType.isMultipart
    }

    /// Writes a decoded part to the app's temp directory. Phase-7 polish can
    /// replace this with a size-bounded managed directory; for Phase 4 we
    /// rely on the OS sweeping `/tmp` between launches.
    private func writeToTmp(data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-attachments-\(envelope.uid)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent(safeName)
        try data.write(to: url, options: .atomic)
        return url
    }
}
