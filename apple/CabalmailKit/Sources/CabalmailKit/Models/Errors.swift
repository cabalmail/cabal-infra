import Foundation

/// Top-level error type surfaced by every `CabalmailKit` API.
///
/// Wire-level failures (HTTP, TLS) are normalized into this
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
    /// A failure the server named with a code callers branch on: the RSS
    /// API's error tokens (`not_a_feed`), Cognito's exception names
    /// (`NotAuthorizedException`), and the config.json fetch.
    case server(code: String, message: String)
    /// A non-2xx reply from the Lambda API, or from a presigned S3 URL, with
    /// no code the client branches on; `body` is the reply as text. Callers
    /// that do branch (the 409 of a send in flight or a rules conflict, the
    /// BIMI 400) compare `status`.
    case http(status: Int, body: String)
    case decoding(String)
    case cancelled

    /// The device's own storage failed: a keychain read, write or delete
    /// answered an OSStatus other than success or not-found. Distinct from
    /// `.transport`, which is the wire: a keychain that can't save a
    /// refreshed token pair says nothing about whether the server is
    /// reachable (#1808).
    case storage(String)

    /// Authentication token expired and could not be refreshed.
    case authExpired

    /// The IMAP tier is mid-redeploy (planned maintenance): the API returned a
    /// 503 with `{"status":"maintenance"}`. `message` is the client-facing copy
    /// so the UI can show "temporarily unavailable" instead of a raw error.
    case maintenance(message: String)

    /// The API is holding an unresolved dedupe claim on this message's
    /// Message-Id (`409 {"status":"duplicate_in_flight"}`): an earlier
    /// submission of the same message is still in flight, or died before it
    /// could report whether it delivered. Neither sent nor failed — the
    /// caller keeps the message and tries again once the claim clears (#1019).
    case sendInFlight

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
        case .cancelled:
            return "That request was cancelled."
        case .storage(let detail):
            return explain("Couldn't read or save data on this device.", detail)
        case .server(let code, let message):
            // The API explains itself in the body ("That message is no
            // longer in Drafts"); prefer that sentence over the status code.
            return Self.serverExplanation(message) ?? "The server couldn't complete that request (\(code))."
        case .http(let status, let body):
            // The same sentence `.server` gives for a numeric code.
            return Self.serverExplanation(body) ?? "The server couldn't complete that request (\(status))."
        case .maintenance(let message):
            // Already client-facing copy, carried for exactly this purpose.
            return message
        case .sendInFlight:
            return "That message is already being sent; it will finish on its own."
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
