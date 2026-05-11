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
    private let preferences: Preferences

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

    /// Mirrors the server's `\Flagged` state. Same role as `isSeen`: lets the
    /// toolbar render the right icon and updates optimistically on toggle.
    var isFlagged: Bool

    /// Gate for remote-content loading in the `WKWebView`. Seeded from the
    /// `Preferences.loadRemoteContent` preference — Off leaves the user in
    /// control per-message, Always drops the block entirely. "Ask" starts
    /// blocked and surfaces the toolbar toggle so the user can flip it per
    /// message, which is the plan's "Ask" semantics.
    var remoteContentAllowed: Bool

    /// Controls whether the HTML body is rendered with the reader-view
    /// stylesheet injection. Seeded from `Preferences.defaultBodyRenderMode`;
    /// the detail toolbar toggles it per-message without mutating the
    /// preference.
    var readerMode: Bool

    /// Pending mark-as-read task for the `.afterDelay` behavior. Cancelled
    /// if the user navigates away before the 2-second threshold or marks the
    /// message read manually in the meantime.
    private var pendingMarkAsReadTask: Task<Void, Never>?

    /// Hook for the view to relay flag changes to the list view model so the
    /// list row's unread dot / bold styling flips immediately. Set by
    /// `MessageDetailView` after construction so the model itself stays
    /// decoupled from `AppState`.
    var onFlagChanged: ((Flag, Bool) -> Void)?

    /// Delay for the `.afterDelay` mark-as-read mode. Matches the plan's
    /// "After delay (2s)" label and is low enough that a quick glance
    /// doesn't bleed over into "read."
    static let markAsReadDelay: TimeInterval = 2

    struct Attachment: Identifiable, Hashable {
        let id: String
        let filename: String
        let mimeType: String
        let size: Int
        let fileURL: URL
    }

    init(folder: Folder, envelope: Envelope, client: CabalmailClient, preferences: Preferences) {
        self.folder = folder
        self.envelope = envelope
        self.client = client
        self.preferences = preferences
        self.isSeen = envelope.flags.contains(.seen)
        self.isFlagged = envelope.flags.contains(.flagged)
        self.remoteContentAllowed = preferences.loadRemoteContent == .always
        self.readerMode = preferences.defaultBodyRenderMode == .reader
    }

    func load() async {
        // Clear any stale error from a prior attempt so a retry doesn't keep
        // the red banner visible while the new fetch is in flight.
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        // One automatic retry on transient cancellation. The body fetch
        // chains two `URLSession.data(for:)` calls (Lambda + presigned S3);
        // if either's underlying data task is cancelled while our own Swift
        // Task is still alive, we see `URLError.cancelled` with no way to
        // tell *why* the data task died. Tapping a message right as the
        // list's load finishes is the easiest way to reproduce it. A second
        // attempt typically succeeds. If our own Task is the one being
        // cancelled (view going away), `Task.isCancelled` is already true
        // and we leave the error suppressed — the view is on its way out
        // and shouldn't flash a red banner on disappear.
        var attemptsRemaining = 2
        while attemptsRemaining > 0 {
            attemptsRemaining -= 1
            do {
                let bytes = try await fetchBodyBytes()
                let tree = MimeParser.parse(bytes)
                try await hydrate(from: tree)
                errorMessage = nil
                scheduleMarkAsReadIfNeeded()
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession cancellations sometimes fire mid-fetch while
                // our own Swift Task is still alive (we see it on quick
                // taps right as the list finishes its initial load) — one
                // retry inside the same Task usually clears it. If our
                // Task is itself cancelled, retrying inside it would just
                // throw the same cancellation, so surface an error and
                // let the Retry button give the user a fresh Task.
                if !Task.isCancelled, attemptsRemaining > 0 { continue }
                errorMessage = "Couldn't load message body."
                return
            } catch is CancellationError {
                errorMessage = "Couldn't load message body."
                return
            } catch let error as CabalmailError {
                errorMessage = String(describing: error)
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    /// Cancels any pending delayed mark-as-read task. Called when the detail
    /// view goes away — either the user navigated to another message or
    /// backed out entirely — so we don't mark a message read the user
    /// barely previewed.
    func onDisappear() {
        pendingMarkAsReadTask?.cancel()
        pendingMarkAsReadTask = nil
    }

    /// Toggles the server's `\Seen` flag. Drives both the toolbar button's
    /// manual path and the `.onOpen` / `.afterDelay` mark-as-read
    /// preferences — a successful flip cancels any still-pending delayed
    /// task so the two paths can't race.
    func toggleSeen() async {
        await setSeen(!isSeen)
    }

    private func setSeen(_ shouldBeSeen: Bool) async {
        // Optimistic flip: update the toolbar icon and signal the list
        // before the server round trip so the user sees the change land
        // instantly. The pending delayed-mark-as-read task is cancelled
        // because either path supersedes it. On STORE failure we revert
        // the flag and the cross-view signal so the row goes back to its
        // truthful state.
        let previous = isSeen
        isSeen = shouldBeSeen
        pendingMarkAsReadTask?.cancel()
        pendingMarkAsReadTask = nil
        onFlagChanged?(.seen, shouldBeSeen)
        do {
            try await client.imapClient.setFlags(
                folder: folder.path,
                uids: [envelope.uid],
                flags: [.seen],
                operation: shouldBeSeen ? .add : .remove
            )
        } catch {
            isSeen = previous
            onFlagChanged?(.seen, previous)
            errorMessage = "\(error)"
        }
    }

    private func scheduleMarkAsReadIfNeeded() {
        guard !isSeen else { return }
        switch preferences.markAsRead {
        case .manual:
            return
        case .onOpen:
            Task { await setSeen(true) }
        case .afterDelay:
            pendingMarkAsReadTask?.cancel()
            pendingMarkAsReadTask = Task { [weak self] in
                let delay = Self.markAsReadDelay
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.setSeen(true)
            }
        }
    }

    /// Flip the server's `\Flagged` bit. Optimistic update with revert-on-
    /// failure mirrors `setSeen(_:)`; the cross-view signal lets the list
    /// row's flag indicator appear or disappear without a refresh.
    func toggleFlagged() async {
        let previous = isFlagged
        let shouldBeFlagged = !previous
        isFlagged = shouldBeFlagged
        onFlagChanged?(.flagged, shouldBeFlagged)
        do {
            try await client.imapClient.setFlags(
                folder: folder.path,
                uids: [envelope.uid],
                flags: [.flagged],
                operation: shouldBeFlagged ? .add : .remove
            )
        } catch {
            isFlagged = previous
            onFlagChanged?(.flagged, previous)
            errorMessage = "\(error)"
        }
    }

    func toggleRemoteContent() {
        remoteContentAllowed.toggle()
    }

    func toggleReaderMode() {
        readerMode.toggle()
    }

    /// Dispose target mirrors `MessageListViewModel.dispose(_:)`: read
    /// `Preferences.disposeAction` at call time (Archive or Trash), mark
    /// `\Seen` before the move (archived == read, matching the React app),
    /// then run `UID MOVE` and prune both caches so a relaunch can't re-
    /// hydrate the message into the list.
    ///
    /// Optimistic UI: `onSuccess` fires before the server round trip so the
    /// list selection advances to the next unread message instantly. The
    /// list view also prunes the row in response. If the server work fails,
    /// `onFailure` lets the view revert: the list re-inserts the row and
    /// the user gets a toast. Cache pruning still waits for confirmation —
    /// pruning before that would leave the persistent snapshot disagreeing
    /// with the server on a transient failure.
    func dispose(
        onSuccess: (() -> Void)? = nil,
        onFailure: ((Error) -> Void)? = nil
    ) async {
        let destination = preferences.disposeAction.destinationFolder
        let wasSeen = isSeen
        if !isSeen {
            isSeen = true
            pendingMarkAsReadTask?.cancel()
            pendingMarkAsReadTask = nil
            onFlagChanged?(.seen, true)
        }
        onSuccess?()
        do {
            if !wasSeen {
                try await client.imapClient.setFlags(
                    folder: folder.path,
                    uids: [envelope.uid],
                    flags: [.seen],
                    operation: .add
                )
            }
            try await client.imapClient.move(
                folder: folder.path,
                uids: [envelope.uid],
                destination: destination
            )
            let uidValidity = try? await currentUIDValidity()
            try? await client.envelopeCache.remove(
                uids: [envelope.uid],
                folder: folder.path
            )
            if let uidValidity {
                await client.bodyCache.remove(
                    folder: folder.path,
                    uidValidity: uidValidity,
                    uid: envelope.uid
                )
            }
        } catch {
            errorMessage = "\(error)"
            onFailure?(error)
        }
    }

    /// The currently-configured dispose action, exposed so the toolbar can
    /// render the right icon and label without reaching into the preferences
    /// environment itself.
    var disposeAction: DisposeAction { preferences.disposeAction }

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
