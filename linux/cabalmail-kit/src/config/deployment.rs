//! The deployment descriptor: which Cabalmail this client is talking to.
//!
//! Terraform writes `config.json` to the control domain's CloudFront
//! distribution (`terraform/infra/modules/app/templates/config.js.tftpl`); the
//! React app reads the same values as `config.js`, and the Apple client decodes
//! them into `Configuration`. This module fetches it, decodes it into a
//! [`Deployment`], and caches it under `$XDG_CACHE_HOME/cabalmail/`.
//!
//! The descriptor belongs to the deployment, not the user, and is never
//! edited: every successful fetch overwrites the cache. The cache is read only
//! when a fetch fails in a way that might succeed later — the laptop is
//! offline, the distribution is mid-deploy — so deleting it is always
//! harmless. A deployment that answers and refuses (a 404 from a host that is
//! not a Cabalmail control domain, a descriptor that does not decode) is
//! reported, never papered over with a copy fetched from it earlier.

use std::path::{Path, PathBuf};

use reqwest::{Client, Url};
use serde::Deserialize;

use super::env::Environment;
use super::file;
use super::schema::Key;
use super::settings::Settings;
use crate::error::{AuthFailure, CabalmailError, Result};

/// A decoded `config.json`.
///
/// Carries the fields the client reads. Terraform writes more
/// (`invitation_required`, `sms_enabled`, `monitoring`, and the enrolment and
/// extension client IDs); those are ignored until something needs them.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Deployment {
    /// The host that serves `config.json` and the admin app.
    pub control_domain: String,
    /// The mail domains this deployment is authoritative for.
    pub domains: Vec<MailDomain>,
    /// The API Gateway stage every Lambda call goes to. Always `https://`;
    /// [`Deployment::decode`] refuses anything else, since the Cognito ID
    /// token rides on every request to it.
    #[serde(rename = "invokeUrl")]
    pub invoke_url: String,
    /// The user pool the client authenticates against.
    #[serde(rename = "cognitoConfig")]
    pub cognito: CognitoConfig,
}

/// One mail domain, as the `domains` Terraform module outputs it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct MailDomain {
    /// The domain addresses are created under subdomains of.
    pub domain: String,
    /// The Route 53 hosted zone's ID.
    pub zone_id: Option<String>,
    /// The hosted zone's delegation set.
    #[serde(default)]
    pub name_servers: Vec<String>,
    /// The hosted zone's ARN.
    pub arn: Option<String>,
}

/// The Cognito identifiers, flattened out of the `poolData` object the Cognito
/// JavaScript SDK expects them in.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(from = "CognitoWire")]
pub struct CognitoConfig {
    /// The AWS region the user pool lives in.
    pub region: String,
    /// `UserPoolId` on the wire.
    pub user_pool_id: String,
    /// `ClientId` on the wire: the app client the admin app and every native
    /// client sign in with.
    pub client_id: String,
}

/// `cognitoConfig` exactly as Terraform writes it.
#[derive(Deserialize)]
struct CognitoWire {
    region: String,
    #[serde(rename = "poolData")]
    pool_data: PoolData,
}

#[derive(Deserialize)]
struct PoolData {
    #[serde(rename = "UserPoolId")]
    user_pool_id: String,
    #[serde(rename = "ClientId")]
    client_id: String,
}

impl From<CognitoWire> for CognitoConfig {
    fn from(wire: CognitoWire) -> Self {
        Self {
            region: wire.region,
            user_pool_id: wire.pool_data.user_pool_id,
            client_id: wire.pool_data.client_id,
        }
    }
}

impl Deployment {
    /// Decodes a `config.json` body.
    ///
    /// # Errors
    ///
    /// [`CabalmailError::Decode`] if the body is not a descriptor, and
    /// [`CabalmailError::Protocol`] if it names an API endpoint that is not
    /// `https://`.
    pub fn decode(body: &[u8]) -> Result<Self> {
        let deployment: Self = serde_json::from_slice(body)
            .map_err(|error| CabalmailError::Decode(format!("config.json: {error}")))?;
        if !deployment.invoke_url.starts_with("https://") {
            return Err(CabalmailError::Protocol(
                "config.json names an API endpoint that is not HTTPS".to_owned(),
            ));
        }
        Ok(deployment)
    }

