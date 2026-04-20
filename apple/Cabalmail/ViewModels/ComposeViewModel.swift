import Foundation
import Observation
import CabalmailKit

/// Backs `ComposeView`. Holds the editable `Draft`, the list of addresses
/// the From picker is seeded from, and attachment + error state; drives the
/// on-disk autosave loop and the send flow through `CabalmailClient`.
///
/// Phase 5 scope:
/// - Body is plain text — rich-text editor is Phase 5.1 (see `apple/README.md`).
/// - Drafts persist locally via `DraftStore` (autosave every 5 s).
///   Cross-device IMAP `Drafts` sync is Phase 5.1.
/// - Sending uses `CabalmailClient.send(_:)`, which performs the SMTP
///   submission and then best-effort `APPEND`s to the Sent folder.
@Observable
@MainActor
final class ComposeViewModel {
    /// Interval between autosave flushes. Matches the plan.
    static let autosaveInterval: TimeInterval = 5

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
    var body: String = ""
    var attachments: [ComposeAttachment] = []

    var availableAddresses: [Address] = []
    var isSending = false
    var errorMessage: String?
    /// Set to `.queued` when the most recent send dropped the message into
    /// the outbox instead of delivering it. `ComposeView` reads this to
    /// decide whether the dismiss toast should say "Sent" or "Queued — will
    /// send when back online." Reset whenever the user edits the form.
    var lastSendOutcome: SendOutcome?

    /// Immutable compose-context bits; only set during init from a reply /
    /// forward / new-message seed, never mutated after.
    private let inReplyTo: String?
    private let references: [String]

    private var autosaveTask: Task<Void, Never>?

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
        self.body = SignatureFormatter.seedBody(
            base: seed.body,
            signature: preferences.signature
        )
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

    /// Is the form complete enough to enable the Send button?
    var canSend: Bool {
        guard fromAddress != nil, !subject.isEmpty else { return false }
        return !parseRecipients(toText).isEmpty
            || !parseRecipients(ccText).isEmpty
            || !parseRecipients(bccText).isEmpty
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
            let message = OutgoingMessage(
                from: fromEmail,
                to: parseRecipients(toText),
                cc: parseRecipients(ccText),
                bcc: parseRecipients(bccText),
                subject: subject,
                textBody: body,
                htmlBody: nil,
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

    private func persistCurrentDraft() async {
        let snapshot = Draft(
            id: draftId,
            fromAddress: fromAddress,
            to: parseRecipients(toText).map(formatAddress),
            cc: parseRecipients(ccText).map(formatAddress),
            bcc: parseRecipients(bccText).map(formatAddress),
            subject: subject,
            body: body,
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

// MARK: - EmailAddress parsing

extension EmailAddress {
    /// Lenient `user@host` parser. No display-name support; the Phase 5
    /// compose view only needs the raw address form — display names are a
    /// Phase 5.1 enhancement alongside contact autocomplete.
    init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let atIndex = trimmed.firstIndex(of: "@") else { return nil }
        let mailbox = String(trimmed[..<atIndex])
        let host = String(trimmed[trimmed.index(after: atIndex)...])
        guard !mailbox.isEmpty, !host.isEmpty, host.contains(".") else { return nil }
        self.init(name: nil, mailbox: mailbox, host: host)
    }
}
