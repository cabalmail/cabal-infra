# Browser extension

Cabalmail's signature behaviour is a separate email address per vendor: mint one when you sign up for a service, revoke it when it starts attracting spam. The browser extension collapses that into the sign-up form itself, the way a password manager collapses password generation into it. It ships for Chrome (Manifest V3) and Safari (a Web Extension inside a small macOS host app) from one TypeScript codebase in [`extensions/`](../extensions/).

This document is the whole story for that extension: building it, pointing it at your environment, verifying its backend, and publishing it to both stores. It assumes you are comfortable with AWS and a JavaScript toolchain but know nothing else about Cabalmail. Design rationale and the implementation record live separately, in [the plan](./1.x/browser-extension-plan.md).

## What the extension does

- **Suggest.** On a page the detector scores as a sign-up form, the extension offers a freshly generated address for the email field. Accepting it creates the address immediately, before the form is submitted.
- **Adopt.** If the user types an address on one of their own domains that does not exist yet, the extension offers to create it before submit.
- **Open privately.** A mail app cannot open a private browser window directly — no OS API allows it — so the Cabalmail clients navigate to a redirector page at `https://admin.<control-domain>/private-link#<target>`, which the extension intercepts and re-opens in a private window. Without the extension the page renders the target with an "open normally" link, so nothing dead-ends.

The extension talks only to the API Gateway surface of your own deployment. It never connects to IMAP or SMTP, never parses mail, and never reports anything about the sites a user visits.

### Terms

| Term | Meaning |
|---|---|
| **Control domain** | The domain your deployment's own infrastructure lives on (`TF_VAR_CONTROL_DOMAIN`). The admin web app, the runtime configuration document, and the API are all served from `admin.<control-domain>`. |
| **Mail domain** | A domain users' addresses live on (`TF_VAR_MAIL_DOMAINS`). Addresses are always on a subdomain — `user@subdomain.example.com` — never on the apex. |
| **Pending address** | An address created eagerly, before the sign-up form is submitted: fully provisioned, but flagged unconfirmed and revoked automatically if never used. |

### The pending-address model

Most sign-up backends send a verification message within seconds of form submission, and a brand-new Cabalmail address needs DNS propagation plus a sendmail configuration reload before it can receive anything. So the extension creates the address the moment the user commits to it — while they are still filling in the rest of the form — which typically buys tens of seconds of runway.

Such an address carries `pending=true` and a `pending_since` timestamp in the `cabal-addresses` DynamoDB table. Three things clear it:

1. The extension calls `POST /confirm_address` when the form is actually submitted. A second call returns `409`, which the extension treats as success by contract.
2. Mail arrives at the address. The IMAP tier keeps a generated procmail include (`/etc/procmail-pending.rc`) with one side-effect-only rule per pending address; the rule spools a signal file that a root daemon drains into a conditional DynamoDB update. Delivery is never diverted.
3. Neither happens, and the hourly `reap_pending_addresses` Lambda revokes the address once it is older than `PENDING_TTL_HOURS` (default 24), removing the row and the subdomain's Route 53 records if no other address needs them. Every run — including zero-reap runs — emits a `PendingAddressesReaped` metric in the `Cabalmail` CloudWatch namespace, so absence of data means the schedule is not firing.

## Prerequisites

- Node 20.19+ or 22.12+ and npm. The workspace uses npm workspaces, not pnpm or yarn.
- For the Safari target: macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated, not committed.
- A deployed Cabalmail environment whose API carries the pending-address endpoints (`POST /new` with `pending`, `POST /confirm_address`) and whose `config.json` advertises `cognitoConfig.extensionClientId` — anything built from this repository at or after release 1.9.0.
- For publishing: a Chrome Web Store developer account and an Apple Developer Program membership.

## Repository layout

```
extensions/
  shared/     platform-agnostic core: auth (Cognito Hosted UI + PKCE), API client,
              runtime configuration, the form-detection scoring engine, address
              generation, the content-script controller, the message schema
  chrome/     the extension proper — background service worker, content script,
              Preact popup and overlay — plus the Chrome manifest template
  safari/     Safari manifest template and the Xcode host-app project spec; the
              web sources are Chrome's, rebuilt into the host app's bundle
  fixtures/   the form-detection corpus the detector is regression-tested against
  icons/      the manifest's `icons` map, generated from the source vector by
              scripts/generate-logo-assets and copied flat into both bundles
  scripts/    the build orchestrator and the page-snapshot tool
```

