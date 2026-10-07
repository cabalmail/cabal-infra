# Auth Parity Plan — Webmail Off `amazon-cognito-identity-js`, Native Sign-Up, Native Admin Recognition

## Context

AWS has announced the end of support for the Amplify JavaScript v5
ecosystem: maintenance mode from 2026-09-01, end of support on
**2027-03-01**. The notice names `amazon-cognito-identity-js`
explicitly, and that is the one Amplify-ecosystem package in the
repository: the React webmail's entire Cognito surface goes through it
(`react/admin/src/App.jsx`). Nothing else is affected. The browser
extension uses the Hosted UI with PKCE, and the Apple and Android
clients speak Cognito's JSON API directly (`CognitoAuthService` in each
kit). After the deadline the library keeps working but receives no
fixes, including security fixes.

AWS's suggested path is Amplify v6 (`aws-amplify/auth`). This plan
takes the other one: drop the library and call the Cognito JSON API
directly, as the native clients already do. Every webmail auth
operation is one JSON call; the result is a small first-party module
with no AWS JavaScript dependency to chase through future end-of-support
cycles, and all three clients then share one auth flow. Amplify v6 would
also store tokens in `localStorage` by default, so it would need a
custom token store anyway (see decision D2).

Two further goals ride on that parity:

- **Sign-up without webmail.** Today an account can only be created in
  the webmail. Both native kits declare `signUp` / `confirmSignUp`, but
  no screen calls them, and as written they would fail against the pool
  (no invitation code; see Phase B1).
- **Admin recognition in the native clients**, so admin-only features
  (today: webmail's Users, Addresses (all users), DMARC and CAA views)
  can migrate to the native clients one at a time.

The three workstreams are independent. Only A carries the deadline;
B and C build on the native kits' existing JSON clients and do not wait
for A.

## Progress

| Phase | Work item                                                        | Status      |
| ----- | ---------------------------------------------------------------- | ----------- |
| A1    | Webmail: Cognito JSON client module + tests                      | Not started; blocked on D2 |
| A2    | Webmail: port `App.jsx` flows, drop the dependency               | Not started |
| A3    | Promote the auth contract below to `docs/auth.md`                | Not started |
| B1    | Native kits: sign-up contract fixes (Apple + Android)            | Not started |
| B2    | Apple: sign-up, confirm and resend screens                       | Not started |
| B3    | Android: sign-up, confirm and resend screens                     | Not started |
| B4    | Native: recovery-email gate after sign-in                        | Not started |
| C1    | Native kits: `isAdmin` from the ID token's `cognito:groups`      | Not started |
| C2    | Native: first admin feature — Users (approve, disable, delete)   | Not started |

Tracking issues: A #1950, B #1951, C #1952.

## Decisions

**D1 — Sign-in flow: `USER_PASSWORD_AUTH` everywhere.** The native
clients already use it. The webmail uses the library's default,
`USER_SRP_AUTH` (`App.jsx` never calls `setAuthenticationFlowType`).
The pool clients (`cabal_admin_client`, `cabal_mfa_enroll_client`)
declare the legacy `explicit_auth_flows = ["USER_PASSWORD_AUTH"]`,
which permits SRP, password and refresh alike, so no Terraform change
is needed for A, and a later move to `ALLOW_*` values can drop SRP once
no client uses it. SRP's advantage (the password never leaves the
browser) is small next to TLS to Cognito, and implementing SRP by hand
is the one piece of this work that would justify keeping a library.

**D2 — Webmail session persistence. OPEN; blocks A1.** `CLAUDE.md`
says auth tokens live in a module-level variable in `App.jsx` and are
never written to `localStorage`. That is true of `_token`, but the
library itself persists the ID, access and refresh tokens to
`localStorage` (`CognitoIdentityServiceProvider.<clientId>.*` keys,
since `App.jsx` passes no `Storage` in `poolData`), and the reload
restore at `App.jsx:309` (`getCurrentUser()` + `getSession`) depends on
it: a reload within the refresh token's 7 days lands signed in. The
port has to pick a behaviour on purpose:

