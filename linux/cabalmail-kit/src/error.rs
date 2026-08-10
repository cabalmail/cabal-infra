//! The one error type every `cabalmail-kit` API returns.
//!
//! Wire-level failures — DNS, TLS, HTTP, JSON, Cognito, Secret Service — are
//! normalized into [`CabalmailError`] so call sites never pattern-match a
//! `reqwest::Error` or an `oo7::Error`. This mirrors `CabalmailError` in
//! `apple/CabalmailKit/Sources/CabalmailKit/Models/Errors.swift`, which is the
//! taxonomy that survived contact with a shipped client.

use std::fmt;

/// Shorthand for the crate's fallible returns.
pub type Result<T> = std::result::Result<T, CabalmailError>;

/// Every failure the kit surfaces.
///
/// The split that matters is [`Disposition`]: a transport failure may succeed
/// on retry, an application rejection will not. The outbox (Phase 5) branches
/// on exactly that — a send that failed because the laptop's Wi-Fi dropped is
/// queued and drained later, while one the server refused has to reach the
/// user now so the compose window can correct it. Getting that wrong either
/// silently swallows a rejected message or retries a malformed one ten times.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CabalmailError {
    /// The request never got an answer: DNS, TLS, connection reset, timeout.
    ///
    /// Timeouts live here rather than in a case of their own — `reqwest`
    /// reports them as one more way the transport failed, and every caller
    /// that cares treats them identically to a dropped connection.
    Network(String),

    /// Authentication state, not a transport or an HTTP outcome. Carries
    /// [`AuthFailure`] because "sign in first", "that password was wrong",
    /// and "your token aged out" lead to three different behaviours: the
    /// first two are terminal for the request, the third is what makes the
    /// API client refresh once and retry (Phase 3).
    Auth(AuthFailure),

    /// The server answered and refused. `body` is the response verbatim; the
    /// API client turns it into a sentence for the user (the Lambda handlers
    /// explain themselves in `{"status": "..."}`) when it lands in Phase 3.
    Http { status: u16, body: String },

    /// The response arrived intact but did not decode into the expected type.
    Decode(String),

    /// The response decoded but violates an invariant the caller depends on —
    /// a UID outside the requested set, a folder path the server does not
    /// list, a MIME structure that contradicts its own headers.
    Protocol(String),

    /// The caller dropped the work before it finished.
    Cancelled,
}

/// Why an authenticated call could not proceed. Each case is a port of the
/// Apple client's equivalent (`notConfigured`, `notSignedIn`,
/// `invalidCredentials`, `authExpired`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthFailure {
    /// No deployment descriptor yet — the client does not know which
    /// Cabalmail it is talking to.
    NotConfigured,
    /// No credentials for this deployment.
    NotSignedIn,
    /// The credentials were presented and rejected.
    InvalidCredentials,
    /// The session aged out and could not be refreshed.
    Expired,
}

/// Whether retrying the same request could plausibly succeed.
///
/// This is the outbox's queue/surface decision, named so it reads the same at
/// every call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Disposition {
    /// Retry when conditions change (connectivity returns, the server stops
    /// throttling, a redeploy finishes).
    Transient,
    /// Retrying re-runs the same rejection. Surface it.
    Permanent,
}

/// HTTP statuses whose semantics are "not now" rather than "not ever":
/// request timeout, throttling, and the gateway/redeploy family — a
/// mid-deployment mail tier answers 503, and dropping the user's message on
/// the floor for it would be indefensible.
const RETRYABLE_STATUSES: &[u16] = &[408, 429, 502, 503, 504];

impl CabalmailError {
    /// Classifies the failure for retry.
    ///
    /// Note this is deliberately finer-grained than the Apple client's
    /// `shouldQueue`, which never queues on a server error. That classifier
    /// predates carrying a numeric status in the error at all; with one in
    /// hand, "permanent 5xx surfaces immediately" (the phase plan's wording)
    /// can mean what it says rather than "every 5xx".
    #[must_use]
    pub fn disposition(&self) -> Disposition {
        match self {
            Self::Network(_) | Self::Cancelled => Disposition::Transient,
            Self::Http { status, .. } if RETRYABLE_STATUSES.contains(status) => {
                Disposition::Transient
            }
            Self::Http { .. } | Self::Auth(_) | Self::Decode(_) | Self::Protocol(_) => {
                Disposition::Permanent
            }
        }
    }

    /// Convenience for the queue/surface branch.
    #[must_use]
    pub fn is_transient(&self) -> bool {
        self.disposition() == Disposition::Transient
    }
}

/// User-facing copy for every case.
///
/// Every variant gets a plain sentence because the alternative is what the
/// Apple client shipped by accident (issue #940): a UI that rendered the
/// derived debug form, escaped JSON and all. Wire detail rides along only
/// where it tells the user something, never as a bare code.
impl fmt::Display for CabalmailError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Network(detail) => explain(f, "Couldn't reach the server.", detail),
            Self::Auth(failure) => f.write_str(failure.message()),
            // The server's own explanation lives in the body, but extracting
            // it means decoding JSON, which the kit has no dependency for yet.
            // The API client does that when it constructs the error in
            // Phase 3; until then the status is the honest thing to show.
            Self::Http { status, .. } => {
                write!(f, "The server couldn't complete that request ({status}).")
            }
            Self::Decode(detail) => explain(f, "Couldn't read the server's reply.", detail),
            Self::Protocol(detail) => explain(f, "The server sent something unexpected.", detail),
            Self::Cancelled => f.write_str("That request was cancelled."),
        }
    }
}

