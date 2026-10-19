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
| A1    | Webmail: Cognito JSON client module + tests                      | Done 2026-10-18 (#2103) |
| A2    | Webmail: port `App.jsx` flows, drop the dependency               | Done 2026-10-18 (#2107, #2116) |
| A3    | Promote the auth contract to `docs/auth.md`                      | Done 2026-10-18 |
| B1    | Native kits: sign-up contract fixes (Apple + Android)            | Not started |
| B2    | Apple: sign-up, confirm and resend screens                       | Not started |
| B3    | Android: sign-up, confirm and resend screens                     | Not started |
| B4    | Native: recovery-email gate after sign-in                        | Not started |
| C1    | Native kits: `isAdmin` from the ID token's `cognito:groups`      | Done 2026-10-18 (#2124, #2126) |
| C2    | Native: first admin feature — Users (approve, disable, delete)   | Done 2026-10-18 (#2127, #2128) |

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

**D2 — Webmail session persistence: `sessionStorage`.** Decided by
the operator 2026-10-18. The refresh token and the username go to
`sessionStorage`; the ID and access tokens stay in memory; nothing
goes to `localStorage`. A reload stays signed in by refreshing; a new
tab, or a tab closed and reopened, signs in again (with TOTP).

Why it had to be decided: `CLAUDE.md` says auth tokens live in a
module-level variable in `App.jsx` and are never written to
`localStorage`. That is true of `_token`, but the library itself
persists the ID, access and refresh tokens to `localStorage`
(`CognitoIdentityServiceProvider.<clientId>.*` keys, since `App.jsx`
passes no `Storage` in `poolData`), and the reload restore at
`App.jsx:309` (`getCurrentUser()` + `getSession`) depends on it: a
reload within the refresh token's 7 days lands signed in. The
alternatives were keeping the refresh token in `localStorage` (today's
UX, with the `CLAUDE.md` rule corrected) and memory only (every reload
signs in again). `sessionStorage` was chosen because the webmail is
the secondary client, and a new tab asking for a sign-in is a modest
cost for not keeping a 7-day credential in long-lived storage. A2
rewrites the `CLAUDE.md` sentence to describe it.

**D3 — Native admin recognition is a UI hint only.** Clients read the
ID token's `cognito:groups` claim the way the webmail does
(`App.jsx:316`) to decide what to show. Authorization stays on the
server (`lambda/api/_shared/admin_limits.py`, whole-element matching).
A client never sends its own idea of admin-ness anywhere.

**D4 — The invitation code is the only sign-up gate.** Confirmed by
the operator 2026-10-07: an invitation code, then admin approval of the
new account. Native sign-up matches the webmail exactly; no new gate,
no client-side policy beyond what `/config.js` advertises.

**D5 — Contacts at sign-up: a phone with SMS, an email without.**
Decided by the operator 2026-10-18, so that Cabalmail can be someone's
only email service. With `sms_enabled`, the phone (with SMS consent) is
required and the recovery email is optional. Without it, the email is
required, since it is then the only channel that can verify or recover
the account. After sign-in, an account with no email is asked to add
one unless SMS is on and its phone is verified; an email the user gave
is always offered for verification. The cost is that a phone-only
account recovers by SMS alone, so a SIM swap could reset its password;
the authenticator suggestion is its defence. The webmail implements it
(the PR that recorded this decision), including a recovery-email
section in its Security view so a phone-only account can still add an
address later, and `docs/auth.md` carries the rule. B1's kits take both contacts as optional, so the rule lives in
the screens.

## The auth contract

Moved to [`docs/auth.md`](../auth.md) in A3 (2026-10-18), which also
records what each client implements today. B and C are checked against
it there.

## Phase A — Webmail

### A1 — Cognito JSON client module

**Status:** Done 2026-10-18 (#2103). Nothing imports it yet; A2 wires it in.

A module under `react/admin/src/auth/` exposing promise-returning
functions for every operation in the contract, plus a token holder that
implements the D2 choice and a single-flight refresh. No React in it;
Vitest tests against a stubbed `fetch` for each operation's request
shape and each documented error mapping (invalid invitation code, wrong
MFA code, `NotAuthorizedException`, the `require_admin_mfa` refusal).

As built (`index.js` re-exports all of it):

- `cognito.js`: `clientsFromConfig(cognitoConfig)` returns the main
  client and the enrollment client (null when `/config.js` has no
  `enrollClientId`). Each client has `signUp`, `confirmSignUp`,
  `resendConfirmationCode`, `signIn`, `respondToMfaChallenge`,
  `refresh`, `forgotPassword`, `confirmForgotPassword`, `getUser` (the
  attributes and the MFA list in one call), `updateUserAttributes`,
  `getUserAttributeVerificationCode`, `verifyUserAttribute`,
  `associateSoftwareToken`, `verifySoftwareToken` and
  `setSoftwareTokenMfa`. `signIn` resolves to `{status: 'signed-in',
  tokens}` or `{status: 'mfa', mfa: 'totp' | 'sms', challenge}`; the
  challenge is a plain value, so A2 keeps it in a ref where the
  library kept a `CognitoUser`. Code deliveries come back as `{medium:
  'email' | 'phone', destination}`.
- `session.js`: `createSession({client})` with `establish(tokens,
  username)` after a sign-in, `restore()` on load, `idToken()` /
  `accessToken()` (each refreshes when the token has under five
  minutes left), `current()` for render-time reads, `clear()` and
  `subscribe(listener)`. A refresh Cognito refuses (any 4xx but
  throttling) ends the session with `SessionExpired`. A network
  failure or a 5xx keeps the session for the next try. A refresh still
  in flight across a sign-out or an account switch is discarded rather
  than written back.
- `errors.js`: `CognitoError` carries the exception name in both
  `code` and `name`, as the library's errors did, so
  `signUpErrorMessage` and the `LimitExceededException` checks in
  `App.jsx` work unchanged. Predicates: `isInvalidInvitationCode`,
  `isMfaEnrollmentRequired`, `isCodeMismatch`, `isNotAuthorized`,
  `isLimitExceeded`, `isSignInRequired`.
- `jwt.js`: `isAdminToken(idToken)` matches the `admin` group as a
  whole element, as `admin_limits.is_admin` does. `decodeJwtPayload`
  decodes base64url and UTF-8. `App.jsx`'s `atob` read does neither: it
  can throw on a claim holding `~`, `?` or `>`, and it garbles
  non-ASCII text.

Checked live against the stage pool on 2026-10-18 (no account
created): a sign-up with a wrong invitation code maps to
`isInvalidInvitationCode` and `signUpErrorMessage` words it, and a
sign-in for an unknown username maps to `isNotAuthorized`.

### A2 — Port `App.jsx`, remove the dependency

**Status:** Done 2026-10-18: #2107, merged to stage only after the
batch ahead of it was promoted, so A2 soaks and releases on its own,
and #2116 (below). Checked
live on 2026-10-18 against the stage pool, with the A2 bundle served at
the stage origin and signed in as the second test account: sign-up
with a wrong invitation code, forgot password (code sent, not used), a
wrong password, the TOTP challenge with a wrong and then the right code,
the Security view, a reload restoring without the sign-in form, a new
tab starting signed out, the legacy-key purge, an idle tab refreshing
before expiry (page clock jumped forward), and sign-out. Neither test
account is an admin, so admin views were checked hidden only. Three
checks rest on `App.test.jsx` alone: a valid-code sign-up (it would
leave an account nobody here can delete), locked-out enrollment (both
test accounts are enrolled), and the admin case.

Replace every `CognitoUser` / `CognitoUserPool` / `CognitoUserAttribute`
use in `App.jsx` with the A1 module. Behaviour is unchanged apart from
D1 and D2. On load, also remove the library's leftover
`CognitoIdentityServiceProvider.*` keys from `localStorage`: a user
signed in before the port still has a 7-day refresh token there, and
D2 says none stays. Today's `checkSession` signs the user out when the 12-hour
ID token expires; the port refreshes instead, which is what the native
clients do. Remove `amazon-cognito-identity-js` from `package.json`
and the lockfile, rewrite the `CLAUDE.md` token-storage sentence, and
add a `changed` changelog fragment. Verify on stage as the shared
tester account: sign-up with and without a valid code, TOTP sign-in,
locked-out enrollment, forgot password, the email gate, a reload, an
idle refresh, and admin views appearing for an admin only.

As built:

- Behaviour beyond D1 and D2, all small: an expired MFA challenge
  (`NotAuthorizedException` on the answer) restarts the sign-in
  instead of repeating "That code did not match"; a submit before
  `/config.js` has loaded, or after it failed, gets a banner instead
  of nothing; a reload shows a placeholder while it restores instead
  of flashing the sign-in form.
- `loadSavedState` starts every load signed out on a logged-out view.
  The `state` bag in `localStorage` is shared by every tab, so its
  `loggedIn` says nothing about a tab whose session lives in that
  tab's `sessionStorage`.
- The token and `isAdmin` come from the session's snapshot
  (`subscribe`), so they follow every refresh and sign-out. The
  session check runs on render, on focus and on a one-minute timer,
  and refreshes through `session.idToken()`.
- The Security view's `mfaApi` keeps its callback contract, so the
  view is unchanged.
- `vite.config.js`'s `define: { global: 'globalThis' }` and the
  `js-cookie` override existed only for the library and are gone.
- `App.test.jsx` drives the real auth screens against a stubbed
  Cognito: every flow above, plus reload, refusal, idle refresh,
  sign-out and the legacy-key purge. Mutation-checked.
- Stage and prod serve a React development build (#2115: `app.yml`
  sets `NODE_ENV` to the environment's name, which Vite honours), so
  `React.StrictMode` runs mount effects twice there. Once deployed,
  that showed up as two sessions and two refreshes per reload. #2116
  guards the bootstrap effect with a ref, and adds a StrictMode test.
  The fix for #2115 drops `NODE_ENV` from the build step, and
  `vite build` now refuses any value other than `production`, so the
  build checked locally is the build CI ships.

### A3 — Promote the contract

**Status:** Done 2026-10-18.

Move "The auth contract" to `docs/auth.md`, link it from
`docs/operations.md`, and leave a pointer here. As built, `docs/auth.md`
also covers the pool's app clients and triggers, the error mapping,
where each client keeps its session, and a per-client implementation
table. The table's gaps are B and C. The sign-up wording "pending admin
approval" maps to the domain grant: a new account is confirmed at once
but can create no addresses until an admin grants it mail domains.

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
invitation code when required, and the contacts D5 sets: with
`sms_enabled` a required phone with consent and an optional recovery
email, otherwise a required recovery email), confirm-code with resend,
and the pending-approval result. Apple and Android land as separate
PRs, Apple first.

### B4 — Recovery-email gate

**Status:** Not started.

Neither native client checks for a verified recovery email after
sign-in. A natively created account (B2/B3) with SMS on that gave an
email would never be asked to verify it, so this lands with or right
after B2/B3. Same advisory rules as the webmail, which D5 sets: no ask
to add an email when SMS is on and the phone is verified. Because a
phone-only account is then never asked, B4 also adds a recovery-email
row to each client's settings, as the webmail's Security view has
(`docs/auth.md`, "Recovery email").

Locked-out TOTP enrollment through `enrollClientId` is the remaining
native gap. Android's config already carries the field. It only
matters once an MFA gate is enforced, so it is noted here and not
scheduled.

## Phase C — Native admin recognition

### C1 — `isAdmin` in the kits

**Status:** Done 2026-10-18: Apple #2124, Android #2126.

Decode the ID token payload (base64url JSON, no signature check; the
token came from Cognito over TLS and D3 makes it a hint), expose
`isAdmin` alongside the existing token observers, and re-derive it on
refresh, sign-out and account switch. Kit tests cover the claim
renderings `admin_limits.is_admin` accepts and a group whose name only
contains "admin".

As built (Apple): `IdTokenClaims(idToken:)` in
`CabalmailKit/Auth/IdTokenClaims.swift` (`groups`, `isAdmin`), plus
`AuthTokens.isAdmin` and an `AuthService.isAdmin()` protocol
extension. The extension computes the answer from `currentTokens()` on
every call rather than caching it, so it follows a refresh (a group
granted or removed shows up in the next token Cognito issues), a
sign-out, and an account switch (an ended session reads no tokens),
with no new protocol requirement for the test doubles. Nothing in the
app reads it yet. C2 decides where the admin views appear and reads it
at session start. `TestFixtures.idToken(claims:)` builds unsigned test
tokens.

As built (Android, #2126): the same shape in
`kit/.../auth/IdTokenClaims.kt`. `AuthTokens.isAdmin` is an extension
property, so the serialized token format is untouched, and
`AuthService.isAdmin()` is an extension function, so the app's fakes
gain no interface member. `testIdToken(claimsJson)` builds test tokens.

### C2 — First admin feature: Users

**Status:** Done 2026-10-18: Apple #2127, Android #2128.

The webmail's Users view on native: list users (`/list_users`),
approve (`/confirm_user`), enable/disable, delete, and per-user domain
access (`/list_user_domain_access`, `/set_user_domain_access`). It
pairs with B: someone signs up on a phone and an admin approves them
from theirs. Shown only when `isAdmin`; a 403 from the server is
treated as the authority. The other admin views (all-user Addresses,
DMARC, CAA) are later work and out of scope here.

As built (Apple):

- **Where it lives:** a Users category in Settings (the operator's
  choice, 2026-10-18), listed only while `SessionManager.isAdmin` is
  true. That flag is read from the token when the session is wired,
  before it reads as signed in. It's read again on each return to the
  foreground and after any 403, and cleared at sign-out. Later admin
  views become sibling categories in `CabalmailUI/Admin/`.
- **The list:** accounts awaiting confirmation (any Cognito status but
  `CONFIRMED`, as in the webmail), then confirmed ones. Each row pushes a
  page with status, sign-in state, created date, mail user ID, Confirm
  or Enable/Disable, Delete (confirmed in a dialog), and one toggle per
  configured mail domain. Toggles are optimistic and move back if the
  server refuses.
- **Guards:** the admin's own account offers no Disable or Delete. The
  server refuses self-delete, and self-disable would lock them out.
  `master`, `dmarc` and `ci-probe`, the accounts `require_admin_mfa`
  exempts, are hidden. The webmail hides only the first two.
- **Errors:** a failed action shows in an alert, since the macOS Settings
  window has no toast host. A 403 shows "Administrators only" and re-reads
  `isAdmin`.
- **Not included:** address assignment, which the webmail's Users view
  also offers. It belongs with the all-user Addresses view.
- **Replay verdicts:** `docs/request-replay.md` has the five writes.
  `confirm_user` and `delete_user` are sent once, because a second copy
  answers 500 for work the first did. `enable_user`, `disable_user` and
  `set_user_domain_access` are sent again.

As built (Android, #2128): the same screens and guards, in `ui/admin/`.

- **Where it lives:** a `USERS` settings category, listed by
  `SettingsCategory.listed(isAdmin)`. `UsersScreen` is Settings' Users
  pane, and `UserDetailScreen` sits on a `users/{username}` route that
  shares the pane's view model, the way the rules editor does.
- **The admin flag:** `SettingsUiState.isAdmin` is read when
  `SettingsViewModel` starts and again each time Settings enters
  composition.
- **The 403 path:** a 403 sets the Users state's `accessDenied`, and the
  settings route re-reads the flag.
- **Errors:** failed actions are typed errors that the screens word as
  snackbars from `strings.xml`.
- **Android has no request-replay table** like the Apple kit's. The
  client's own retry is the one 401 replay every call gets. Whatever OkHttp
  does on a failed connection applies to these writes as to every other.