- (a) Keep the refresh token in `localStorage`, written explicitly by
  our module, and correct the `CLAUDE.md` rule to say so. Same UX as
  today.
- (b) `sessionStorage`. Survives a reload, not a closed tab or a new
  tab. Smaller exposure window; new tabs sign in again.
- (c) Memory only. Every reload signs in again (with TOTP).

Recommendation: (b). The webmail is the secondary client, and a new
tab asking for a sign-in is a modest cost for not keeping a 7-day
credential in long-lived storage. Whatever is chosen, the `CLAUDE.md`
sentence is rewritten in the same PR to describe it.

**D3 — Native admin recognition is a UI hint only.** Clients read the
ID token's `cognito:groups` claim the way the webmail does
(`App.jsx:316`) to decide what to show. Authorization stays on the
server (`lambda/api/_shared/admin_limits.py`, whole-element matching).
A client never sends its own idea of admin-ness anywhere.

**D4 — The invitation code is the only sign-up gate.** Confirmed by
the operator 2026-10-07: an invitation code, then admin approval of the
new account. Native sign-up matches the webmail exactly; no new gate,
no client-side policy beyond what `/config.js` advertises.

## The auth contract

What every client does, as the webmail implements it today. Phase A3
moves this section to `docs/auth.md` once A ships; until then this is
the reference B and C are checked against.

**Configuration** (`/config.js`, from
`terraform/infra/modules/app/templates/config.js.tftpl`):
`cognitoConfig.region`, `poolData.UserPoolId`, `poolData.ClientId`,
`enrollClientId`, `invitation_required`, `sms_enabled`.

**Transport.** `POST https://cognito-idp.<region>.amazonaws.com/`,
`Content-Type: application/x-amz-json-1.1`,
`X-Amz-Target: AWSCognitoIdentityProviderService.<Operation>`. Errors
come back as `{"__type": "...Exception", "message": "..."}`.

**Sign-up** (`SignUp`):
- `Username`, `Password`, `UserAttributes`: `preferred_username`
  (= username), `email` (always), `phone_number` only when
  `sms_enabled`.
- `ValidationData`: `[{"Name": "invitationCode", "Value": <code>}]`.
  The `check_invite` pre-sign-up Lambda compares it; a mismatch
  surfaces as `UserLambdaValidationException` with "Invalid invitation
  code." Sent as validation data so it never lands on the user record.
- Outcome, from the response's `CodeDeliveryDetails`:
  - present: a code went to that medium/destination; show the confirm
    screen (`ConfirmSignUp`, `ResendConfirmationCode`).
  - absent: `check_invite` auto-confirmed the account (SMS off); show
    "Account created. It is pending admin approval."
- After confirmation the account is pending admin approval either way.

**Sign-in** (`InitiateAuth`, `USER_PASSWORD_AUTH`):
- Challenges `SOFTWARE_TOKEN_MFA` / `SMS_MFA` answered with
  `RespondToAuthChallenge`, echoing `Session` and `USERNAME`.
