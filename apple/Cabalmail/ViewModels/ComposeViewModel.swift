import Foundation
import Observation
import CabalmailKit

/// Backs `ComposeView`. Holds the editable `Draft`, the list of addresses
/// the From picker is seeded from, and attachment + error state; drives the
/// on-disk autosave loop and the send flow through `CabalmailClient`.
///
/// Body editing is dual-mode (rich text + Markdown), matching the React
/// composer. The canonical persisted form is Markdown — the rich editor is a
/// WebKit-backed surface owned by `editorController`, which also hosts the
/// marked + turndown libraries used for conversion. At send time the same
/// rules React applies decide which MIME part is empty and convert the other:
///
///   - both empty  -> both empty
///   - rich only   -> html = rich, text = turndown(rich)
///   - md only     -> text = md, html = styleParagraphs(marked(md))
///   - both filled -> send each as the author wrote it
///
/// Drafts persist locally via `DraftStore` (autosave every 5 s) and store the
/// Markdown source plus the user's editor-mode preference. Cross-device sync
/// layers on top: the buffer is pushed to the IMAP `Drafts` folder via
/// `/save_draft` on close-without-send and on a long debounce, with
/// `serverDraftRef` threading the replace chain so every device sees one
/// copy (see `docs/draft-sync-and-threading.md`).
@Observable
@MainActor
final class ComposeViewModel {
    /// Interval between local autosave flushes. Matches the plan.
    static let autosaveInterval: TimeInterval = 5

    /// Interval between server-side draft pushes while composing. Long on
    /// purpose — the 5 s local autosave is the crash-recovery story, and
    /// each server save costs a Lambda invocation plus EFS churn. Close-
    /// without-send always pushes, so this only bounds how stale another
    /// device's view of an *open* compose window can be.
    static let serverAutosaveInterval: TimeInterval = 60

    /// Soft-warn the user when total attachment payload exceeds this size.
    /// Many mail servers reject messages over ~25 MB, so anything above 20
    /// MB is worth flagging without hard-blocking the send. Mirrors the
    /// React composer's threshold.
    static let attachmentWarnBytes = 20 * 1024 * 1024

    /// Which compose editor pane the user is looking at. The Markdown pane
    /// is the canonical persistence surface; rich-text state lives only in
    /// the WebKit editor until send time.
    enum EditorMode: String, Codable, Sendable { case rich, markdown }

    let client: CabalmailClient
    private(set) var draftId: UUID
    let draftStore: DraftStore
    private let preferences: Preferences
    private let onClose: @MainActor () -> Void

    var fromAddress: String?
    var toText: String = ""
    var ccText: String = ""
    var bccText: String = ""
    var subject: String = ""
    /// Markdown source — survives autosave and persists across launches.
    var markdownBody: String = ""
    var editorMode: EditorMode = .rich
    var attachments: [ComposeAttachment] = []

    var availableAddresses: [Address] = []
    var isSending = false
    var errorMessage: String?
    /// Set to `.queued` when the most recent send dropped the message into
    /// the outbox instead of delivering it. `ComposeView` reads this to
    /// decide whether the dismiss toast should say "Sent" or "Queued — will
    /// send when back online." Reset whenever the user edits the form.
    var lastSendOutcome: SendOutcome?

    /// WebKit-backed rich-text editor + marked/turndown sandbox. Created
    /// eagerly so the user can start typing immediately, and reused for
    /// every conversion call so the bridge stays warm.
    let editorController: RichTextEditorController
    /// Latest selection snapshot from the rich editor; drives the toolbar's
    /// active states.
    var richSelection: RichTextEditorController.Selection = .init()

    /// Immutable compose-context bits; only set during init from a reply /
    /// forward / new-message seed, never mutated after. Access defaults to
    /// `internal` so `ComposeViewModel+Internals.swift` can read them.
    let inReplyTo: String?
    let references: [String]
    private let composeIntent: ComposeIntent

    /// Server-side Drafts copy the next save replaces (and a send
    /// discards). Seeded from the draft when resuming; updated after every
    /// successful `/save_draft` round trip.
    var serverDraftRef: DraftServerRef?
    /// Serializes server saves so the debounce loop and an in-progress
    /// close-without-send can't append racing copies.
    var serverSaveInFlight = false

    private var autosaveTask: Task<Void, Never>?
    private var serverAutosaveTask: Task<Void, Never>?
    /// When true, the rich editor and the markdown source are in sync — the
    /// user hasn't typed in the rich pane since the last seed/import. The
    /// send logic treats them as "rich is empty" so single-mode markdown
    /// composes don't double-up the text part.
    var richMirrorsMarkdown: Bool = true

    struct ComposeAttachment: Identifiable, Hashable {
        let id: UUID
        let filename: String
        let mimeType: String
        let data: Data