Bundle contents are flat by necessity, not taste: the Safari appex adds the bundle to an Xcode resources build phase, which flattens directories, so a file in a subdirectory would land loose in the appex and leave its manifest path dangling — while still looking correct in `chrome/dist`. The build fails if any path the manifest names is missing from the output, which is the guard against exactly that asymmetry.

`shared/` is the analog of `apple/CabalmailKit/` and `android/kit/`: everything with logic in it, nothing platform-specific. Per-platform code is confined to packaging glue.

## Building

[`scripts/build-extension.sh`](../scripts/build-extension.sh) wraps the workspace build. Run it from anywhere in the checkout:

```sh
# Development bundles for both browsers
./scripts/build-extension.sh --control-domain example.net

# An upload-ready Chrome package
./scripts/build-extension.sh --control-domain example.net --store
```

| Output | Contents |
|---|---|
| `extensions/chrome/dist/` | the unpacked Chrome extension |
| `extensions/safari/CabalmailExtension/Resources/` | the same bundle with Safari's manifest, inside the host app |
| `extensions/build/cabalmail-chrome-<version>.zip` | the Web Store package (`--store` only) |

All three are generated; none are committed.

**Nothing about a deployment is compiled in.** The control domain is chosen at runtime — stored per install, and asked for in the popup when it is not known — and everything else (API URL, Cognito pool and client IDs, the Hosted UI domain, the list of mail domains) is fetched from `https://admin.<control-domain>/config.json` and cached in `browser.storage.local`, keyed to the domain it came from. `--control-domain` only supplies a *default* for a fresh install, which is what lets a published build work without the user typing anything; a build made without it (the `cabalmail.example` placeholder) simply asks. The user can change servers from the popup at any time.

That is why the manifest declares `optional_host_permissions` rather than `host_permissions`: the origins the extension needs are not known until the deployment is. The popup requests `admin.<control-domain>` and the Cognito domain when it has them, which is also the prompt Safari needs anyway, since it grants host access per site regardless.

