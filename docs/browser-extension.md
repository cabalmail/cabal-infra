# Browser extension

Cabalmail's signature user behaviour is a separate email address per vendor: mint one when you sign up for a service, revoke it when it starts attracting spam. The browser extension collapses that flow into the sign-up form itself, the way a password manager collapses password generation into it. It ships for Chrome (Manifest V3) and Safari (a Web Extension inside a small macOS host app) from one TypeScript codebase in [`extensions/`](../extensions/).

This document is the whole build, distribution, and operations story for that extension: how to build it, how to point it at your environment, how to verify its backend, and how to publish it to the two stores. It assumes you are comfortable with AWS and a JavaScript toolchain but know nothing else about Cabalmail. The design rationale and phase-by-phase implementation record live separately, in [the plan](./1.x/browser-extension-plan.md).

## What the extension does

Three responsibilities, all driven from the content script and the popup:

- **Suggest.** On a page the detector scores as a sign-up form, the extension offers a freshly generated address for the email field. Accepting it creates the address immediately, before the form is submitted.
- **Adopt.** If the user types an address that parses as one of their own domains but does not exist yet, the extension offers to create it before submit.
- **Open privately.** The Cabalmail mail clients cannot open a private browser window directly — no OS API allows it — so they navigate to a redirector page the extension intercepts and re-opens in a private window.

The extension talks only to the API Gateway surface of your own deployment. It never connects to IMAP or SMTP, never parses mail, and never reports anything about the sites a user visits.

### Terms

| Term | Meaning |
|---|---|
| **Control domain** | The domain your deployment's own infrastructure lives on. The admin web app and the runtime configuration document are served from `admin.<control-domain>`; the API shares that origin. Set by `TF_VAR_CONTROL_DOMAIN`. |
| **Mail domain** | A domain users' addresses live on, from `TF_VAR_MAIL_DOMAINS`. Addresses are always on a subdomain (`user@subdomain.example.com`), never on the apex. |
| **Pending address** | An address created eagerly, before the sign-up form is submitted. Fully provisioned — DNS, sendmail maps — but flagged unconfirmed, and revoked automatically if it is never used. See below. |

### The pending-address model

Most sign-up backends send a verification message within seconds of form submission, and a brand-new Cabalmail address needs DNS propagation plus a sendmail configuration reload before it can receive anything. So the extension creates the address at the moment the user commits to it — while they are still filling in the rest of the form — which typically buys tens of seconds of runway.

An address created that way carries `pending=true` and a `pending_since` timestamp in the `cabal-addresses` DynamoDB table. Three things can clear it:

1. The extension calls `POST /confirm_address` when the form is actually submitted.
2. Mail arrives at the address. The IMAP tier keeps a generated procmail include (`/etc/procmail-pending.rc`) with one side-effect-only rule per pending address; the rule spools a signal file that a root daemon drains into a conditional DynamoDB update. Delivery is unaffected either way.
3. Neither happens, and the hourly `reap_pending_addresses` Lambda revokes the address once it is older than `PENDING_TTL_HOURS` (default 24) — removing the row, the shared DNS records if no other address needs them, and emitting a `PendingAddressesReaped` metric in the `Cabalmail` CloudWatch namespace on every run, including zero-reap runs.

## Prerequisites