        var asKitAttachment: Attachment {
            Attachment(filename: filename, mimeType: mimeType, data: data)
        }
    }

    init(
        seed: Draft = Draft(),
        client: CabalmailClient,
        draftStore: DraftStore,
        preferences: Preferences,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.client = client
        self.draftId = seed.id
        self.draftStore = draftStore
        self.preferences = preferences
        self.onClose = onClose
        // Default From falls back to the user's preference *only* when the
        // seed didn't already pick one. Reply-builder's "From = original
        // addressee" behavior (Phase 5) therefore still wins over the
        // preferences default — the relationship-scoped-address idiom
        // requires replies to reuse the address the correspondent already
        // wrote to.
        self.fromAddress = seed.fromAddress ?? preferences.defaultFromAddress
        self.toText = seed.to.joined(separator: ", ")
        self.ccText = seed.cc.joined(separator: ", ")
        self.bccText = seed.bcc.joined(separator: ", ")
        self.subject = seed.subject
        self.inReplyTo = seed.inReplyTo
        self.references = seed.references
        self.composeIntent = seed.composeIntent ?? .new
        self.serverDraftRef = seed.serverRef
        // Append the preference signature to the seeded body, but only once.
        // Replies / forwards seed with an attribution + quoted body; the
        // signature goes *above* that block so the user's reply text lands
        // with the signature on the line above the quoted original (the
        // same shape every UNIX mail client has produced since Pine).
        self.markdownBody = SignatureFormatter.seedBody(
            base: seed.body,
            signature: preferences.signature
        )
        self.editorController = RichTextEditorController(placeholder: "Compose your message…")
        self.editorMode = .rich
        self.editorController.onSelectionChanged = { [weak self] selection in
            self?.richSelection = selection
        }
        // The user's first character mutates rich-only state; the mirror
        // flag flips and the send logic stops treating the rich pane as a
        // pure echo of the markdown source.
        self.editorController.onContentChanged = { [weak self] in
            self?.richMirrorsMarkdown = false
        }
    }

    /// Cancel the autosave loops. Called from the view's `onDisappear` and
    /// from every flow that dismisses the sheet (`send`, `cancel`, `discard`)
    /// so the background `Task`s always wind down deterministically.
    /// Swift 5.10 strict concurrency makes `deinit` nonisolated, so we can't
    /// just cancel from there — view-level lifecycle is the right hook.
    func stop() {
        autosaveTask?.cancel()
        autosaveTask = nil
        serverAutosaveTask?.cancel()
        serverAutosaveTask = nil
    }

