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
}
