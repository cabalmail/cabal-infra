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
/// Markdown source plus the user's editor-mode preference. Cross-device IMAP
/// `Drafts` sync is Phase 5.1.
@Observable
@MainActor
final class ComposeViewModel {
    /// Interval between autosave flushes. Matches the plan.
    static let autosaveInterval: TimeInterval = 5

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
    private let draftStore: DraftStore
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
    /// forward / new-message seed, never mutated after.
    private let inReplyTo: String?
    private let references: [String]

    private var autosaveTask: Task<Void, Never>?
    /// When true, the rich editor and the markdown source are in sync — the
    /// user hasn't typed in the rich pane since the last seed/import. The
    /// send logic treats them as "rich is empty" so single-mode markdown
    /// composes don't double-up the text part.
    private var richMirrorsMarkdown: Bool = true

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

    /// Cancel the autosave loop. Called from the view's `onDisappear` and
    /// from every flow that dismisses the sheet (`send`, `cancel`, `discard`)
    /// so the background `Task` always winds down deterministically.
    /// Swift 5.10 strict concurrency makes `deinit` nonisolated, so we can't
    /// just cancel from there — view-level lifecycle is the right hook.
    func stop() {
        autosaveTask?.cancel()
        autosaveTask = nil
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

    /// On reply / reply-all the user wants the cursor in the body above the
    /// seeded separator so they can start typing immediately. Forward and
    /// new-message seeds focus the To field instead. `inReplyTo` is set by
    /// `ReplyBuilder` only on reply paths, so it's a sufficient signal.
    var shouldFocusBodyOnAppear: Bool {
        inReplyTo != nil
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
        // Reply / reply-all seeds start with two blank lines above the
        // horizontal rule in the Markdown source, but marked collapses
        // leading whitespace so the rendered HTML sits the `<hr>` flush
        // against the top of the editor. Prepend two single-`<br>`
        // paragraphs to recover the visual spacing the user expects
        // when the rich pane opens for editing.
        let seeded = shouldFocusBodyOnAppear
            ? "<p><br></p><p><br></p>" + html
            : html
        await editorController.setHTML(seeded)
        richMirrorsMarkdown = true
    }

    func send() async -> Bool {
        guard canSend, let fromAddress else { return false }
        isSending = true
        defer { isSending = false }
        do {
            guard let fromEmail = EmailAddress(parsing: fromAddress) else {
                errorMessage = "Invalid From address."
                return false
            }

            let bodies = await computeMessageBodies()
            let message = OutgoingMessage(
                from: fromEmail,
                to: parseRecipients(toText),
                cc: parseRecipients(ccText),
                bcc: parseRecipients(bccText),
                subject: subject,
                textBody: bodies.text,
                htmlBody: bodies.html,
                inReplyTo: inReplyTo,
                references: references,
                attachments: attachments.map(\.asKitAttachment)
            )
            let outcome = try await client.send(message)
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

    /// Cancel button — flushes one last autosave (so the draft survives
    /// re-open) and dismisses. Empty drafts are removed by `DraftStore.save`.
    func cancel() async {
        await persistCurrentDraft()
        stop()
        onClose()
    }

    /// Delete the draft entirely (user confirmed "Discard draft") and
    /// dismiss.
    func discard() async {
        try? await draftStore.remove(id: draftId)
        stop()
        onClose()
    }

    // MARK: - Attachments

    /// Add an already-loaded file (raw bytes + mime type) as an attachment.
    /// Returns the id of the newly-added attachment.
    @discardableResult
    func addAttachment(filename: String, mimeType: String, data: Data) -> UUID {
        let attachment = ComposeAttachment(
            id: UUID(),
            filename: filename,
            mimeType: mimeType,
            data: data
        )
        attachments.append(attachment)
        return attachment.id
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - Internals

    /// Resolves the (text, html) MIME-part bodies using the same four-way
    /// table the React composer applies. The mirror flag treats a rich
    /// pane that's only ever been seeded from markdown as "empty," so a
    /// pure-markdown compose doesn't ship the seed HTML as if the user
    /// had hand-edited it.
    private func computeMessageBodies() async -> (text: String, html: String) {
        let richHtml = await editorController.getHTML()
        let richEmpty = richHtml.isEmpty || richMirrorsMarkdown
        let mdEmpty = markdownBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        switch (richEmpty, mdEmpty) {
        case (true, true):
            return ("", "")
        case (false, true):
            let text = await editorController.htmlToMarkdown(richHtml)
            return (text, richHtml)
        case (true, false):
            let raw = await editorController.markdownToHtml(markdownBody)
            let styled = await editorController.styleParagraphs(raw)
            return (markdownBody, styled)
        case (false, false):
            return (markdownBody, richHtml)
        }
    }

    private func persistCurrentDraft() async {
        let snapshot = Draft(
            id: draftId,
            fromAddress: fromAddress,
            to: parseRecipients(toText).map(formatAddress),
            cc: parseRecipients(ccText).map(formatAddress),
            bcc: parseRecipients(bccText).map(formatAddress),
            subject: subject,
            body: markdownBody,
            inReplyTo: inReplyTo,
            references: references
        )
        try? await draftStore.save(snapshot)
    }

    /// Parses a comma/semicolon-separated list of addresses into
    /// `EmailAddress` values. Matches the React compose's permissive
    /// tokenization (comma, semicolon, or space). Invalid tokens are
    /// dropped silently — the UI flags them separately via `canSend`.
    private func parseRecipients(_ raw: String) -> [EmailAddress] {
        let separators: Set<Character> = [",", ";", "\n"]
        let tokens = raw
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return tokens.compactMap(EmailAddress.init(parsing:))
    }

    private func formatAddress(_ address: EmailAddress) -> String {
        "\(address.mailbox)@\(address.host)"
    }

    private func describe(_ error: CabalmailError) -> String {
        switch error {
        case .invalidCredentials: return "Send failed: your credentials were rejected."
        case .network(let detail): return "Network error: \(detail)"
        case .smtpCommandFailed(_, let detail): return "SMTP error: \(detail)"
        case .authExpired: return "Your session expired; please sign in again."
        default: return "Send failed: \(error)"
        }
    }
}