- Node 20.19+ or 22.12+ and npm (the workspace uses npm workspaces, not pnpm or yarn).
- For the Safari target: macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated, not committed.
- A deployed Cabalmail environment to point at. The extension needs one whose API carries the pending-address endpoints and whose configuration document advertises an extension app client — that is, anything built from this repository at or after release 1.9.0.
- For publishing: a Chrome Web Store developer account and an Apple Developer Program membership. See [Publishing](#publishing-to-the-chrome-web-store).

## Repository layout

```
extensions/
  shared/     platform-agnostic core: auth (Cognito Hosted UI + PKCE), API client,
              runtime configuration, the form-detection scoring engine, address
              generation, the content-script controller, the message schema
  chrome/     the extension proper — background service worker, content script,
              Preact popup and overlay — plus the Chrome manifest template
  safari/     Safari manifest template and the Xcode host-app project spec;
              the web sources are Chrome's, rebuilt into the host app's bundle
  fixtures/   the form-detection corpus the detector is regression-tested against
  scripts/    the build orchestrator and the page-snapshot tool
```

`shared/` is the analog of `apple/CabalmailKit/` and `android/kit/`: everything with logic in it, nothing platform-specific. Per-platform code is confined to packaging glue.

## Building

`scripts/build-extension.sh` wraps the workspace build. Run it from anywhere in the checkout:

```sh
# Development bundles for both browsers
./scripts/build-extension.sh --control-domain example.net

# An upload-ready Chrome package
./scripts/build-extension.sh --control-domain example.net --store
```

Outputs:

| Path | Contents |
|---|---|
| `extensions/chrome/dist/` | the unpacked Chrome extension |
| `extensions/safari/CabalmailExtension/Resources/` | the same bundle, with Safari's manifest, inside the host app |
| `extensions/build/cabalmail-chrome-<version>.zip` | the Web Store package (`--store` only) |

All three are generated and none are committed.

**The control domain is the only value baked in at build time.** Everything else — API URL, Cognito pool and client IDs, the Hosted UI domain, the list of mail domains — is fetched at runtime from `https://admin.<control-domain>/config.json` and cached in `browser.storage.local`. Omitting `--control-domain` builds against the `cabalmail.example` placeholder, which compiles but reaches nothing; the popup says so rather than failing silently.

Other options: `--browser chrome|safari|both`, `--version <semver>` (defaults to the newest release in `CHANGELOG.md`), `--report-url <url>` (see [Forking](#forking)). `--help` prints the full list.

### The manifest key, and why store builds differ

The Chrome manifest carries a `key` field, which pins the extension ID of an unpacked build to one value on every machine. That matters because the OAuth redirect URI is derived from the extension ID: without a pinned key, every developer's build would need its own entry in the Cognito app client.

The Web Store rejects a *new-item* upload whose manifest carries a `key` ("key field not allowed in manifest") and assigns the listing its own permanent ID instead. So `--store` strips the key, and the store build's extension ID — and therefore its redirect URI — is different from the development build's. Both need to be registered; see [OAuth redirect URIs](#oauth-redirect-uris).

## Running a development build

Build against a real environment first, then load the result:

**Chrome.** Open `chrome://extensions`, enable Developer mode, choose "Load unpacked", and select `extensions/chrome/dist`.

**Safari.** Generate and build the host app, then enable the extension:

```sh
cd extensions/safari
CABALMAIL_CONTROL_DOMAIN=example.net xcodegen generate   # rebuilds the web bundle first
xcodebuild -project Cabalmail.xcodeproj -scheme CabalmailExtensionHost \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Run the built host app once, then enable the extension in Safari Settings → Extensions. Safari refuses unsigned extensions until you tick "Allow unsigned extensions" in its Develop menu; that setting resets when Safari restarts.

One Safari difference matters before you try to sign in: its OAuth redirect URL is not derivable the way Chrome's is. It is a `safari-web-extension://` URL tied to the installation, so read it out of the installed extension — evaluate `browser.identity.getRedirectURL()` in its background console — and register that, as described under [OAuth redirect URIs](#oauth-redirect-uris).

## Forking

Nothing environment-specific is committed — the control domain is a build-time variable with a deliberately fake default, and every runtime value comes from your own deployment's `config.json`. Three identity-shaped values are still upstream's, and a fork should replace all three:

1. **The Chrome manifest `key`** in `extensions/chrome/manifest.template.json`, which determines your development extension ID. Generate your own:

   ```sh
   openssl genrsa 2048 | openssl rsa -pubout -outform DER | base64 | tr -d '\n'
   ```

   Only the public half goes in the manifest; the private key is disposable, because store uploads strip the key entirely and the Web Store signs packages itself.

2. **`CABALMAIL_REPORT_URL`**, where the popup's "report wrong detection" link files issues. It defaults to the upstream tracker; point it at yours with `--report-url` (or the environment variable of the same name) at build time.

3. **The Safari bundle identifiers** — `com.cabalmail.extension-host` and its `.web-extension` child in `extensions/safari/project.yml`. Replace the reverse-DNS prefix with your own before registering App IDs.

## OAuth redirect URIs

The extension is a public OAuth client: it signs in through the Cognito Hosted UI with PKCE, so no client secret is embedded anywhere. Terraform provisions a dedicated app client for it (`cabal_extension_client`) whose callback URLs must list one URI per shipped build. Until you set them, the client carries a loopback placeholder and sign-in cannot complete.

There are up to three URIs:

| Build | URI | Where it comes from |
|---|---|---|
| Chrome, unpacked | `https://<id>.chromiumapp.org/` | derived offline from the manifest `key` |
| Chrome, store listing | `https://<id>.chromiumapp.org/` | the store-assigned item ID, visible in the developer console after the first upload |
| Safari | `safari-web-extension://<uuid>/` | evaluate `browser.identity.getRedirectURL()` in the installed extension's background console — it is per-installation, so read it, don't guess |

`scripts/extension-redirect-uris.py` computes the derivable ones and assembles the list:

```sh
# The development build's URI, computed from the committed manifest key
./scripts/extension-redirect-uris.py

# The full list, with the store and Safari URIs added
./scripts/extension-redirect-uris.py --store-id <store-item-id> \
    --uri 'safari-web-extension://<uuid>/'
```

Terraform reads the list from the `extension_redirect_uris` variable, which `infra.yml` feeds from the GitHub environment variable `TF_VAR_EXTENSION_REDIRECT_URIS` (default `[]`). That value is expanded inside a double-quoted shell `echo` in the workflow, so every quote in the stored value must be backslash-escaped or the shell eats it and Terraform receives unparseable HCL — the same convention `TF_VAR_MAIL_DOMAINS` and `TF_VAR_AVAILABILITY_ZONES` follow. The script emits the escaped form, and `--set` writes it for you:

```sh
./scripts/extension-redirect-uris.py --store-id <store-item-id> --set --env stage
```

After the next `infra.yml` run, `aws cognito-idp describe-user-pool-client` should show the real callback URLs, and `https://admin.<control-domain>/config.json` should carry `cognitoConfig.extensionClientId` and `cognitoConfig.hostedUiDomain`. Note that the Hosted UI lives on Cognito's own prefix domain (`<prefix>.auth.<region>.amazoncognito.com`), not on your control domain; `hostedUiDomain` is where the extension reads it from, so you do not need to hard-code it anywhere.

## Verifying the pending-address backend

Run this against a non-production environment after both deploy workflows have run — `app.yml` for the Lambdas and container images, `infra.yml` for the endpoint, the reaper, and the IAM changes.

`scripts/verify-pending-addresses.py` drives the whole lifecycle end to end: it creates a pending address, asserts the DynamoDB row carries the marker, checks that `GET /list` flags it, confirms it, checks that confirming twice returns `409` (which the extension treats as success by contract), then creates a second address, backdates it past the TTL, invokes the reaper, and asserts the row and the listing entry are gone. Addresses it creates are revoked on the way out.

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

Two checks cannot be automated, because they need a shell in the container or a real inbound message. Do them once per environment:

**The procmail rule regenerates.** Creating a pending address publishes an SNS reconfigure event, and within about twenty seconds the IMAP tier rescans and rewrites its pending-rule include. Watch it happen, or look directly:

```sh
aws logs tail /ecs/cabal-imap --since 5m | grep procmail-pending

TASK=$(aws ecs list-tasks --cluster cabal-mail --service-name cabal-imap \
  --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster cabal-mail --task "$TASK" --container imap \
  --interactive --command "cat /etc/procmail-pending.rc"
```

**Mail arriving clears the flag.** Create a pending address, send it a message from an outside account, and watch the drain:

```sh
aws logs tail /ecs/cabal-imap --since 5m | grep confirm-spool-drain
# expect: [confirm-spool-drain] confirmed <address>
```

The message must still land in the user's inbox — the recipe is side-effect-only and must never divert delivery — and the DynamoDB row's `pending` attribute must be gone. Sending to an *already confirmed* address must not invoke the hook at all: the generated include carries no rule for it, so nothing new appears in the drain log.

One further measurement is worth taking once, because it is the number the whole eager-create design exists to buy: the gap between creating an address and the relay accepting mail for it. Create a pending address and probe until `RCPT TO` succeeds (`swaks --to <address> --server smtp-in.<control-domain> --quit-after RCPT` is the easy way). Expect acceptance well inside thirty seconds — one reconfigure cycle.

## Publishing to the Chrome Web Store

### One-time setup

1. **Developer account.** Register a [Chrome Web Store developer account](https://chrome.google.com/webstore/devconsole) (a one-time $5 fee) under an organisation identity rather than a personal one.
2. **First upload.** Build a store package and upload it as a **new item** in the developer console by hand. This is the only upload that cannot be scripted: creating the item is what assigns its permanent ID.

   ```sh
   ./scripts/build-extension.sh --control-domain <control-domain> --store
   # then upload extensions/build/cabalmail-chrome-<version>.zip in the console
   ```

   Record the assigned item ID; it is both an upload credential and the source of the store build's redirect URI. Note also that items can never be deleted from the dashboard, only abandoned — if a draft goes wrong, create a fresh item rather than fighting it.
3. **API credentials.** Uploads authenticate with an OAuth refresh token. Google's console UI churns often enough that the best instructions are the maintained ones in the [chrome-webstore-upload key guide](https://github.com/fregante/chrome-webstore-upload/blob/main/How%20to%20generate%20Google%20API%20keys.md). In outline: create a Google Cloud project, enable the **Chrome Web Store API**, configure the OAuth consent screen with your account as a test user, create an OAuth client, then mint a refresh token authorised for the `https://www.googleapis.com/auth/chromewebstore` scope.
4. **Store the credentials.** Four values, as repository secrets (`gh secret set <NAME>`): `CHROME_WEBSTORE_EXTENSION_ID`, `CHROME_WEBSTORE_CLIENT_ID`, `CHROME_WEBSTORE_CLIENT_SECRET`, `CHROME_WEBSTORE_REFRESH_TOKEN`.
5. **Privacy policy URL.** The listing cannot be published without one. See [Privacy policy](#privacy-policy).

### Subsequent uploads

`scripts/upload-extension-chrome.sh` takes the package the build script produced, exchanges the refresh token, uploads, and optionally publishes:

```sh
export CHROME_WEBSTORE_EXTENSION_ID=... CHROME_WEBSTORE_CLIENT_ID=... \
       CHROME_WEBSTORE_CLIENT_SECRET=... CHROME_WEBSTORE_REFRESH_TOKEN=...

./scripts/upload-extension-chrome.sh --dry-run                  # check credentials only
./scripts/upload-extension-chrome.sh --target trustedTesters    # tester group
./scripts/upload-extension-chrome.sh --target default           # public; enters review
```

With no `--target` it uploads a draft and leaves publishing to the console. It refuses a package that still carries a manifest `key`, which is the most common way a store upload fails with an unhelpful error.

### Privacy-practices disclosures

The listing's privacy tab wants a justification per requested permission. The manifest requests only `storage`, `identity`, and `history` — tab manipulation and the redirector interception ride the host permission instead, so `tabs` and `webNavigation` are deliberately not requested. The following texts match what the code actually does:

- **storage** — "Caches the user's sign-in session (OAuth tokens) and the Cabalmail server's configuration locally so the user does not have to sign in on every browser start. No browsing data is stored."
- **identity** — "Runs the OAuth 2.0 (PKCE) sign-in flow against the user's own Cabalmail server via launchWebAuthFlow. The extension never sees or stores the password."
- **history** — "When the user opens a mail link in a private window through the extension, the intermediate redirector URL (which embeds the target link) is deleted from normal-window history so the private link does not linger there. History is never read for any other purpose and never transmitted."
- **Host permissions** — "The extension contacts only the user's own self-hosted Cabalmail server: the admin origin for its API and configuration, and the Amazon Cognito domain for sign-in. The content script must run on sign-up pages to detect email fields and offer a freshly generated address — the same model as a password manager. No page content or browsing data is transmitted anywhere; the server is contacted only on explicit user action."
- **Remote code** — answer **No**. All JavaScript ships in the package; the extension neither evaluates strings nor loads external scripts.

## Publishing to the App Store (Safari)

The Safari extension ships inside a minimal macOS host app (`extensions/safari/`), distributed through the same Apple Developer Program membership as the Cabalmail mail clients.

1. **App IDs.** Register two identifiers in the developer portal: one for the host app (`com.cabalmail.extension-host` upstream — use your own prefix) and one for the extension, which must be the host's identifier plus a suffix (`...extension-host.web-extension`). Neither needs any capabilities.
2. **App Store Connect record.** Create a new macOS app against the host app's identifier.
3. **Credentials.** The App Store Connect API-key secrets the mail clients already use cover this app too — `APPLE_APP_STORE_CONNECT_API_KEY_ID`, `..._ISSUER_ID`, `..._API_KEY`, and `APPLE_DEVELOPER_TEAM_ID`. The key is account-scoped, so there is nothing new to mint.
4. **Signing.** One pitfall carries over from the mail clients: the developer portal cannot mint macOS provisioning profiles for universal App IDs through its UI. If signing fights you, [`scripts/make-mac-profile.py`](../scripts/make-mac-profile.py) is the workaround, and the resulting profile's `Platform` array must include `OSX`.

Archive and upload with `xcodebuild -exportArchive` and `xcrun altool`/`notarytool` exactly as for the mail clients; the host app has no unusual entitlements.

## Privacy policy

Both stores require a privacy-policy URL on the listing, and the extension's data story is different enough from the service's to need its own paragraph. The service policy served at `https://www.<control-domain>/privacy.html` (source: [`front-door/privacy.html`](../front-door/privacy.html)) is the natural home. It must state, in the extension's own section: that the extension transmits no browsing data to anyone; that it contacts only the operator's own Cabalmail API; and that it does so only on explicit user action.

## Form-detection corpus

Sign-up and sign-in forms are not distinguishable by any single signal — notably not by HTTP verb, since both POST. The detector is therefore a weighted scoring engine over about a dozen signals (`autocomplete="new-password"`, two password fields, submit-button vocabulary, form action, page path, headings, and so on), with an upper threshold for "sign-up", a lower one for "sign-in", and an ambiguous band in between where the extension shows a passive badge and does nothing on its own. Weights and thresholds live in `extensions/shared/src/detect/config.ts`.

The corpus in `extensions/fixtures/` is what keeps that tuning honest. It is two levels deep — a tree name, then the expected classification: `synthetic/signup/`, `captured/signin/`, and so on. The `synthetic/` tree is hand-authored seed material; sibling trees hold snapshots of real pages, and the corpus test picks up any tree it finds, asserting that every fixture still classifies as its category directory says.

To add a page:

```sh
cd extensions
npm i -D playwright && npx playwright install chromium   # local only; not a workspace dependency
node scripts/snapshot.mjs https://example.com/signup captured/signup/example-2026-08.html
npm run test --workspace shared
```

Commit the fixture; do not commit the Playwright dependency. When a new fixture misclassifies, tune the weights and thresholds until the entire corpus passes again — never special-case a site, and never delete an inconvenient fixture. Users can also report a misdetection from the popup, which opens a pre-labelled issue on the tracker `CABALMAIL_REPORT_URL` points at; every accepted report should end up here as a fixture.

## Continuous integration

`.github/workflows/extensions.yml` runs on any change under `extensions/`:

- **`test`** (Linux) — `npm run lint`, `npm test` (vitest over `shared/`, including the corpus, plus a `tsc` type-check of `chrome/`), then builds both bundles and archives the Chrome one as a workflow artifact. It builds against the repository variable `TF_VAR_CONTROL_DOMAIN`, falling back to the placeholder domain on forks that have not set it.
- **`build-safari`** (macOS) — `xcodegen generate` followed by an unsigned `xcodebuild` of the host app, which is what catches Safari-side packaging breakage without needing signing credentials.

Neither job deploys anything to AWS; the extension's backend rides the ordinary `app.yml` and `infra.yml` pipelines with the rest of the Lambda and Terraform code. Store uploads are the scripts above, run against a tagged release.

## Related documents

- [Browser extension plan](./1.x/browser-extension-plan.md) — design rationale, detector research, and the phase-by-phase implementation record.
- [Operations](./operations.md) — where this extension sits among the rest of the running system.
- [Setup](./setup.md) — standing up an environment in the first place.
