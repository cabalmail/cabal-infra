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
    /// The message this reader shows: `envelope` in `folder`. The host hands
    /// the reader the folder the selected row came from, so this is that
    /// row's own message, even when another search row shares its UID.
    var ref: MessageRef {
        MessageRef(folder: folder.path, uid: envelope.uid, messageId: envelope.messageId)
    }
    // Internal (not `private`) so the flag-handling methods, lifted into the
    // `+Flags` sibling extension to keep this type body under SwiftLint's cap,
    // can reach them.
    let client: CabalmailClient
    let preferences: Preferences
    /// This reader's own folder for attachment files (`AttachmentFolders`).
    @ObservationIgnored private let attachmentDirectory = AttachmentFolders.make()

    var isLoading = false
    var errorMessage: String?
    var plainText: String?
    var htmlBody: String?
    var attachments: [Attachment] = []
    var inlineImages: [String: URL] = [:]

    /// RFC 5322 threading identity parsed from the fetched message's
    /// headers (angle-bracketed, like the envelope payload). The list
    /// envelope may predate the server emitting these fields, so the
    /// open-message reply path overlays them via `threadedEnvelope`
    /// (Phase 0 of the draft-sync-and-threading plan).
    var threadingMessageId: String?
    var threadingInReplyTo: String?
    var threadingReferences: [String] = []
    /// Root-part headers, retained for the Drafts resume path — Bcc and
    /// the threading headers live only here.
    var rootHeaders: [MimeHeader] = []

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

    /// Mirrors the message's custom-flag slot atoms (rules-composition
    /// plan, Phase 4). Same optimistic role as `isFlagged`; drives the
    /// header chips and the flag menu's checkmarks.
    var keywordSlots: Set<String>

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

    /// Per-message override that bypasses the HTML body and renders the
    /// `text/plain` alternative directly. Off by default; the overflow
    /// menu's "Plain text alternative" item flips it so users who prefer
    /// plain text (or who are debugging an HTML rendering quirk) can
    /// fall back to the text part without changing global settings.
    /// No-op when the message has no plain alternative.
    var forcePlainText: Bool = false

    /// Monotonic counter the overflow menu's Print item bumps. The HTML
    /// body view's Representable observes it via `update*View` and routes
    /// the WKWebView through the system print stack on every increment.
    /// Plain `Int` instead of a Combine subject keeps the surface
    /// @Observable-friendly without pulling extra dependencies in.
    var printRequestTick: Int = 0

    func requestPrint() { printRequestTick += 1 }

    /// In-flight body fetch (#403). Owned by the model so SwiftUI's `.task`
    /// double-fire can't cancel it. Deliberately not cancelled when the view
    /// disappears: `.onDisappear` is unreliable on iPhone (SwiftUI fires it
    /// mid-push for phantom view instances that aren't going away), so the
    /// Task runs to completion and the model deallocates naturally if the
    /// view is truly gone.
    private var loadTask: Task<Void, Never>?

    /// Where this reader's writes go: the signed-in store's mutation service
    /// once `MessageDetailView` connects it (`connect(to:in:)`), which tells
    /// every list, moves the counts and shields the write; until then (a
    /// test's reader), a service of its own that nobody hears, so its server
    /// calls still go out.
    @ObservationIgnored private(set) var mutations: MailMutationService = .unconnected()

    /// The main window this reader is in (`commandWindowID`), which its
    /// writes' events name, so only that window's list advances past a
    /// message it removes (#1845).
    @ObservationIgnored private(set) var window: UUID?

    /// Who this reader's writes are from, as the events name it.
    var writer: MailWriter { .reader(self, in: window, through: client) }

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
        self.keywordSlots = Set(FlagPalette.slots(in: envelope.flags))
        self.remoteContentAllowed = preferences.loadRemoteContent == .always
        self.readerMode = preferences.defaultBodyRenderMode == .reader
    }

    /// Connects the reader to the signed-in account's store: its writes go
    /// through the store's mutation service, naming `window`, and it hears
    /// the store's events, so a flag another list or reader changes on its
    /// message shows on its toolbar too.
    func connect(to mailStore: MailSessionStore, in window: UUID?) {
        mutations = mailStore.mutations
        self.window = window
        mailStore.events.subscribe(self)
    }

    func load() async {
        // Defensive (#403): nothing in the view cancels `loadTask` any more
        // (see its doc), but a Task that arrives here cancelled must not
        // paint an error screen.
        if Task.isCancelled { return }
        errorMessage = nil
        isLoading = true
        // Only mark attempted on a definitive outcome — a mid-flight cancel
        // leaves the load un-attempted so the next live Task can take over.
        var completed = false
        defer {
            isLoading = false
            if completed { hasAttemptedLoad = true }
        }
        do {
            let bytes = try await fetchBodyBytes()
            let tree = MimeParser.parse(bytes)
            try await hydrate(from: tree)
            errorMessage = nil
            donateBodyToSpotlight()
            scheduleMarkAsReadIfNeeded()
            completed = true
        } catch {
            // This load's task was cancelled mid-fetch: leave quietly,
            // un-attempted, for the next live task to take over. The
            // transport reports that cancel as `.cancelled` (#1815); a
            // spurious URLSession cancel has had its one retry there and
            // arrives as `.network`, a failure like any other.
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
            completed = true
        }
    }

    /// Adds the just-parsed body text to the message's Spotlight entry
    /// (fire-and-forget; the indexer gates on the folder being subscribed).
    /// Prefers the `text/plain` alternative; an HTML-only message falls
    /// back to a search-oriented tag strip (`HTMLText`). Bodies are never
    /// fetched just to index them.
    private func donateBodyToSpotlight() {
        var text = plainText ?? ""
        if text.isEmpty, let html = htmlBody {
            text = HTMLText.plainText(from: html)
        }
        guard !text.isEmpty else { return }
        let donated = text
        let client = client
        let envelope = envelope
        let folderPath = folder.path
        Task {
            await client.spotlightIndexer?.indexBody(
                text: donated, envelope: envelope, folder: folderPath
            )
        }
    }

    /// Spawns the body fetch on `loadTask`. No-op if loaded or in flight.
    /// `loadTask` is cleared when it finishes, so after a failed load a
    /// reader that appears again fetches again rather than staying on the
    /// error until Retry is tapped (#1815).
    func startLoadIfNeeded() {
        guard htmlBody == nil, plainText == nil, !isLoading else { return }
        if let existing = loadTask, !existing.isCancelled { return }
        loadTask = Task { @MainActor [weak self] in
            await self?.load()
            self?.loadTask = nil
        }
    }

    func toggleRemoteContent() {
        remoteContentAllowed.toggle()
    }

    func toggleReaderMode() {
        readerMode.toggle()
    }

    /// Dispose target mirrors `MessageListViewModel.dispose(_:)`: read
    /// `Preferences.disposeAction` at call time (Archive or Trash), and have
    /// the server mark the message `\Seen` as it moves it (archived == read,
    /// matching the React app).
    ///
    /// `action` overrides the preference when the caller has already picked
    /// a destination — the overflow menu's alternate dispose item offers
    /// whichever of Archive / Delete the toolbar button doesn't. `nil`
    /// keeps the read-the-preference-at-call-time behavior.
    ///
    /// Optimistic UI: the mutation service drops the row from every list
    /// before the server round trip, so this window's selection advances to
    /// the next message at once. If the server refuses, every list puts the
    /// row back, unread again if this call marked it read (as the list's own
    /// dispose reverts its unread count), and `onFailure` shows the user a
    /// toast. The offline caches forget the message only once the server
    /// confirms, so a transient failure can't leave the persistent snapshot
    /// disagreeing with the server.
    func dispose(
        action: DisposeAction? = nil,
        onFailure: ((Error) -> Void)? = nil
    ) async {
        let destination = (action ?? preferences.disposeAction).destinationFolder
        let wasSeen = isSeen
        isSeen = true
        // Mark-seen + move in a single call (server adds `\Seen` before
        // moving) so the archive commits in one round trip — see
        // MessageListViewModel.dispose for why the reduced call count
        // matters when disposing as the app backgrounds.
        let outcome = await removeOpenMessage(.move(to: destination, markingSeen: !wasSeen), unread: !wasSeen)
        guard outcome.failed.contains(ref) else { return }
        isSeen = wasSeen
        reportRefusal(outcome, to: onFailure)
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
    func move(
        to destination: String,
        onFailure: ((Error) -> Void)? = nil
    ) async {
        let outcome = await removeOpenMessage(.move(to: destination, markingSeen: false), unread: !isSeen)
        guard outcome.failed.contains(ref) else { return }
        reportRefusal(outcome, to: onFailure)
    }

    /// The open message's removal, through the mutation service: the row
    /// leaves every list at once, and comes back if the server refuses.
    /// `unread` moves the message's unread count with it.
    func removeOpenMessage(
        _ removal: MailMutationService.Removal,
        unread: Bool
    ) async -> MailMutationService.RemovalOutcome {
        await mutations.remove(
            [ref], removal, unread: unread ? [ref] : [], flagged: isFlagged ? [ref] : [], by: writer
        ).value
    }

    /// Shows a removal the server refused: its error on the reader, and the
    /// caller's toast.
    func reportRefusal(_ outcome: MailMutationService.RemovalOutcome, to onFailure: ((Error) -> Void)?) {
        errorMessage = outcome.message
        if let error = outcome.error { onFailure?(error) }
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

// Internal (not `private`) so the Drafts resume path (`+Drafts`) can
// resolve the folder's UIDVALIDITY.
extension MessageDetailViewModel {
    func currentUIDValidity() async throws -> UInt32 {
        if let snapshot = await client.envelopeCache.snapshot(for: folder.path) {
            return snapshot.uidValidity
        }
        let status = try await client.imapClient.status(path: folder.path)
        return status.uidValidity ?? 0
    }
}

private extension MessageDetailViewModel {
    func fetchBodyBytes() async throws -> Data {
        try await client.rawMessage(folder: folder.path, uid: envelope.uid)
    }

    func hydrate(from root: MimePart) async throws {
        // Parts marked as attachments are never the body (#1812).
        if let plain = root.bodyPart(mimeType: "text/plain") {
            plainText = plain.textContent()
        }
        if let html = root.bodyPart(mimeType: "text/html") {
            htmlBody = html.textContent()
        }
        rootHeaders = root.headers
        threadingMessageId = MessageIds.parse(root.headerValue("Message-ID")).first
        threadingInReplyTo = MessageIds.parse(root.headerValue("In-Reply-To")).first
        threadingReferences = MessageIds.parse(root.headerValue("References"))
        // Classification (which leaves are downloadable attachments vs inline
        // `cid:` images) is a pure decision, lifted into `MimePart.attachmentPlan()`
        // in CabalmailKit so it's unit-tested. Inline images are embedded as
        // `data:` URIs, not temp files: the body web view loads with an opaque
        // origin and can't fetch `file://` subresources, so a file URL would
        // silently fail to render. See `MimePart.inlineImageDataURL`.
        let plan = root.attachmentPlan()
        inlineImages = plan.inlineImages
        var fileNames = AttachmentFileNamer()
        attachments = try plan.attachments.map { item in
            let filename = item.filename ?? "attachment-\(UUID().uuidString).bin"
            let url = try writeToTmp(data: item.data, filename: fileNames.name(for: filename))
            return Attachment(
                id: item.contentID ?? url.lastPathComponent,
                filename: filename,
                mimeType: item.mimeType,
                size: item.data.count,
                fileURL: url
            )
        }
    }

    /// Writes a decoded part, under a name from `AttachmentFileNamer`, to this
    /// reader's own temp folder (`attachmentDirectory`). Sign-out deletes
    /// it; otherwise the OS sweeps the temp directory between launches.
    func writeToTmp(data: Data, filename: String) throws -> URL {
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        let url = attachmentDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
