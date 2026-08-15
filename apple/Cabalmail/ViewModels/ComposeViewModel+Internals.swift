import Foundation
import CabalmailKit

/// Attachment-list mutation, message-assembly, body conversion, recipient
/// parsing, and error-rendering helpers split out of `ComposeViewModel`
/// to keep the type body under the SwiftLint length ceiling. Everything
/// here is `@MainActor` by inheritance from the host class.
extension ComposeViewModel {
    // MARK: - Presentation

    /// Title for the compose surface (the sheet's navigation bar on iPhone,
    /// the window title elsewhere). "New Message" is a lie for every
    /// composer that opens populated: a resumed Drafts copy (whose send
    /// replaces that draft rather than adding a second one), and a reply /
    /// reply-all / forward, which come up with the recipient, a prefixed
    /// subject, and the quoted original already in place. Each says what it
    /// is instead; only a genuinely blank compose is a new message.
    ///
    /// The resumed draft wins over the intent: what the user reopened is a
    /// draft, whatever it was first composed as.
    var navigationTitle: String {
        if isResumedServerDraft { return "Draft" }
        switch composeIntent {
        case .reply:     return "Reply"
        case .replyAll:  return "Reply All"
        case .forward:   return "Forward"
        case .new:       return "New Message"
        }
    }

    // MARK: - Editor bridge health

    /// Banner copy for a dead editor bridge. One phrasing for both the
    /// compose-open announcement and the send refusal, so recovery can
    /// recognize (and clear) the message it put up.
    static func editorUnavailableMessage(_ reason: String) -> String {
        "The message editor didn't load (\(reason)). Nothing can be sent from this "
            + "window — copy anything you still need, close it, and compose again."
    }

    /// The bridge reported itself unusable. Raise the banner now, at
    /// compose-open, rather than leaving the user to discover it by
    /// pressing Send and watching nothing happen (#812).
    func noteEditorUnavailable(_ reason: String) {
        editorUnavailable = reason
        errorMessage = Self.editorUnavailableMessage(reason)
    }

    /// The bridge came up after all. Clears the banner, but only the one
    /// this failure raised — a send or address error reported since then is
    /// still the more useful message to leave on screen.
    func noteEditorRecovered() {
        guard let reason = editorUnavailable else { return }
        editorUnavailable = nil
        if errorMessage == Self.editorUnavailableMessage(reason) {
            errorMessage = nil
        }
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

    /// Seed the composer with the forwarded message's attachments. Called
    /// by `ComposeView` on appearance with the bytes the forward action
    /// stashed on `AppState` (see `MessageDetailView.beginCompose`). The
    /// seeded rows are ordinary `ComposeAttachment`s from here on — the
    /// user can remove them, and send stages them like hand-picked files.
    func seedForwardedAttachments(_ forwarded: [Attachment]) {
        for attachment in forwarded {
            addAttachment(
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                data: attachment.data
            )
        }
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
        await buildOutgoingMessage(from: from, bodies: computeMessageBodies())
    }

    /// Assembly over bodies the caller has already converted. `cancel()`
    /// needs the bodies before it knows whether it has a sender to build
    /// with, and each conversion is a WebKit round trip worth not repeating.
    func buildOutgoingMessage(
        from: EmailAddress,
        bodies: (text: String, html: String)
    ) -> OutgoingMessage {
        OutgoingMessage(
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
            serverUidValidity: serverDraftRef?.uidValidity,
            replySourceFolder: replySourceFolder,
            replySourceUid: replySourceUid
        )
        try? await draftStore.save(snapshot)
    }

    /// True when the compose buffer carries anything worth keeping — the
    /// shared emptiness check behind close-without-send and the server-save
    /// debounce. Takes the converted bodies rather than an assembled
    /// message so it can answer before a `From` address is in hand.
    func hasDraftContent(bodies: (text: String, html: String)) -> Bool {
        !subject.isEmpty
            || !bodies.text.isEmpty
            || !bodies.html.isEmpty
            || !parseRecipients(toText).isEmpty
            || !parseRecipients(ccText).isEmpty
            || !parseRecipients(bccText).isEmpty
            || !attachments.isEmpty
    }

    /// `/save_draft` leg of `cancel()`. Returns true when the window may
    /// close; false leaves it up with the failure on screen — the local
    /// copy is still on disk either way, so nothing is lost by retrying.
    func pushDraftToServer(_ message: OutgoingMessage) async -> Bool {
        do {
            serverSaveInFlight = true
            defer { serverSaveInFlight = false }
            if let ref = try await client.saveDraft(message, replacing: serverDraftRef) {
                adoptServerDraftRef(ref)
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

    /// Debounced server-side draft push (the `serverAutosaveInterval`
    /// loop). Quietly skips when there's nothing to save, no From to
    /// authorize against, a send is running, or another server save is in
    /// flight. Failures are silent on purpose: the 5-second local autosave
    /// is the durability story, and the next tick — or the always-pushed
    /// close-without-send — retries, which is the offline behavior the
    /// plan calls for without a second persistent queue.
    func autosaveToServer() async {
        guard !isSending, !serverSaveInFlight else { return }
        // Same reasoning as `cancel()`: with the bridge dead every body
        // converts to "", and a debounced push of that would overwrite the
        // server copy with an empty draft (#745).
        guard editorController.bridgeFailure == nil else { return }
        guard let fromEmail = currentFromEmail() else { return }
        let bodies = await computeMessageBodies()
        guard hasDraftContent(bodies: bodies) else { return }
        let message = buildOutgoingMessage(from: fromEmail, bodies: bodies)
        serverSaveInFlight = true
        defer { serverSaveInFlight = false }
        do {
            if let ref = try await client.saveDraft(message, replacing: serverDraftRef) {
                adoptServerDraftRef(ref)
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

    /// Every server-side Drafts UID a completed send has just superseded,
    /// oldest first, or empty when there's nothing for the Drafts list to
    /// prune. `/send` discards the current copy server-side as part of
    /// delivery, so the row the user is looking at is stale the moment this
    /// returns a value — the compose surface signals the list rather than
    /// leaving it to the next background reconcile a minute later.
    ///
    /// It reports the whole chain, not just the current ref, because each
    /// 60-second autosave replaces the copy with a *new* UID and nothing
    /// tells an already-loaded Drafts list about the swap. Naming only the
    /// survivor pruned a UID the list never had, leaving a phantom row for
    /// the pre-autosave copy that could still be opened and re-sent (#1071).
    ///
    /// A queued send keeps its draft on purpose (the outbox hasn't
    /// delivered anything yet, and the ref is dropped rather than
    /// discarded), so it reports nothing.
    var supersededDraftUIDs: [UInt32] {
        guard lastSendOutcome == .sent else { return [] }
        return replacedServerDraftUIDs + (serverDraftRef.map { [$0.uid] } ?? [])
    }

    /// Takes on the ref `/save_draft` just returned, remembering the UID it
    /// replaced. The old copy is expunged server-side by the replace, so
    /// its row in an open Drafts list is already a phantom (#1071).
    func adoptServerDraftRef(_ ref: DraftServerRef) {
        if let previous = serverDraftRef?.uid, previous != ref.uid {
            replacedServerDraftUIDs.append(previous)
        }
        serverDraftRef = ref
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
