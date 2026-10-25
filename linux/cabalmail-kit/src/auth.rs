//! Cognito `USER_PASSWORD_AUTH`, MFA, and token refresh — hand-rolled JSON
//! POSTs to `cognito-idp.<region>.amazonaws.com`, with no AWS SDK, mirroring
//! the Apple client's `CognitoAuthService`.
//!
//! The user pool allows exactly one flow, `USER_PASSWORD_AUTH`
//! (`terraform/infra/modules/user_pool/main.tf`), so the raw JSON API every
//! Cognito SDK wraps is all this needs: a POST with an `X-Amz-Target` header
//! naming the operation.
//!
//! Tokens live in memory here. Keeping them across restarts is the secret
//! store's job (Phase 3, work item 3), which reads them with
//! [`CognitoAuth::tokens`] and puts them back with [`CognitoAuth::restore`].

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use reqwest::{Client, Url};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::config::Deployment;
use crate::error::{AuthFailure, CabalmailError, Result};

/// How long before the ID token's expiry it is treated as expired, so a
/// request minted just before the deadline does not arrive just after it.
/// The Apple client's leeway.
pub const REFRESH_MARGIN: Duration = Duration::from_secs(30);

/// What the clock reads; injectable so tests can age tokens without waiting.
pub type Clock = Arc<dyn Fn() -> SystemTime + Send + Sync>;

/// A Cognito session.
///
/// `Debug` is written by hand and prints no token: these values are bearer
/// credentials, and a session that reached a log line would be one anybody
/// reading the log could use.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tokens {
    /// Sent as `Authorization` on every API call.
    pub id_token: String,
    /// Authenticates the user-attribute and MFA operations.
    pub access_token: String,
    /// Mints new ID and access tokens. Cognito does not return one on a
    /// refresh, so the one from sign-in is carried forward.
    pub refresh_token: Option<String>,
    /// When the ID token expires, in seconds since the Unix epoch.
    pub expires_at: u64,
}

impl std::fmt::Debug for Tokens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tokens")
            .field("id_token", &"<redacted>")
            .field("access_token", &"<redacted>")
            .field(
                "refresh_token",
                &self.refresh_token.as_ref().map(|_| "<redacted>"),
            )
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

impl Tokens {
    /// Whether the ID token has expired, or will within [`REFRESH_MARGIN`].
    #[must_use]
    pub fn is_expired(&self, now: SystemTime) -> bool {
        unix_seconds(now + REFRESH_MARGIN) >= self.expires_at
    }
}

/// The second factor Cognito asked for mid-sign-in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MfaMethod {
    /// `SOFTWARE_TOKEN_MFA`: a code from an authenticator app.
    Totp,
    /// `SMS_MFA`: a code Cognito just texted to the verified number.
    Sms,
}

impl MfaMethod {
    fn from_challenge(name: &str) -> Option<Self> {
        match name {
            "SOFTWARE_TOKEN_MFA" => Some(Self::Totp),
            "SMS_MFA" => Some(Self::Sms),
            _ => None,
        }
    }

    fn challenge_name(self) -> &'static str {
        match self {
            Self::Totp => "SOFTWARE_TOKEN_MFA",
            Self::Sms => "SMS_MFA",
        }
    }

    fn code_key(self) -> &'static str {
        match self {
            Self::Totp => "SOFTWARE_TOKEN_MFA_CODE",
            Self::Sms => "SMS_MFA_CODE",
        }
    }
}

/// How [`CognitoAuth::sign_in`] ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignIn {
    /// The session is live.
    SignedIn,
    /// The password was accepted; [`CognitoAuth::submit_mfa_code`] has to
    /// complete the sign-in before any token exists.
    MfaRequired(MfaMethod),
}

/// The `otpauth://` URI an authenticator app enrolls from, in the Key URI
/// Format the React client also writes: the label is `Cabalmail:<username>`
/// and the issuer `Cabalmail`.
#[must_use]
pub fn totp_uri(secret: &str, username: &str) -> String {
    let mut uri = Url::parse("otpauth://totp/").expect("a constant URL parses");
    uri.path_segments_mut()
        .expect("an otpauth URL has a path")
        .pop_if_empty()
        .push(&format!("Cabalmail:{username}"));
    uri.query_pairs_mut()
        .append_pair("secret", secret)
        .append_pair("issuer", "Cabalmail");
    uri.to_string()
}

/// A sign-in the password has passed and the second factor has not. Cognito's
/// `Session` is opaque and has to be echoed, and so does the username. Memory
/// only: a restart mid-challenge restarts the sign-in.
struct PendingChallenge {
    method: MfaMethod,
    session: String,
    username: String,
}

#[derive(Default)]
struct State {
    tokens: Option<Tokens>,
    pending: Option<PendingChallenge>,
    /// Bumped whenever the session is replaced or ended. A refresh that
    /// started under one generation writes nothing if it finishes under
    /// another, so a sign-out cannot be undone by a refresh that was already
    /// on the wire, and one account's refresh cannot land in the next
    /// account's session.
    generation: u64,
    /// Refreshes finished so far. A caller notes it before queueing for the
    /// refresh lock; if it has moved by the time the caller's turn comes, a
    /// refresh finished while the caller waited, and its outcome is the
    /// caller's too.
    refreshes: u64,
    /// How the last refresh failed, and in which generation — what a caller
    /// that waited behind it is answered with, rather than sending the same
    /// refresh again.
    last_failure: Option<(u64, CabalmailError)>,
}

/// What `NotAuthorizedException` means for one operation. Cognito answers it
/// to a wrong password, a refused refresh, an expired challenge, a disabled
/// account, and an account that is already confirmed alike; only the caller
/// knows which it asked for.
#[derive(Clone, Copy)]
enum NotAuthorized {
    /// Sign-in: a wrong username or password, when Cognito says so in as
    /// many words. Anything else — "Password attempts exceeded", "User is
    /// disabled." — is passed through, since reporting it as a wrong password
    /// would invite another attempt.
    Credentials,
    /// A refresh or an MFA challenge: nobody typed a password on this path,
    /// so the session itself is over.
    Session,
    /// Every other operation: Cognito's own name and sentence.
    Refusal,
}

/// Cognito's message for a wrong username or password.
const WRONG_CREDENTIALS: &str = "Incorrect username or password.";

/// The Cognito client for one deployment.
///
/// Shared by reference across the application: every method takes `&self`, and
/// refreshes are serialized internally, so ten requests that find the ID token
/// stale at once cost one refresh between them.
pub struct CognitoAuth {
    client: Client,
    endpoint: Url,
    client_id: String,
    clock: Clock,
    state: Mutex<State>,
    refresh: tokio::sync::Mutex<()>,
}