    /// The IMAP host, by the rule the React app and the Apple client share: a
    /// `dev.` prefix on the control domain becomes `imap.`, and anything else
    /// has `imap.` prepended.
    #[must_use]
    pub fn imap_host(&self) -> String {
        match self.control_domain.strip_prefix("dev.") {
            Some(rest) => format!("imap.{rest}"),
            None => format!("imap.{}", self.control_domain),
        }
    }
}

/// Where a [`Resolution`]'s descriptor came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Origin {
    /// Fetched from the control domain on this call.
    Fetched,
    /// Read from the cache at this path, because the fetch failed transiently.
    Cache(PathBuf),
}

/// A resolved descriptor, and how it was arrived at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolution {
    /// The descriptor in force.
    pub deployment: Deployment,
    /// Whether it is fresh or cached.
    pub origin: Origin,
    /// Non-fatal complaints: a fetched descriptor that could not be cached.
    pub warnings: Vec<String>,
}

/// Normalizes what a user typed as a control domain: surrounding whitespace, a
/// scheme, and trailing slashes are dropped, and the host is lowercased.
/// `None` when nothing is left.
#[must_use]
pub fn normalize_control_domain(raw: &str) -> Option<String> {
    let mut domain = raw.trim().to_ascii_lowercase();
    for scheme in ["https://", "http://"] {
        if let Some(rest) = domain.strip_prefix(scheme) {
            domain = rest.to_owned();
        }
    }
    let domain = domain.trim_end_matches('/');
    (!domain.is_empty()).then(|| domain.to_owned())
}

/// The largest `config.json` the client reads. A real one is a kilobyte or two;
/// anything near this is not a descriptor.
pub const MAX_DESCRIPTOR_BYTES: usize = 1024 * 1024;

/// `https://{control_domain}/config.json`.
///
/// Always HTTPS, whatever scheme the user typed: the descriptor names the user
/// pool and the API endpoint, and a plain-HTTP fetch would let anyone on the
/// path substitute their own.
///
/// # Errors
///
/// [`AuthFailure::NotConfigured`] when the control domain is not a bare host
/// — one carrying a path, credentials, or characters no host name has.
pub fn descriptor_url(control_domain: &str) -> Result<Url> {
    let url = Url::parse(&format!("https://{control_domain}/config.json"))
        .map_err(|_| AuthFailure::NotConfigured)?;
    if url.path() != "/config.json" || !url.username().is_empty() || url.password().is_some() {
        return Err(AuthFailure::NotConfigured.into());
    }
    Ok(url)
}

/// Fetches and decodes the descriptor for `control_domain`, bypassing the
/// cache.
///
/// # Errors
///
/// [`AuthFailure::NotConfigured`] for a control domain that is not a host,
/// [`CabalmailError::Network`] if the request gets no answer,
/// [`CabalmailError::Http`] for a non-success status, whatever
/// [`Deployment::decode`] reports for the body, and
/// [`CabalmailError::Protocol`] for a body over [`MAX_DESCRIPTOR_BYTES`] or a
/// descriptor describing some other control domain.
///
/// Build `client` with [`crate::http::client`], which is what holds every
/// redirect to HTTPS and bounds the request in time.
pub async fn fetch(client: &Client, control_domain: &str) -> Result<Deployment> {
    let url = descriptor_url(control_domain)?;
    let (deployment, _body) = fetch_from(client, url, control_domain).await?;
    Ok(deployment)
}

/// Resolves the descriptor for the control domain `settings` names: fetched
/// when the control domain answers, cached when it cannot be reached.
///
/// # Errors
///
/// [`AuthFailure::NotConfigured`] when no control domain is set, which is the
/// client's cue to ask for one. Otherwise as [`fetch`], except that a
/// transient failure is answered from the cache when the cache holds this
/// control domain's descriptor.
pub async fn resolve(
    client: &Client,
    environment: &Environment,
    settings: &Settings,
) -> Result<Resolution> {
    let control_domain = normalize_control_domain(settings.text(Key::ControlDomain))
        .ok_or(AuthFailure::NotConfigured)?;
    let url = descriptor_url(&control_domain)?;
    let cache = environment.deployment_cache_file();
    resolve_from(client, url, &control_domain, cache.as_deref()).await
}