    func start() async {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autosaveInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.persistCurrentDraft()
            }
        }
        serverAutosaveTask?.cancel()
        serverAutosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.serverAutosaveInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.autosaveToServer()
            }
        }
        await seedRichFromMarkdown()
        await refreshAddresses()
    }

    func refreshAddresses(forceRefresh: Bool = false) async {
        do {
            availableAddresses = try await client.addresses(forceRefresh: forceRefresh)
        } catch {
            errorMessage = "Couldn't load addresses: \(error)"
        }
    }

    /// Called after the user creates a new address from the inline "Create
    /// new address…" sheet. Invalidates the address cache, refreshes the
    /// picker, and selects the new address as From.
    func onAddressCreated(_ address: String) async {
        await refreshAddresses(forceRefresh: true)
        fromAddress = address
    }

    /// Reply / reply-all focus the body; forward / new focus the To field.
    /// Driven by the explicit `composeIntent` rather than `inReplyTo`: a
    /// resumed or persisted draft can carry threading headers without
    /// being a freshly-seeded reply.
    var shouldFocusBodyOnAppear: Bool {
        composeIntent == .reply || composeIntent == .replyAll
    }

    /// Is the form complete enough to enable the Send button?
    var canSend: Bool {
        guard fromAddress != nil, !subject.isEmpty else { return false }
        return !parseRecipients(toText).isEmpty
            || !parseRecipients(ccText).isEmpty
            || !parseRecipients(bccText).isEmpty
    }

    /// Sum of the attached file sizes in bytes. Drives the soft-warn banner.
    var attachmentTotalBytes: Int {
        attachments.reduce(0) { $0 + $1.data.count }
    }

    /// True when the total attachment payload is over the soft-warn threshold.
    var attachmentTotalExceedsWarning: Bool {
        attachmentTotalBytes > Self.attachmentWarnBytes
    }

    // MARK: - Editor mode + cross-pane imports

    /// Convert the current Markdown source into HTML (via marked +
    /// flattenParagraphs) and load it into the rich editor, then switch the
    /// active pane to rich. Mirrors the React composer's "Import from
    /// Markdown" toolbar button.
    func importFromMarkdown() async {
        let html = await editorController.markdownToHtml(markdownBody)
        await editorController.setHTML(html)
        richMirrorsMarkdown = false
        editorMode = .rich
    }

    /// Convert the rich editor's current HTML back to Markdown (via
    /// turndown's React-tuned rules) and load it into the markdown buffer,
    /// then switch the active pane to markdown. Mirrors the React
    /// composer's "Import from Rich Text" button.
    func importFromRichText() async {
        let html = await editorController.getHTML()
        let markdown = await editorController.htmlToMarkdown(html)
        markdownBody = markdown
        richMirrorsMarkdown = true
        editorMode = .markdown
    }

    /// Loads the (current) markdown body into the rich editor as HTML, so
    /// new sessions and reopened drafts start with the rich pane already
    /// populated. The mirror flag stays `true` until the user types — at
    /// which point send-time treats rich + markdown as independent surfaces.
    private func seedRichFromMarkdown() async {
        let html: String
        if markdownBody.isEmpty {
            html = ""
        } else {
            html = await editorController.markdownToHtml(markdownBody)
        }
        // Reply / reply-all seeds want two blank lines above the `<hr>`
        // marker; marked collapses leading whitespace, so prepend two
        // single-`<br>` paragraphs to the rendered HTML to recover the
        // visual spacing when the rich pane opens for editing.
        let seeded = shouldFocusBodyOnAppear
            ? "<p><br></p><p><br></p>" + html
            : html
        await editorController.setHTML(seeded)
        richMirrorsMarkdown = true
    }

    func send() async -> Bool {
        guard canSend, let fromEmail = currentFromEmail() else {
            if fromAddress != nil { errorMessage = "Invalid From address." }
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            let message = await buildOutgoingMessage(from: fromEmail)
            // Send-from-draft cleans up the server copy after delivery
            // (best-effort, server-side). A queued send drops the ref; the
            // stale copy survives, which beats discarding a draft for a
            // message that hasn't actually left yet.
            let outcome = try await client.send(message, discardingDraft: serverDraftRef)
            lastSendOutcome = outcome
            // Whether the message left the device or got queued, the draft
            // is no longer authoritative — the outbox owns it from here.
            try? await draftStore.remove(id: draftId)
            stop()
            onClose()
            return true
        } catch let error as CabalmailError {
            errorMessage = describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    /// Cancel button (or the macOS close-button intercept) — flushes one
    /// last autosave, pushes the draft to IMAP `Drafts` (replacing the copy
    /// a previous save produced) so it shows up on every device, and
    /// dismisses. Returns true when the window can close; false when the
    /// push surfaced a hard error and the user should see the banner before
    /// the window goes away — the local copy is still on disk either way,
    /// so nothing is lost by retrying or by force-closing.
    ///
    /// Empty drafts and drafts without a valid `From` address fall back to
    /// the local-only autosave: empty composes leave nothing behind (any
    /// stale server copy is discarded), and a half-finished compose without
    /// a sender selected can't be saved server-side (no envelope to
    /// authorize against). `DraftStore.save` silently removes empty drafts
    /// so a user who opens Compose and closes immediately leaves no
    /// breadcrumb.
    @discardableResult
    func cancel() async -> Bool {
        await persistCurrentDraft()
        guard let fromEmail = currentFromEmail() else {
            stop()
            onClose()
            return true
        }
        let message = await buildOutgoingMessage(from: fromEmail)
        guard hasDraftContent(message) else {
            if let ref = serverDraftRef {
                _ = try? await client.discardDraft(ref)
            }
            try? await draftStore.remove(id: draftId)
            stop()
            onClose()
            return true
        }
        do {
            serverSaveInFlight = true
            defer { serverSaveInFlight = false }
            if let ref = try await client.saveDraft(message, replacing: serverDraftRef) {
                serverDraftRef = ref
            }
            try? await draftStore.remove(id: draftId)
            stop()
            onClose()
            return true
        } catch let error as CabalmailError {
            errorMessage = "Couldn't save draft: \(describe(error))"
        } catch {
            errorMessage = "Couldn't save draft: \(error.localizedDescription)"
        }
        return false
    }

    /// Delete the draft entirely (user confirmed "Discard draft") and
    /// dismiss. Also removes the server-side copy when one is recorded —
    /// discarding on one device should discard everywhere.
    func discard() async {
        try? await draftStore.remove(id: draftId)
        if let ref = serverDraftRef {
            _ = try? await client.discardDraft(ref)
        }
        stop()
        onClose()
    }

    // Attachment helpers, recipient parsing, message-body assembly, and
    // error rendering live in `ComposeViewModel+Internals.swift` to keep
    // this type body under the SwiftLint length ceiling.
}