impl CognitoAuth {
    /// The Cognito client for `deployment`'s user pool. Build `client` with
    /// [`crate::http::client`].
    ///
    /// # Errors
    ///
    /// [`CabalmailError::Protocol`] if the descriptor's region would not form
    /// a Cognito host name.
    pub fn new(client: Client, deployment: &Deployment) -> Result<Self> {
        let region = &deployment.cognito.region;
        if region.is_empty()
            || !region
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        {
            return Err(CabalmailError::Protocol(format!(
                "config.json names a Cognito region that is not one: {region}"
            )));
        }
        let endpoint = Url::parse(&format!("https://cognito-idp.{region}.amazonaws.com/"))
            .map_err(|error| CabalmailError::Protocol(error.to_string()))?;
        Ok(Self::with_endpoint(
            client,
            endpoint,
            deployment.cognito.client_id.clone(),
            Arc::new(SystemTime::now),
        ))
    }

    /// A client against an explicit endpoint and clock — the tests' entry
    /// point, pointed at a local server.
    fn with_endpoint(client: Client, endpoint: Url, client_id: String, clock: Clock) -> Self {
        Self {
            client,
            endpoint,
            client_id,
            clock,
            state: Mutex::new(State::default()),
            refresh: tokio::sync::Mutex::new(()),
        }
    }

    /// Signs in with a username and password.
    ///
    /// # Errors
    ///
    /// [`AuthFailure::InvalidCredentials`] for a wrong username or password;
    /// [`CabalmailError::Rejected`] for any other refusal, such as an
    /// unconfirmed account (`UserNotConfirmedException`); and
    /// [`CabalmailError::Protocol`] for a challenge this client cannot answer.
    pub async fn sign_in(&self, username: &str, password: &str) -> Result<SignIn> {
        self.lock().pending = None;
        let response = self
            .call(
                "InitiateAuth",
                json!({
                    "AuthFlow": "USER_PASSWORD_AUTH",
                    "ClientId": self.client_id,
                    "AuthParameters": {"USERNAME": username, "PASSWORD": password},
                }),
                NotAuthorized::Credentials,
            )
            .await?;

        if let Some(challenge) = response["ChallengeName"].as_str() {
            let method = MfaMethod::from_challenge(challenge).ok_or_else(|| {
                CabalmailError::Protocol(format!("unhandled sign-in challenge {challenge}"))
            })?;
            let session = response["Session"]
                .as_str()
                .ok_or_else(|| CabalmailError::Decode("challenge without a Session".to_owned()))?;
            self.lock().pending = Some(PendingChallenge {
                method,
                session: session.to_owned(),
                username: username.to_owned(),
            });
            return Ok(SignIn::MfaRequired(method));
        }

        let tokens = self.parse_tokens(&response, None)?;
        self.replace_session(tokens);
        Ok(SignIn::SignedIn)
    }

    /// Completes a sign-in that [`sign_in`](Self::sign_in) answered with
    /// [`SignIn::MfaRequired`]. A wrong code leaves the challenge open, so the
    /// user can try again.
    ///
    /// # Errors
    ///
    /// [`AuthFailure::NotSignedIn`] with no challenge open;
    /// [`CabalmailError::Rejected`] (`CodeMismatchException`) for a wrong code;
    /// and [`AuthFailure::Expired`] once Cognito's three minutes for the
    /// challenge are up.
    pub async fn submit_mfa_code(&self, code: &str) -> Result<()> {
        let (method, session, username) = {
            let state = self.lock();
            let pending = state.pending.as_ref().ok_or(AuthFailure::NotSignedIn)?;
            (
                pending.method,
                pending.session.clone(),
                pending.username.clone(),
            )
        };
        let response = self
            .call(
                "RespondToAuthChallenge",
                json!({
                    "ChallengeName": method.challenge_name(),
                    "ClientId": self.client_id,
                    "Session": session,
                    "ChallengeResponses": {"USERNAME": username, method.code_key(): code},
                }),
                NotAuthorized::Session,
            )
            .await?;
        let tokens = self.parse_tokens(&response, None)?;
        self.replace_session(tokens);
        Ok(())
    }

    /// Registers an account. Empty contact details are left out rather than
    /// sent blank, which Cognito would reject.
    ///
    /// # Errors
    ///
    /// [`CabalmailError::Rejected`] when Cognito or a pool trigger refuses it
    /// — a taken username, a weak password, an invitation check.
    pub async fn sign_up(
        &self,
        username: &str,
        password: &str,
        email: Option<&str>,
        phone: Option<&str>,
    ) -> Result<()> {
        let mut attributes = Vec::new();
        for (name, value) in [("email", email), ("phone_number", phone)] {
            if let Some(value) = value.filter(|value| !value.is_empty()) {
                attributes.push(json!({"Name": name, "Value": value}));
            }
        }
        self.call(
            "SignUp",
            json!({
                "ClientId": self.client_id,
                "Username": username,
                "Password": password,
                "UserAttributes": attributes,
            }),
            NotAuthorized::Refusal,
        )
        .await?;
        Ok(())
    }

    /// Confirms a new account with the code Cognito sent it.
    ///
    /// # Errors
    ///
    /// [`CabalmailError::Rejected`] for a wrong or expired code.
    pub async fn confirm_sign_up(&self, username: &str, code: &str) -> Result<()> {
        self.call(
            "ConfirmSignUp",
            json!({"ClientId": self.client_id, "Username": username, "ConfirmationCode": code}),
            NotAuthorized::Refusal,
        )
        .await?;
        Ok(())
    }

    /// Sends a new account's confirmation code again.
    ///
    /// # Errors
    ///
    /// [`CabalmailError::Rejected`] when Cognito refuses, as it does for an
    /// account that is already confirmed.
    pub async fn resend_confirmation_code(&self, username: &str) -> Result<()> {
        self.call(
            "ResendConfirmationCode",
            json!({"ClientId": self.client_id, "Username": username}),
            NotAuthorized::Refusal,
        )
        .await?;
        Ok(())
    }

    /// Starts a password reset; Cognito sends the account a code.
    ///
    /// # Errors
    ///
    /// [`CabalmailError::Rejected`] when Cognito refuses.
    pub async fn forgot_password(&self, username: &str) -> Result<()> {
        self.call(
            "ForgotPassword",
            json!({"ClientId": self.client_id, "Username": username}),
            NotAuthorized::Refusal,
        )
        .await?;
        Ok(())
    }