/// [`resolve`] against an explicit URL and cache path, which is what lets the
/// tests point it at a local server.
async fn resolve_from(
    client: &Client,
    url: Url,
    control_domain: &str,
    cache: Option<&Path>,
) -> Result<Resolution> {
    match fetch_from(client, url, control_domain).await {
        Ok((deployment, body)) => {
            let mut warnings = Vec::new();
            if let Some(path) = cache
                && let Err(error) = file::write_atomic(path, &body)
            {
                warnings.push(format!("couldn't cache the deployment descriptor: {error}"));
            }
            Ok(Resolution {
                deployment,
                origin: Origin::Fetched,
                warnings,
            })
        }
        Err(error) if error.is_transient() => cache
            .and_then(|path| {
                read_cached(path, control_domain).map(|deployment| Resolution {
                    deployment,
                    origin: Origin::Cache(path.to_path_buf()),
                    warnings: Vec::new(),
                })
            })
            .ok_or(error),
        Err(error) => Err(error),
    }
}

/// GETs `url` and decodes the body, returning it alongside the descriptor so
/// the cache holds exactly what the deployment served.
///
/// The descriptor has to describe `control_domain`. One that names another
/// deployment is refused rather than cached: the cache is matched on the
/// descriptor's own `control_domain`, so accepting it would let this host
/// answer, offline, for the one it names.
async fn fetch_from(
    client: &Client,
    url: Url,
    control_domain: &str,
) -> Result<(Deployment, String)> {
    let mut response = client.get(url).send().await?;
    let status = response.status();
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if body.len() + chunk.len() > MAX_DESCRIPTOR_BYTES {
            return Err(CabalmailError::Protocol(format!(
                "config.json is larger than {MAX_DESCRIPTOR_BYTES} bytes"
            )));
        }
        body.extend_from_slice(&chunk);
    }
    let body = String::from_utf8_lossy(&body).into_owned();
    if !status.is_success() {
        return Err(CabalmailError::Http {
            status: status.as_u16(),
            body,
        });
    }
    let deployment = Deployment::decode(body.as_bytes())?;
    if !same_host(&deployment.control_domain, control_domain) {
        return Err(CabalmailError::Protocol(format!(
            "{control_domain} serves the config.json of {}",
            deployment.control_domain
        )));
    }
    Ok((deployment, body))
}

/// The cached descriptor, if there is one, it decodes, and it belongs to
/// `control_domain`. A cache written for a different deployment — the user
/// has since pointed the client elsewhere — is no answer for this one.
fn read_cached(path: &Path, control_domain: &str) -> Option<Deployment> {
    let body = std::fs::read(path).ok()?;
    Deployment::decode(&body)
        .ok()
        .filter(|deployment| same_host(&deployment.control_domain, control_domain))
}

/// Whether two spellings of a control domain name one host. Both go through
/// the URL parser, so case, a trailing dot, a port, and a Unicode name against
/// its punycode form all compare equal.
fn same_host(first: &str, second: &str) -> bool {
    match (canonical_host(first), canonical_host(second)) {
        (Some(first), Some(second)) => first == second,
        _ => false,
    }
}