Other options: `--browser chrome|safari|both`, `--version <semver>` (default: the newest release in `CHANGELOG.md`), `--report-url <url>` (see [Forking](#forking)), `--out <dir>`. `--help` prints the full list. The underlying workspace commands, if you would rather drive them directly, are `npm run lint`, `npm test` (vitest over `shared/` plus a `tsc` type-check of `chrome/`), and `npm run build`, all from `extensions/`.

### Store builds and the manifest key

The Chrome manifest carries a `key` field, which pins the extension ID of an unpacked build to one value on every machine. That matters because the OAuth redirect URI is derived from the extension ID: without a pinned key, every developer's build would need its own entry on the Cognito app client.

The Web Store rejects a *new-item* upload whose manifest carries a `key` ("key field not allowed in manifest") and assigns the listing its own permanent ID instead. So `--store` strips the key, and the store build's extension ID — and therefore its redirect URI — differs from the development build's. Both must be registered; see [OAuth redirect URIs](#oauth-redirect-uris).

## Running a development build

A build without `--control-domain` is perfectly usable: the popup asks which server to use on first open. Supplying one just saves that step.

### Chrome

`chrome://extensions` → Developer mode → "Load unpacked" → `extensions/chrome/dist`. Every unpacked install shares the one ID the manifest `key` pins, and therefore one registered Cognito redirect URI.

### Safari

Safari registers the extension by *running the host app*, so the host app has to be built and launched. Build it ad-hoc signed — not with `CODE_SIGNING_ALLOWED=NO`, which produces a bundle with no signature at all, and the extension machinery can refuse a signature-less appex even with the unsigned-extensions toggle on:

```sh
cd extensions/safari
CABALMAIL_CONTROL_DOMAIN=<control-domain> xcodegen generate
xcodebuild -project Cabalmail.xcodeproj -scheme CabalmailExtensionHost \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
  build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
open "build/Build/Products/Debug/Cabalmail Extension.app"
```

`xcodegen generate` runs the Safari web build first, so it needs `CABALMAIL_CONTROL_DOMAIN` in its environment.

**`CabalmailExtension/Resources/` is build output, and it is gitignored.** Nothing about it comes from the repository: the web bundle is written there by `npm run build --workspace safari`, which `xcodegen generate` runs as its `preGenCommand`, and the Xcode target copies the whole directory into the appex as a folder reference (hence the `…/CabalmailExtension.appex/Contents/Resources/Resources/` path in a built product). So `git pull` followed by `xcodebuild` gives you new Swift and *stale JavaScript* — the extension keeps running whatever the last web build produced, which is a genuinely confusing failure because the source you are reading is correct. Re-run `xcodegen generate` (or `npm run build` directly) whenever you pull.

For web-only iteration, skip Xcode entirely: point Safari's unpacked-extension loader (Develop → Web Extensions) at `extensions/safari/CabalmailExtension/Resources` — the directory `npm run build` writes — and the loop is `npm run build`, then reload the extension. An extension loaded that way reports an ID of the form `com.apple.Safari.UnpackedExtensions.<hash> (UNSIGNED)`, which is also how you tell the two install routes apart. The tab-based sign-in flow works unchanged under it, because its redirect target is the admin origin rather than an extension-scoped URL.

The manifest `version` is a weak staleness check — it comes from the latest CHANGELOG release, so consecutive builds usually share one. Grep the loaded bundle for a string from the change you are testing instead:

```sh
# Non-zero means this bundle has the tab-based sign-in flow
grep -c extension-auth extensions/safari/CabalmailExtension/Resources/background.js
```

Then, in Safari: enable the Develop menu (Settings → Advanced), tick Develop → **Allow Unsigned Extensions** (admin password required; it resets every time Safari quits — re-tick each session, or run the scheme from Xcode with your team's automatic signing to avoid it), and enable the extension under Settings → Extensions, granting website access. Add "Allow in Private Browsing" to exercise the private-link handoff.

While that toggle is off, Safari *hides* unsigned extensions from the Extensions pane entirely rather than graying them out. An empty pane after a Safari relaunch therefore means the toggle reset, not that registration was lost: `pluginkit -m | grep -i cabalmail` confirms the appex is still registered, and `pluginkit -a <path-to-.appex>` forces registration in the rare case it is not.

Safari grants host permissions **per site, at the user's discretion** — unlike Chrome, which grants everything in `host_permissions` at install. The extension's sign-in button asks for the two origins it needs (`admin.<control-domain>` and `*.amazoncognito.com`) with `permissions.request` when you click it, so answering that prompt with Allow is normally the whole story; you can also set them ahead of time in Settings → Extensions → Cabalmail. Denying them is worth knowing about because of how it fails: the background worker's `config.json` fetch and its redirect interception both need that access, so a denied or unanswered grant reads as a sign-in button that does nothing.

Sign-in itself needs no per-install configuration on Safari — see [OAuth redirect URIs](#oauth-redirect-uris). The flow opens a tab on the Cognito Hosted UI; when it redirects to `https://admin.<control-domain>/extension-auth`, the background finishes the token exchange and closes the tab. If that tab stays open on the "Completing Cabalmail sign-in…" page, the interception did not fire: check the host permission first, then the background's console (Develop → Web Extension Background Content → Cabalmail), which logs `[cabalmail] sign-in completion failed:` with the reason.

## Forking

Nothing environment-specific is committed: the control domain is a build-time variable with a deliberately fake default, and every runtime value comes from your own deployment's `config.json`. Three identity-shaped values are still upstream's, and a fork should replace all three:

1. **The Chrome manifest `key`** in `extensions/chrome/manifest.template.json`, which determines your development extension ID. Regenerate it so your fork has its own identity:

   ```sh
   openssl genrsa 2048 | openssl rsa -pubout -outform DER | base64 | tr -d '\n'
   ```

   Only the public half goes in the manifest; the private half is disposable, because store uploads strip the key entirely and the Web Store signs packages itself.

2. **`CABALMAIL_REPORT_URL`**, where the popup's "Report wrong detection" link files issues. It defaults to the upstream cabal-infra tracker; point it at yours with `--report-url` (or the environment variable of the same name) at build time.

3. **The Safari bundle identifiers** — `com.cabalmail.extension-host` and its `.web-extension` child in `extensions/safari/project.yml`. Replace the reverse-DNS prefix with your own before registering App IDs, the same as the mail clients under `apple/`.

## OAuth redirect URIs

The extension is a public OAuth client: it signs in through the Cognito Hosted UI with PKCE, so no client secret is embedded anywhere. Terraform provisions a dedicated app client for it (`cabal_extension_client`), whose callback URLs are one Terraform-derived entry plus whatever you supply for Chrome.

**Safari needs no configuration at all.** Safari implements no WebExtensions `identity` API — `browser.identity` is simply undefined there — so its sign-in runs the Hosted UI in an ordinary tab redirecting to `https://admin.<control-domain>/extension-auth`, which the background intercepts via `tabs.onUpdated`; the same mechanism as the private-link handoff, with PKCE and the `state` check carrying the security. That redirect URI is registered on the app client unconditionally, and the page itself is provisioned in `modules/app/s3.tf`.

Chrome needs up to two URIs, both of the form `https://<extension-id>.chromiumapp.org/`: one for unpacked development builds, whose ID is derived from the manifest `key`, and one for the store listing, whose ID the Web Store assigns at first upload.

[`scripts/extension-redirect-uris.py`](../scripts/extension-redirect-uris.py) computes them and assembles the list:

```sh
# The development build's URI, computed offline from the committed manifest key
./scripts/extension-redirect-uris.py

# Both, once the listing exists
./scripts/extension-redirect-uris.py --store-id <chrome-store-id>
```

Terraform reads the list from the `extension_redirect_uris` variable, which `infra.yml` feeds from the GitHub environment variable `TF_VAR_EXTENSION_REDIRECT_URIS` (default `[]`). That value is expanded inside a double-quoted shell `echo` in the workflow, so every quote in the stored value must be backslash-escaped or the shell eats it and Terraform receives unparseable HCL — the same convention `TF_VAR_MAIL_DOMAINS` and `TF_VAR_AVAILABILITY_ZONES` follow. The script emits the escaped form, and `--set` writes it per environment:

```sh
./scripts/extension-redirect-uris.py --store-id <chrome-store-id> --set --env stage
```

After the next `infra.yml` run, `aws cognito-idp describe-user-pool-client` should list the real callback URLs, and `https://admin.<control-domain>/config.json` should carry `cognitoConfig.extensionClientId` and `cognitoConfig.hostedUiDomain`. The Hosted UI lives on Cognito's own prefix domain (`<prefix>.auth.<region>.amazoncognito.com`), not on your control domain; `hostedUiDomain` is where the extension reads it from, so nothing needs hard-coding.

## Verifying the pending-address backend

Run this against a non-production environment after both deploy workflows have run: `app.yml` for the Lambdas and container images, `infra.yml` for the endpoint, the reaper, and the IAM changes.

[`scripts/verify-pending-addresses.py`](../scripts/verify-pending-addresses.py) drives the lifecycle end to end. It creates a pending address, asserts the DynamoDB row carries the marker, checks that `GET /list` flags it, confirms it, checks that confirming twice returns `409`, then creates a second address, backdates it past the TTL, invokes the reaper, and asserts the row and the listing entry are gone. Addresses it creates are revoked on the way out unless you pass `--keep`.

```sh
export CABALMAIL_USERNAME='<a user in the environment Cognito pool>'
export CABALMAIL_PASSWORD='...'

./scripts/verify-pending-addresses.py \
    --control-domain example.net \
    --mail-domain example.com \
    --profile <aws profile for that account> \
    --totp 123456            # only if the user is MFA-enrolled
```

Sign-in goes straight to Cognito, so the API checks need only a pool user. The DynamoDB assertions and the reaper invocation additionally need AWS credentials for the environment's account; `--no-aws` skips those and runs the rest.

Two things cannot be automated, because they need a shell in the container or a real inbound message. Do them once per environment.

**The procmail rule regenerates.** Creating a pending address publishes an SNS reconfigure event, and within about twenty seconds the IMAP tier rescans and rewrites its pending-rule include:

```sh
aws logs tail /ecs/cabal-imap --since 5m | grep procmail-pending

TASK=$(aws ecs list-tasks --cluster cabal-mail --service-name cabal-imap \
  --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster cabal-mail --task "$TASK" --container imap \
  --interactive --command "cat /etc/procmail-pending.rc"
```

Confirming the address removes the rule again on the next reconfigure cycle.

**Mail arriving clears the flag.** Create a pending address, send it a message from an outside account, and watch the drain:

```sh
aws logs tail /ecs/cabal-imap --since 5m | grep confirm-spool-drain
# expect: [confirm-spool-drain] confirmed <address>
```

The message must still land in the user's inbox — the recipe is a pure side effect and must never divert delivery — and the row's `pending` attribute must be gone afterwards. Sending to an *already confirmed* address must not invoke the hook at all: the generated include carries no rule for it, so nothing new appears in the drain log.

One measurement is worth taking once, because it is the number the whole eager-create design exists to buy: the gap between creating an address and the relay accepting mail for it. Create a pending address and probe until `RCPT TO` succeeds (`swaks --to <address> --server smtp-in.<control-domain> --quit-after RCPT` is the easy way). Expect acceptance well inside thirty seconds — one reconfigure cycle, whose ceiling is about twenty.

## Publishing to the Chrome Web Store

### 1. Developer account

Register a [Chrome Web Store developer account](https://chrome.google.com/webstore/devconsole) (a one-time $5 fee) under an organisation identity rather than a personal one.

### 2. First upload

The first upload is the one step that cannot be scripted: creating the item is what assigns its permanent ID. Build a store package and upload it as a **new item** in the developer console.

```sh
./scripts/build-extension.sh --control-domain <control-domain> --store
# upload extensions/build/cabalmail-chrome-<version>.zip in the console
```

Record the assigned item ID. It is both an upload credential and the source of the store build's redirect URI. Two console quirks are worth knowing: items can never be deleted from the dashboard, only abandoned — so create a fresh item rather than fighting a broken draft — and the listing needs its [privacy-policy URL](#privacy-policy) before it can be published at all.

### 3. API credentials

Uploads authenticate with three values: an OAuth **client ID and client secret**, which identify the application, and a **refresh token**, which is the publisher account's standing grant. All three are needed; the refresh token is a separate artefact from the secret.

In the Google Cloud console: pick a project (which project is immaterial — reusing an existing one, such as the Android/Firebase project, disturbs neither FCM nor a Play-publisher service account, both of which are service-account based), enable the **Chrome Web Store API**, configure the OAuth consent screen, and create an OAuth client of type **Desktop Application**. Not the "Chrome Extension" type: that is a secretless client for an unrelated feature — extensions signing users into Google APIs via `chrome.identity.getAuthToken` — and cannot drive the upload API. Google's console UI churns; the [chrome-webstore-upload key guide](https://github.com/fregante/chrome-webstore-upload-keys) is the maintained recipe if the layout has moved again.

Two details are load-bearing:

- Authorise as the **Google account that owns the Web Store developer account**. The token acts as the publisher; the hosting project is irrelevant to that.
- Set the consent screen's publishing status to **"In production"**. In "Testing" mode Google expires refresh tokens after seven days, which silently kills unattended CI uploads weeks later. The `chromewebstore` scope is not on the sensitive list, so production status needs no verification review — the one-time authorisation just shows an "unverified app" interstitial.

Then mint the refresh token once, on a machine whose browser is signed in as the publisher account:

```sh
./scripts/mint-chrome-webstore-token.py --client-id <id> --client-secret <secret>
```

[The script](../scripts/mint-chrome-webstore-token.py) opens the consent screen, catches the redirect on `localhost:8818`, and exchanges the code, which removes the three ways the manual version goes wrong: the code arrives URL-encoded in the address bar, it is single-use and expires in about ten minutes, and the exchange request needs `access_type=offline&prompt=consent` or Google returns no refresh token at all. The OAuth client must list `http://localhost:8818` as a redirect URI (`--port` changes both sides).

### 4. Store the credentials

Four repository secrets (`gh secret set <NAME>`): `CHROME_WEBSTORE_EXTENSION_ID`, `CHROME_WEBSTORE_CLIENT_ID`, `CHROME_WEBSTORE_CLIENT_SECRET`, `CHROME_WEBSTORE_REFRESH_TOKEN`.

### 5. Uploads thereafter

`extensions.yml`'s `upload-chrome` job ships a store-variant zip to the listing on every `stage`/`main` push, behind a `gate-*` environment approval (gate-prod waits for a reviewer; gate-stage passes on its own) and warn-green when the `CHROME_WEBSTORE_*` secrets are absent. It uploads a **draft only** — publishing, which is what triggers a store review each time, stays a deliberate act in the developer console. Store versions are `<CHANGELOG version>.<run number>`, so repeat uploads always increase.

A listing locked by a pending review makes the upload warn and skip rather than fail; that is expected around submissions, and the next push after the review completes goes through. Never cancel an in-progress review just to swap the package — cancellation sends the item to the back of the review queue.

### Privacy-practices disclosures

The listing's privacy tab requires a justification per requested permission. The manifest deliberately requests only `storage`, `identity`, and `history`; tab manipulation and the redirector interception ride the host permission instead, so `tabs` and `webNavigation` are not requested. These texts match what the code does:

- **storage** — "Caches the user's sign-in session (OAuth tokens) and the Cabalmail server's configuration locally so the user does not have to sign in on every browser start. No browsing data is stored."
- **identity** — "Runs the OAuth 2.0 (PKCE) sign-in flow against the user's own Cabalmail server via launchWebAuthFlow. The extension never sees or stores the password."
- **history** — "When the user opens a mail link in a private window through the extension, the intermediate redirector URL (which embeds the target link) is deleted from normal-window history so the private link does not linger there. History is never read for any other purpose and never transmitted."
- **Host permissions** (requested at runtime, not granted at install) — "The extension contacts only the user's own self-hosted Cabalmail server, whose address the user supplies: the admin origin for its API and configuration, and the Amazon Cognito domain for sign-in. Because the server is chosen by the user rather than fixed by us, the manifest can only declare the permission as optional; the extension requests the two specific origins once the user names their server, and holds no access before that. The content script must run on sign-up pages to detect email fields and offer a freshly generated address — the same model as a password manager. No page content or browsing data is transmitted anywhere; the server is contacted only on explicit user action."
- **Remote code** — answer **No**: all JavaScript ships in the package; the extension does not use eval or load external scripts. Exchanging *data* with the server (the JSON API, `config.json`) is not remote code — the question is strictly about fetching executable code at runtime, which MV3's CSP largely forbids anyway. The one code-adjacent trap: the server also serves `config.js`, the JS-flavoured twin the React app executes. The extension must only ever fetch and `JSON.parse` the `.json` variant, or the "No" stops being true.

Expect a **"Broad Host Permissions" warning** at submission. It comes from the content script's `https://*/*` match, not from the two named host permissions, and it is inherent and correct to click through: automatic sign-up-form detection means running on the pages the user visits — the same surface every password manager requests — and `activeTab` cannot replace it without removing the popover-on-focus and adopt-while-typing flows. It may route the listing into the longer in-depth review; the host-permissions justification above is written to answer exactly that reviewer's question.

## The extension embedded in the Mac mail app

Per the plan's OQ9 resolution, the Safari extension's long-term home is inside the Cabalmail mail apps rather than the standalone host: `apple/project.yml` embeds it in `CabalmailMac` as the `CabalmailMacWebExtension` appex, whose Resources are the same web bundle this workspace builds (`scripts/sync-vendored.sh` builds it as part of `xcodegen generate`, with no control domain baked — the extension asks the mail app at runtime). The mail app publishes the control domain the user signed in with to the shared App Group (`ExtensionControlDomainStore`), and the extension's background asks its native handler for it, so the user never types the server twice; an explicit "Change server" choice in the extension popup still overrides it. The embedded and standalone extensions have different identities (`com.cabalmail.CabalmailMac.web-extension` vs `com.cabalmail.extension-host.web-extension`), so both can be enabled during the transition — expect two "Cabalmail" rows in Safari's Extensions pane on a machine that has both.

The iOS mail app embeds the same extension as the `CabalmailWebExtension` appex (`com.cabalmail.Cabalmail.web-extension`), destination-filtered to iOS as the NSE is — visionOS Safari extension support and provisioning are a later decision. Same handler source, same App Group handoff, same web bundle. The one capability difference is by design: iOS Safari does not support `windows.create`, so the private-link handoff does not exist there and the appex serves the suggest and adopt flows only. It needs one profile: register `com.cabalmail.Cabalmail.web-extension` **with App Groups enabled and the group assigned** (the same prerequisite as below), mint an iOS App Store profile for it, and store it as `IOS_WEBEXT_APP_STORE_PROFILE`; until it exists the iOS upload leg parks warn-green, exactly like the macOS one.

Signing needs two more per-bundle-id profiles for the new appex, one per export method, exactly as the macOS NSE did. **Register the App ID with the App Groups capability enabled and `group.com.cabalmail.Cabalmail` assigned before minting anything** — a profile inherits its entitlements from the App ID at mint time, so a profile minted against a capability-less App ID archives fine and then fails at export with `doesn't include the App Groups capability` / `doesn't support the group.com.cabalmail.Cabalmail App Group`; adding the capability afterwards invalidates the profile, so re-mint. `make-mac-profile.py` prints the App ID's enabled capabilities before it mints for exactly this reason, and `--replace` deletes the invalidated same-named profile the API would otherwise refuse to duplicate. Then mint both for `com.cabalmail.CabalmailMac.web-extension` and store them as `MAC_WEBEXT_APP_STORE_PROFILE` and `MAC_WEBEXT_DEVID_PROFILE` (`scripts/make-mac-profile.py` if the portal refuses; `Platform` must include `OSX`). **Until both exist, `apple.yml`'s macOS upload leg parks warn-green** — the same skip-not-fail posture as every other missing signing secret, but it does pause macOS mail-app TestFlight uploads, so mint them promptly.

## Publishing to the App Store (Safari)

The Safari extension ships inside a minimal macOS host app (`extensions/safari/`), through the same Apple Developer Program membership as the Cabalmail mail clients.

1. **App IDs.** Register two identifiers in the developer portal: one for the host app (`com.cabalmail.extension-host` upstream — use your own prefix) and one for the extension, which must be the host's identifier plus a suffix (`...extension-host.web-extension`). Neither needs capabilities.
2. **App Store Connect record.** Create a new macOS app against the host app's identifier. Two form choices cannot be revisited or bite later: **SKU** is internal-only (it appears in financial reports) but immutable, so reuse the bundle ID unless your other records follow another pattern; and **User Access** should be **Full Access** — "Limited Access" hides the app from team members, and therefore from App Store Connect API keys whose associated user lacks access, which surfaces as a baffling app-not-found in the CI upload leg rather than anything obviously permission-shaped.
3. **Secrets.** Most are the mail app's, reused as-is: `APPLE_TEAM_ID`, the signing certificates (`APPLE_DISTRIBUTION_CERT_P12`/`_PASSWORD`, `MAC_INSTALLER_CERT_P12`/`_PASSWORD`), and the account-scoped ASC API key (`APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8`). Two are specific to the extension, because manual signing needs a Mac App Store provisioning profile **per bundle ID**: mint one for each App ID from step 1 and store them base64-encoded as `MAC_EXT_HOST_APP_STORE_PROFILE` and `MAC_EXT_WEB_APP_STORE_PROFILE`. The portal cannot mint macOS profiles for some App IDs through its UI; if it fights you, [`scripts/make-mac-profile.py`](../scripts/make-mac-profile.py) is the workaround, and the produced profile's `Platform` array must include `OSX`.
4. **TestFlight groups.** On the host app's record, create two internal testing groups named exactly **`stage`** and **`prod`** (lowercase — the upload job looks them up by name), under TestFlight → Internal Testing → **+**, and leave **"Enable automatic distribution" unchecked**. CI attaches each uploaded build to the group matching its branch (`stage` pushes → `stage`, `main` → `prod`) via [`assign-testflight-group.py`](../.github/scripts/assign-testflight-group.py), the same script and the same reasoning as the mail apps ([docs/apple.md](./apple.md)) — automatic distribution would give every group every build and erase the routing, and the API refuses explicit attaches to such groups. The routing still matters even though the control domain is now chosen at runtime: a build's *default* server is whichever environment produced it, so a tester who takes the default lands on that deployment. A build that cannot be attached fails the job rather than silently reaching nobody.
5. **Export compliance.** The host app declares `ITSAppUsesNonExemptEncryption: false` in its `Info.plist` (via `project.yml`), the same declaration the mail-app targets carry: the extension uses only standard TLS and the browser's own WebCrypto, whose one use is a SHA-256 PKCE challenge — a hash, not a cipher. Without that key every upload lands in App Store Connect as **Missing Compliance**, and that is not merely a paperwork state: such a build is not internally testable, so the TestFlight attach in step 4 fails with `HTTP 422 — Build is not assignable`. If you meet that error on an already-uploaded build, answer the encryption question in App Store Connect (**None of the algorithms mentioned above**) to release that build; the `Info.plist` key is what stops it recurring.
6. **Uploads.** `extensions.yml`'s `upload-safari` job — behind the same `gate-*` approval as the Chrome leg — archives the manually-signed host app with its embedded extension, exports an app-store-connect `.pkg`, and uploads it via `altool` with the API key, mirroring `apple.yml`'s `upload-mac` leg including its trust-the-verdict-banner handling. It parks warn-green until the two profile secrets exist. Versions are the CHANGELOG marketing version with a clock build number.

## Privacy policy

Both store listings require a privacy-policy URL, and the extension's data story is distinct enough from the service's to need its own section. The service policy served at `https://www.<control-domain>/privacy.html` (source: [`front-door/privacy.html`](../front-door/privacy.html)) is its home. That section must state that the extension transmits no browsing data to anyone, that it contacts only the operator's own Cabalmail API, and that it does so only on explicit user action.

## Form-detection corpus

Sign-up and sign-in forms are not distinguishable by any single signal — notably not by HTTP verb, since both POST. The detector is a weighted scoring engine over about a dozen signals (`autocomplete="new-password"`, two password fields, submit-button vocabulary, form action, page path, headings, and so on), with an upper threshold for "sign-up", a lower one for "sign-in", and an ambiguous band between them where the extension shows a passive badge and does nothing on its own. Weights and thresholds live in `extensions/shared/src/detect/config.ts`.

The corpus in `extensions/fixtures/` keeps that tuning honest. It is two levels deep — a tree name, then the expected classification: `synthetic/signup/`, `captured/signin/`, and so on. `synthetic/` is hand-authored seed material; sibling trees hold snapshots of real pages. The corpus test picks up any tree it finds and asserts every fixture still classifies as its category directory says. Accuracy in the wild depends on real pages, across SaaS, e-commerce, news, government, banking, and localized sites.

To add one:

```sh
cd extensions
npm i -D playwright && npx playwright install chromium   # local only; deliberately not a workspace dependency
node scripts/snapshot.mjs https://example.com/signup captured/signup/example-2026-08.html
npm run test --workspace shared
```

Some sites serve a bot interstitial to headless Chromium and the real page to a visible one — `stackoverflow.com/users/login` answers 403 `Just a moment...` headless and 200 `Log In - Stack Overflow` headed. A capture that hits one says so, naming the status and the title; re-run it with `--headed`.

What a capture does and does not preserve:

- **Markup, attributes and text are exact.** Script *bodies* are stripped — the `<script>` elements and their attributes stay, so structure is unchanged and no detector signal is affected.
- **CSS is inlined at capture time**, so the fixture carries whatever `visibility` and `display` the live page computed. This matters: a fixture is replayed from a different origin than it was captured from, and jsdom fetches no external resources at all, so a `<link>` stylesheet would simply never apply. Before inlining, Stack Overflow's sign-up modal computed `visibility: hidden; display: flex` live and `visible / block` from the capture — a hidden form reading as a visible one.
- **A stylesheet the capture could not fetch is named on stderr** (`not inlined: <href> (HTTP 403)`) and left as a `<link>`. Treat a visibility-dependent expectation about that part of the page as unsupported by the fixture.
- **Relative `url()` targets inside an inlined sheet are rewritten absolute**; `@import` is not followed, and neither are images or fonts, so a fixture is not a pixel-accurate reproduction. It is a structural and computed-style one, which is what the scorer reads.

Commit the fixture; do not commit the Playwright dependency. A fixture that misclassifies is the signal to tune the weights and thresholds until the whole corpus passes — never special-case a site, and never delete an inconvenient fixture. Users can also report a misdetection from the popup, which opens a pre-labelled issue on the tracker `CABALMAIL_REPORT_URL` points at; every accepted report should end up here as a fixture.

## Continuous integration

`.github/workflows/extensions.yml` runs on any change under `extensions/`:

| Job | Runner | What it does |
|---|---|---|
| `test` | ubuntu | lint, vitest (including the corpus), `tsc` type-check, both bundle builds, and an artifact upload of the Chrome bundle |
| `build-safari` | macOS | `xcodegen generate` plus an unsigned `xcodebuild` of the host app — Safari packaging breakage without needing signing credentials |
| `upload-chrome` | ubuntu | on `stage`/`main` pushes only: store-variant zip to the Web Store listing as a draft |
| `upload-safari` | macOS | on `stage`/`main` pushes only: signed host app to App Store Connect |

Both upload jobs sit behind a `gate-*` environment approval and go warn-green when their credentials are absent, so a fork that has not provisioned store accounts still gets a green pipeline. The `test` job builds against the repository variable `TF_VAR_CONTROL_DOMAIN`, falling back to the placeholder domain when it is unset.

No job in this workflow deploys to AWS: the extension's backend rides the ordinary `app.yml` and `infra.yml` pipelines with the rest of the Lambda and Terraform code.

## Related documents

- [Browser extension plan](./1.x/browser-extension-plan.md) — design rationale, detector research, and the implementation record.
- [Operations](./operations.md) — where the extension sits among the rest of the running system.
- [Setup](./setup.md) — standing up an environment in the first place.