- The `require_admin_mfa` pre-token-generation trigger can refuse an
  un-enrolled user ("admin accounts require..."); the webmail then
  offers the locked-out TOTP setup through `enrollClientId`
  (`AssociateSoftwareToken` / `VerifySoftwareToken` /
  `SetUserMFAPreference` on that client's short-lived tokens).
- After sign-in, two advisory gates, email first, one per sign-in:
  no verified recovery email (`GetUser` → `email` /
  `email_verified`; `UpdateUserAttributes`,
  `GetUserAttributeVerificationCode`, `VerifyUserAttribute`), then no
  MFA factor (enrollment nudge). A failed metadata read never blocks
  the sign-in.

**Session.** ID token on API calls; refresh with
`InitiateAuth` / `REFRESH_TOKEN_AUTH`. Persistence per platform (D2
for the webmail; Keychain / encrypted store on native).

**Admin.** `cognito:groups` in the ID token payload contains `admin`
(D3). Re-derived on every token change, including refresh and account
switch.

**Password reset.** `ForgotPassword` (report the delivery medium from
`CodeDeliveryDetails`), `ConfirmForgotPassword`.

## Phase A — Webmail

### A1 — Cognito JSON client module

**Status:** Not started; blocked on D2.

A module under `react/admin/src/auth/` exposing promise-returning
functions for every operation in the contract, plus a token holder that
implements the D2 choice and a single-flight refresh. No React in it;
Vitest tests against a stubbed `fetch` for each operation's request
shape and each documented error mapping (invalid invitation code, wrong
MFA code, `NotAuthorizedException`, the `require_admin_mfa` refusal).

### A2 — Port `App.jsx`, remove the dependency

**Status:** Not started.

Replace every `CognitoUser` / `CognitoUserPool` / `CognitoUserAttribute`
use in `App.jsx` with the A1 module. Behaviour is unchanged apart from
D1 and D2. Today's `checkSession` signs the user out when the 12-hour
ID token expires; the port refreshes instead, which is what the native
clients do. Remove `amazon-cognito-identity-js` from `package.json`
and the lockfile, rewrite the `CLAUDE.md` token-storage sentence, and
add a `changed` changelog fragment. Verify on stage as the shared
tester account: sign-up with and without a valid code, TOTP sign-in,
locked-out enrollment, forgot password, the email gate, a reload, an
idle refresh, and admin views appearing for an admin only.

### A3 — Promote the contract

**Status:** Not started.

Move "The auth contract" to `docs/auth.md`, link it from
`docs/operations.md`, and leave a pointer here.

## Phase B — Native sign-up

### B1 — Kit contract fixes (Apple and Android)

**Status:** Not started.

Both `signUp` implementations (`AuthService.swift`,
`CognitoAuthService.kt`) need: `preferred_username`; an
`invitationCode` parameter sent as `ValidationData`; a return value
that distinguishes "code sent to <medium, destination>" from
"auto-confirmed, pending approval"; a typed error for an invalid
invitation code. The kits' config models read `invitation_required`
and `sms_enabled` so the screens can hide the invitation and phone
fields when they are not needed. Kit tests on each side pin the
request body against the contract. Protocol changes update every
conformer, including the shared test doubles.

### B2 / B3 — Sign-up screens

**Status:** Not started.

A "Create account" entry on each sign-in screen, using the control
domain already typed there. Screens: sign-up form (username, password,
recovery email, invitation code when required, phone when
`sms_enabled`), confirm-code with resend, and the pending-approval
result. Apple and Android land as separate PRs, Apple first.

### B4 — Recovery-email gate

**Status:** Not started.

Neither native client checks for a verified recovery email after
sign-in. A natively created account (B2/B3) with SMS on would never be
asked to verify its email, so this lands with or right after B2/B3.
Same advisory rules as the webmail.

Locked-out TOTP enrollment through `enrollClientId` is the remaining
native gap. Android's config already carries the field. It only
matters once an MFA gate is enforced, so it is noted here and not
scheduled.

## Phase C — Native admin recognition

### C1 — `isAdmin` in the kits

**Status:** Not started.

Decode the ID token payload (base64url JSON, no signature check; the
token came from Cognito over TLS and D3 makes it a hint), expose
`isAdmin` alongside the existing token observers, and re-derive it on
refresh, sign-out and account switch. Kit tests cover the claim
renderings `admin_limits.is_admin` accepts and a group whose name only
contains "admin".

### C2 — First admin feature: Users

**Status:** Not started.

The webmail's Users view on native: list users (`/list_users`),
approve (`/confirm_user`), enable/disable, delete, and per-user domain
access (`/list_user_domain_access`, `/set_user_domain_access`). It
pairs with B: someone signs up on a phone and an admin approves them
from theirs. Shown only when `isAdmin`; a 403 from the server is
treated as the authority. The other admin views (all-user Addresses,
DMARC, CAA) are later work and out of scope here.
