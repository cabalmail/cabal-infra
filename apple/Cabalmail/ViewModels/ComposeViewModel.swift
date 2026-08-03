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
    /// Dismisses the compose surface (sheet on iPhone, window elsewhere).
    /// Internal rather than private so the close-without-send legs in
    /// `ComposeViewModel+Internals.swift` can reach it.
    let onClose: @MainActor () -> Void

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
    /// Non-nil while the WebKit editor bridge is known to be unusable,
    /// mirroring `RichTextEditorController.bridgeFailure` — the controller
    /// is a plain `NSObject`, so SwiftUI can't observe its state directly.
    /// Every body conversion answers `""` from that point on, so nothing can
    /// be sent: this keeps Send disabled and the banner up (#812). Mutated
    /// only by the `noteEditorUnavailable` / `noteEditorRecovered` pair in
    /// `ComposeViewModel+Internals.swift`, which a `private(set)` here
    /// would put out of reach.
    var editorUnavailable: String?
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

    /// True when `fromAddress` was pre-filled from the default-From
    /// preference rather than the seed. `refreshAddresses` uses this to
    /// drop a pre-fill the account can't actually send from (a revoked or
    /// leaked-in default) without touching a reply seed's deliberate
    /// "From = original addressee" choice.
    private let fromSeededFromPreference: Bool

    /// Immutable compose-context bits; only set during init from a reply /
    /// forward / new-message seed, never mutated after. Access defaults to
    /// `internal` so `ComposeViewModel+Internals.swift` can read them.
    let inReplyTo: String?
    let references: [String]
    let composeIntent: ComposeIntent

    /// Server-side Drafts copy the next save replaces (and a send
    /// discards). Seeded from the draft when resuming; updated after every
    /// successful `/save_draft` round trip.
    var serverDraftRef: DraftServerRef?
    /// Whether this surface opened on a draft that already exists in the
    /// server Drafts folder (Edit Draft), rather than on a new message, reply
    /// or forward. Captured at init rather than read off `serverDraftRef`,
    /// which also becomes non-nil once a fresh compose autosaves: the title
    /// describes what the user opened, not what has since been saved.
    let isResumedServerDraft: Bool
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
        self.fromSeededFromPreference = seed.fromAddress == nil && preferences.defaultFromAddress != nil
        self.toText = seed.to.joined(separator: ", ")
        self.ccText = seed.cc.joined(separator: ", ")
        self.bccText = seed.bcc.joined(separator: ", ")
        self.subject = seed.subject
        self.inReplyTo = seed.inReplyTo
        self.references = seed.references
        self.composeIntent = seed.composeIntent ?? .new
        self.serverDraftRef = seed.serverRef
        self.isResumedServerDraft = seed.serverRef != nil
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
        // A bridge that dies while bootstrapping never posts `ready`, so
        // the rich pane (and send-time conversion) is out of commission
        // for this compose. Say so instead of failing silently (#734).
        self.editorController.onBridgeError = { [weak self] message in
            self?.noteEditorUnavailable(message)
        }
        // A `ready` that lands after the failure means the boot was merely
        // slow; the controller has already cleared its own failure, so drop
        // the banner and re-enable Send rather than stranding the compose.
        self.editorController.onReady = { [weak self] in
            self?.noteEditorRecovered()
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
        // Load the address list concurrently with the editor seed rather
        // than after it. The seed blocks on the WebKit bridge bootstrap,
        // and a bridge that never comes up (broken editor-bridge.js, a
        // killed content process) would otherwise park `start()` before
        // the address load, leaving the From picker permanently empty and
        // compose unusable (#734).
        async let addressLoad: Void = refreshAddresses()
        await seedRichFromMarkdown()
        await addressLoad
    }

    func refreshAddresses(forceRefresh: Bool = false) async {
        do {
            availableAddresses = try await client.addresses(forceRefresh: forceRefresh)
        } catch {
            errorMessage = "Couldn't load addresses: \(error)"
            return
        }
        // The preference-seeded pre-fill is only trustworthy once the real
        // address list confirms it. A default that isn't in the list — a
        // revoked address, or one leaked in from another account before
        // preferences were account-scoped — must not sit in the From field
        // of a message the user is about to send. Reconciling the
        // preference also pushes the cleared value to the server, healing
        // the synced copy that keeps re-applying it at sign-in.
        preferences.reconcileDefaultFromAddress(available: availableAddresses.map(\.address))
        if fromSeededFromPreference, let current = fromAddress, !availableAddresses.isEmpty,
           !availableAddresses.contains(where: { $0.address == current }) {
            fromAddress = nil
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

    /// Is the form complete enough to enable the Send button? A dead editor
    /// bridge disables it too: the body can't be assembled, so the send
    /// would only be refused (#745) — better not to offer the tap (#812).
    var canSend: Bool {
        guard editorUnavailable == nil else { return false }
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
        // Checked ahead of `canSend` so a tap that races the bridge dying
        // gets the real reason instead of the generic form complaint —
        // silence here is what made a dead bridge look like a dead button.
        if let reason = editorUnavailable {
            errorMessage = Self.editorUnavailableMessage(reason)
            return false
        }
        guard canSend, let fromEmail = currentFromEmail() else {
            if fromAddress != nil { errorMessage = "Invalid From address." }
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            let message = await buildOutgoingMessage(from: fromEmail)
            // Body assembly runs through the WebKit bridge, which answers
            // "" for every conversion once it is dead. Sending that would
            // deliver an empty message the user had written text into, so
            // refuse and leave the window open (#745).
            if let failure = editorController.bridgeFailure {
                noteEditorUnavailable(failure)
                return false
            }
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
    /// Empty drafts leave nothing behind (any stale server copy is
    /// discarded); `DraftStore.save` silently removes them, so a user who
    /// opens Compose and closes immediately leaves no breadcrumb. A draft
    /// that *has* content but no valid `From` can't be pushed at all —
    /// `/save_draft` has no envelope to authorize against — so it keeps the
    /// composer up and says why rather than closing as if it had saved,
    /// which is how a filled-in message used to vanish (#903).
    ///
    /// `ComposeCancelPolicy` owns the order those cases are considered in.
    @discardableResult
    func cancel() async -> Bool {
        await persistCurrentDraft()
        let fromEmail = currentFromEmail()
        // Bodies first: converting them is what makes a sick bridge report
        // itself, so `bridgeFailure` is only trustworthy afterwards (#745).
        let bodies = await computeMessageBodies()
        switch ComposeCancelPolicy.resolve(
            bridgeFailed: editorController.bridgeFailure != nil,
            hasContent: hasDraftContent(bodies: bodies),
            hasFrom: fromEmail != nil
        ) {
        case .closeKeepingLocalCopy:
            // Pushing an all-empty body would replace a good Drafts copy
            // with a blank one, so keep the local draft (already flushed
            // above) and let the window close — trapping the user in a
            // compose they can't fix is worse.
            stop()
            onClose()
            return true
        case .discardEmpty:
            if let ref = serverDraftRef {
                _ = try? await client.discardDraft(ref)
            }
            try? await draftStore.remove(id: draftId)
            stop()
            onClose()
            return true
        case .refuseMissingFrom:
            errorMessage = ComposeCancelPolicy.missingFromMessage
            return false
        case .saveToServer:
            guard let fromEmail else { return false }
            return await pushDraftToServer(buildOutgoingMessage(from: fromEmail, bodies: bodies))
        }
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
