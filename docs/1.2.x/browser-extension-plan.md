# Browser Extension Plan (Address-Suggesting Plugin)

## Context

Cabalmail's signature user behavior is per-vendor (or per-purpose) email addresses: spin one up before signing up for a new service, burn it when it goes bad. Today that flow lives in the React admin app (`react/admin/src/Addresses/Request.jsx`) and the native clients (`apple/`, the planned `android/`). The user must context-switch to a Cabalmail surface, generate or hand-craft an address, copy it, switch back to the signup tab, and paste.

This version introduces a browser extension that collapses that flow into the sign-up form itself, in the same way 1Password's "Suggest strong password" UI collapses password generation into the sign-up form. The extension has two responsibilities:

1. **Suggest.** When the user lands on a sign-up form, detect the email field and offer a one-click insert of a freshly generated Cabalmail address on an apex domain the user is entitled to use. The address is created eagerly when the user commits to it (clicks "Use this address" in the popover) so that DNS and the sendmail tier have runway to converge before any verification mail arrives; addresses the user abandons without submitting are revoked by a TTL reaper, with the procmail-based clear-on-receive hook as the high-confidence "address really is in use" signal in between.
2. **Adopt.** If the user manually types an address that parses as `<local>@<subdomain>.<apex>` where `<apex>` is one of the user's authorized apex domains and the full address is not already in their list, offer to create the address before they submit the form. The address is created at the moment the user accepts the offer (same eager-create model as Suggest). The only path that blocks submission is the typed-and-ignored case where the user dismisses the offer banner *and* hits submit -- there we hold the submit and surface a modal warning, since otherwise the destination service would receive a not-yet-deliverable address.

Out of scope for 1.2.x:
- Saving site-to-address mappings, breach alerts, "show me what I gave this site," vault sync. Those are future work; the MVP is *generate and insert*, not a relationship store.
- Filling existing addresses on **sign-in** forms (i.e. the autofill counterpart). The extension only operates on sign-up forms in 1.2.x. Storing which address was minted for which site is the natural prerequisite, and lives in a later version.
- Replacing the address-management UI in the admin app, on Apple, or on Android. The extension is an *additional* surface, not a replacement.
- Firefox, Edge, Brave, Opera, Arc, and other Chromium/Gecko derivatives. The MV3 build will likely run on most Chromium derivatives unchanged, but only Chrome and Safari are validated and shipped.

## Approach

Seven phases: shared core; CI/CD (early, so every subsequent phase runs through it); auth and API; form detection; suggest flow; adopt flow; platform targets and distribution.

### Guiding principles

- **One codebase, two manifests.** Safari Web Extensions and Chrome MV3 share the same `manifest.json` schema, the same content-script model, the same `chrome.*`/`browser.*` API surface (Safari implements the WebExtensions API). The differences are real but localized: Safari packaging is an Xcode app extension target, Chrome packaging is a `.zip` uploaded to the Web Store. All extension *logic* lives in a single TypeScript codebase. Per-platform code is confined to packaging glue.
- **API-backed, no direct IMAP/SMTP.** The extension only ever touches the Lambda API surface. It does not parse mail, it does not connect to IMAP, it does not generate DKIM. The eager-create-and-reap model does require additive backend work (Phase 3.1): one extension to `POST /new`, a new `POST /confirm_address` endpoint, a scheduled reaper Lambda, and a procmail-based clear-on-receive hook on the IMAP tier. All purely additive and direct-to-prod-scaffolding-eligible per CLAUDE.md.
- **Generate locally, create eagerly, reap on abandon.** Random address generation mirrors `react/admin/src/Addresses/Request.jsx` lines 69-71 exactly: 8-char local part (first/last alphanumeric, middle allows `._-`), 8-char subdomain (first/last alphanumeric, middle allows `-` only). Generation is pure client-side -- refreshing the suggestion does not hit the API. *Commit* (the user clicking "Use this address") creates the address immediately, ahead of form submit. This avoids the verification-email race: most sign-up backends send a verification mail within seconds of form submission, and a brand-new Cabalmail address needs DNS propagation + sendmail config reload before it can receive mail. Creating at commit time gives that pipeline runway -- typically tens of seconds while the user fills the rest of the form. Eagerly-created addresses are tagged `pending=true`; the extension issues a `confirm_address` call on actual form submit to clear the flag, and a server-side TTL reaper revokes any address that stays `pending` for longer than a window (default 24h). This handles the close-the-browser-without-submitting case the extension can't observe.
- **Cognito Hosted UI + PKCE for auth.** The extension is a public client; embedding the Cognito SRP flow would require the user to type their password into a popup UI, which is worse for trust and worse for shared-device scenarios. PKCE via the platform's web-auth APIs (`chrome.identity.launchWebAuthFlow` on Chrome, `ASWebAuthenticationSession` via the Safari app extension host) is the right shape. Embedded SRP via `amazon-cognito-identity-js` is the fallback if Hosted UI work slips.
- **Never block submission silently.** Any time the extension intercepts a form submit, the user sees a visible explanation (banner or popover) and an explicit "submit anyway" escape hatch. Surprise-blocking a form because of a Cabalmail decision is worse than letting a bad address through.
- **No telemetry.** The extension does not phone home about which sites the user visits, which forms it detected, or which suggestions were accepted. Cabalmail is a privacy product; this surface is the most privacy-sensitive of all.

### Sign Up vs Sign In detection

This is the central technical risk and warrants its own treatment. The user's question -- "is it a question of GET vs POST?" -- is the natural first guess, but the answer is no: both sign-up and sign-in forms POST to `/auth`, `/session`, `/api/login`, etc. with no consistent verb distinction. Production password managers do not rely on that signal.

What they rely on instead, ranked roughly by reliability:

| Signal | Reliability | Source |
|---|---|---|
| `autocomplete="new-password"` on a password field | **High.** It is the WHATWG-blessed answer; sites that care about password managers set it. | [HTML Living Standard, autofill detail tokens](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#autofill-detail-tokens) |
| `autocomplete="current-password"` on a password field | **High.** Inverse signal: explicitly *not* a sign-up. | Same |
| Two password fields in the same form (the second usually labelled "Confirm") | **High.** Sign-in forms almost never have two password fields. | Empirical |
| Submit button or anchor text containing "Sign up", "Create account", "Register", "Get started", "Join" | **Medium-high.** Localized variants required (Inscrivez-vous, Anmelden, etc.). | Empirical |
| Submit button text containing "Sign in", "Log in", "Continue" | **Medium-high.** Inverse signal. | Empirical |
| Form `action` URL containing `signup`, `register`, `create`, `join` | **Medium.** Many SPAs POST to `/api/auth` with no semantic verb in the URL. | Empirical |
| Page URL pathname containing `/signup`, `/register`, `/join`, `/create-account` | **Medium.** | Empirical |
| Heading text (nearest preceding `h1`/`h2`) containing sign-up vocabulary | **Medium.** | Empirical |
| Field label, placeholder, or aria-label containing "Confirm password", "Choose username", "Pick a password" | **Medium.** | Empirical |
| Presence of a "Terms of Service" or "Privacy Policy" checkbox in the same form | **Low.** Strong correlation with sign-up in practice, but false positives on consent-required sign-in (rare). | Empirical |
| `GET` vs `POST` on the form | **None.** Both verbs appear on both kinds of form; do not weight this signal. | Verified |

References worth reading before implementing the detector:

- **Bitwarden's autofill heuristics** (the most accessible open-source reference): `services/autofill.service.ts` in the open-source Bitwarden browser extension. Its `getFormsWithPasswordFields` and `inIframeOrTab` helpers, and the `LoginField` enum, document the signal soup in production code. License is GPLv3; we read it for technique, not for copying.
- **Chromium's password-form parser** (`components/password_manager/core/common/password_form.h` and `components/autofill/core/browser/heuristic_source.h`): the most thoroughly battle-tested classifier in existence. Open-source but heavily entangled with Chromium internals; read for ideas, not copying.
- **Mozilla's `formautofill` engine** (`browser/extensions/formautofill/` in the Firefox source tree): an extension-shaped classifier; closer to what we'll build than Chromium's is. Documents the heuristic ordering, scoring thresholds, and the iframe-handling subtleties.
- **1Password Web Inline Menu Detection** (1Password's public blog post "How we detect login forms," and the related public talks). Not source-available, but the architecture they describe -- a per-page scorer that runs once at content-script load, then on `MutationObserver` events, with results cached per-form -- is the right shape.

**Our detector.** A scoring engine, not a tree of `if`s. Each form on the page gets a numeric score from each signal above, weighted by reliability (the table is a starting point for weights, not the final numbers -- we tune empirically). Total score above an upper threshold -> sign-up (offer suggest); below a lower threshold -> sign-in (do nothing); between the thresholds -> ambiguous (show a passive badge on the field that the user can click to open the popup, but no automatic action). The thresholds and per-signal weights live in a config file, are unit-tested against a corpus of captured form HTML from real sign-up and sign-in pages (Phase 4), and are tunable without a release.

The corpus itself is the durable asset. Phase 4 builds a snapshot tool (a separate extension build that dumps form HTML on demand) and seeds it with 50+ sign-up and 50+ sign-in pages from a representative set: top SaaS apps, e-commerce, news sites, gov forms, banking, region-localized sites. Subsequent tuning, both in 1.2.x and beyond, regresses against this corpus.

### Stack decisions

| Choice | Decision | Rationale |
|---|---|---|
| Language | **TypeScript** strict mode | Standard; type-checks the WebExtension API surface |
| Manifest | **MV3 for Chrome, MV3 for Safari** | Safari 16.4+ supports MV3 (`manifest_version: 3`); Chrome has required MV3 for new submissions since 2024 |
| Build | **Vite** with a custom WebExtension plugin (e.g. `@crxjs/vite-plugin`) | Same toolchain as `react/admin/`; hot-reload during dev |
| Cross-browser API shim | **`webextension-polyfill`** | Lets us write `browser.*` everywhere; Chrome's `chrome.*` is callback-based, the polyfill makes both Promise-based |
| UI framework | **Preact + signals** for the popup and the inline overlay | React-API-compatible but ~3 kB; matters for a content script. Avoids dragging React 17 into a content-script bundle |
| Styling | **Inline styles for the content-script overlay**, **CSS modules for the popup** | Content-script CSS must be shadow-DOM-encapsulated to avoid host-page conflicts |
| Auth | **Cognito Hosted UI + PKCE** via `chrome.identity.launchWebAuthFlow` (Chrome) and `browser.identity.launchWebAuthFlow` (Safari) | Public-client OAuth flow; no embedded password UI |
| Auth fallback | **`amazon-cognito-identity-js`** embedded SRP | Used when Hosted UI is not configured for the environment (dev iteration only) |
| HTTP | **`fetch`** | No third-party HTTP client; the API surface is small |
| State | **Signals (`@preact/signals`)** for UI state, **`browser.storage.local`** for persisted tokens and config cache | Idiomatic Preact; browser-managed encrypted storage on Safari, plain on Chrome (acceptable for short-lived tokens) |
| Testing | **Vitest** for unit, **Playwright** for integration (against a fixture page set) | Same Vitest setup as `react/admin/`; Playwright loads the extension into a controlled browser instance |
| Linting | **eslint + `@typescript-eslint`** | Standard |

### Repository layout

A new top-level directory, sibling to `apple/`, `react/admin/`, and the planned `android/`:

```
extensions/
  package.json                     # workspace root; npm workspaces or pnpm
  pnpm-workspace.yaml              # if pnpm
  tsconfig.base.json
  vite.config.shared.ts
  README.md

  shared/                          # platform-agnostic core
    src/
      auth/                        # PKCE flow, token storage, refresh
      api/                         # ApiClient (fetch); endpoint wrappers
      config/                      # /config.js fetch + cache
      detect/                      # form detection + scoring engine
        scorer.ts                  # the scoring engine
        signals.ts                 # individual signal extractors
        corpus.ts                  # in-tree fixtures for unit tests
      generate/                    # address generation (mirrors Request.jsx)
      models/                      # Address, Config, Domain, FormScore
      messaging/                   # content-script <-> background bridge
    test/                          # vitest unit tests
    package.json                   # exports the above as a workspace package

  chrome/                          # Chrome MV3 extension
    manifest.json
    src/
      background.ts                # service worker (MV3)
      content.ts                   # content script entry
      popup/                       # toolbar popup (sign-in, address list, settings)
      overlay/                     # the inline "Suggest address" UI
    vite.config.ts
    package.json

  safari/                          # Safari Web Extension
    Cabalmail.xcodeproj/           # generated by xcodegen (not committed)
    project.yml                    # xcodegen input
    Cabalmail/                     # iOS/macOS app shell that hosts the extension
      Resources/                   # web extension bundle output goes here
      Info.plist
    CabalmailExtension/            # Safari Web Extension target
      manifest.json                # symlink or copy from chrome/manifest.json with safari-only deltas
      Info.plist
      SafariWebExtensionHandler.swift
    src/                           # same TypeScript build as chrome/, different manifest
    vite.config.ts
    package.json

  fixtures/                        # form-HTML corpus for detector tests
    signup/
      stripe-2025-04.html
      github-2025-04.html
      ...
    signin/
      stripe-2025-04.html
      github-2025-04.html
      ...
    ambiguous/
      ...
```

`shared/` is the analog of `apple/CabalmailKit/` and `android/kit/`: the place where everything not specific to a single browser engine lives. Both browser-specific packages depend on it via the workspace.

---

## Phase 1: Foundation & Shared Core

### 1. Repository skeleton

Create `extensions/` with the layout above. Set up:
- `package.json` workspaces (npm workspaces is fine; pnpm if we want stricter dep isolation between `chrome/` and `safari/`)
- `tsconfig.base.json` with `strict: true`, `noUncheckedIndexedAccess: true`, `target: es2022`, `lib: ["DOM", "ES2022", "WebWorker"]`
- `eslint.config.js` mirroring the React admin app's config
- `.gitignore` entries for `extensions/*/dist/`, `extensions/safari/Cabalmail.xcodeproj/`, `extensions/*/node_modules/`

### 2. Runtime configuration

The extension needs `apiUrl`, `userPoolId`, `clientId`, and the list of apex mail domains from somewhere. The convention established by the React admin app (`react/admin/public/config.js`) and adopted by Apple is to fetch `https://<control-domain>/config.js` (or `.json`) at first launch.

The control domain itself is the only value baked at build time. Store it in a Vite-injected constant per build variant (dev/stage/prod), much like the Android plan's `buildConfigField`. In Vite this is `define: { __CONTROL_DOMAIN__: JSON.stringify(...) }` keyed off `process.env.CABALMAIL_ENV`.

`shared/src/config/ConfigService.ts`:
- Fetch `https://<control-domain>/config.js`, parse out the JSON literal it assigns
- Cache the result in `browser.storage.local` with a 24h soft expiry (re-fetch on next launch, serve cache if offline)
- Expose `apiUrl`, `userPoolId`, `clientId`, `apexDomains` (derived from `config.domains[].domain`) as observable signals

### 3. Address generation

`shared/src/generate/generateAddress.ts` -- a pure function that mirrors `react/admin/src/Addresses/Request.jsx` lines 69-71:

```typescript
const ALPHANUM = 'abcdefghijklmnopqrstuvwxyz0123456789';
const LOCAL_MID = ALPHANUM + '._-';
const SUBDOMAIN_MID = ALPHANUM + '-';

export function generateAddress(apex: string): { local: string; subdomain: string; address: string } {
  const local = randomFromPool(ALPHANUM, 1) + randomFromPool(LOCAL_MID, 6) + randomFromPool(ALPHANUM, 1);
  const subdomain = randomFromPool(ALPHANUM, 1) + randomFromPool(SUBDOMAIN_MID, 6) + randomFromPool(ALPHANUM, 1);
  return { local, subdomain, address: `${local}@${subdomain}.${apex}` };
}
```

Unit-test against statistical properties of the pools and edge cases (apex with a hyphen, apex with multiple labels).

### 4. Models

`shared/src/models/`:
- `Address` -- `{ address, tld, subdomain, username, comment }`, matching the `/list` and `/new` shapes
- `Domain` -- `{ domain, arn, zone_id }`, matching the `domains` array in `config.js`
- `Config` -- the runtime config shape
- `FormScore` -- `{ formId, score, classification: 'signup' | 'signin' | 'ambiguous', signals: SignalContribution[] }`
- `SignalContribution` -- `{ name, weight, contribution }` for explainability in dev mode

### Phase 1 verification

1. `cd extensions && pnpm install && pnpm -r build` succeeds with no compilation errors.
2. `cd extensions && pnpm -r test` runs the smoke tests (config parse, address generation).
3. Address generation produces strings matching the regex used by the React admin app's validator.

---

## Phase 2: CI/CD

Land the workflow early so every subsequent phase ships through it. Two jobs that always run; a third that uploads to stores on `main`/`stage`.

### 1. Workflow layout

**`.github/workflows/extensions.yml`** -- triggers on `extensions/**` changes, pushes to `main`/`stage`, and manual `workflow_dispatch`.

| Job | Runner | Purpose |
|---|---|---|
| `test` | `ubuntu-latest` | Install deps, run `pnpm -r lint test build`, archive built `chrome/dist/` and `safari/Resources/` |
| `build-safari` | `macos-latest` | Run `xcodegen generate` and `xcodebuild` against the Safari extension targets (macOS and iOS), unsigned, to verify it compiles |
| `upload` | `ubuntu-latest` (Chrome) + `macos-latest` (Safari) | On `stage`/`main`: upload to the Chrome Web Store and to App Store Connect (TestFlight for iOS, Mac App Store internal testers for macOS) |

### 2. Chrome upload

Use **`chrome-webstore-upload`** (the npm package, not the deprecated CLI). Authenticate with a refresh token stored as `CHROME_WEBSTORE_REFRESH_TOKEN`; pass the `.zip` produced by `pnpm --filter chrome build && cd chrome/dist && zip -r ../chrome.zip .`. Push to the `trustedTesters` track on `stage`, the `default` track on `main`.

Secrets required:
- `CHROME_WEBSTORE_EXTENSION_ID`
- `CHROME_WEBSTORE_CLIENT_ID`
- `CHROME_WEBSTORE_CLIENT_SECRET`
- `CHROME_WEBSTORE_REFRESH_TOKEN`

### 3. Safari upload

Two App Store Connect uploads: one for the iOS/visionOS app extension target, one for the Mac app extension target (which is a separate App Store Connect record by convention even though Safari supports both from a single Mac Catalyst target -- we're not going Catalyst, we're shipping two targets).

Use **`xcodebuild -exportArchive`** to produce `.ipa` (iOS) and `.pkg` (macOS); then **`xcrun altool --upload-app`** or the newer `xcrun notarytool` + `altool` chain. The exact incantation matches what the Apple client uses in `apple.yml` (see the existing workflow for the API-key-based auth pattern).

Secrets required:
- `APPLE_APP_STORE_CONNECT_API_KEY_ID`
- `APPLE_APP_STORE_CONNECT_API_KEY_ISSUER_ID`
- `APPLE_APP_STORE_CONNECT_API_KEY` (base64-encoded `.p8`)
- `APPLE_DEVELOPER_TEAM_ID`

### 4. Versioning

Marketing version derived from `CHANGELOG.md` (same `sed` pattern as `apple.yml` and the planned `android.yml`). Build number derived from `github.run_number`.

### Phase 2 verification

1. Open a PR touching `extensions/**`; confirm `test` and `build-safari` run against the Phase 1 scaffold.
2. Confirm the workflow does **not** trigger on changes outside `extensions/**`.
3. Merge to `stage`; confirm Chrome trusted-tester upload succeeds and Safari TestFlight build is processed.

---

## Phase 3: Backend Additions, Authentication & API Client

### 1. Backend additions (Lambda + Terraform)

The eager-create-and-reap model requires four additive server-side changes (a-d below). They have no impact on existing clients, so each can ship via the direct-to-prod-scaffolding path per CLAUDE.md.

**a. Extend `POST /new` to accept and store a `pending` flag.**

`lambda/api/new/function.py` currently writes a fixed set of attributes to the `cabal-addresses` row. Add:
- `pending` (boolean, defaults to `false` when absent so existing clients are unaffected)
- `pending_since` (ISO 8601 timestamp, written only when `pending=true`)

The DNS-record creation and SNS reconfigure-notification paths are unchanged. The `pending` flag is purely a marker for the reaper and for the extension's own bookkeeping.

**b. New endpoint `POST /confirm_address`.**

`lambda/api/confirm_address/function.py` (new). Request body:
```json
{ "address": "f8x3p_qr@bzkw4mnv.cabalmail.com" }
```

Behavior:
- Looks up the address row in `cabal-addresses`
- Verifies the row's `user` matches the caller's `cognito:username` (or 403)
- Clears `pending` and `pending_since` via an `UpdateItem` with a condition that the row exists and is owned by the caller
- Returns 200 on success; 404 if the address doesn't exist; 409 if it exists but is already confirmed (treated as success by the extension)

**c. Scheduled reaper Lambda.**

`lambda/api/reap_pending_addresses/function.py` (new). Triggered by EventBridge on a fixed schedule (default: every hour). Behavior:
- Scans `cabal-addresses` for `pending=true AND pending_since < now - PENDING_TTL` (default `PENDING_TTL=24h`, configurable via env)
- For each match, invokes the same revocation path used by `lambda/api/revoke/function.py`: deletes the DynamoDB row, removes the Route 53 records, publishes the SNS reconfigure event
- Emits a CloudWatch metric (`PendingAddressesReaped`) per run for observability
- Idempotent: if a match is concurrently confirmed mid-scan, the conditional delete on the DynamoDB row no-ops cleanly

Terraform changes, all in `terraform/infra/modules/app/`:
- New `aws_lambda_function` resource for `confirm_address` (mirrors the existing `revoke` pattern)
- New API Gateway route `POST /confirm_address` wired to the Cognito authorizer
- New `aws_lambda_function` for `reap_pending_addresses` with an `aws_cloudwatch_event_rule` schedule and matching IAM policy permitting `dynamodb:Scan`, `dynamodb:DeleteItem`, `route53:ChangeResourceRecordSets`, and `sns:Publish` to the reconfigure topic

Refactor opportunity (low-stakes, optional): factor the address-revocation logic out of `lambda/api/revoke/function.py` and the reaper into `lambda/api/_shared/helper.py` so both call the same code path. The shared-helper convention is already established (`user_authorized_for_domain`, etc.), so this is just one more function.

**d. Procmail-based clear-on-receive on the IMAP tier.**

The extension's submit-time `confirm_address` is best-effort: extensions get killed, networks flake, users sometimes submit cross-device. The reliable ground truth that an address is in use is mail actually arriving at it. Hook into the IMAP tier's existing per-user procmail pipeline to clear the `pending` flag the instant a message is delivered to a pending address.

This costs effectively nothing at steady state. The vast majority of inbound messages route to confirmed addresses; procmail reads an empty include file and falls through. The DynamoDB write only fires on the rare arrival to a still-pending address. Compare to a milter-publishes-SNS-on-every-RCPT design, which pays Lambda + SNS cost per message regardless of pending-set size -- bad fit when the pending set is almost always empty.

Three pieces:

- **`docker/shared/generate-config.sh` extension.** During the same DynamoDB scan that builds virtusertable, collect addresses with `pending=true` into a separate group. Emit `/etc/procmail-pending.rc` -- one rule per pending address:
  ```
  :0 wc
  * ^TO_f8x3p_qr@bzkw4mnv\.cabalmail\.com
  | /usr/local/bin/confirm-cabal-address f8x3p_qr@bzkw4mnv.cabalmail.com
  ```
  The `wc` flags mean "wait for the action, copy" -- the action is a pure side effect; mail still flows to the user's maildir regardless of the script's exit code. When no addresses are pending (the steady state), the file is regenerated empty. Written via the same atomic-mv idiom `generate-config.sh` already uses for virtusertable and friends.

- **`/etc/procmailrc` template change.** Add `INCLUDERC=/etc/procmail-pending.rc` near the top of `docker/imap/configs/procmailrc`. Adjust `docker/shared/sync-users.sh` so existing users' `~/.procmailrc` files pick up the include line on next container start (`grep -q INCLUDERC || echo INCLUDERC=/etc/procmail-pending.rc >> ~/.procmailrc`, since the existing `cp -n` won't overwrite them).

- **`/usr/local/bin/confirm-cabal-address`** -- a ~20-line Python script baked into the imap image. One positional arg (the recipient address); conditional DynamoDB `UpdateItem` that removes `pending` and `pending_since` only if the row exists and is still pending. Exits 0 on success or no-op (a row confirmed or reaped between rule generation and mail arrival); exits non-zero only on genuinely unexpected errors. Idempotent against the reaper-and-mail-arrive-at-the-same-instant race.

The imap task role needs `dynamodb:UpdateItem` on `cabal-addresses` (it already has `Scan`, so this is one additional action in the existing IAM policy).

Reconfigure events must fire on every `pending` transition so the rule set converges quickly: `lambda/api/new/function.py` already publishes on creation; `lambda/api/confirm_address/function.py` (per 3.1.b) publishes after clearing the flag; the reaper (per 3.1.c) publishes after revoke. The procmail script itself does *not* need to publish -- the rule it just executed becomes a harmless no-op the moment the flag clears, and the next address-change event picks up the rule removal opportunistically.

**Coexistence with the planned end-user procmail framework** (roadmap: the minor point release following 1.2.x). That framework will expose forward and move rules to end users through the admin app. The pending-confirmation rules introduced here coexist cleanly:

1. The pending rules live in `/etc/procmail-pending.rc`, a system-owned file the end-user framework does not touch. The end-user framework will have its own data model and its own generated file (presumably one per user, sourced via a separate `INCLUDERC`).
2. The pending rules are `:0 wc` -- side-effect-only, never divert delivery. A user-defined rule that *does* divert (a typical `:0` move-to-folder recipe) could otherwise suppress later rules in the file, but ours run *first* and as `wc` they never block what comes after.
3. The ordering constraint is one line in `/etc/procmailrc`: put `INCLUDERC=/etc/procmail-pending.rc` ahead of any user-rule INCLUDERC. The end-user framework can append its own includes after ours without renegotiating anything from this version's work.

No reordering of the roadmap is required. The 1.2.x work and the end-user framework live in adjacent procmail niches that don't collide.

**Steady-state cost** (the case ~99% of the time): empty include file; procmail reads it, finds nothing, falls through. Approximately free.

**Per-confirmation cost** (rare): one Python interpreter spawn + one DynamoDB `UpdateItem`.

### 2. Cognito Hosted UI + PKCE

The Cognito User Pool already supports the Hosted UI; the existing infrastructure exposes it on `https://<control-domain>/auth/...` (configured in `terraform/infra/modules/user_pool/`). We add an App Client for the extension specifically -- a public client with no client secret, with allowed callback URLs of the form `https://<extension-id>.chromiumapp.org/oauth2/redirect` (Chrome's `chrome.identity.launchWebAuthFlow` redirect convention) and a Safari analog.

`shared/src/auth/HostedUiAuth.ts`:
- Generates a PKCE code verifier + challenge
- Constructs the Hosted UI URL: `https://<auth-domain>/oauth2/authorize?response_type=code&client_id=...&redirect_uri=...&scope=openid+email&state=...&code_challenge=...&code_challenge_method=S256`
- Calls `browser.identity.launchWebAuthFlow({ url, interactive: true })`
- Receives the redirect URL, extracts `code` and `state`
- Exchanges `code` for `{ id_token, access_token, refresh_token }` at `https://<auth-domain>/oauth2/token`
- Stores the tokens in `browser.storage.local` (Safari encrypts this by default; Chrome does not, but the tokens are short-lived and replaceable)

Refresh:
- On any API call, if the cached `id_token` is within 5 minutes of expiry (decoded from the JWT `exp` claim), refresh it using the `refresh_token` against the `/oauth2/token` endpoint before sending the request
- If the refresh fails (refresh token revoked, expired), surface a "sign in again" state and clear the cached tokens

### 3. Embedded SRP fallback (dev only)

`shared/src/auth/EmbeddedSrpAuth.ts` -- thin wrapper over `amazon-cognito-identity-js` for use during local development before the Hosted UI App Client is provisioned. Selected at build time via a Vite-injected constant; not shipped to production builds.

### 4. API client

`shared/src/api/ApiClient.ts` -- a class wrapping `fetch`. All requests attach `Authorization: <idToken>` via an interceptor that calls the auth service. 401 responses trigger a single retry after a forced token refresh; a second 401 clears the session and surfaces `AuthError.SessionExpired`.

Endpoints needed for 1.2.x:

| Method | HTTP | Endpoint | Notes |
|---|---|---|---|
| `listMyDomains()` | GET | `/list_my_domains` | Existing |
| `listAddresses()` | GET | `/list` | Existing; used by adopt flow for "does this address already exist?" check |
| `newAddress({ tld, subdomain, username, address, comment?, pending? })` | POST | `/new` | Existing endpoint extended to accept `pending` |
| `confirmAddress({ address })` | POST | `/confirm_address` | New (per section 1) |

That's the entire API surface for the extension. The two endpoints in italics above require the Phase 3.1 backend work to land first; the others are unchanged.

### 5. Background script as the auth boundary

In MV3, content scripts cannot make authenticated cross-origin requests to arbitrary origins without `host_permissions`, and they cannot persist tokens safely (they share storage with the host page only via messaging). The pattern:

- The **service worker** (`background.ts`) owns the auth state and is the only thing that talks to the Cabalmail API.
- The **content script** posts messages to the background asking for actions: "score this form," "give me a fresh address suggestion," "create this address now."
- The **popup** also posts messages to the background; it does not have its own auth state.

`shared/src/messaging/` defines the message schema with discriminated unions and a typed dispatcher on both sides.

### Phase 3 verification

1. Unit tests cover: PKCE challenge generation, token refresh logic, 401 retry, API client request shaping, the new `/confirm_address` Lambda's owner check and idempotent-already-confirmed path.
2. Pylint passes on the new `confirm_address` and `reap_pending_addresses` Lambdas and on `/usr/local/bin/confirm-cabal-address`; `terraform plan` on the new resources is clean.
3. Manual: call `POST /new` with `pending=true` (curl + a fresh JWT), confirm the resulting DynamoDB row has the flag set. Call `POST /confirm_address` against that address, confirm the flag clears. Call again; confirm 409-treated-as-success.
4. Manual: create a `pending=true` address; observe `/etc/procmail-pending.rc` on the imap tier regenerate with the new rule within seconds. Confirm the file is empty after `/confirm_address` and another reconfigure cycle.
5. Manual: create a `pending=true` address, then send a test message to it from outside the system. Confirm the procmail script fires, the DynamoDB row's `pending` flag clears, and the message still delivers to the user's maildir (procmail's `wc` semantics).
6. Manual: send a test message to a confirmed (already non-pending) address; confirm the procmail script is *not* invoked (the include file has no rule for it).
7. Manual: insert a `pending=true` address with `pending_since` backdated 25h. Invoke the reaper Lambda manually; confirm the row, the Route 53 records, the procmail rule, and the SNS reconfigure event all fire. Confirm the `PendingAddressesReaped` CloudWatch metric increments.
8. Manual: simulate the reaper-and-mail-arrive race -- mark a row reaped on one host while the procmail script is in flight on another -- confirm the conditional `UpdateItem` no-ops cleanly and the script exits 0.
9. Manual: open the popup, click "Sign in with Cabalmail," complete the Hosted UI flow, confirm `listMyDomains()` returns the expected array.
10. Manual: revoke the refresh token via the Cognito console, confirm the next API call surfaces `SessionExpired` and the popup prompts for re-auth.
11. Manual: kill the extension service worker (`chrome://extensions` -> "service worker (inactive)"), confirm the next content-script -> background message wakes it and the call still succeeds.

---

## Phase 4: Form Detection

The most novel work. Build the scoring engine and the fixture corpus before any UI lands; the engine's accuracy gates Phase 5 quality.

### 1. Signal extractors

`shared/src/detect/signals.ts` -- a list of pure functions, each `(form: HTMLFormElement, context: PageContext) => SignalContribution | null`. One per row in the table in [Approach](#sign-up-vs-sign-in-detection) above.

Each extractor returns either `null` (signal absent) or `{ name, weight, contribution }`. Contribution can be positive (towards sign-up) or negative (towards sign-in). Magnitude is the configured weight; sign is the direction.

### 2. Scoring engine

`shared/src/detect/scorer.ts`:

```typescript
export type Classification = 'signup' | 'signin' | 'ambiguous' | 'not-an-auth-form';

export interface FormScore {
  form: HTMLFormElement;
  emailField: HTMLInputElement | null;
  score: number;            // positive -> signup, negative -> signin
  classification: Classification;
  signals: SignalContribution[];
}

export function scoreForm(form: HTMLFormElement, ctx: PageContext): FormScore {
  const signals = SIGNAL_EXTRACTORS.map(fn => fn(form, ctx)).filter(notNull);
  const score = signals.reduce((s, c) => s + c.contribution, 0);
  const classification = classify(score, signals);
  const emailField = findEmailField(form);
  return { form, emailField, score, classification, signals };
}
```

`classify` applies the upper/lower thresholds and a "must have an email field" gate. Forms without a plausible email field are classified `not-an-auth-form` and ignored.

### 3. Lifecycle

Run the scorer:
- Once at content-script load, after `DOMContentLoaded`.
- On every `MutationObserver` event that adds an `<input>` or `<form>` to the DOM, debounced by 200ms. (SPAs rebuild the form after route changes.)
- Cached per-form by a stable form key (form id, form name, or a hash of field names) -- recomputing on every mutation is wasteful and visibly janky on slow pages.

### 4. Corpus

`extensions/fixtures/` holds saved HTML snapshots of real forms. A small CLI tool (`extensions/scripts/snapshot.mjs`) lets the developer:

```bash
$ pnpm exec snapshot https://github.com/signup signup/github-2025-04.html
```

It opens the URL in a headless Playwright browser, waits for the form to render, and dumps the form's outer HTML plus the page URL, page title, and nearest heading into the fixture file. The fixture file is committed; the build snapshot of github.com lives forever in the repo.

Initial corpus target: 50 sign-up forms, 50 sign-in forms, 10 ambiguous (e.g. magic-link-only flows that don't fit either category). Drawn from: top SaaS apps (Stripe, GitHub, Linear, Notion, Vercel, Cloudflare, Tailscale, Discord, Slack, ...), e-commerce (Amazon, Shopify storefronts), news (NYT, WaPo), gov (login.gov, gov.uk), banking (Chase, Wise), region-localized (Yandex, Naver, MercadoLibre).

### 5. Unit tests against the corpus

`shared/test/detect/corpus.test.ts` loads every fixture and asserts the classifier returns the expected label. Failing fixtures block CI. Tuning the weights is "make all 110 fixtures pass," which is much more tractable than "make this one site work."

### 6. Calibration loop

Plan to mis-classify in the wild. The extension's popup includes a "Report wrong detection" link that opens the user's browser to a GitHub Issues template with the form's outer HTML pre-filled (the user reviews and submits). Each accepted report becomes a new fixture and a new test case, and the weights get re-tuned in the next release. The fix is iterative; the corpus is the durable artifact.

### Phase 4 verification

1. The corpus test passes against all 110 initial fixtures.
2. Manual: load the extension in dev mode on the 110 source sites; visually inspect that the classifier badge in dev mode matches the expected label. (Dev mode adds a small floating overlay showing the score, classification, and per-signal contributions for every form on the page.)
3. False-positive rate on sign-in pages: < 5% (sign-ins where the extension wrongly suggests an address).
4. False-negative rate on sign-up pages: < 20% (sign-ups where the extension shows nothing or only the passive badge). Higher tolerance on FN than FP because FN is "you missed a chance to be useful" while FP is "you offered to do the wrong thing on a login form."

---

## Phase 5: Suggest Flow

The 1Password-style UI: when the user focuses the email field of a sign-up form, an inline popover appears with the suggested address and a "Use this address" button.

### 1. Inline popover

`extensions/chrome/src/overlay/Popover.tsx` (and the Safari equivalent, which is the same source file via the workspace).

- Rendered into a Shadow DOM attached to a `<div>` injected at the end of `document.body`, positioned absolutely over the email input via `getBoundingClientRect` (re-positioned on scroll and resize).
- Closes on outside click, on `Escape`, and when the email field loses focus to anything other than the popover itself.
- Shape:

```
+-----------------------------------------------+
| [Cabalmail logo]   Use a new Cabalmail address|
|                                               |
| f8x3p_qr@bzkw4mnv.cabalmail.com    [Refresh]  |
|                                               |
| Apex domain: cabalmail.com         [Change v] |
|                                               |
| Optional label: ___________________________   |
|                                               |
|                  [Cancel]  [Use this address] |
+-----------------------------------------------+
```

- "Refresh" regenerates a new random local part and subdomain client-side. No API call -- regenerating is a purely visual operation.
- "Change" opens a dropdown of all apex domains in `listMyDomains()`. If the user only has one apex, the dropdown is hidden.
- "Optional label" is the `comment` field that goes into the address record. Free text, capped at 100 chars. Default value is the page's hostname.
- "Use this address" is the commit point. It:
  1. Sends `newAddress({ ..., pending: true })` to the background, which calls `POST /new`.
  2. While the request is in flight, the button shows a spinner; the popover does *not* close yet.
  3. On success, inserts the address into the form's email field via the platform's recommended sequence (`focus` -> set `.value` -> dispatch `input` and `change` events -> blur), so React-controlled inputs see the change. Records the address in `browser.storage.local` under the form's stable key as `{ address, status: 'pending', createdAt }` so the submit handler and the cleanup logic can find it later. Closes the popover.
  4. On failure, shows an inline error in the popover with retry / cancel buttons. The popover stays open; nothing was filled.

### 2. Triggering UI

The popover surfaces when:
- The form is classified `signup` and the user focuses the email field. The popover opens automatically.
- The form is classified `ambiguous` and the email field has a small Cabalmail icon at its right edge (added via Shadow DOM, doesn't affect the host page's layout); the user clicks the icon to open the popover.
- The form is classified `signin` or `not-an-auth-form`: nothing happens. No icon, no popover.

### 3. Form submission

When the user submits the form after having committed to an address via the popover:

- The content script intercepts the `submit` event in the capture phase and calls `confirmAddress({ address })` against the background.
- This is a fast call -- one DynamoDB `UpdateItem` -- so the inline indicator is usually invisible. If it takes longer than ~150ms, a small "Saving Cabalmail address..." indicator appears over the submit button so the user understands there's a brief hold.
- On success: lets the original submit proceed (`form.submit()` programmatically since we already preventDefaulted).
- On failure: the address still exists in `pending` state, but the submit shouldn't be infinitely blocked on a network glitch. Show an inline banner: "Couldn't finalize your Cabalmail address (it will be cleaned up automatically in 24h). Submit anyway?" with "Retry" / "Submit anyway" / "Cancel" buttons. "Submit anyway" releases the form; the address will get reaped server-side if confirm never lands.

The user's "warn the user not to submit the form until the address has been created" requirement is now satisfied differently than in the original draft: by the time the submit fires, the address has *already* been created (during the popover commit). Submit-time is only confirming an existing address, not creating one. The "warning while we're still creating it" UI lives in the popover's commit step, where it belongs -- the user sees the spinner before the field is filled, so there's never a window where they could submit a not-yet-existent address from the suggest path.

### 4. Abandonment paths

The eager-create model means we have to handle several ways the user could walk away from a `pending` address. Three signals confirm an address (any one suffices): the extension's `confirmAddress` call on submit (3.1.b), mail actually arriving at the address via the procmail hook (3.1.d), and -- absent both of those -- the TTL reaper revokes the address (3.1.c).

| Path | Observable to extension? | Handling |
|---|---|---|
| User clicks "Use this address," then submits the form | Yes | `confirmAddress` fires from the submit handler. Address transitions `pending -> confirmed`. The procmail hook is the redundant backstop when the verification mail lands seconds later. |
| User clicks "Use this address," then clicks Refresh in a reopened popover and commits a different one | Yes | The previous address is in `browser.storage.local`; the new commit's success handler revokes it via `POST /revoke` before recording the new one. |
| User clicks "Use this address," then closes the tab without submitting | Partially -- `pagehide` and `beforeunload` fire, but neither is guaranteed (mobile background, OS-level kill) | Best-effort: on `pagehide` with a still-`pending` address in storage, send a `revoke` beacon via `navigator.sendBeacon` to a future `POST /revoke` proxy in the background. If it lands, immediate cleanup. If it doesn't *and* the form was never actually submitted (so no mail arrives), the TTL reaper catches it. |
| User clicks "Use this address," then navigates within an SPA to a different form | Yes (URL change observable via `History` API hooks) | Same as tab close: best-effort `revoke` beacon; TTL backstop. |
| User closes the browser entirely (crash, OS shutdown) -- but had already submitted before crash | Not from the extension | Procmail hook clears `pending` when verification mail arrives. The extension's storage gets reconciled on next startup. |
| User closes the browser entirely without submitting | No | TTL reaper. |
| User submits cross-device (typed the address into a phone, the desktop extension never sees the submit) | No | Procmail hook is the primary confirm path for this case. |
| User submits the form, destination site rejects for non-email reasons, user retries | Yes -- the field still holds the (now confirmed) address; resubmit will fire `confirmAddress` again, which 409s and is treated as success | No-op. Address stays confirmed; user can revoke from the admin app if they truly want to abandon. |

The procmail hook is the high-confidence signal -- if real mail arrived, the address is in use. The submit-time `confirmAddress` is the fast signal -- it fires before any mail could arrive, so the address is confirmed by the time the destination site's verification mailer runs. The TTL reaper is the floor under both.

### Phase 5 verification

1. Manual against the top 10 corpus sites: load each sign-up page, focus the email field, confirm popover appears, click "Use this address," confirm the address row appears in `cabal-addresses` with `pending=true` *while the user is still filling the form*, fill remaining required fields with synthetic data, submit, confirm the row flips to `pending=false` and the destination site's verification email actually delivers to the IMAP mailbox.
2. **DNS propagation race check.** Click "Use this address" and immediately measure the time until a test SMTP `RCPT TO:` against `smtp-in.<control-domain>` for the new address returns success rather than 5xx. Confirm this is consistently faster than the typical interval between form submit and the destination site sending its verification mail (target: under 30 seconds; ideally under 10).
3. Manual on the bottom of the corpus (the trickier sites): confirm the popover positions correctly even when the email field is in an iframe, a modal, or a virtualized list.
4. Manual: focus the email field, click "Refresh" 10 times, confirm the suggested address changes each time and no API calls fire (no rows appear in `cabal-addresses`).
5. Manual: click "Use this address," then re-open the popover, click "Refresh," click "Use this address" again. Confirm the first address is revoked and the second is created `pending`.
6. Manual: click "Use this address," then close the tab without submitting. Confirm the `pagehide` beacon fires and the address is revoked within a few seconds. Separately, simulate a beacon failure (kill the network before close), confirm the row stays `pending` and would fall within the reaper's scan filter -- a more direct test runs the reaper Lambda manually against a row with `pending_since` backdated past the TTL (already covered in Phase 3 verification).
7. Manual: click "Use this address," then trigger a `confirm_address` failure on submit (network offline, throttle in browser devtools). Confirm the inline submit-time banner appears and the form is held until "Retry," "Submit anyway," or "Cancel" is chosen. Confirm the address stays `pending` and gets reaped if confirm never lands.
8. Manual sign-in pages (the 50 fixtures and 10 real production sign-ins): confirm no popover appears, no icon appears, no observable difference from a browser without the extension.

---

## Phase 6: Adopt Flow

If the user types an address manually -- because they remember the convention, or they're copying from another tool, or they're filling in a familiar address -- the extension should still help.

### 1. Detection

The content script subscribes to `input` events on the email field of any form classified `signup` or `ambiguous`. On every input, debounced by 300ms:

1. Parse the field's value as `<local>@<host>`. If it doesn't parse, ignore.
2. Decompose `<host>` into `<subdomain>.<apex>`. If `<host>` is exactly an apex (no subdomain), this is a sign that the user typed a non-Cabalmail-shaped address; treat as "not interesting" and ignore. (Cabalmail addresses live on subdomains; an apex-shaped address is either a different mail provider or an error.)
3. Check whether `<apex>` is in `listMyDomains()`. If not, ignore. The user is just typing a personal Gmail or whatever.
4. Check whether the full address is already in `listAddresses()`. If yes, ignore -- they're entering an existing address, which is a legitimate "this is the address I want to use here" choice. (Note: we don't *know* the user typed this; they may have pasted it, or it may have been autofilled by the browser's own password manager. We treat all sources the same. For this check, `pending=true` addresses count as "exists" so we don't double-create one the user committed via the suggest flow earlier in the session.)
5. If we reach this step, the address looks like a Cabalmail address on an authorized apex but doesn't exist yet: offer to create it.

### 2. Offer UI

A subtle inline banner appears just below the email field:

```
+-----------------------------------------------+
| You typed a Cabalmail address that doesn't    |
| exist yet. Create it before submitting?       |
| [Yes, create it]  [No, leave as-is]           |
+-----------------------------------------------+
```

- "Yes, create it" calls `POST /new` immediately with `pending=true` (this *is* the user committing to the address). Shows a progress indicator, then a success or error state. Records the address in `browser.storage.local` under the form's stable key, same as the suggest flow, so submit-time `confirmAddress` and abandonment cleanup work uniformly across both flows.
- "No, leave as-is" dismisses the banner; the form submits normally and the destination site receives an address that won't deliver mail. The user has explicitly chosen this.
- The banner re-appears if the user edits the field and the address parses to something still-not-existing.

### 3. Submit-time guard

If the user starts to submit while the banner is still visible (i.e. they typed a creatable address, didn't click either banner button, and hit submit), intercept the submit and show a blocking modal:

```
+-----------------------------------------------+
| Wait                                          |
|                                               |
| The address you entered (f8x3p_qr@bzkw4mnv.   |
| cabalmail.com) doesn't exist yet. If you      |
| submit now, this site won't be able to email  |
| you.                                          |
|                                               |
| [Create the address and submit]               |
| [Submit anyway]                               |
| [Cancel]                                      |
+-----------------------------------------------+
```

This is the warning the user prompt calls out explicitly. The default action (highlighted button) is "Create the address and submit." "Submit anyway" is dimmed and requires a deliberate click; we don't make it the path of least resistance.

When "Create the address and submit" is chosen, the modal calls `POST /new` with `pending=true`, then `POST /confirm_address` once `/new` returns (the user has committed by clicking that button -- no need to wait for the post-submit `confirmAddress` round-trip), then releases the original submit. The address row goes straight from non-existent to `confirmed`. This is the one path where the verification-mail race the eager-create model is meant to solve is *not* mitigated: the user typed the address themselves and ignored the earlier banner, and we have nowhere to insert a delay. Acceptable -- the typed-and-ignored case is the rare path; the popover-commit case (Phase 5) is the common one and gets full mitigation.

### 4. Subdomain reuse

When the user types `local@existing-subdomain.apex`, we should not blindly create a new DNS subdomain. Detect this case: if `<subdomain>` is already present in `listAddresses()` (i.e. another address shares the subdomain), the create call's DNS-record creation is idempotent (Route 53 `UPSERT`), so the call still works -- but we surface a notice to the user that they're reusing an existing subdomain, which has slightly different privacy properties (mail-to-this-subdomain correlates the new address with the existing one). The notice is informational, not blocking.

### Phase 6 verification

1. Manual: on a sign-up form, type `test@made-up.cabalmail.com` (assuming `cabalmail.com` is in the user's apex list), confirm the banner appears, click "Yes, create it," confirm the address exists in the admin app with `pending=true`. Submit the form. Confirm the address flips to `pending=false`.
2. Manual: type `test@madeup.cabalmail.com`, click "Yes, create it," then close the tab without submitting. Confirm the abandonment cleanup paths from Phase 5.4 apply (beacon or TTL).
3. Manual: type `test@madeup.cabalmail.com`, hit submit without clicking the banner, confirm the blocking modal appears. Click "Create the address and submit," confirm the address is created and immediately confirmed (skips the `pending` middle state).
4. Manual: type `test@madeup.cabalmail.com`, click "No, leave as-is," confirm the form submits normally without creating the address.
5. Manual: type an address on an apex the user is *not* authorized for (e.g. another user's domain), confirm no banner appears.
6. Manual: type an address that already exists in `listAddresses()` (including a `pending=true` address from an earlier suggest-flow commit in the same session), confirm no banner appears.
7. Manual: type an address apex-shaped (no subdomain, e.g. `someone@cabalmail.com`), confirm no banner appears (apex addressing is unsupported, and the destination site would get an undeliverable address either way).
8. Manual: type an address that reuses an existing subdomain, confirm the informational reuse notice appears.

---

## Phase 7: Platform Targets & Distribution

### 1. Chrome on macOS, Linux, and Windows

The Chrome MV3 bundle ships unchanged across desktop OSes. The Chrome Web Store handles distribution.

- Listing in the Web Store under a Cabalmail developer account (separate from the Chrome developer account used for any unrelated projects).
- Store screenshots and short description derived from this document and from screenshots captured during Phase 5 verification.
- Privacy policy: required by Chrome Web Store. Drafted as `extensions/PRIVACY.md` and published to the Cabalmail site; the listing links to it. Key claim: the extension does not transmit browsing data to any third party; it only contacts the Cabalmail API on the user's behalf when they explicitly act.

### 2. Safari on macOS

Safari Web Extensions on macOS are packaged as an app extension target inside a host macOS app. The host app is minimal -- a single window with an explainer screen, a "Sign in" button, and a link to the extension settings in Safari preferences. It exists primarily to be installable from the Mac App Store.

- The Safari MV3 bundle is the same TypeScript build as Chrome's, with the `manifest.json` swapped for the Safari-flavored one (different default popup path, Safari-specific permissions strings).
- `xcodegen` generates the Xcode project from `extensions/safari/project.yml`, mirroring the pattern in `apple/project.yml`.
- Distribution via the Mac App Store under the existing Cabalmail Apple Developer account.

### 3. Safari on iOS, iPadOS, and visionOS

Safari Web Extensions on iOS use the same Apple framework as macOS, packaged into an iOS app extension target. The host iOS app is, again, minimal -- a single screen with sign-in and a link to Safari's settings where the user enables the extension.

Three Safari versions to keep in mind:
- **iOS Safari**: full Web Extensions API support since iOS 15. MV3 since iOS 16.4.
- **iPadOS Safari**: same as iOS, but with a richer extension surface (popups can be wider, the extension can target the toolbar).
- **visionOS Safari**: Safari on visionOS supports Web Extensions since visionOS 1.1; the API surface is the iOS subset. The popover should not assume any 3D affordances; render as a flat 2D panel. Confirm the popover positions correctly when the user is browsing in Safari's "windowed" mode (no special handling expected, but verify).

All three are a single iOS app extension target. The host app uses `WindowSizeClass` analogs in SwiftUI to adapt the explainer screen.

### 4. Chrome on Android: open question, not committed

The user prompt asks for Chrome on Android support. **As of this writing, Chrome stable on Android does not support extensions.** Google has shipped experimental MV3 extension support in Chrome's desktop-Android beta channel, but the rollout is narrow and the path to stable is uncertain. This means:

- Chrome on Android cannot be a 1.2.x deliverable on the stable channel.
- Realistic Android browser-extension targets are: Firefox for Android (has supported WebExtensions for years), Microsoft Edge for Android (recent addition), Kiwi Browser (Chromium-based, supports MV2 extensions), Samsung Internet (limited extension support).

Recommended scope:
1. **In 1.2.x**: confirm the bundle loads in Firefox for Android (this is essentially free given the WebExtensions API parity). Do not commit to a store listing on Firefox; just verify it works. Document the limitation in the user-facing README.
2. **Defer to a later version**: a proper Android target with a Chromium derivative or via a Firefox add-ons listing. Tracked as a follow-up issue. Re-evaluate when Chrome Android extension support reaches stable.

This is *not* a quiet drop of the user's stated platform target -- it's a flag that the target is materially harder than they may have assumed, and that the right answer is to investigate before committing rather than ship a broken Android target. The trade-off is captured in Open Questions.

### 5. Cross-platform parity testing

Once both Chrome and Safari builds exist, run the Phase 4-6 verification matrices on:
- macOS Sequoia: Safari 18+, Chrome stable
- iOS 18: Safari
- iPadOS 18: Safari
- visionOS 2: Safari
- Android (Firefox stable, if pursued): Firefox 132+

Document any per-platform divergences (popover positioning bugs, scroll behavior on iOS, etc.) and fix in this phase.

### Phase 7 verification

1. Install Chrome build from the Web Store trusted-tester track on macOS, complete the suggest and adopt flows end-to-end on three corpus sites.
2. Install Safari macOS build from TestFlight, repeat the same flows.
3. Install Safari iOS build from TestFlight, repeat the same flows on iPhone and iPad.
4. Install Safari visionOS build from TestFlight on a Vision Pro device or simulator, confirm the popover renders correctly in windowed Safari.
5. Sideload the Firefox-for-Android build, confirm basic suggest flow works (this gates whether we pursue Android in this version).
6. Accessibility: VoiceOver on Safari macOS and iOS, ChromeVox on Chrome, confirm the popover and banner are announced correctly. Keyboard navigation: Tab order through the popover is sensible, Enter activates "Use this address," Escape closes.

---

## Out of Scope for 1.2.0

- **Chrome on Android stable.** Platform limitation; tracked as a follow-up. See Phase 7.
- **Saved site-to-address mappings.** Knowing which address you gave Stripe is the natural next feature, but introducing a new persistent store (whether server-side or browser-storage-only) is its own design exercise.
- **Fill existing addresses on sign-in.** Requires the mapping store above; sign-in autofill is the obvious follow-up once it exists.
- **Reset-password forms.** Distinct heuristics, low immediate value (user already has an address on file with that site). Re-evaluate after 1.2.x ships.
- **Bulk operations (one-click revoke all addresses for a site, etc.).** Future work.
- **Token sharing with the React admin app.** If the user is signed in to the admin app in the same browser, it would be nice to share the session with the extension. Possible via `chrome.storage` and a permission to read from the admin domain, but adds complexity for marginal benefit. Defer.

## Prerequisites

- **Chrome Web Store developer account** ($5 one-time registration). Cabalmail developer organization, not a personal account.
- **Apple Developer Program enrollment** -- already in place for the existing Apple clients. The same membership covers the extension host apps.
- **Cognito App Client provisioned for the extension** -- one new public client with OAuth flows enabled and Hosted UI callback URLs registered. Terraform change in `terraform/infra/modules/user_pool/`, applied via the standard CI/CD path. Direct-to-prod-scaffolding-eligible per CLAUDE.md if it's purely additive and no existing client references it.
- **Hosted UI domain provisioned for the User Pool** -- if not already configured. Terraform change in `terraform/infra/modules/user_pool/`.
- **Backend additions for eager-create / reap / clear-on-receive shipped before the extension does** (Phase 3.1):
  - `POST /new` extended to accept and store `pending` / `pending_since` (3.1.a)
  - New `POST /confirm_address` Lambda + API Gateway route (3.1.b)
  - New scheduled `reap_pending_addresses` Lambda + EventBridge rule (3.1.c)
  - Procmail-pending include file + helper script baked into the IMAP image, plus the `dynamodb:UpdateItem` IAM addition on the imap task role (3.1.d)
  - Each is purely additive and direct-to-prod-scaffolding-eligible per CLAUDE.md.
- **API Gateway CORS** -- the Cabalmail API already allows the React admin origin. Extensions running in Chrome and Safari send requests with the `Origin: chrome-extension://...` / `safari-web-extension://...` headers. Two paths:
  1. Declare `host_permissions` for the API URL in the manifest; the browser bypasses CORS for extension-initiated requests, no API-side change needed. (Preferred.)
  2. Add the extension origins to the API Gateway CORS allowlist. (Fallback if for some reason the host-permissions path fails for a specific endpoint.)
- **Privacy policy** published at a stable URL on the Cabalmail site, referenced from both store listings.
- **Form corpus** assembled: ~110 fixtures across sign-up, sign-in, and ambiguous categories, drawn from a representative spread of sites.

## Open Questions

1. **Chrome on Android: ship now in a degraded form, defer, or pivot to Firefox for Android?** Recommend defer + Firefox-as-bonus per Phase 7. Decision point before Phase 7 starts.
2. **Embedded SRP vs Hosted UI as the production auth mode.** Hosted UI is the right answer for trust and UX; Embedded SRP is faster to ship. Decision: ship Hosted UI for production, keep Embedded SRP as a dev-only build flag. Reconsider only if Hosted UI provisioning hits unexpected friction.
3. **Single Cognito App Client for all platforms vs one per platform.** The Apple, React, and (planned) Android clients use distinct App Clients today. One per browser target (one Chrome, one Safari) is the same pattern. Default: one per target.
4. **`manifest.json` per platform vs single shared with build-time post-processing.** Vite plugin can synthesize per-platform manifests from a base. Default: shared base + per-platform overrides in `extensions/{chrome,safari}/manifest.json`, with the build script merging. The overlap is high enough (>90%) that a shared base is worth the cost.
5. **Pending TTL window.** Default 24h. The procmail clear-on-receive hook (3.1.d) doesn't actually let us shorten this much: the constraint that sets the TTL is not "how long until we're sure the extension's confirm failed" (the procmail hook covers that) but "what's the slowest legitimate form-fill we want to support." A user committing an address, then taking 90 minutes to finish an apartment application, then submitting -- if the TTL is too short, the reaper revokes the address mid-fill and the verification mail bounces. 24h is comfortable; 6h would still cover virtually all real form-fills; 1h is too aggressive. The reaper's env var lets us tune without a redeploy. Revisit after a quarter of usage data; default holds at 24h until then.
6. **Corpus refresh cadence.** Sites change their sign-up forms frequently. The corpus drifts; the detector regresses against drift. Suggestion: a scheduled job (monthly) that re-snapshots the corpus URLs and surfaces fixtures whose HTML has changed for re-classification. Out of scope for 1.2.x but should be on the roadmap.
7. **What happens when `listMyDomains()` returns an empty array?** The user has no authorized apex domains. The popover should explain this and link to the admin app where domains are assigned. The extension is not the right place to handle the empty-state case beyond a clear explanation.
8. **Visibility of `pending` addresses in the admin app.** A `pending=true` address showing up in the user's address list in the admin app could be confusing -- "I never created this." Options: hide pending addresses from the list entirely, show them with a "pending" badge, or expose a filter. Recommend showing with a badge so the user has a way to manually clean up an orphan if needed. Coordinate with the existing admin app UI in a small follow-up PR.

## Settled design decisions worth noting

These came up during planning and have a documented resolution; recording here so the implementation phase doesn't relitigate them.

- **Address-comment default**: page hostname (e.g. "github.com"), editable in the popover. The `comment` column already exists on `cabal-addresses`.
- **Resubmit semantics**: if the user submits, the destination site rejects for non-email reasons, and the user resubmits, the extension's submit handler fires `confirmAddress` again. `/confirm_address` returns 409 (already confirmed); the extension treats 409 as success. The extension's address bookkeeping is keyed off `listAddresses()` membership, so resubmit never re-creates.
