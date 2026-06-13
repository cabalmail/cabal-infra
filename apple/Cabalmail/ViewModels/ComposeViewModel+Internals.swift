import Foundation
import CabalmailKit

/// Attachment-list mutation, message-assembly, body conversion, recipient
/// parsing, and error-rendering helpers split out of `ComposeViewModel`
/// to keep the type body under the SwiftLint length ceiling. Everything
/// here is `@MainActor` by inheritance from the host class.
extension ComposeViewModel {
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

    /// Resolves the current `fromAddress` string into a parsed
    /// `EmailAddress`, or nil when nothing is selected / the value isn't
    /// parseable. Used by both the send and save-draft paths.
    func currentFromEmail() -> EmailAddress? {
        guard let fromAddress else { return nil }
        return EmailAddress(parsing: fromAddress)
    }

    /// Assembles the `OutgoingMessage` from the current compose state.
    /// Shared by `send()` and `cancel()` (Save Draft) so both flows ship
    /// an identical message to `/send`.
    func buildOutgoingMessage(from: EmailAddress) async -> OutgoingMessage {
        let bodies = await computeMessageBodies()
        return OutgoingMessage(
            from: from,
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
    }

    /// Resolves the (text, html) MIME-part bodies using the same four-way
    /// table the React composer applies. The mirror flag treats a rich
    /// pane that's only ever been seeded from markdown as "empty," so a
    /// pure-markdown compose doesn't ship the seed HTML as if the user
    /// had hand-edited it.
    func computeMessageBodies() async -> (text: String, html: String) {
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

    func persistCurrentDraft() async {
        let snapshot = Draft(
            id: draftId,
            fromAddress: fromAddress,
            to: parseRecipients(toText).map(formatAddress),
            cc: parseRecipients(ccText).map(formatAddress),
            bcc: parseRecipients(bccText).map(formatAddress),
            subject: subject,
            body: markdownBody,
            inReplyTo: inReplyTo,
            references: references,
            serverUid: serverDraftRef?.uid,
            serverUidValidity: serverDraftRef?.uidValidity
        )
        try? await draftStore.save(snapshot)
    }

    /// True when the assembled message carries anything worth keeping —
    /// the shared emptiness check behind close-without-send and the
    /// server-save debounce.
    func hasDraftContent(_ message: OutgoingMessage) -> Bool {
        !subject.isEmpty
            || !(message.textBody?.isEmpty ?? true)
            || !(message.htmlBody?.isEmpty ?? true)
            || !message.to.isEmpty
            || !message.cc.isEmpty
            || !message.bcc.isEmpty
            || !message.attachments.isEmpty
    }

    /// Debounced server-side draft push (the `serverAutosaveInterval`
    /// loop). Quietly skips when there's nothing to save, no From to
    /// authorize against, a send is running, or another server save is in
    /// flight. Failures are silent on purpose: the 5-second local autosave
    /// is the durability story, and the next tick — or the always-pushed
    /// close-without-send — retries, which is the offline behavior the
    /// plan calls for without a second persistent queue.
    func autosaveToServer() async {
        guard !isSending, !serverSaveInFlight else { return }
        guard let fromEmail = currentFromEmail() else { return }
        let message = await buildOutgoingMessage(from: fromEmail)
        guard hasDraftContent(message) else { return }
        serverSaveInFlight = true
        defer { serverSaveInFlight = false }
        do {
            if let ref = try await client.saveDraft(message, replacing: serverDraftRef) {
                serverDraftRef = ref
            }
        } catch {
            // Swallowed: see the doc comment. A failed replace server-side
            // already degrades to save-as-new, so the worst outcome here is
            // a duplicate draft copy, never a lost one.
        }
    }

    /// Parses a comma/semicolon-separated list of addresses into
    /// `EmailAddress` values. Matches the React compose's permissive
    /// tokenization (comma, semicolon, or space). Invalid tokens are
    /// dropped silently — the UI flags them separately via `canSend`.
    func parseRecipients(_ raw: String) -> [EmailAddress] {
        let separators: Set<Character> = [",", ";", "\n"]
        let tokens = raw
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return tokens.compactMap(EmailAddress.init(parsing:))
    }

    func formatAddress(_ address: EmailAddress) -> String {
        "\(address.mailbox)@\(address.host)"
    }

    func describe(_ error: CabalmailError) -> String {
        switch error {
        case .invalidCredentials: return "Send failed: your credentials were rejected."
        case .network(let detail): return "Network error: \(detail)"
        case .smtpCommandFailed(_, let detail): return "SMTP error: \(detail)"
        case .authExpired: return "Your session expired; please sign in again."
        case .maintenance(let message): return message
        default: return "Send failed: \(error)"
        }
    }
}
