import Foundation

/// SPF / DKIM / DMARC verdicts for one message, parsed server-side from the
/// trusted `Authentication-Results` header the smtp-in milters stamp (see
/// docs/0.10.x/inbound-auth-verification-plan.md). Values are RFC 8601
/// result tokens, lowercased (`pass`, `fail`, `none`, `neutral`,
/// `softfail`, `temperror`, `permerror`, `policy`).
///
/// A `nil` method means it was not evaluated. A `nil` (or empty) whole
/// value means no trusted header existed on the message — pre-feature
/// mail, or mail that never transited smtp-in. **Absence must never
/// render as pass**; it is the quiet "not verified" state.
public struct AuthResults: Sendable, Codable, Hashable {
    public let spf: String?
    public let dkim: String?
    public let dmarc: String?

    public init(spf: String? = nil, dkim: String? = nil, dmarc: String? = nil) {
        self.spf = spf
        self.dkim = dkim
        self.dmarc = dmarc
    }

    /// True when no method carries a verdict — treated identically to a
    /// missing field (the Lambda never emits `{}`, but a defensive decoder
    /// shouldn't distinguish it from `null`).
    public var isEmpty: Bool {
        spf == nil && dkim == nil && dmarc == nil
    }
}

/// The three display states both clients bucket verdicts into. Bucketing
/// lives here (not in the views) so the iOS and macOS targets share it and
/// it stays unit-testable.
public enum AuthVerificationState: Sendable, Hashable {
    /// DMARC passed — the message authenticated as coming from its
    /// claimed sender.
    case verifiedOk
    /// DMARC failed hard (`fail` / `permerror`), or DMARC was not
    /// evaluated while SPF and DKIM both failed. Copy for this state says
    /// the message *could not be authenticated as coming from its claimed
    /// sender* — not "dangerous" — since forwarding legitimately breaks
    /// these checks.
    case warning
    /// No verdict data (nil / empty), or a middle-ground verdict that is
    /// neither a pass nor a hard failure (e.g. `dmarc=none`,
    /// `spf=softfail`). The quiet default.
    case notVerified

    public init(_ results: AuthResults?) {
        guard let results, !results.isEmpty else {
            self = .notVerified
            return
        }
        switch results.dmarc {
        case "pass":
            self = .verifiedOk
        case "fail", "permerror":
            self = .warning
        case nil:
            self = (results.spf == "fail" && results.dkim == "fail") ? .warning : .notVerified
        default:
            self = .notVerified
        }
    }
}

/// Chip coloring for a single method's verdict token in the detail view:
/// `pass` is the only ok; `fail` / `permerror` are bad; everything else —
/// including an absent method — is neutral, so absence can never dress up
/// as a pass.
public enum AuthMethodSeverity: Sendable, Hashable {
    case ok
    case bad
    case neutral

    public init(token: String?) {
        switch token {
        case "pass":
            self = .ok
        case "fail", "permerror":
            self = .bad
        default:
            self = .neutral
        }
    }
}
