import Foundation

/// Pure value-type helper that seeds a `Draft` from an incoming `Envelope`
/// and (optionally) the decoded plain-text body of the original message.
///
/// Covers the three compose entry points from the message detail view —
/// `reply`, `replyAll`, `forward` — plus an explicit `newDraft()` factory
/// for the blank compose case. Intentionally has no dependency on `Cabalmail`
/// app state: `ComposeViewModel` feeds it envelopes and address lists, and
/// it returns a fully-populated `Draft` the view model can persist.
///
/// ### On-the-fly From
///
/// Per `docs/README.md`, every Cabalmail outgoing message is expected to
/// originate from a subdomain-scoped address the user minted *for this
/// correspondent specifically*. The reply paths therefore default `From` to
/// **the address the original message was sent to** — so a reply naturally
/// reuses the same relationship-scoped address rather than forcing the user
/// to pick one. If none of the original recipients match an address the user
/// owns, From is left unset and the UI falls through to the "Create new
/// address…" flow. Matches the React app's 0.3.0 semantics (see
/// `react/admin/src/Email/Messages/`).
public enum ReplyBuilder {
    public enum ReplyMode: Sendable, Hashable {
        case reply
        case replyAll
        case forward
    }

    /// Builds a reply `Draft`.
    ///
    /// - Parameters:
    ///   - envelope: The message being replied to. `to` / `cc` / `from` /
    ///     `subject` / `messageId` / `inReplyTo` are all read.
    ///   - body: The original message's rendered plain-text body, or nil
    ///     if the renderer hasn't produced one (HTML-only messages). Used
    ///     for the quoted-text block; reply headers still thread regardless.
    ///   - mode: `reply`, `replyAll`, or `forward`.
    ///   - userAddresses: The signed-in user's owned addresses, used both
    ///     to pick the default From and (for reply-all) to drop the user
    ///     from the recipient list.
    ///   - now: Clock hook for deterministic tests. Production passes
    ///     `Date.init`.
    public static func build(
        from envelope: Envelope,
        body: String?,
        mode: ReplyMode,
        userAddresses: [Address],
        now: () -> Date = Date.init
    ) -> Draft {
        let ownedAddressStrings = Set(userAddresses.map { $0.address.lowercased() })
        let defaultFrom = pickDefaultFrom(from: envelope, owned: ownedAddressStrings)

        let subject = prefixedSubject(envelope.subject ?? "", mode: mode)

        let (toList, ccList): ([EmailAddress], [EmailAddress]) = {
            switch mode {
            case .reply:
                // Reply goes to the author. Reply-To overrides From when
                // present, per RFC 5322 §3.6.2.
                let primary = envelope.replyTo.isEmpty ? envelope.from : envelope.replyTo
                return (primary, [])
            case .replyAll:
                let primary = envelope.replyTo.isEmpty ? envelope.from : envelope.replyTo
                let extras = envelope.to + envelope.cc
                let recipients = deduped(primary + extras, excluding: ownedAddressStrings)
                return (Array(recipients.prefix(1)), Array(recipients.dropFirst()))
            case .forward:
                return ([], [])
            }
        }()

        let quoted = mode == .forward
            ? forwardQuote(body: body, envelope: envelope)
            : replyQuote(body: body, envelope: envelope, now: now())

        let threading = threadingHeaders(from: envelope, mode: mode)

        return Draft(
            updatedAt: now(),
            fromAddress: defaultFrom,
            to: toList.map(formatAddressForDraft),
            cc: ccList.map(formatAddressForDraft),
            bcc: [],
            subject: subject,
            body: quoted,
            inReplyTo: threading.inReplyTo,
            references: threading.references
        )
    }

    /// Factory for the new-message case. Returns an empty draft (no From,
    /// no recipients, no subject, no body) so the compose sheet renders its
    /// "Create new address…" flow as the primary affordance.
    public static func newDraft() -> Draft {
        Draft()
    }

    // MARK: - Subject

