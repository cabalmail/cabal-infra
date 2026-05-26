// swiftlint:disable file_length
// `file_length` is suppressed while issue #403 diagnostic logging lives
// here. Re-enable (remove this line) when `BodyFetchLog` calls are
// stripped and the file falls back under the 400-line cap.
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

    /// Flips to `true` after the first `load()` call finishes — successfully
    /// or otherwise. The view treats the pre-attempt state as "loading" so a
    /// fast-failing fetch can never paint the error/retry screen before the
    /// user has seen a spinner. The Retry button still works on its own
    /// because `load()` also drives `isLoading` while it's in flight.
    var hasAttemptedLoad = false

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

    /// In-flight body fetch (#403). Owned by the model so SwiftUI's `.task`
    /// double-fire can't cancel it. Torn down by `onDisappear()`.
    private var loadTask: Task<Void, Never>?

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

    // swiftlint:disable:next function_body_length
    func load() async {
        let uid = envelope.uid
        let startedAt = Date()
        BodyFetchLog.loadEnter(uid: uid)
        // #403: SwiftUI fires `.onDisappear` mid-push transition, cancelling
        // this Task before `.onAppear` re-fires and spawns the live one.
        // Short-circuit so the cancelled Task doesn't paint an error screen.
        if Task.isCancelled { return }
        errorMessage = nil
        isLoading = true
        // Only mark attempted on a definitive outcome — a mid-flight cancel
        // leaves the load un-attempted so the next live Task can take over.
        var completed = false
        defer {
            isLoading = false
            if completed { hasAttemptedLoad = true }
            let hasBody = htmlBody != nil || plainText != nil
            BodyFetchLog.loadExit(uid: uid, startedAt: startedAt, errorSet: errorMessage != nil, hasBody: hasBody)
        }
        // One automatic retry on transient `URLError.cancelled`.
        var attemptsRemaining = 2
        while attemptsRemaining > 0 {
            attemptsRemaining -= 1
            let attemptNumber = 2 - attemptsRemaining
            BodyFetchLog.loadAttempt(uid: uid, attempt: attemptNumber)
            do {
                let bytes = try await fetchBodyBytes()
                let tree = MimeParser.parse(bytes)
                try await hydrate(from: tree)
                errorMessage = nil
                BodyFetchLog.loadSuccess(uid: uid, attempt: attemptNumber, bytes: bytes.count)
                scheduleMarkAsReadIfNeeded()
                completed = true
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                BodyFetchLog.loadURLError(uid: uid, attempt: attemptNumber, error: urlError)
                if Task.isCancelled { return }
                if attemptsRemaining > 0 { continue }
                errorMessage = "Couldn't load message body."
                completed = true
                return
            } catch let urlError as URLError {
                BodyFetchLog.loadURLError(uid: uid, attempt: attemptNumber, error: urlError)
                errorMessage = urlError.localizedDescription
                completed = true
                return
            } catch is CancellationError {
                BodyFetchLog.loadCancellation(uid: uid, attempt: attemptNumber)
                if Task.isCancelled { return }
                errorMessage = "Couldn't load message body."
                completed = true
                return
            } catch {
                BodyFetchLog.loadOther(uid: uid, attempt: attemptNumber, error: error)
                errorMessage = (error as? CabalmailError).map { String(describing: $0) }
                    ?? error.localizedDescription
                completed = true
                return
            }
        }
    }

    /// Cancels the pending mark-as-read task so a barely-previewed message
    /// doesn't get marked read. Deliberately does NOT cancel the body-fetch
    /// `loadTask`: on iPhone, SwiftUI fires `.onDisappear` mid-push for
    /// phantom view instances that aren't actually going away (#403). The
    /// load Task holds the model alive for the duration of `load()`, then
    /// everything deallocates naturally if the view is truly gone.
    func onDisappear() {
        pendingMarkAsReadTask?.cancel()
        pendingMarkAsReadTask = nil
        BodyFetchLog.disappear(uid: envelope.uid, hadTask: loadTask != nil)
    }

    /// Spawns the body fetch on `loadTask`. No-op if loaded or in flight.
    func startLoadIfNeeded() {
        let uid = envelope.uid
        BodyFetchLog.startGate(uid: uid, hasHTML: htmlBody != nil,
                               hasPlain: plainText != nil,
                               isLoading: isLoading, hasTask: loadTask != nil)
        guard htmlBody == nil, plainText == nil, !isLoading else { return }
        if let existing = loadTask, !existing.isCancelled { return }
        BodyFetchLog.startSpawn(uid: uid)
        loadTask = Task { @MainActor [weak self] in await self?.load() }
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

    /// Move the current message to an arbitrary folder. Mirrors `dispose`
    /// but accepts a destination path and does NOT mark `\Seen` — archive
    /// is "I'm done with this," whereas Move is "file this for later."
    /// Forcing the seen bit there would surprise users filing unread
    /// messages into project folders.
    ///
    /// Optimistic UI: `onSuccess` fires before the server round trip so
    /// the list view can prune the row immediately. On failure the caller
    /// surfaces a toast; cache pruning still waits for confirmation so a
    /// transient error doesn't leave the persistent snapshot disagreeing
    /// with the server.
    func move(
        to destination: String,
        onSuccess: (() -> Void)? = nil,
        onFailure: ((Error) -> Void)? = nil
    ) async {
        onSuccess?()
        do {
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

    /// Returns the raw RFC 5322 bytes for the current message, going
    /// through the same body cache as the in-pane render. Powers the
    /// View Source sheet — first open is a fetch, subsequent opens hit
    /// the cache that the in-pane render already populated.
    func rawSourceBytes() async throws -> Data {
        try await fetchBodyBytes()
    }
}

// MARK: - Internals
//
// Body-fetch, MIME parsing, and attachment-extraction helpers live in a
// same-file extension so the primary class body stays under SwiftLint's
// type_body_length cap. They remain `private` (file-scoped) and reach
// stored properties (`client`, `folder`, `envelope`) through the type's
// `@MainActor` isolation, inherited by the extension.

private extension MessageDetailViewModel {
    func fetchBodyBytes() async throws -> Data {
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

    func currentUIDValidity() async throws -> UInt32 {
        if let snapshot = await client.envelopeCache.snapshot(for: folder.path) {
            return snapshot.uidValidity
        }
        let status = try await client.imapClient.status(path: folder.path)
        return status.uidValidity ?? 0
    }

    func hydrate(from root: MimePart) async throws {
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

    func isAttachmentLike(_ part: MimePart) -> Bool {
        if part.contentDisposition?.isAttachment == true { return true }
        if part.contentType.isText, part.contentType.subtype == "plain" { return false }
        if part.contentType.isText, part.contentType.subtype == "html" { return false }
        return !part.contentType.isMultipart
    }

    /// Writes a decoded part to the app's temp directory. Phase-7 polish can
    /// replace this with a size-bounded managed directory; for Phase 4 we
    /// rely on the OS sweeping `/tmp` between launches.
    func writeToTmp(data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-attachments-\(envelope.uid)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent(safeName)
        try data.write(to: url, options: .atomic)
        return url
    }
}
