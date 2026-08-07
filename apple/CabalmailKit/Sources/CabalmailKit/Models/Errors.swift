import Foundation

/// Top-level error type surfaced by every `CabalmailKit` API.
///
/// Wire-level failures (IMAP, SMTP, HTTP, TLS) are normalized into this
/// enum so call-sites never have to pattern-match against `URLError`,
/// `NWError`, or the various lower-level error types produced inside the
/// package.
public enum CabalmailError: Error, Sendable, Equatable {
    case notConfigured
    case notSignedIn
    case invalidCredentials
    case network(String)
    case transport(String)
    case protocolError(String)
    case server(code: String, message: String)
    case decoding(String)
    case timeout
    case cancelled

    /// Authentication token expired and could not be refreshed.
    case authExpired

    /// IMAP server refused a command. `status` is one of `NO` or `BAD`;
    /// `detail` is the human-readable text the server sent after the code.
    case imapCommandFailed(status: String, detail: String)

    /// SMTP server refused a command. `code` is the 3-digit reply.
    case smtpCommandFailed(code: Int, detail: String)

    /// The IMAP tier is mid-redeploy (planned maintenance): the API returned a
    /// 503 with `{"status":"maintenance"}`. `message` is the client-facing copy
    /// so the UI can show "temporarily unavailable" instead of a raw error.
    case maintenance(message: String)

    /// A bulk flag/move landed for some UIDs but not others. The bulk-op
    /// Lambdas issue their IMAP commands in bounded batches and report a
    /// succeeded/failed split (`status: "partial"`); the API-backed client
    /// also aggregates across its own request chunks into one of these.
    /// Callers keep the succeeded UIDs applied and restore (or offer to
    /// retry) the failed ones.
    case bulkPartialFailure(succeeded: Set<UInt32>, failed: Set<UInt32>)
}

/// User-facing copy for every case. Without this the UI printed the enum's
/// synthesized description — `server(code: "404", message: "{\"status\": …`,
/// escaped JSON and all — because `localizedDescription` falls back to it
/// for an `Error` that isn't a `LocalizedError` (#940). The sentences are
/// deliberately plain and actionable; the wire detail rides along only
/// where it tells the user something (a server's own explanation), never
/// as a bare code.
extension CabalmailError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cabalmail isn't set up on this device yet."
        case .notSignedIn:
            return "You're signed out. Sign in and try again."
        case .invalidCredentials:
            return "That username or password wasn't accepted."
        case .authExpired:
            return "Your session expired. Sign in again."
        case .network(let detail):
            return explain("Couldn't reach the server.", detail)
        case .transport(let detail):
            return explain("The connection failed.", detail)
        case .protocolError(let detail):
            return explain("The server sent something unexpected.", detail)
        case .decoding(let detail):
            return explain("Couldn't read the server's reply.", detail)
        case .timeout:
            return "The server took too long to respond."
        case .cancelled:
            return "That request was cancelled."
        case .server(let code, let message):
            // The API explains itself in the body ("That message is no
            // longer in Drafts"); prefer that sentence over the status code.
            return Self.serverExplanation(message) ?? "The server couldn't complete that request (\(code))."
        case .imapCommandFailed(_, let detail):
            return explain("The mail server refused that.", detail)
        case .smtpCommandFailed(_, let detail):
            return explain("The mail server refused the message.", detail)
        case .maintenance(let message):
            // Already client-facing copy, carried for exactly this purpose.
            return message
        case .bulkPartialFailure(let succeeded, let failed):
            let total = succeeded.count + failed.count
            return "\(failed.count) of \(total) messages couldn't be updated."
        }
    }

    /// The human-readable sentence inside an API error body, if there is
    /// one. Handlers answer `{"status": "<sentence>", …}`; API Gateway's own
    /// errors use `{"message": "<sentence>"}`. A one-word marker (`unable`,
    /// `partial`) is machine state, not an explanation, so it's rejected —
    /// the caller falls back to the status code.
    static func serverExplanation(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let candidate = (json["status"] as? String) ?? (json["message"] as? String)
        guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.contains(" ")
        else { return nil }
        return text.hasSuffix(".") ? text : text + "."
    }

    /// Plain sentence plus whatever the lower layer had to say. The detail
    /// arrives as a fragment ("cancelled") as often as a sentence, so it gets
    /// a full stop; an empty one is simply dropped rather than leaving the
    /// copy trailing off.
    private func explain(_ lead: String, _ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lead }
        return trimmed.hasSuffix(".") ? "\(lead) \(trimmed)" : "\(lead) \(trimmed)."
    }
}
