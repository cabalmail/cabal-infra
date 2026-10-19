# Authentication

Every Cabalmail client signs users in against one Cognito user pool per environment. The webmail and the native clients call Cognito's JSON API directly, with no AWS SDK, and use the same requests. The browser extension uses Cognito's Hosted UI instead. This page is the contract the clients follow: what they send, what comes back, how they keep a session, and which client implements which part today.

Clients only decide what to show. Authorization belongs to the server: API Gateway's Cognito authorizer validates the ID token on every API call, and the Lambdas check admin membership themselves (`lambda/api/_shared/admin_limits.py`). Nothing a client concludes about a user is trusted.

## The user pool

Terraform: `terraform/infra/modules/user_pool/`.

| App client | Used by | Flows | Token lifetimes (ID / access / refresh) |
| --- | --- | --- | --- |
| `cabal_admin_client` (`poolData.ClientId`) | Webmail, Apple, Android, Linux (in progress) | `USER_PASSWORD_AUTH`, refresh | 12 h / 12 h / 7 days |
| `cabal_mfa_enroll_client` (`enrollClientId`) | Webmail's locked-out TOTP setup | `USER_PASSWORD_AUTH` | 5 min / 5 min / 60 min |
| `cabal_extension_client` (`extensionClientId`) | Browser extension | Hosted UI authorization code + PKCE (S256), refresh | 1 h / 1 h / 7 days |