    /// Reply / forward prefix, idempotent — "Re: Re: foo" collapses to
    /// "Re: foo" (and similarly for "Fwd: "). Matches the React app's
    /// `Re:`/`Fwd:` behavior and what every mainstream client does.
    public static func prefixedSubject(_ raw: String, mode: ReplyMode) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let prefix: String
        switch mode {
        case .reply, .replyAll: prefix = "Re: "
        case .forward:          prefix = "Fwd: "
        }
        if hasReplyLikePrefix(trimmed, expected: prefix) { return trimmed }
        return prefix + trimmed
    }

    private static func hasReplyLikePrefix(_ subject: String, expected: String) -> Bool {
        let lower = subject.lowercased()
        let expectedLower = expected.lowercased()
        return lower.hasPrefix(expectedLower)
    }

    // MARK: - From selection

    /// Picks the owned address matching any recipient of the original, or
    /// nil if none match. Walks To then Cc then Bcc so the "primary" slot
    /// wins when multiple of the user's addresses were recipients.
    private static func pickDefaultFrom(
        from envelope: Envelope,
        owned: Set<String>
    ) -> String? {
        let ordered = envelope.to + envelope.cc + envelope.bcc
        for address in ordered {
            let candidate = "\(address.mailbox)@\(address.host)".lowercased()
            if owned.contains(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Recipient list

    /// Deduplicates an address list and drops anything owned by the signed-in
    /// user, preserving the first-seen order.
    private static func deduped(
        _ list: [EmailAddress],
        excluding owned: Set<String>
    ) -> [EmailAddress] {
        var seen: Set<String> = []
        var result: [EmailAddress] = []
        for address in list {
            let key = "\(address.mailbox)@\(address.host)".lowercased()
            if owned.contains(key) { continue }
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(address)
        }
        return result
    }

    private static func formatAddressForDraft(_ address: EmailAddress) -> String {
        "\(address.mailbox)@\(address.host)"
    }

    // MARK: - Quoting

    /// Reply-style attribution + prefixed-with-`> ` original body. Matches
    /// the `On <date>, <sender> wrote:` convention every UNIX mail client
    /// since at least Elm uses, because downstream mail clients unindent
    /// quoted blocks by the same marker.
    private static func replyQuote(body: String?, envelope: Envelope, now: Date) -> String {
        guard let body, !body.isEmpty else { return "" }
        let attribution = attributionLine(envelope: envelope)
        let quoted = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\n\n\(attribution)\n\(quoted)"
    }

    /// Forward wraps the original in a banner block rather than prefix-
    /// quoting it — the intent is "here's this other message" not "I am
    /// replying to this."
    private static func forwardQuote(body: String?, envelope: Envelope) -> String {
        var header = "---------- Forwarded message ----------\n"
        if let from = envelope.from.first { header += "From: \(from.formatted)\n" }
        if let subject = envelope.subject { header += "Subject: \(subject)\n" }
        if let date = envelope.date ?? envelope.internalDate {
            header += "Date: \(rfc5322Date(date))\n"
        }
        if !envelope.to.isEmpty {
            header += "To: \(envelope.to.map(\.formatted).joined(separator: ", "))\n"
        }
        header += "\n"
        header += body ?? ""
        return "\n\n" + header
    }

    private static func attributionLine(envelope: Envelope) -> String {
        let sender = envelope.from.first?.name
            ?? envelope.from.first.map { "\($0.mailbox)@\($0.host)" }
            ?? "someone"
        guard let date = envelope.date ?? envelope.internalDate else {
            return "\(sender) wrote:"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return "On \(formatter.string(from: date)), \(sender) wrote:"
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: - Threading

    private struct Threading {
        let inReplyTo: String?
        let references: [String]
    }

    /// Builds RFC 5322 §3.6.4 threading headers. `In-Reply-To` is the
    /// original's `Message-ID`; `References` chains the original's existing
    /// References plus its Message-ID. Forwards drop these on purpose — a
    /// forward is a new conversation branch, not a continuation.
    private static func threadingHeaders(from envelope: Envelope, mode: ReplyMode) -> Threading {
        guard mode != .forward else {
            return Threading(inReplyTo: nil, references: [])
        }
        let angleBrackets = CharacterSet(charactersIn: "<>")
        let messageId = envelope.messageId?.trimmingCharacters(in: angleBrackets)
        let prior = envelope.inReplyTo?.trimmingCharacters(in: angleBrackets)
        var references = prior.map { [$0] } ?? []
        if let messageId, !references.contains(messageId) {
            references.append(messageId)
        }
        return Threading(inReplyTo: messageId, references: references)
    }
}