/// The host a control domain names, as the URL parser spells it, without a
/// trailing dot.
fn canonical_host(control_domain: &str) -> Option<String> {
    let url = Url::parse(&format!("https://{control_domain}/")).ok()?;
    let host = url.host_str()?.trim_end_matches('.');
    Some(host.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Source, Value};
    use crate::error::Disposition;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    const DESCRIPTOR: &str = include_str!("../../tests/fixtures/deployment/descriptor.json");

    /// The kit's client configuration without `https_only`, since the mock
    /// server speaks plain HTTP.
    fn client() -> Client {
        crate::http::configured()
            .build()
            .expect("the client builds")
    }

    fn served(server: &MockServer) -> Url {
        Url::parse(&format!("{}/config.json", server.uri())).expect("the mock URL parses")
    }

    async fn serving(status: u16, body: &str) -> MockServer {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/config.json"))
            .respond_with(ResponseTemplate::new(status).set_body_string(body))
            .mount(&server)
            .await;
        server
    }

    /// A URL on a loopback port nothing listens on: the listener is bound to
    /// claim a free port and dropped before the request is made.
    fn unreachable() -> Url {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let port = listener.local_addr().expect("the bound address").port();
        drop(listener);
        Url::parse(&format!("http://127.0.0.1:{port}/config.json")).expect("the URL parses")
    }

    fn with_invoke_url(invoke_url: &str) -> String {
        DESCRIPTOR.replace(
            "https://abcdef1234.execute-api.us-east-1.amazonaws.com/prod",
            invoke_url,
        )
    }

    #[test]
    fn the_fixture_decodes_into_every_field() {
        let deployment = Deployment::decode(DESCRIPTOR.as_bytes()).expect("the fixture decodes");

        assert_eq!(deployment.control_domain, "admin.example.com");
        assert_eq!(
            deployment.invoke_url,
            "https://abcdef1234.execute-api.us-east-1.amazonaws.com/prod"
        );
        assert_eq!(
            deployment.cognito,
            CognitoConfig {
                region: "us-east-1".to_owned(),
                user_pool_id: "us-east-1_EXAMPLE".to_owned(),
                client_id: "exampleclientid0000000000".to_owned(),
            }
        );
        let domains: Vec<&str> = deployment
            .domains
            .iter()
            .map(|domain| domain.domain.as_str())
            .collect();
        assert_eq!(domains, ["example.net", "example.org"]);
        assert_eq!(
            deployment.domains[0].zone_id.as_deref(),
            Some("Z0000000EXAMPLE1")
        );
        assert_eq!(deployment.domains[1].name_servers, ["ns-3.awsdns-00.com"]);
    }

    /// Only `domain` is required of a mail domain; the zone details are
    /// Terraform's and absent from older deployments.
    #[test]
    fn a_mail_domain_needs_only_its_name() {
        let body = r#"{
            "control_domain": "admin.example.com",
            "domains": [{"domain": "example.net"}],
            "invokeUrl": "https://api.example.com/prod",
            "cognitoConfig": {"region": "us-east-1",
                              "poolData": {"UserPoolId": "p", "ClientId": "c"}}
        }"#;
        let deployment = Deployment::decode(body.as_bytes()).expect("the body decodes");
        assert_eq!(
            deployment.domains,
            [MailDomain {
                domain: "example.net".to_owned(),
                zone_id: None,
                name_servers: Vec::new(),
                arn: None,
            }]
        );
    }

    #[test]
    fn a_body_that_is_not_a_descriptor_is_a_decode_failure() {
        for body in ["<html>not found</html>", "{}", r#"{"control_domain": 7}"#] {
            let error = Deployment::decode(body.as_bytes()).expect_err("the body is rejected");
            assert!(
                matches!(&error, CabalmailError::Decode(detail) if detail.starts_with("config.json: ")),
                "{body} gave {error:?}"
            );
        }
    }

    #[test]
    fn a_plain_http_api_endpoint_is_refused() {
        let body = with_invoke_url("http://abcdef1234.execute-api.us-east-1.amazonaws.com/prod");
        let error = Deployment::decode(body.as_bytes()).expect_err("the descriptor is refused");
        assert!(matches!(error, CabalmailError::Protocol(_)), "{error:?}");
    }

    #[test]
    fn the_imap_host_follows_the_shared_rule() {
        let mut deployment =
            Deployment::decode(DESCRIPTOR.as_bytes()).expect("the fixture decodes");
        assert_eq!(deployment.imap_host(), "imap.admin.example.com");

        deployment.control_domain = "dev.example.com".to_owned();
        assert_eq!(deployment.imap_host(), "imap.example.com");

        // Only a leading `dev.` label is replaced.
        deployment.control_domain = "devices.example.com".to_owned();
        assert_eq!(deployment.imap_host(), "imap.devices.example.com");
    }

    #[test]
    fn a_typed_control_domain_is_normalized() {
        for (typed, expected) in [
            ("admin.example.com", Some("admin.example.com")),
            ("  Admin.Example.COM\n", Some("admin.example.com")),
            ("https://admin.example.com/", Some("admin.example.com")),
            ("HTTP://admin.example.com//", Some("admin.example.com")),
            ("", None),
            ("   ", None),
            ("https://", None),
        ] {
            assert_eq!(
                normalize_control_domain(typed).as_deref(),
                expected,
                "{typed:?}"
            );
        }
    }

    #[test]
    fn the_descriptor_is_always_fetched_over_https() {
        assert_eq!(
            descriptor_url("admin.example.com")
                .expect("a host is accepted")
                .as_str(),
            "https://admin.example.com/config.json"
        );
        assert_eq!(
            descriptor_url("admin.example.com:8443")
                .expect("a port is accepted")
                .as_str(),
            "https://admin.example.com:8443/config.json"
        );
    }

    /// Anything but a bare host would fetch some other document, from some
    /// other host, or with credentials in the URL.
    #[test]
    fn a_control_domain_that_is_not_a_host_is_not_configured() {
        for domain in [
            "admin.example.com/other",
            "user@admin.example.com",
            "user:pass@admin.example.com",
            "admin example.com",
            "admin.example.com?query",
        ] {
            assert_eq!(
                descriptor_url(domain).expect_err("the domain is refused"),
                CabalmailError::Auth(AuthFailure::NotConfigured),
                "{domain}"
            );
        }
    }

    #[tokio::test]
    async fn a_served_descriptor_is_fetched_and_decoded() {
        let server = serving(200, DESCRIPTOR).await;
        let (deployment, body) = fetch_from(&client(), served(&server), "admin.example.com")
            .await
            .expect("the fetch succeeds");
        assert_eq!(deployment.control_domain, "admin.example.com");
        assert_eq!(body, DESCRIPTOR);
    }

    #[tokio::test]
    async fn a_refusal_is_an_http_error_that_is_not_retried() {
        let server = serving(404, "no such key").await;
        let error = fetch_from(&client(), served(&server), "admin.example.com")
            .await
            .expect_err("the fetch fails");
        assert_eq!(
            error,
            CabalmailError::Http {
                status: 404,
                body: "no such key".to_owned(),
            }
        );
        assert_eq!(error.disposition(), Disposition::Permanent);
    }

    #[tokio::test]
    async fn no_answer_is_a_network_error() {
        let error = fetch_from(&client(), unreachable(), "admin.example.com")
            .await
            .expect_err("the fetch fails");
        assert!(matches!(error, CabalmailError::Network(_)), "{error:?}");
    }

    /// The public entry point refuses a malformed domain before it makes a
    /// request.
    #[tokio::test]
    async fn fetch_refuses_a_control_domain_that_is_not_a_host() {
        let error = fetch(&client(), "user@admin.example.com")
            .await
            .expect_err("the fetch is refused");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::NotConfigured));
    }

    #[tokio::test]
    async fn a_fetch_overwrites_the_cache_with_what_was_served() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let cache = cache_root.path().join("cabalmail").join("deployment.json");
        std::fs::create_dir_all(cache.parent().expect("the cache has a parent"))
            .expect("the directory is created");
        std::fs::write(&cache, "stale").expect("the stale cache writes");
        let server = serving(200, DESCRIPTOR).await;

        let resolution = resolve_from(
            &client(),
            served(&server),
            "admin.example.com",
            Some(&cache),
        )
        .await
        .expect("the resolution succeeds");

        assert_eq!(resolution.origin, Origin::Fetched);
        assert!(resolution.warnings.is_empty(), "{:?}", resolution.warnings);
        assert_eq!(
            std::fs::read_to_string(&cache).expect("the cache reads"),
            DESCRIPTOR
        );
    }

    /// Offline, the descriptor this control domain served last time is the
    /// answer.
    #[tokio::test]
    async fn an_unreachable_deployment_is_answered_from_the_cache() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let cache = cache_root.path().join("deployment.json");
        std::fs::write(&cache, DESCRIPTOR).expect("the cache writes");

        let resolution = resolve_from(&client(), unreachable(), "admin.example.com", Some(&cache))
            .await
            .expect("the cache answers");

        assert_eq!(resolution.origin, Origin::Cache(cache));
        assert_eq!(resolution.deployment.control_domain, "admin.example.com");
    }

    /// A 503 is a deployment mid-redeploy, which is transient.
    #[tokio::test]
    async fn a_retryable_status_is_answered_from_the_cache() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let cache = cache_root.path().join("deployment.json");
        std::fs::write(&cache, DESCRIPTOR).expect("the cache writes");
        let server = serving(503, "").await;

        let resolution = resolve_from(
            &client(),
            served(&server),
            "admin.example.com",
            Some(&cache),
        )
        .await
        .expect("the cache answers");

        assert_eq!(resolution.origin, Origin::Cache(cache));
    }

    /// A deployment that answers and refuses is reported, never overridden by
    /// what it served before.
    #[tokio::test]
    async fn a_refusal_is_not_answered_from_the_cache() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let cache = cache_root.path().join("deployment.json");
        std::fs::write(&cache, DESCRIPTOR).expect("the cache writes");

        let not_found = serving(404, "").await;
        let error = resolve_from(
            &client(),
            served(&not_found),
            "admin.example.com",
            Some(&cache),
        )
        .await
        .expect_err("the refusal surfaces");
        assert!(matches!(error, CabalmailError::Http { status: 404, .. }));

        let garbled = serving(200, "<html></html>").await;
        let error = resolve_from(
            &client(),
            served(&garbled),
            "admin.example.com",
            Some(&cache),
        )
        .await
        .expect_err("the garbled descriptor surfaces");
        assert!(matches!(error, CabalmailError::Decode(_)));
    }

    /// The cache holds one deployment. After the user repoints the client, the
    /// old deployment's descriptor answers nothing.
    #[tokio::test]
    async fn another_deployments_cache_is_no_answer() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let cache = cache_root.path().join("deployment.json");
        std::fs::write(&cache, DESCRIPTOR).expect("the cache writes");

        let error = resolve_from(&client(), unreachable(), "stage.example.com", Some(&cache))
            .await
            .expect_err("the fetch error surfaces");
        assert!(matches!(error, CabalmailError::Network(_)), "{error:?}");
    }

    #[tokio::test]
    async fn a_corrupt_or_missing_cache_is_no_answer() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let corrupt = cache_root.path().join("corrupt.json");
        std::fs::write(&corrupt, "{").expect("the cache writes");
        let missing = cache_root.path().join("missing.json");

        for cache in [Some(corrupt.as_path()), Some(missing.as_path()), None] {
            let error = resolve_from(&client(), unreachable(), "admin.example.com", cache)
                .await
                .expect_err("the fetch error surfaces");
            assert!(matches!(error, CabalmailError::Network(_)), "{error:?}");
        }
    }

    /// A cache that cannot be written costs the next offline start, not this
    /// one.
    #[tokio::test]
    async fn an_unwritable_cache_is_a_warning() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let blocker = cache_root.path().join("cabalmail");
        std::fs::write(&blocker, "a file where the directory belongs").expect("the blocker writes");
        let server = serving(200, DESCRIPTOR).await;

        let resolution = resolve_from(
            &client(),
            served(&server),
            "admin.example.com",
            Some(&blocker.join("deployment.json")),
        )
        .await
        .expect("the resolution succeeds");

        assert_eq!(resolution.origin, Origin::Fetched);
        assert_eq!(resolution.warnings.len(), 1, "{:?}", resolution.warnings);
        assert!(
            resolution.warnings[0].starts_with("couldn't cache the deployment descriptor"),
            "{:?}",
            resolution.warnings
        );
    }

    #[test]
    fn spellings_of_one_host_compare_equal() {
        for (first, second) in [
            ("admin.example.com", "ADMIN.example.com"),
            ("admin.example.com", "admin.example.com."),
            ("admin.example.com", "admin.example.com:8443"),
            ("bücher.example", "xn--bcher-kva.example"),
        ] {
            assert!(same_host(first, second), "{first} and {second}");
        }
        for (first, second) in [
            ("admin.example.com", "stage.example.com"),
            ("admin.example.com", "example.com"),
            ("admin.example.com", "admin example.com"),
        ] {
            assert!(!same_host(first, second), "{first} and {second}");
        }
    }

    /// A host serving another deployment's descriptor is refused, and what it
    /// served never reaches the cache, where it would answer for the host it
    /// names.
    #[tokio::test]
    async fn a_descriptor_for_another_deployment_is_refused_and_not_cached() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let cache = cache_root.path().join("deployment.json");
        let server = serving(200, DESCRIPTOR).await;

        let error = resolve_from(
            &client(),
            served(&server),
            "stage.example.com",
            Some(&cache),
        )
        .await
        .expect_err("the descriptor is refused");

        assert!(
            matches!(&error, CabalmailError::Protocol(detail)
                if detail == "stage.example.com serves the config.json of admin.example.com"),
            "{error:?}"
        );
        assert!(!cache.exists(), "a refused descriptor was cached");
    }

    /// The typed domain and the one the descriptor declares need only name the
    /// same host; otherwise the cache would never answer a user who typed a
    /// trailing dot.
    #[tokio::test]
    async fn the_cache_answers_another_spelling_of_the_same_host() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let cache = cache_root.path().join("deployment.json");
        let server = serving(200, DESCRIPTOR).await;
        resolve_from(
            &client(),
            served(&server),
            "admin.example.com.",
            Some(&cache),
        )
        .await
        .expect("the fetch succeeds");

        let resolution = resolve_from(&client(), unreachable(), "Admin.Example.com.", Some(&cache))
            .await
            .expect("the cache answers");
        assert_eq!(resolution.origin, Origin::Cache(cache));
    }

    #[tokio::test]
    async fn an_oversized_body_is_refused() {
        let server = serving(200, &" ".repeat(MAX_DESCRIPTOR_BYTES + 1)).await;
        let error = fetch_from(&client(), served(&server), "admin.example.com")
            .await
            .expect_err("the body is refused");
        assert!(
            matches!(&error, CabalmailError::Protocol(detail) if detail.contains("larger than")),
            "{error:?}"
        );
    }

    /// A server that accepts the connection and never answers is the case a
    /// timeout exists for: without one the request hangs and the cache is
    /// never consulted.
    #[tokio::test]
    async fn a_request_that_times_out_is_answered_from_the_cache() {
        let cache_root = tempfile::tempdir().expect("a temp directory");
        let cache = cache_root.path().join("deployment.json");
        std::fs::write(&cache, DESCRIPTOR).expect("the cache writes");
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_string(DESCRIPTOR)
                    .set_delay(std::time::Duration::from_secs(5)),
            )
            .mount(&server)
            .await;
        let impatient = crate::http::configured()
            .timeout(std::time::Duration::from_millis(100))
            .build()
            .expect("the client builds");

        let resolution = resolve_from(
            &impatient,
            served(&server),
            "admin.example.com",
            Some(&cache),
        )
        .await
        .expect("the cache answers");
        assert_eq!(resolution.origin, Origin::Cache(cache));
    }

    #[tokio::test]
    async fn resolving_with_no_control_domain_is_not_configured() {
        let environment = Environment::from_pairs([("XDG_CACHE_HOME", "/nonexistent")]);
        let mut settings = Settings::defaults();

        let error = resolve(&client(), &environment, &settings)
            .await
            .expect_err("nothing is configured");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::NotConfigured));

        settings.set(
            Key::ControlDomain,
            Value::Text("user@admin.example.com".to_owned()),
            Source::Default,
        );
        let error = resolve(&client(), &environment, &settings)
            .await
            .expect_err("the domain is refused");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::NotConfigured));
    }
}
