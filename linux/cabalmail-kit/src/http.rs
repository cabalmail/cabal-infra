//! The one HTTP client configuration every request in the kit goes through.
//!
//! The deployment descriptor (Phase 3, work item 1) and the API client (work
//! item 4) both take a [`reqwest::Client`]; [`client`] is where one is built,
//! so the properties below hold for every request rather than for whichever
//! caller remembered them:
//!
//! - HTTPS only, on the first hop and on every redirect. The descriptor names
//!   the user pool and the API endpoint, and the ID token rides on every API
//!   call; neither may cross the network in the clear.
//! - A connect timeout and an overall timeout, so a network that drops packets
//!   without refusing them fails the request instead of hanging it. A request
//!   that fails is one the descriptor's cache can answer.

use std::time::Duration;

use reqwest::redirect::{Attempt, Policy};
use reqwest::{Client, ClientBuilder};

use crate::error::{CabalmailError, Result};

/// How long establishing a connection, TLS included, may take.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a whole request may take, from connecting to the last byte of the
/// body.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// How many redirects a request follows before giving up.
pub const MAX_REDIRECTS: usize = 5;

/// The client every kit request is made with.
///
/// # Errors
///
/// [`CabalmailError::Protocol`] if the TLS stack cannot be initialized — no
/// crypto provider, or no readable system trust store.
pub fn client() -> Result<Client> {
    configured().https_only(true).build().map_err(|error| {
        CabalmailError::Protocol(format!("couldn't build the HTTP client: {error}"))
    })
}

/// Everything [`client`] sets except `https_only`, which is what lets the
/// tests exercise the redirect policy against a plain-HTTP mock server.
pub(crate) fn configured() -> ClientBuilder {
    Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(REQUEST_TIMEOUT)
        .redirect(Policy::custom(follow_https_only))
}

/// Follows a redirect only to an `https://` URL, and only [`MAX_REDIRECTS`]
/// times. `https_only` on the client refuses a plain-HTTP first hop; this is
/// what refuses a redirect to one, and it does so whether or not that flag is
/// set. A custom policy replaces `reqwest`'s default one outright, hop limit
/// included, which is why the limit is restated here.
fn follow_https_only(attempt: Attempt<'_>) -> reqwest::redirect::Action {
    match refuse_redirect(attempt.url().scheme(), attempt.previous().len()) {
        Some(reason) => attempt.error(reason),
        None => attempt.follow(),
    }
}

/// Why a redirect to a `scheme` URL, after `hops` earlier requests, must not be
/// followed; `None` when it may.
fn refuse_redirect(scheme: &str, hops: usize) -> Option<String> {
    if scheme != "https" {
        Some(format!("refused a redirect to a {scheme} URL"))
    } else if hops > MAX_REDIRECTS {
        Some(format!("more than {MAX_REDIRECTS} redirects"))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::path;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn only_https_redirects_are_followed_and_only_so_many() {
        assert_eq!(refuse_redirect("https", 1), None);
        assert_eq!(refuse_redirect("https", MAX_REDIRECTS), None);
        assert_eq!(
            refuse_redirect("https", MAX_REDIRECTS + 1).as_deref(),
            Some("more than 5 redirects")
        );
        assert_eq!(
            refuse_redirect("http", 1).as_deref(),
            Some("refused a redirect to a http URL")
        );
    }

    #[test]
    fn the_client_builds() {
        client().expect("the TLS stack initializes");
    }

    /// Without an overall timeout, a network that drops packets hangs every
    /// request and the descriptor's cache is never consulted. `reqwest` exposes
    /// no getter, so this reads the client's debug form, which names the total
    /// timeout; the connect timeout is not shown there, and the total bounds
    /// connecting too. A `reqwest` upgrade that renames the field fails this
    /// test loudly rather than letting the timeout go unchecked.
    #[test]
    fn the_client_bounds_every_request_in_time() {
        let rendered = format!("{:?}", client().expect("the client builds"));
        assert!(
            rendered.contains(&format!("TotalTimeout: {REQUEST_TIMEOUT:?}")),
            "{rendered}"
        );
    }

    #[tokio::test]
    async fn the_client_refuses_plain_http() {
        let server = MockServer::start().await;
        let error = client()
            .expect("the client builds")
            .get(format!("{}/config.json", server.uri()))
            .send()
            .await
            .expect_err("plain HTTP is refused");
        assert!(
            matches!(CabalmailError::from(error), CabalmailError::Protocol(_)),
            "a refused scheme is not something a retry fixes"
        );
    }

    #[tokio::test]
    async fn a_redirect_to_plain_http_is_refused() {
        let server = MockServer::start().await;
        Mock::given(path("/config.json"))
            .respond_with(
                ResponseTemplate::new(302)
                    .insert_header("location", format!("{}/elsewhere", server.uri())),
            )
            .mount(&server)
            .await;

        let error = configured()
            .build()
            .expect("the client builds")
            .get(format!("{}/config.json", server.uri()))
            .send()
            .await
            .expect_err("the redirect is refused");
        assert!(error.is_redirect(), "{error:?}");
        assert!(matches!(
            CabalmailError::from(error),
            CabalmailError::Protocol(_)
        ));
    }
}
