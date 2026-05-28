import Foundation

/// Parsed representation of an RFC 6068 `mailto:` URL.
///
/// Only the four standard header slots (`to`, `cc`, `bcc`, `subject`)
/// plus the body are surfaced. Other RFC 6068 hfields (`in-reply-to`,
/// `references`, custom `X-` headers) are accepted by the parser but
/// dropped — adding routing for them is straightforward when a real
/// use case emerges.
///
/// Recipient slots are comma-separated by the spec; each entry is
/// trimmed of surrounding whitespace. The path recipients (e.g.
/// `mailto:a@x,b@y`) and any `?to=` query value are concatenated.
public struct MailtoURL: Sendable, Hashable {
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let body: String

    public init(
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "",
        body: String = ""
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    /// Parses an incoming `mailto:` URL. Returns nil for any other
    /// scheme — callers can safely route every `.onOpenURL` payload
    /// through here.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // URLComponents decodes percent-encoding on `path` and
        // `queryItems.value`, so we get human-readable strings back.
        var to = Self.splitAddresses(components.path)
        var cc: [String] = []
        var bcc: [String] = []
        var subject = ""
        var body = ""

        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "to":
                to += Self.splitAddresses(value)
            case "cc":
                cc += Self.splitAddresses(value)
            case "bcc":
                bcc += Self.splitAddresses(value)
            case "subject":
                subject = value
            case "body":
                body = value
            default:
                // RFC 6068 §6.1 says clients SHOULD only honor a fixed
                // set of safe headers; anything else is dropped.
                break
            }
        }

        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    /// Converts the parsed URL into a compose seed. `composeIntent` is
    /// set to `.new` so the compose surface focuses the To field rather
    /// than the body (the reply-style focus rules don't apply to a
    /// fresh mailto-launched window).
    public func draft() -> Draft {
        Draft(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            composeIntent: .new
        )
    }

    private static func splitAddresses(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