impl std::error::Error for CabalmailError {}

impl AuthFailure {
    /// The sentence shown to the user, and the one thing about this type that
    /// is not a plain tag.
    #[must_use]
    pub fn message(self) -> &'static str {
        match self {
            Self::NotConfigured => "Cabalmail isn't set up on this device yet.",
            Self::NotSignedIn => "You're signed out. Sign in and try again.",
            Self::InvalidCredentials => "That username or password wasn't accepted.",
            Self::Expired => "Your session expired. Sign in again.",
        }
    }
}

impl fmt::Display for AuthFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for AuthFailure {}

impl From<AuthFailure> for CabalmailError {
    fn from(failure: AuthFailure) -> Self {
        Self::Auth(failure)
    }
}

/// A plain sentence plus whatever the lower layer had to say. Detail arrives
/// as a fragment ("connection reset by peer") as often as a sentence, so it
/// gets a full stop; an empty one is dropped rather than leaving the copy
/// trailing off with a stray space.
fn explain(f: &mut fmt::Formatter<'_>, lead: &str, detail: &str) -> fmt::Result {
    let detail = detail.trim();
    if detail.is_empty() {
        return f.write_str(lead);
    }
    if detail.ends_with(['.', '!', '?']) {
        write!(f, "{lead} {detail}")
    } else {
        write!(f, "{lead} {detail}.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn http(status: u16) -> CabalmailError {
        CabalmailError::Http {
            status,
            body: String::new(),
        }
    }

    #[test]
    fn transport_failures_are_transient() {
        assert!(CabalmailError::Network("connection reset".into()).is_transient());
        assert!(CabalmailError::Cancelled.is_transient());
    }

    #[test]
    fn application_rejections_are_permanent() {
        for error in [
            CabalmailError::Auth(AuthFailure::InvalidCredentials),
            CabalmailError::Auth(AuthFailure::Expired),
            CabalmailError::Decode("expected an array".into()),
            CabalmailError::Protocol("uid 7 not in the requested set".into()),
        ] {
            assert_eq!(
                error.disposition(),
                Disposition::Permanent,
                "{error:?} should not be retried"
            );
        }
    }

    #[test]
    fn only_the_retryable_statuses_queue() {
        for status in [408, 429, 502, 503, 504] {
            assert!(http(status).is_transient(), "{status} should be retried");
        }
        for status in [400, 401, 403, 404, 409, 413, 422, 500, 501] {
            assert!(!http(status).is_transient(), "{status} should surface");
        }
    }

    /// A mid-redeploy mail tier answers 503. Queueing that send instead of
    /// dropping it is the whole reason the status is carried in the error.
    #[test]
    fn maintenance_response_queues() {
        let error = CabalmailError::Http {
            status: 503,
            body: r#"{"status":"maintenance"}"#.into(),
        };
        assert_eq!(error.disposition(), Disposition::Transient);
    }

    #[test]
    fn every_variant_renders_a_sentence() {
        for error in [
            CabalmailError::Network("connection reset".into()),
            CabalmailError::Auth(AuthFailure::NotConfigured),
            CabalmailError::Auth(AuthFailure::NotSignedIn),
            CabalmailError::Auth(AuthFailure::InvalidCredentials),
            CabalmailError::Auth(AuthFailure::Expired),
            http(500),
            CabalmailError::Decode("expected an array".into()),
            CabalmailError::Protocol("uid 7 not in the requested set".into()),
            CabalmailError::Cancelled,
        ] {
            let rendered = error.to_string();
            assert!(
                rendered.ends_with('.'),
                "{error:?} renders `{rendered}`, which is not a sentence"
            );
            // The derived debug form is what leaked to users in the Apple
            // client (#940) — braces and quoted payloads are its signature.
            // If either appears here, Display is missing a case.
            assert!(
                !rendered.contains('{') && !rendered.contains('"'),
                "{error:?} renders `{rendered}`, which looks like a debug form"
            );
        }
    }

    #[test]
    fn http_display_names_the_status_and_hides_the_body() {
        let rendered = CabalmailError::Http {
            status: 404,
            body: r#"{"status":"no such folder"}"#.into(),
        }
        .to_string();
        assert!(rendered.contains("404"), "{rendered}");
        assert!(!rendered.contains('{'), "{rendered}");
    }

    #[test]
    fn detail_is_punctuated_once_and_empty_detail_is_dropped() {
        assert_eq!(
            CabalmailError::Network("connection reset".into()).to_string(),
            "Couldn't reach the server. connection reset."
        );
        assert_eq!(
            CabalmailError::Network("connection reset.".into()).to_string(),
            "Couldn't reach the server. connection reset."
        );
        assert_eq!(
            CabalmailError::Network("  ".into()).to_string(),
            "Couldn't reach the server."
        );
    }

    #[test]
    fn auth_failures_convert_into_the_top_level_error() {
        let error: CabalmailError = AuthFailure::Expired.into();
        assert_eq!(error, CabalmailError::Auth(AuthFailure::Expired));
    }

    /// `Result<T>` is the crate's spelling; this pins that a layer working in
    /// bare `AuthFailure`s composes into it with `?`.
    #[test]
    fn question_mark_lifts_an_auth_failure() {
        fn require_session() -> std::result::Result<(), AuthFailure> {
            Err(AuthFailure::NotSignedIn)
        }
        fn list_folders() -> Result<Vec<String>> {
            require_session()?;
            Ok(Vec::new())
        }
        assert_eq!(
            list_folders().unwrap_err(),
            CabalmailError::Auth(AuthFailure::NotSignedIn)
        );
    }
}