All three clients have token revocation on. MFA is optional at the pool. TOTP is always available, and SMS only when the environment has SMS configured (`sms_enabled`). Account recovery uses a verified email first and a verified phone second, the phone only when SMS is on. Members of the `admin` group are administrators. Group membership is granted in the Cognito console; see the [user manual](./user_manual.md#administration).

Three Lambda triggers sit on the pool (`lambda/counter/`):

| Trigger | Function | What it does |
| --- | --- | --- |
| Pre sign-up | `check_invite` | Checks the invitation code (when one is configured) and the username's shape, and auto-confirms the account when SMS is off, because no code could be delivered. Admin-created users skip the checks. |
| Post confirmation | `assign_osid` | Gives the account its mail-system user ID (`custom:osid`), from a counter in DynamoDB. |
| Pre token generation | `require_admin_mfa` | The MFA gate (see [The MFA gate](#the-mfa-gate)). |

## Client configuration

Clients read the pool's coordinates at runtime from `/config.js` on the control domain, generated from `terraform/infra/modules/app/templates/config.js.tftpl`. The auth-relevant keys are:

| Key | Meaning |
| --- | --- |
| `cognitoConfig.region` | The pool's region. Older files without it: take the prefix of `UserPoolId`. |
| `cognitoConfig.poolData.UserPoolId`, `.ClientId` | The pool, and the client every native client and the webmail sign in through. |
| `cognitoConfig.enrollClientId` | The enrollment client for the locked-out TOTP setup. Empty in a file older than that feature: fall back to a plain message. |
| `cognitoConfig.extensionClientId`, `.hostedUiDomain` | The extension's client and the Hosted UI domain. |
| `invitation_required` | Show the invitation-code field at sign-up. |
| `sms_enabled` | Require a phone number at sign-up (with consent), make the recovery email optional, and expect SMS codes. When it is off, require the email instead (see [Sign-up](#sign-up)). Treat a missing key as `true`, so an older file keeps the phone field. |

## Transport and errors

Every operation is a `POST` to `https://cognito-idp.<region>.amazonaws.com/` with `Content-Type: application/x-amz-json-1.1` and `X-Amz-Target: AWSCognitoIdentityProviderService.<Operation>`. Nothing is signed. The body carries whatever authenticates the call: a password, a code, a refresh token or an access token.

An error is a non-2xx with `{"__type": "<Exception>", "message": "..."}`. `__type` sometimes carries a namespace prefix (`...model#NotAuthorizedException`), so match on the part after the last `#`. A 2xx whose body isn't JSON (a captive portal, a proxy page) is not a Cognito answer; report it as unreadable rather than let a parse error escape.

| Cognito says | It means | Show |
| --- | --- | --- |
| `UserLambdaValidationException`, message containing "invitation code" | `check_invite` refused the invitation code | "Invalid invitation code." |
| `UserLambdaValidationException`, message `PreSignUp failed with error <text>.` | `check_invite` refused the username | The trigger's `<text>`, with Cognito's wrapper and doubled full stop removed |
| message matching `requires multi-factor` (from `PreTokenGeneration`) | The MFA gate refused tokens | The locked-out setup, or "contact the operator" |
| `NotAuthorizedException` at sign-in | Wrong password, or a disabled user | "Login failed" |
| `NotAuthorizedException` answering a challenge | The challenge session expired (a few minutes), or too many wrong codes | Restart the sign-in |
| `NotAuthorizedException` on refresh | The refresh token expired or was revoked | Sign in again |
| `CodeMismatchException`, `EnableSoftwareTokenMFAException` | A wrong one-time code | "That code did not match" |
| `LimitExceededException` | The per-user limit on sending codes | Stop offering Resend for a while |

## Sign-up

`SignUp` with:

- `ClientId`, `Username`, `Password`.
- `UserAttributes`: `preferred_username` (the username), plus the contacts below. Leave out a contact the user left empty rather than sending an empty value.
- `ValidationData`: `[{"Name": "invitationCode", "Value": <code>}]`. Send it, empty, even when no code is required. It travels as validation data so `check_invite` can read it without it being stored on the user record.

Which contacts the form asks for depends on `sms_enabled`, so that Cabalmail can be someone's only email service:

| | `phone_number` (E.164) | `email` (recovery address) |
| --- | --- | --- |
| SMS on | Required, with SMS consent. It receives the confirmation code and recovers the account. | Optional. If given, it is verified after the first sign-in and becomes the first recovery channel. |
| SMS off | Not collected: the pool cannot text. | Required. It is the only channel that can verify or recover the account. |

The form says the email should be an address outside Cabalmail, since a mailbox you are locked out of can't receive its own reset code. A phone-only account recovers by SMS alone, so a SIM swap could reset its password. Its second factor still stands after a reset, which is why the authenticator suggestion (see [After sign-in](#after-sign-in)) matters most for those accounts. The requirement is the clients' to enforce; `check_invite` checks only the invitation code and the username.

The `SignUp` reply says what happens next:

- **`CodeDeliveryDetails` present:** Cognito sent a confirmation code to that medium and destination (masked). Ask for it and send `ConfirmSignUp` (`ClientId`, `Username`, `ConfirmationCode`), offering `ResendConfirmationCode` (`ClientId`, `Username`).
- **`CodeDeliveryDetails` absent:** `check_invite` already confirmed the account (SMS off). There is nothing to enter.

Either way the account is now confirmed and can sign in. The sign-up screens tell the user it is pending admin approval. In practice that approval is the domain grant: access to mail domains is an allow list (`cabal-user-domain-access`), so a new account can create no addresses until an admin grants it one or more domains in the Users view. An account whose owner never entered the code stays `UNCONFIRMED`, and an admin can confirm it from the same view.

## Sign-in

`InitiateAuth` with `AuthFlow: USER_PASSWORD_AUTH`, `ClientId`, and `AuthParameters: {USERNAME, PASSWORD}`. SRP is not used.

The reply is either `AuthenticationResult` (`IdToken`, `AccessToken`, `RefreshToken`, `ExpiresIn`), or a challenge:

- **`SOFTWARE_TOKEN_MFA` or `SMS_MFA`:** ask for the code, then send `RespondToAuthChallenge` with `ChallengeName`, `ClientId`, the `Session` from the challenge, and `ChallengeResponses: {USERNAME, SOFTWARE_TOKEN_MFA_CODE | SMS_MFA_CODE}`. Answer with the `USERNAME` Cognito resolved (`ChallengeParameters.USER_ID_FOR_SRP`), not what was typed. For SMS, `ChallengeParameters.CODE_DELIVERY_DESTINATION` says where the code went. A wrong code can be retried against the same session; an expired session means starting over. The challenge lives in memory only, so a reload or relaunch mid-challenge restarts the sign-in.
- **Anything else** (`NEW_PASSWORD_REQUIRED`, `MFA_SETUP`): nothing the pool produces for a self-service user. Fail the sign-in.

### The MFA gate

`require_admin_mfa` runs on every token issue, sign-in and refresh alike, and can refuse tokens to an account with no MFA factor. It enforces separately for admins (`TF_VAR_ENFORCE_ADMIN_MFA`) and for everyone else (`TF_VAR_ENFORCE_USER_MFA`, with a grace window for new accounts). When enforcement is off it only logs; see [GitHub variables](./github.md). A refusal comes back as `PreTokenGeneration failed with error This account requires multi-factor authentication. ...`.

An un-enrolled user who is refused can never get a session through the normal client, so the gate lets one other client through: the enrollment client. The webmail's locked-out setup uses it:

1. `InitiateAuth` (`USER_PASSWORD_AUTH`) through `enrollClientId` with the password just typed. If that draws an MFA challenge instead, the account already has a factor; send the user back to the normal sign-in.
2. `AssociateSoftwareToken` with that client's access token. Show the secret as an `otpauth://` QR code and as text.
3. `VerifySoftwareToken` (`UserCode`, `FriendlyDeviceName: Cabalmail`). Treat any `Status` other than `SUCCESS` as a wrong code.
4. `SetUserMFAPreference` with `SoftwareTokenMfaSettings: {Enabled: true, PreferredMfa: true}`.
5. Discard those tokens and sign in normally. That sign-in now draws a TOTP challenge.

The enrollment tokens live five minutes. They stay in memory for the setup and are never persisted.

### After sign-in

Two advisory checks follow a successful sign-in, at most one per sign-in, email first. One `GetUser` (the access token) answers both:

- **An `email` whose `email_verified` is not `"true"`:** offer to verify it. **No `email`:** offer to add one, unless `sms_enabled` and `phone_number_verified` is `"true"`, in which case the phone already recovers the account and nothing is asked. Adding one is `UpdateUserAttributes`, which makes Cognito send a code because the pool auto-verifies email. A new code is `GetUserAttributeVerificationCode`; the code itself goes to `VerifyUserAttribute`, all for `AttributeName: email`. The user can skip.
- **`UserMFASettingList` lacks `SOFTWARE_TOKEN_MFA`:** suggest setting up an authenticator. Skip this when the sign-in itself just answered a TOTP challenge.

A failed `GetUser` never blocks the sign-in.

## Session

The ID token authorizes API calls (`Authorization: <IdToken>`). The access token authorizes the self-service user operations above. Refresh with `InitiateAuth`, `AuthFlow: REFRESH_TOKEN_AUTH`, `AuthParameters: {REFRESH_TOKEN}`. The reply omits `RefreshToken` unless Cognito rotated it, so keep the old one otherwise. Refresh a few minutes before expiry rather than after, so a token isn't handed to a call that outlives it (the webmail and Android use five minutes, Apple 30 seconds). Serialize refreshes, because concurrent callers must share one. If Cognito refuses a refresh outright, the session is over and the user signs in again. A network failure, throttling or a 5xx is not a refusal; keep the session and retry later.

Where each client keeps the session:

| Client | ID and access tokens | Refresh token |
| --- | --- | --- |
| Webmail | Memory only | `sessionStorage` (`cabal.auth.session`, with the username): a reload restores by refreshing, while a new tab, or a tab closed and reopened, signs in again. Never `localStorage`. |
| Apple | Keychain (`kSecAttrAccessibleAfterFirstUnlock`) | Keychain |
| Android | `SharedPreferences`, encrypted under an Android Keystore AES-GCM key | Same |
| Browser extension | `browser.storage.local` | Same |

Sign-out discards the stored session on the device. No client calls `RevokeToken` or `GlobalSignOut` today, so a refresh token copied off a device stays valid until it expires. An operator can end every session for a user with `admin-user-global-sign-out`.

## Admin recognition

A client may show admin features when the ID token's `cognito:groups` claim contains the `admin` group. Decode the payload as base64url, then as UTF-8 JSON. There's no signature check: the token came from Cognito over TLS, and this is a display hint. Match `admin` as a whole element. Cognito puts a JSON array in the token, and API Gateway's string renderings (`admin,users`, `[admin users]`) are split on commas and whitespace, so `nonadmin` or `admin-readonly` never counts. Re-derive it on every token change: sign-in, refresh, sign-out, account switch. A 403 from the server overrides whatever the client concluded.

## Password reset

`ForgotPassword` (`ClientId`, `Username`). The reply's `CodeDeliveryDetails` says whether the code went to email or phone; say so rather than assuming. Then `ConfirmForgotPassword` (`ClientId`, `Username`, `ConfirmationCode`, `Password`). A user with no verified email or phone cannot reset; an operator sets a password with `admin-set-user-password`.

## Recovery email

Signed in, a user can see, add, change and verify their recovery email: `GetUser` reads `email` and `email_verified`, `UpdateUserAttributes` saves a new address (Cognito sends it a code, as the pool auto-verifies email), `GetUserAttributeVerificationCode` sends a fresh code, and `VerifyUserAttribute` takes it, all for `AttributeName: email` with the user's access token. The pool keeps no pending value, so a change replaces a verified address at once with an unverified one; say so before the user saves. For a phone-only account this is the only way to add an address after sign-up, since the check after sign-in no longer asks it.

## TOTP management

Signed in, a user can turn TOTP on with `AssociateSoftwareToken`, then `VerifySoftwareToken`, then `SetUserMFAPreference` (`Enabled` and `PreferredMfa` true), all with their own access token. Turning it off is `SetUserMFAPreference` with both false. `GetUser`'s `UserMFASettingList` reports the current state.

## What each client implements

| | Webmail | Apple | Android | Browser extension |
| --- | --- | --- | --- | --- |
| Sign-in, TOTP and SMS challenges | Yes | Yes | Yes | Hosted UI |
| Refresh | Yes | Yes | Yes | Yes, via the Hosted UI token endpoint |
| Sign-up, confirm, resend | Yes | Kit only, with no UI and no invitation code | Kit only, with no UI and no invitation code | No |
| Forgot and reset password | Yes | Kit only, no UI | Kit only, no UI | No |
| Recovery-email check | Yes | No | No | No |
| Recovery email in settings (add, change, verify) | Yes (Security) | No | No | No |
| Enrollment suggestion | Yes | No | No | No |
| Locked-out TOTP setup | Yes | No | No | No |
| TOTP on and off (Security settings) | Yes | Kit only, no UI | No | No |
| Admin recognition | Yes | Yes: Settings lists Users for an admin | Yes: Settings lists Users for an admin | No |
| Users view (admin) | Yes | Yes (Settings → Users) | Yes (Settings → Users) | No |

The native gaps are planned in [the auth parity plan](./1.x/auth-parity-plan.md): sign-up (B1–B3), the recovery-email check (B4), and the other admin views. The Linux client's sign-in, MFA and refresh are in progress against this contract ([Linux client plan](./1.x/linux-client-plan.md)).

The webmail's implementation is `react/admin/src/auth/`, the Apple kit's is `apple/CabalmailKit/Sources/CabalmailKit/Auth/`, and the Android kit's is `android/kit/src/main/kotlin/com/cabalmail/kit/auth/`. The extension's Hosted UI flow is in `extensions/shared/src/auth/`.