    /// Finishes a password reset with the code and the new password.
    ///
    /// # Errors
    ///
    /// [`CabalmailError::Rejected`] for a wrong code or a password the pool's
    /// policy refuses.
    pub async fn confirm_forgot_password(
        &self,
        username: &str,
        code: &str,
        new_password: &str,
    ) -> Result<()> {
        self.call(
            "ConfirmForgotPassword",
            json!({
                "ClientId": self.client_id,
                "Username": username,
                "ConfirmationCode": code,
                "Password": new_password,
            }),
            NotAuthorized::Refusal,
        )
        .await?;
        Ok(())
    }

    /// Ends the session on this device: the tokens and any open challenge are
    /// dropped, and a refresh still on the wire writes nothing back. Like the
    /// Apple client, this does not revoke the refresh token with Cognito.
    pub fn sign_out(&self) {
        let mut state = self.lock();
        state.tokens = None;
        state.pending = None;
        state.generation += 1;
    }

    /// The session, if there is one — what the secret store persists.
    #[must_use]
    pub fn tokens(&self) -> Option<Tokens> {
        self.lock().tokens.clone()
    }

    /// Resumes a session the secret store kept. An expired ID token is fine;
    /// the next request refreshes it.
    pub fn restore(&self, tokens: Tokens) {
        self.replace_session(tokens);
    }

    /// An ID token for an API request, refreshed first if it is within
    /// [`REFRESH_MARGIN`] of expiry.
    ///
    /// # Errors
    ///
    /// [`AuthFailure::NotSignedIn`] with no session;
    /// [`AuthFailure::Expired`] when Cognito refuses the refresh token, and
    /// [`CabalmailError::Rejected`] when the pool refuses to issue tokens —
    /// after either there is no session; and a transient error, which leaves
    /// the session for the next attempt.
    pub async fn id_token(&self) -> Result<String> {
        Ok(self.fresh_tokens(None).await?.id_token)
    }

    /// An ID token to replace one the API rejected with a 401: refreshed even
    /// if the clock says it is still good, since a skewed clock and a
    /// server-side revocation both look like that. If another request has
    /// already replaced `rejected`, its token is returned without a second
    /// refresh.
    ///
    /// # Errors
    ///
    /// As [`id_token`](Self::id_token).
    pub async fn refresh_id_token(&self, rejected: &str) -> Result<String> {
        Ok(self.fresh_tokens(Some(rejected)).await?.id_token)
    }

    /// Whether the account has TOTP set up as its second factor.
    ///
    /// # Errors
    ///
    /// As [`id_token`](Self::id_token), or whatever Cognito refuses.
    pub async fn totp_enabled(&self) -> Result<bool> {
        let response = self
            .call(
                "GetUser",
                json!({"AccessToken": self.access_token().await?}),
                NotAuthorized::Refusal,
            )
            .await?;
        Ok(response["UserMFASettingList"]
            .as_array()
            .is_some_and(|settings| {
                settings
                    .iter()
                    .any(|setting| setting == "SOFTWARE_TOKEN_MFA")
            }))
    }

    /// Starts TOTP enrollment and returns the shared secret. Show it with
    /// [`totp_uri`] as a QR code, and as text for manual entry.
    ///
    /// # Errors
    ///
    /// As [`totp_enabled`](Self::totp_enabled).
    pub async fn begin_totp_enrollment(&self) -> Result<String> {
        let response = self
            .call(
                "AssociateSoftwareToken",
                json!({"AccessToken": self.access_token().await?}),
                NotAuthorized::Refusal,
            )
            .await?;
        response["SecretCode"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| CabalmailError::Decode("enrollment without a SecretCode".to_owned()))
    }

    /// Finishes TOTP enrollment with a first code from the authenticator, and
    /// makes TOTP the preferred factor. A verified token is inert until that
    /// preference is set: no sign-in would be challenged.
    ///
    /// # Errors
    ///
    /// [`CabalmailError::Rejected`] for a wrong code, otherwise as
    /// [`totp_enabled`](Self::totp_enabled).
    pub async fn confirm_totp_enrollment(&self, code: &str) -> Result<()> {
        let access_token = self.access_token().await?;
        let verified = self
            .call(
                "VerifySoftwareToken",
                json!({
                    "AccessToken": access_token,
                    "UserCode": code,
                    "FriendlyDeviceName": "Cabalmail",
                }),
                NotAuthorized::Refusal,
            )
            .await?;
        if verified["Status"] != "SUCCESS" {
            return Err(CabalmailError::Protocol(
                "the authenticator code was not verified".to_owned(),
            ));
        }
        self.call(
            "SetUserMFAPreference",
            json!({
                "AccessToken": access_token,
                "SoftwareTokenMfaSettings": {"Enabled": true, "PreferredMfa": true},
            }),
            NotAuthorized::Refusal,
        )
        .await?;
        Ok(())
    }

    /// The access token, refreshed as [`id_token`](Self::id_token) refreshes.
    async fn access_token(&self) -> Result<String> {
        Ok(self.fresh_tokens(None).await?.access_token)
    }

    /// The session's tokens, refreshed if they are stale or if the ID token is
    /// `rejected`.
    ///
    /// Refreshes are serialized, and their outcome is shared: a caller that
    /// finds the tokens stale waits its turn, then takes whatever the refresh
    /// ahead of it produced — the new tokens, or its failure — rather than
    /// sending the same request again. That is what makes ten concurrent
    /// callers cost one refresh, and ten callers during an outage cost one
    /// timeout rather than ten in a row.
    ///
    /// A refresh that finishes after the session was replaced or ended writes
    /// nothing and starts over against whatever session is there now.
    async fn fresh_tokens(&self, rejected: Option<&str>) -> Result<Tokens> {
        loop {
            let seen = {
                let state = self.lock();
                let tokens = state.tokens.clone().ok_or(AuthFailure::NotSignedIn)?;
                if !self.needs_refresh(&tokens, rejected) {
                    return Ok(tokens);
                }
                state.refreshes
            };

            let _turn = self.refresh.lock().await;
            let (tokens, generation) = {
                let state = self.lock();
                if state.refreshes != seen
                    && let Some((failed_in, error)) = &state.last_failure
                    && *failed_in == state.generation
                {
                    return Err(error.clone());
                }
                let tokens = state.tokens.clone().ok_or(AuthFailure::NotSignedIn)?;
                if !self.needs_refresh(&tokens, rejected) {
                    return Ok(tokens);
                }
                (tokens, state.generation)
            };

            let outcome = self.refresh_tokens(&tokens).await;
            let mut state = self.lock();
            state.refreshes += 1;
            if state.generation != generation {
                state.last_failure = None;
                continue;
            }
            return match outcome {
                Ok(refreshed) => {
                    state.tokens = Some(refreshed.clone());
                    state.last_failure = None;
                    Ok(refreshed)
                }
                Err(error) => {
                    if ends_session(&error) {
                        state.tokens = None;
                        state.generation += 1;
                    }
                    state.last_failure = Some((state.generation, error.clone()));
                    Err(error)
                }
            };
        }
    }

