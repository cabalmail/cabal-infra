import Foundation

/// Builds the compose seed for resuming a server-side draft (Phase 4 of
/// `docs/0.10.x/draft-sync-and-threading-headers-plan.md`).
///
/// The caller has already fetched and MIME-parsed the draft (the message
/// detail path does both); this maps the pieces onto a `Draft` whose
/// `serverUid` / `serverUidValidity` point back at the copy being resumed,
/// so the first re-save replaces it and a send discards it.
public enum DraftResume {
    /// - Parameters:
    ///   - envelope: The draft's list envelope (recipients, subject, From).
    ///   - headers: The MIME root part's headers — the only place Bcc and
    ///     the threading headers live (drafts keep Bcc; the fetch path only
    ///     ever returns the user's own mailbox).
    ///   - plainText: Decoded `text/plain` part, if any.
    ///   - htmlBody: Decoded `text/html` part, if any.
    ///   - serverRef: Drafts-folder coordinates of the copy being resumed.
    public static func seed(
        envelope: Envelope,
        headers: [MimeHeader],
        plainText: String?,
        htmlBody: String?,
        serverRef: DraftServerRef?
    ) -> Draft {
        let angleBrackets = CharacterSet(charactersIn: "<>")
        let inReplyTo = MessageIds.parse(value(of: "In-Reply-To", in: headers)).first?
            .trimmingCharacters(in: angleBrackets)
        let references = MessageIds.parse(value(of: "References", in: headers))
            .map { $0.trimmingCharacters(in: angleBrackets) }
        return Draft(
            fromAddress: envelope.from.first.map { "\($0.mailbox)@\($0.host)" },
            to: envelope.to.map { "\($0.mailbox)@\($0.host)" },
            cc: envelope.cc.map { "\($0.mailbox)@\($0.host)" },
            bcc: addressList(value(of: "Bcc", in: headers)),
            subject: envelope.subject ?? "",
            body: body(plainText: plainText, htmlBody: htmlBody),
            inReplyTo: inReplyTo,
            references: references,
            // Resumed drafts open as ordinary composes: focus the To field
            // and skip the reply-seed blank-line scaffolding (the body is
            // already the user's own words, not a quoted original).
            composeIntent: .new,
            serverUid: serverRef?.uid,
            serverUidValidity: serverRef?.uidValidity
        )
    }

    /// Resolves the compose buffer's Markdown source from the draft's MIME
    /// parts. Both first-party composers are Markdown-canonical and emit
    /// the Markdown source as the `text/plain` part, so preferring it makes
    /// the round trip lossless for our own drafts. An HTML-only draft
    /// (foreign client) falls back to the raw HTML: Markdown passes inline
    /// HTML through to the rendered output, so nothing is lost — it is just
    /// less pretty to edit in the Markdown pane.
    static func body(plainText: String?, htmlBody: String?) -> String {
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plainText
        }
        return htmlBody ?? ""
    }

    /// Splits an address-list header value (`Bcc: a@x, "B" <b@y>`) into
    /// bare `mailbox@host` strings, the form `Draft` recipient fields use.
    static func addressList(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",").compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if let open = trimmed.lastIndex(of: "<"),
               let close = trimmed.lastIndex(of: ">"),
               open < close {
                let inside = trimmed[trimmed.index(after: open)..<close]
                    .trimmingCharacters(in: .whitespaces)
                return inside.isEmpty ? nil : inside
            }
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func value(of name: String, in headers: [MimeHeader]) -> String? {
        let needle = name.lowercased()
        return headers.first { $0.name.lowercased() == needle }?.value
    }
}