    fn needs_refresh(&self, tokens: &Tokens, rejected: Option<&str>) -> bool {
        tokens.is_expired((self.clock)()) || rejected == Some(tokens.id_token.as_str())
    }

    /// One `REFRESH_TOKEN_AUTH` round trip. Nobody typed anything on this
    /// path, so a refusal means the session is over, not that a credential
    /// was wrong.
    async fn refresh_tokens(&self, tokens: &Tokens) -> Result<Tokens> {
        let refresh_token = tokens
            .refresh_token
            .as_deref()
            .ok_or(AuthFailure::Expired)?;
        let response = self
            .call(
                "InitiateAuth",
                json!({
                    "AuthFlow": "REFRESH_TOKEN_AUTH",
                    "ClientId": self.client_id,
                    "AuthParameters": {"REFRESH_TOKEN": refresh_token},
                }),
                NotAuthorized::Session,
            )
            .await?;
        self.parse_tokens(&response, Some(refresh_token))
    }

    /// Installs a new session, closing any open challenge.
    fn replace_session(&self, tokens: Tokens) {
        let mut state = self.lock();
        state.tokens = Some(tokens);
        state.pending = None;
        state.generation += 1;
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Reads `AuthenticationResult`, carrying `previous_refresh` forward when
    /// the response has none of its own.
    fn parse_tokens(&self, response: &Value, previous_refresh: Option<&str>) -> Result<Tokens> {
        let result =
            response
                .get("AuthenticationResult")
                .ok_or_else(|| match response["ChallengeName"].as_str() {
                    Some(challenge) => {
                        CabalmailError::Protocol(format!("unhandled sign-in challenge {challenge}"))
                    }
                    None => CabalmailError::Decode("no AuthenticationResult".to_owned()),
                })?;
        let field = |name: &str| {
            result[name].as_str().map(str::to_owned).ok_or_else(|| {
                CabalmailError::Decode(format!("AuthenticationResult has no {name}"))
            })
        };
        let expires_in = result["ExpiresIn"].as_u64().unwrap_or(3600);
        Ok(Tokens {
            id_token: field("IdToken")?,
            access_token: field("AccessToken")?,
            refresh_token: result["RefreshToken"]
                .as_str()
                .or(previous_refresh)
                .map(str::to_owned),
            expires_at: unix_seconds((self.clock)()) + expires_in,
        })
    }

    /// POSTs one Cognito operation. `not_authorized` says what
    /// `NotAuthorizedException` means for it.
    async fn call(
        &self,
        target: &str,
        body: Value,
        not_authorized: NotAuthorized,
    ) -> Result<Value> {
        let response = self
            .client
            .post(self.endpoint.clone())
            .header("Content-Type", "application/x-amz-json-1.1")
            .header(
                "X-Amz-Target",
                format!("AWSCognitoIdentityProviderService.{target}"),
            )
            .body(body.to_string())
            .send()
            .await?;
        let status = response.status();
        let bytes = response.bytes().await?;

        if status.is_success() {
            return serde_json::from_slice(&bytes)
                .map_err(|error| CabalmailError::Decode(format!("{target}: {error}")));
        }
        match refusal(&bytes) {
            Some((code, message)) if code == "NotAuthorizedException" => {
                Err(match not_authorized {
                    NotAuthorized::Credentials if message == WRONG_CREDENTIALS => {
                        AuthFailure::InvalidCredentials.into()
                    }
                    NotAuthorized::Session => AuthFailure::Expired.into(),
                    NotAuthorized::Credentials | NotAuthorized::Refusal => {
                        CabalmailError::Rejected { code, message }
                    }
                })
            }
            Some((code, message)) => Err(CabalmailError::Rejected { code, message }),
            None => Err(CabalmailError::Http {
                status: status.as_u16(),
                body: String::from_utf8_lossy(&bytes).into_owned(),
            }),
        }
    }
}

/// Whether a refresh that failed this way leaves nothing to refresh with: the
/// refresh token was refused, or the pool refused to issue tokens at all — as
/// the MFA trigger (`lambda/counter/require_admin_mfa`) does on every refresh
/// once enforcement reaches an account with no second factor. Only a retryable
/// failure keeps the session.
fn ends_session(error: &CabalmailError) -> bool {
    match error {
        CabalmailError::Auth(AuthFailure::Expired) => true,
        CabalmailError::Rejected { .. } => !error.is_transient(),
        _ => false,
    }
}

/// The name and message of a Cognito error body, which arrives as either
/// `{"__type": "<namespace>#<Name>", "message": ...}` or `{"code": ...,
/// "message": ...}`. `None` for a body that is neither — a gateway's HTML
/// page, say.
fn refusal(body: &[u8]) -> Option<(String, String)> {
    let value: Value = serde_json::from_slice(body).ok()?;
    let code = value["__type"]
        .as_str()
        .or_else(|| value["code"].as_str())?;
    let code = code.rsplit('#').next().unwrap_or(code).to_owned();
    let message = value["message"]
        .as_str()
        .or_else(|| value["Message"].as_str())
        .unwrap_or_default();
    let message = if code == "UserLambdaValidationException" {
        strip_trigger_wrapper(message)
    } else {
        message.to_owned()
    };
    Some((code, message))
}

/// A pool trigger's refusal arrives as "`<TriggerName>` failed with error
/// `<message>`." — naming an internal function to the user and, when the
/// trigger's message ends in a full stop, doubling it. Returns the trigger's
/// message alone.
fn strip_trigger_wrapper(message: &str) -> String {
    let mut text = message;
    if let Some((lead, rest)) = message.split_once(" failed with error ")
        && !lead.is_empty()
        && !lead.contains(' ')
    {
        text = rest;
    }
    while text.ends_with("..") {
        text = &text[..text.len() - 1];
    }
    text.to_owned()
}

fn unix_seconds(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use wiremock::matchers::{body_partial_json, header, method};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    const NOW: u64 = 1_800_000_000;

    /// A clock the test moves by hand.
    struct TestClock(Arc<AtomicU64>);

    impl TestClock {
        fn new() -> (Self, Clock) {
            let seconds = Arc::new(AtomicU64::new(NOW));
            let reader = Arc::clone(&seconds);
            let clock: Clock =
                Arc::new(move || UNIX_EPOCH + Duration::from_secs(reader.load(Ordering::SeqCst)));
            (Self(seconds), clock)
        }

        fn advance(&self, seconds: u64) {
            self.0.fetch_add(seconds, Ordering::SeqCst);
        }
    }

    fn auth(server: &MockServer, clock: Clock) -> CognitoAuth {
        CognitoAuth::with_endpoint(
            crate::http::configured()
                .build()
                .expect("the client builds"),
            Url::parse(&server.uri()).expect("the mock URL parses"),
            "client-id".to_owned(),
            clock,
        )
    }

    fn target(name: &str) -> wiremock::matchers::HeaderExactMatcher {
        header(
            "X-Amz-Target",
            format!("AWSCognitoIdentityProviderService.{name}").as_str(),
        )
    }

    fn authenticated(id_token: &str, refresh_token: Option<&str>) -> ResponseTemplate {
        let mut result = json!({
            "IdToken": id_token,
            "AccessToken": format!("access-{id_token}"),
            "ExpiresIn": 3600,
            "TokenType": "Bearer",
        });
        if let Some(refresh_token) = refresh_token {
            result["RefreshToken"] = json!(refresh_token);
        }
        ResponseTemplate::new(200).set_body_json(json!({"AuthenticationResult": result}))
    }

    fn refused(code: &str, message: &str) -> ResponseTemplate {
        ResponseTemplate::new(400).set_body_json(json!({
            "__type": format!("com.amazonaws.cognito.identity.idp.model#{code}"),
            "message": message,
        }))
    }

    /// A password built at run time. A literal one in a test reads to code
    /// scanning as a credential committed to the repository.
    fn password() -> String {
        format!("pw-{}", std::process::id())
    }

    /// Waits until the mock server has received `count` requests, so a test
    /// acts while a delayed response is still on its way rather than guessing
    /// at timing with a sleep.
    async fn received(server: &MockServer, count: usize) {
        for _ in 0..500 {
            let seen = server.received_requests().await.map_or(0, |r| r.len());
            if seen >= count {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("the server never received {count} requests");
    }

    fn session(id_token: &str, expires_at: u64) -> Tokens {
        Tokens {
            id_token: id_token.to_owned(),
            access_token: format!("access-{id_token}"),
            refresh_token: Some("refresh-1".to_owned()),
            expires_at,
        }
    }

    #[tokio::test]
    async fn a_password_sign_in_stores_the_session() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(target("InitiateAuth"))
            .and(header("Content-Type", "application/x-amz-json-1.1"))
            .and(body_partial_json(json!({
                "AuthFlow": "USER_PASSWORD_AUTH",
                "ClientId": "client-id",
                "AuthParameters": {"USERNAME": "testuser", "PASSWORD": password()},
            })))
            .respond_with(authenticated("id-1", Some("refresh-1")))
            .expect(1)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);

        assert_eq!(
            auth.sign_in("testuser", &password())
                .await
                .expect("signed in"),
            SignIn::SignedIn
        );
        assert_eq!(
            auth.tokens(),
            Some(Tokens {
                id_token: "id-1".to_owned(),
                access_token: "access-id-1".to_owned(),
                refresh_token: Some("refresh-1".to_owned()),
                expires_at: NOW + 3600,
            })
        );
        assert_eq!(auth.id_token().await.expect("a token"), "id-1");
    }

    #[tokio::test]
    async fn a_wrong_password_is_invalid_credentials() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(refused(
                "NotAuthorizedException",
                "Incorrect username or password.",
            ))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let error = auth(&server, clock)
            .sign_in("testuser", &format!("{}-wrong", password()))
            .await
            .expect_err("refused");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::InvalidCredentials));
    }

    /// The sign-in window routes on the code: an unconfirmed account goes to
    /// the confirmation page rather than an error.
    #[tokio::test]
    async fn other_refusals_keep_their_name_and_sentence() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(refused(
                "UserNotConfirmedException",
                "User is not confirmed.",
            ))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let error = auth(&server, clock)
            .sign_in("testuser", &password())
            .await
            .expect_err("refused");
        assert_eq!(
            error,
            CabalmailError::Rejected {
                code: "UserNotConfirmedException".to_owned(),
                message: "User is not confirmed.".to_owned(),
            }
        );
    }

    #[tokio::test]
    async fn an_unrecognised_failure_keeps_its_status_and_body() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(ResponseTemplate::new(503).set_body_string("<html>busy</html>"))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let error = auth(&server, clock)
            .sign_in("testuser", &password())
            .await
            .expect_err("refused");
        assert_eq!(
            error,
            CabalmailError::Http {
                status: 503,
                body: "<html>busy</html>".to_owned(),
            }
        );
    }

    #[tokio::test]
    async fn a_totp_challenge_is_answered_with_its_session_and_username() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "ChallengeName": "SOFTWARE_TOKEN_MFA",
                "Session": "challenge-session",
            })))
            .mount(&server)
            .await;
        Mock::given(target("RespondToAuthChallenge"))
            .and(body_partial_json(json!({
                "ChallengeName": "SOFTWARE_TOKEN_MFA",
                "ClientId": "client-id",
                "Session": "challenge-session",
                "ChallengeResponses": {"USERNAME": "testuser", "SOFTWARE_TOKEN_MFA_CODE": "123456"},
            })))
            .respond_with(authenticated("id-1", Some("refresh-1")))
            .expect(1)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);

        assert_eq!(
            auth.sign_in("testuser", &password())
                .await
                .expect("challenged"),
            SignIn::MfaRequired(MfaMethod::Totp)
        );
        assert_eq!(auth.tokens(), None);
        auth.submit_mfa_code("123456").await.expect("signed in");
        assert_eq!(auth.id_token().await.expect("a token"), "id-1");
    }

    #[tokio::test]
    async fn an_sms_challenge_uses_the_sms_code_key() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "ChallengeName": "SMS_MFA",
                "Session": "challenge-session",
            })))
            .mount(&server)
            .await;
        Mock::given(target("RespondToAuthChallenge"))
            .and(body_partial_json(json!({
                "ChallengeName": "SMS_MFA",
                "ChallengeResponses": {"SMS_MFA_CODE": "654321"},
            })))
            .respond_with(authenticated("id-1", Some("refresh-1")))
            .expect(1)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);

        assert_eq!(
            auth.sign_in("testuser", &password())
                .await
                .expect("challenged"),
            SignIn::MfaRequired(MfaMethod::Sms)
        );
        auth.submit_mfa_code("654321").await.expect("signed in");
    }

    /// A wrong code keeps the challenge open for another try; an expired
    /// challenge session is reported as an expired session, not a wrong
    /// password.
    #[tokio::test]
    async fn a_wrong_mfa_code_can_be_retried_and_an_expired_one_cannot() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "ChallengeName": "SOFTWARE_TOKEN_MFA",
                "Session": "challenge-session",
            })))
            .mount(&server)
            .await;
        Mock::given(target("RespondToAuthChallenge"))
            .and(body_partial_json(
                json!({"ChallengeResponses": {"SOFTWARE_TOKEN_MFA_CODE": "000000"}}),
            ))
            .respond_with(refused(
                "CodeMismatchException",
                "Invalid code received for user",
            ))
            .mount(&server)
            .await;
        Mock::given(target("RespondToAuthChallenge"))
            .and(body_partial_json(
                json!({"ChallengeResponses": {"SOFTWARE_TOKEN_MFA_CODE": "111111"}}),
            ))
            .respond_with(refused(
                "NotAuthorizedException",
                "Invalid session for the user, session is expired.",
            ))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.sign_in("testuser", &password())
            .await
            .expect("challenged");

        let error = auth
            .submit_mfa_code("000000")
            .await
            .expect_err("wrong code");
        assert!(
            matches!(&error, CabalmailError::Rejected { code, .. } if code == "CodeMismatchException")
        );
        let error = auth.submit_mfa_code("111111").await.expect_err("expired");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::Expired));
    }

    #[tokio::test]
    async fn a_code_with_no_challenge_open_is_not_signed_in() {
        let server = MockServer::start().await;
        let (_clock, clock) = TestClock::new();
        let error = auth(&server, clock)
            .submit_mfa_code("123456")
            .await
            .expect_err("no challenge");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::NotSignedIn));
    }

    #[tokio::test]
    async fn a_challenge_this_client_cannot_answer_is_a_protocol_error() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "ChallengeName": "NEW_PASSWORD_REQUIRED",
                "Session": "challenge-session",
            })))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let error = auth(&server, clock)
            .sign_in("testuser", &password())
            .await
            .expect_err("unanswerable");
        assert!(matches!(error, CabalmailError::Protocol(_)), "{error:?}");
    }

    #[tokio::test]
    async fn the_account_operations_send_what_cognito_expects() {
        let server = MockServer::start().await;
        for (name, body) in [
            (
                "SignUp",
                json!({
                    "ClientId": "client-id",
                    "Username": "testuser",
                    "Password": password(),
                    "UserAttributes": [{"Name": "email", "Value": "testuser@example.com"}],
                }),
            ),
            (
                "ConfirmSignUp",
                json!({"ClientId": "client-id", "Username": "testuser", "ConfirmationCode": "123456"}),
            ),
            (
                "ResendConfirmationCode",
                json!({"ClientId": "client-id", "Username": "testuser"}),
            ),
            (
                "ForgotPassword",
                json!({"ClientId": "client-id", "Username": "testuser"}),
            ),
            (
                "ConfirmForgotPassword",
                json!({
                    "ClientId": "client-id",
                    "Username": "testuser",
                    "ConfirmationCode": "123456",
                    "Password": password(),
                }),
            ),
        ] {
            Mock::given(target(name))
                .and(body_partial_json(body))
                .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
                .expect(1)
                .mount(&server)
                .await;
        }
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);

        auth.sign_up(
            "testuser",
            &password(),
            Some("testuser@example.com"),
            Some(""),
        )
        .await
        .expect("signed up");
        auth.confirm_sign_up("testuser", "123456")
            .await
            .expect("confirmed");
        auth.resend_confirmation_code("testuser")
            .await
            .expect("resent");
        auth.forgot_password("testuser")
            .await
            .expect("reset started");
        auth.confirm_forgot_password("testuser", "123456", &password())
            .await
            .expect("reset finished");
    }

    /// An empty phone number is left out rather than sent blank; the attribute
    /// list holds only what was given.
    #[tokio::test]
    async fn sign_up_omits_empty_contact_details() {
        let server = MockServer::start().await;
        Mock::given(target("SignUp"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        auth(&server, clock)
            .sign_up(
                "testuser",
                &password(),
                Some("testuser@example.com"),
                Some(""),
            )
            .await
            .expect("signed up");

        let requests = server.received_requests().await.expect("recorded");
        let body: Value = serde_json::from_slice(&requests[0].body).expect("a JSON body");
        assert_eq!(
            body["UserAttributes"],
            json!([{"Name": "email", "Value": "testuser@example.com"}])
        );
    }

    #[tokio::test]
    async fn a_trigger_refusal_shows_the_triggers_own_message() {
        let server = MockServer::start().await;
        Mock::given(target("SignUp"))
            .respond_with(refused(
                "UserLambdaValidationException",
                "PreSignUp failed with error An invitation is required to sign up..",
            ))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let error = auth(&server, clock)
            .sign_up("testuser", &password(), None, None)
            .await
            .expect_err("refused");
        assert_eq!(error.to_string(), "An invitation is required to sign up.");
    }

    #[test]
    fn the_trigger_wrapper_is_stripped_only_from_a_bare_trigger_name() {
        assert_eq!(
            strip_trigger_wrapper("PreSignUp failed with error Nope."),
            "Nope."
        );
        assert_eq!(
            strip_trigger_wrapper("The upload failed with error 5."),
            "The upload failed with error 5."
        );
        assert_eq!(strip_trigger_wrapper("Done..."), "Done.");
    }

    #[test]
    fn both_cognito_error_shapes_are_read() {
        assert_eq!(
            refusal(br#"{"__type": "ns#CodeMismatchException", "message": "Wrong."}"#),
            Some(("CodeMismatchException".to_owned(), "Wrong.".to_owned()))
        );
        assert_eq!(
            refusal(br#"{"code": "ExpiredCodeException", "Message": "Old."}"#),
            Some(("ExpiredCodeException".to_owned(), "Old.".to_owned()))
        );
        assert_eq!(refusal(b"<html></html>"), None);
        assert_eq!(refusal(br#"{"message": "no code"}"#), None);
    }

    #[tokio::test]
    async fn a_fresh_token_is_returned_without_a_refresh() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(authenticated("id-2", None))
            .expect(0)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW + 3600));
        assert_eq!(auth.id_token().await.expect("a token"), "id-1");
    }

    /// Inside the margin is expired: a token minted with 10 seconds left
    /// would arrive dead.
    #[tokio::test]
    async fn a_token_inside_the_margin_is_refreshed_and_keeps_its_refresh_token() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .and(body_partial_json(json!({
                "AuthFlow": "REFRESH_TOKEN_AUTH",
                "AuthParameters": {"REFRESH_TOKEN": "refresh-1"},
            })))
            .respond_with(authenticated("id-2", None))
            .expect(1)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW + REFRESH_MARGIN.as_secs() - 10));

        assert_eq!(auth.id_token().await.expect("a token"), "id-2");
        let tokens = auth.tokens().expect("a session");
        assert_eq!(tokens.refresh_token.as_deref(), Some("refresh-1"));
        assert_eq!(tokens.expires_at, NOW + 3600);
    }

    /// The plan's verification criterion: an expired token and ten concurrent
    /// requests cost exactly one refresh.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn ten_concurrent_requests_cost_one_refresh() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(authenticated("id-2", None).set_delay(Duration::from_millis(200)))
            .expect(1)
            .mount(&server)
            .await;
        let (clock_handle, clock) = TestClock::new();
        let auth = Arc::new(auth(&server, clock));
        auth.restore(session("id-1", NOW + 3600));
        clock_handle.advance(3600);

        let mut requests = tokio::task::JoinSet::new();
        for _ in 0..10 {
            let auth = Arc::clone(&auth);
            requests.spawn(async move { auth.id_token().await });
        }
        while let Some(result) = requests.join_next().await {
            assert_eq!(result.expect("the task ran").expect("a token"), "id-2");
        }
    }

    /// Concurrent 401s for one token cost one refresh too; a caller whose
    /// rejected token another caller already replaced gets the replacement.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_rejections_of_one_token_cost_one_refresh() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(authenticated("id-2", None).set_delay(Duration::from_millis(200)))
            .expect(1)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = Arc::new(auth(&server, clock));
        auth.restore(session("id-1", NOW + 3600));

        let mut requests = tokio::task::JoinSet::new();
        for _ in 0..10 {
            let auth = Arc::clone(&auth);
            requests.spawn(async move { auth.refresh_id_token("id-1").await });
        }
        while let Some(result) = requests.join_next().await {
            assert_eq!(result.expect("the task ran").expect("a token"), "id-2");
        }
        assert_eq!(
            auth.refresh_id_token("id-1").await.expect("a token"),
            "id-2"
        );
    }

    #[tokio::test]
    async fn a_refused_refresh_ends_the_session() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(refused(
                "NotAuthorizedException",
                "Refresh Token has expired",
            ))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW));

        let error = auth.id_token().await.expect_err("refused");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::Expired));
        assert_eq!(auth.tokens(), None);
        let error = auth.id_token().await.expect_err("no session");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::NotSignedIn));
    }

    /// A transient failure is not the end of the session: the tokens stay for
    /// the next attempt.
    #[tokio::test]
    async fn a_throttled_refresh_keeps_the_session() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(refused("TooManyRequestsException", "Rate exceeded"))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW));

        let error = auth.id_token().await.expect_err("throttled");
        assert!(error.is_transient(), "{error:?}");
        assert!(auth.tokens().is_some());
    }

    #[tokio::test]
    async fn a_session_with_no_refresh_token_expires() {
        let server = MockServer::start().await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(Tokens {
            refresh_token: None,
            ..session("id-1", NOW)
        });
        let error = auth.id_token().await.expect_err("no way to refresh");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::Expired));
    }

    /// Signing out while a refresh is on the wire must not let that refresh
    /// write the session back.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_sign_out_during_a_refresh_stays_signed_out() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(authenticated("id-2", None).set_delay(Duration::from_millis(300)))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = Arc::new(auth(&server, clock));
        auth.restore(session("id-1", NOW));

        let refreshing = {
            let auth = Arc::clone(&auth);
            tokio::spawn(async move { auth.id_token().await })
        };
        received(&server, 1).await;
        auth.sign_out();

        let error = refreshing
            .await
            .expect("the task ran")
            .expect_err("signed out");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::NotSignedIn));
        assert_eq!(auth.tokens(), None);
    }

    /// A sign-in that lands while the old session's refresh is on the wire:
    /// the refresh writes nothing, and its caller gets the new session's
    /// token rather than an error that would bounce the user to sign-in.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_new_session_during_a_refresh_is_what_the_caller_gets() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(authenticated("id-2", None).set_delay(Duration::from_millis(300)))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = Arc::new(auth(&server, clock));
        auth.restore(session("id-1", NOW));

        let refreshing = {
            let auth = Arc::clone(&auth);
            tokio::spawn(async move { auth.id_token().await })
        };
        received(&server, 1).await;
        auth.restore(session("id-9", NOW + 3600));

        assert_eq!(
            refreshing.await.expect("the task ran").expect("a token"),
            "id-9"
        );
        assert_eq!(auth.tokens().expect("a session").id_token, "id-9");
    }

    /// Callers queued behind a failed refresh take its failure rather than
    /// each sending the same refresh: during an outage, ten callers cost one
    /// timeout, not ten in a row.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_failed_refresh_is_shared_by_every_waiting_caller() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(
                refused("TooManyRequestsException", "Rate exceeded")
                    .set_delay(Duration::from_millis(200)),
            )
            .expect(1)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = Arc::new(auth(&server, clock));
        auth.restore(session("id-1", NOW));

        let mut requests = tokio::task::JoinSet::new();
        for _ in 0..10 {
            let auth = Arc::clone(&auth);
            requests.spawn(async move { auth.id_token().await });
        }
        while let Some(result) = requests.join_next().await {
            let error = result.expect("the task ran").expect_err("throttled");
            assert!(
                matches!(&error, CabalmailError::Rejected { code, .. } if code == "TooManyRequestsException"),
                "{error:?}"
            );
        }
        assert!(
            auth.tokens().is_some(),
            "a throttled refresh ended the session"
        );
    }

    /// Every caller behind a refused refresh is told the session expired, not
    /// some of them that they are signed out.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_refused_refresh_tells_every_waiting_caller_the_same() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(
                refused("NotAuthorizedException", "Refresh Token has expired")
                    .set_delay(Duration::from_millis(200)),
            )
            .expect(1)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = Arc::new(auth(&server, clock));
        auth.restore(session("id-1", NOW));

        let mut requests = tokio::task::JoinSet::new();
        for _ in 0..10 {
            let auth = Arc::clone(&auth);
            requests.spawn(async move { auth.id_token().await });
        }
        while let Some(result) = requests.join_next().await {
            assert_eq!(
                result.expect("the task ran").expect_err("refused"),
                CabalmailError::Auth(AuthFailure::Expired)
            );
        }
    }

    /// The MFA trigger refuses every refresh once enforcement reaches an
    /// account with no second factor. That leaves nothing to refresh with, so
    /// the session ends — with the trigger's own explanation.
    #[tokio::test]
    async fn a_trigger_refusing_the_refresh_ends_the_session() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(refused(
                "UserLambdaValidationException",
                "PreTokenGeneration failed with error MFA enrollment is required.",
            ))
            .expect(1)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW));

        let error = auth.id_token().await.expect_err("refused");
        assert_eq!(error.to_string(), "MFA enrollment is required.");
        assert_eq!(auth.tokens(), None);
        assert_eq!(
            auth.id_token().await.expect_err("no session"),
            CabalmailError::Auth(AuthFailure::NotSignedIn)
        );
    }

    /// Cognito says "not authorized" to far more than a wrong password. On
    /// sign-in only its wrong-password sentence is reported as one; a locked
    /// account is told so, rather than invited to try again.
    #[tokio::test]
    async fn only_a_wrong_password_is_reported_as_one() {
        let server = MockServer::start().await;
        Mock::given(target("InitiateAuth"))
            .respond_with(refused(
                "NotAuthorizedException",
                "Password attempts exceeded",
            ))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let error = auth(&server, clock)
            .sign_in("testuser", &password())
            .await
            .expect_err("refused");
        assert_eq!(
            error,
            CabalmailError::Rejected {
                code: "NotAuthorizedException".to_owned(),
                message: "Password attempts exceeded".to_owned(),
            }
        );
    }

    /// Confirming an account that is already confirmed is not a wrong
    /// password, and neither is a revoked access token; both keep Cognito's
    /// sentence.
    #[tokio::test]
    async fn other_operations_pass_not_authorized_through() {
        let server = MockServer::start().await;
        Mock::given(target("ConfirmSignUp"))
            .respond_with(refused(
                "NotAuthorizedException",
                "User cannot be confirmed. Current status is CONFIRMED",
            ))
            .mount(&server)
            .await;
        Mock::given(target("GetUser"))
            .respond_with(refused(
                "NotAuthorizedException",
                "Access Token has been revoked",
            ))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW + 3600));

        let error = auth
            .confirm_sign_up("testuser", "123456")
            .await
            .expect_err("refused");
        assert_eq!(
            error.to_string(),
            "User cannot be confirmed. Current status is CONFIRMED."
        );
        let error = auth.totp_enabled().await.expect_err("refused");
        assert!(
            matches!(&error, CabalmailError::Rejected { code, .. } if code == "NotAuthorizedException"),
            "{error:?}"
        );
    }

    /// The margin, pinned in literal seconds so changing the constant fails
    /// here: thirty seconds or less before expiry is expired.
    #[test]
    fn a_token_is_expired_thirty_seconds_early() {
        let now = UNIX_EPOCH + Duration::from_secs(NOW);
        assert!(session("id-1", NOW + 30).is_expired(now));
        assert!(!session("id-1", NOW + 31).is_expired(now));
        assert!(session("id-1", NOW).is_expired(now));
    }

    #[tokio::test]
    async fn no_session_is_not_signed_in() {
        let server = MockServer::start().await;
        let (_clock, clock) = TestClock::new();
        let error = auth(&server, clock)
            .id_token()
            .await
            .expect_err("no session");
        assert_eq!(error, CabalmailError::Auth(AuthFailure::NotSignedIn));
    }

    #[tokio::test]
    async fn totp_enrollment_verifies_then_prefers_totp() {
        let server = MockServer::start().await;
        Mock::given(target("AssociateSoftwareToken"))
            .and(body_partial_json(json!({"AccessToken": "access-id-1"})))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(json!({"SecretCode": "JBSWY3DPEHPK3PXP"})),
            )
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(target("VerifySoftwareToken"))
            .and(body_partial_json(
                json!({"AccessToken": "access-id-1", "UserCode": "123456"}),
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"Status": "SUCCESS"})))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(target("SetUserMFAPreference"))
            .and(body_partial_json(json!({
                "AccessToken": "access-id-1",
                "SoftwareTokenMfaSettings": {"Enabled": true, "PreferredMfa": true},
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(target("GetUser"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "Username": "testuser",
                "UserMFASettingList": ["SOFTWARE_TOKEN_MFA"],
            })))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW + 3600));

        assert_eq!(
            auth.begin_totp_enrollment().await.expect("a secret"),
            "JBSWY3DPEHPK3PXP"
        );
        auth.confirm_totp_enrollment("123456")
            .await
            .expect("enrolled");
        assert!(auth.totp_enabled().await.expect("an answer"));
    }

    /// Without the preference a verified token is inert, so a verification
    /// that did not succeed must stop before setting it.
    #[tokio::test]
    async fn an_unverified_code_does_not_set_the_preference() {
        let server = MockServer::start().await;
        Mock::given(target("VerifySoftwareToken"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"Status": "ERROR"})))
            .mount(&server)
            .await;
        Mock::given(target("SetUserMFAPreference"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .expect(0)
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW + 3600));

        let error = auth
            .confirm_totp_enrollment("123456")
            .await
            .expect_err("not verified");
        assert!(matches!(error, CabalmailError::Protocol(_)), "{error:?}");
    }

    #[tokio::test]
    async fn an_account_without_totp_reports_it() {
        let server = MockServer::start().await;
        Mock::given(target("GetUser"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"Username": "testuser"})))
            .mount(&server)
            .await;
        let (_clock, clock) = TestClock::new();
        let auth = auth(&server, clock);
        auth.restore(session("id-1", NOW + 3600));
        assert!(!auth.totp_enabled().await.expect("an answer"));
    }

    #[test]
    fn the_totp_uri_matches_the_key_uri_format() {
        assert_eq!(
            totp_uri("JBSWY3DPEHPK3PXP", "testuser"),
            "otpauth://totp/Cabalmail:testuser?secret=JBSWY3DPEHPK3PXP&issuer=Cabalmail"
        );
        assert_eq!(
            totp_uri("JBSWY3DPEHPK3PXP", "a b/c"),
            "otpauth://totp/Cabalmail:a%20b%2Fc?secret=JBSWY3DPEHPK3PXP&issuer=Cabalmail"
        );
    }

    #[test]
    fn debug_output_carries_no_token() {
        let rendered = format!("{:?}", session("secret-id-token", NOW));
        assert!(!rendered.contains("secret-id-token"), "{rendered}");
        assert!(!rendered.contains("access-secret"), "{rendered}");
        assert!(!rendered.contains("refresh-1"), "{rendered}");
    }

    #[test]
    fn a_region_that_is_not_one_is_refused() {
        let mut deployment = Deployment::decode(include_bytes!(
            "../tests/fixtures/deployment/descriptor.json"
        ))
        .expect("the fixture decodes");
        let client = crate::http::client().expect("the client builds");
        let auth = CognitoAuth::new(client.clone(), &deployment).expect("a real region");
        assert_eq!(
            auth.endpoint.as_str(),
            "https://cognito-idp.us-east-1.amazonaws.com/"
        );

        for region in ["", "evil.example/", "us-east-1.attacker.com#"] {
            deployment.cognito.region = region.to_owned();
            assert!(
                matches!(
                    CognitoAuth::new(client.clone(), &deployment),
                    Err(CabalmailError::Protocol(_))
                ),
                "{region:?}"
            );
        }
    }
}
