# Browser extension: operator runbook

The address-suggesting browser extension (Chrome MV3 + Safari Web Extension) lives in [`extensions/`](../extensions/README.md); its design and phase status live in [the plan doc](./1.x/browser-extension-plan.md). This runbook covers everything an operator must do by hand: verifying the pending-address backend in a live environment, provisioning the two store accounts, wiring the OAuth redirect URIs once store-assigned extension IDs exist, and growing the form-detection corpus. Steps are ordered roughly as you would perform them; each section is independent.

The extension's server side is the eager-create model: an address created with `pending=true` is fully provisioned but unconfirmed, and is confirmed by any one of three signals — the extension's `/confirm_address` call on form submit, mail actually arriving at the address (the imap tier's procmail hook), or nothing, in which case the hourly `reap_pending_addresses` Lambda revokes it after the TTL (default 24h, `PENDING_TTL_HOURS` on the function).

## 1. Verify the pending-address backend

Run this against a non-prod environment after the backend has deployed (both `app.yml` for the Lambdas and containers, and `infra.yml` for the new endpoint, the reaper, and the IAM changes). You need AWS credentials for the environment's account and a test user in its Cognito pool.

### 1.1 Get an API token

```sh
CONTROL_DOMAIN=example.net             # the environment's control domain
MAIL_DOMAIN=example.com                # one of its mail domains
API="https://admin.${CONTROL_DOMAIN}/prod"
CLIENT_ID=$(curl -s "https://admin.${CONTROL_DOMAIN}/config.json" | jq -r .cognitoConfig.poolData.ClientId)

aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id "$CLIENT_ID" \
  --auth-parameters "USERNAME=<user>,PASSWORD=<password>"
```

If the user is MFA-enrolled the response is a `SOFTWARE_TOKEN_MFA` challenge instead of tokens; answer it with the `Session` value from the response:

```sh
aws cognito-idp respond-to-auth-challenge \
  --client-id "$CLIENT_ID" \
  --challenge-name SOFTWARE_TOKEN_MFA \
  --session "<Session from initiate-auth>" \
  --challenge-responses "USERNAME=<user>,SOFTWARE_TOKEN_MFA_CODE=<6 digits>"
```

Either way, export the **IdToken** (the API takes it raw, no `Bearer` prefix):

```sh
TOKEN="<AuthenticationResult.IdToken>"
```

### 1.2 Create a pending address and watch it provision

```sh
ADDR="rbtest1@rbsub1.${MAIL_DOMAIN}"
curl -s -X POST "$API/new" -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"username\":\"rbtest1\",\"subdomain\":\"rbsub1\",\"tld\":\"${MAIL_DOMAIN}\",\"comment\":\"runbook\",\"address\":\"${ADDR}\",\"pending\":true}"
```

Expect `201` with the address. Confirm the row carries the marker:

```sh
aws dynamodb get-item --table-name cabal-addresses \
  --key "{\"address\":{\"S\":\"${ADDR}\"}}" \
  --query 'Item.{pending:pending,since:pending_since}'
```

The `POST` publishes an SNS reconfigure event, so within ~20 seconds the imap tier rescans and regenerates `/etc/procmail-pending.rc` with one rule for the address. Two ways to see it:

```sh
# From the container logs:
aws logs tail /ecs/cabal-imap --since 5m | grep 'procmail-pending'

# Or directly, via ECS exec:
TASK=$(aws ecs list-tasks --cluster cabal-mail --service-name cabal-imap \
  --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster cabal-mail --task "$TASK" --container imap \
  --interactive --command "cat /etc/procmail-pending.rc"
```

`GET /list` should show the address with `"pending": true`, and it should also appear in the admin app's address list.

### 1.3 Confirm via the endpoint, and check idempotency

```sh
curl -s -X POST "$API/confirm_address" -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"address\":\"${ADDR}\"}"
```

Expect `200`; the `get-item` above should now show no `pending` attribute, and after the next reconfigure cycle the procmail rule is gone. Repeat the same call: expect `409` ("already confirmed") — the extension treats that as success by contract.

### 1.4 Clear-on-receive (the procmail hook)

Create a second pending address (as in 1.2), then send a test message to it from an outside account. Watch for the drain to fire, then verify the flag cleared and the message still delivered:

```sh
aws logs tail /ecs/cabal-imap --since 5m | grep confirm-spool-drain
# expect: [confirm-spool-drain] confirmed <address>

aws dynamodb get-item --table-name cabal-addresses \
  --key "{\"address\":{\"S\":\"<address>\"}}" --query 'Item.pending'
# expect: null
```

The recipe is `:0 wc` — a pure side effect — so delivery must be unaffected; check the message landed in the test user's inbox. Sending a message to an already-confirmed address must NOT invoke the hook (the include file carries no rule for it; nothing new in the drain log).

### 1.5 The TTL reaper

Create a third pending address, backdate its timestamp past the TTL, and invoke the reaper by hand:

```sh
aws dynamodb update-item --table-name cabal-addresses \
  --key "{\"address\":{\"S\":\"<address>\"}}" \
  --update-expression 'SET pending_since = :old' \
  --expression-attribute-values '{":old":{"S":"2000-01-01T00:00:00+00:00"}}'

aws lambda invoke --function-name reap_pending_addresses /dev/stdout
aws logs tail /cabal/lambda/reap_pending_addresses --since 5m
```

Expect `{"scanned": 1, "reaped": 1}`, a `[reap-pending] reaped <address>` log line, the DynamoDB row gone, the subdomain's Route 53 records removed (unless another active address shares the subdomain), and the address absent from `/list`. The run also emits the `PendingAddressesReaped` metric in the `Cabalmail` CloudWatch namespace — every run, including zero-reap runs, so absence of data means the schedule is not firing.

### 1.6 DNS-propagation headroom (optional but worth doing once)

The whole point of eager-create is that the address can receive mail by the time a sign-up flow sends its verification message. Measure the gap: create a pending address, then repeatedly probe until the relay accepts it (`swaks --to <address> --server smtp-in.${CONTROL_DOMAIN} --quit-after RCPT` if you have swaks, or any SMTP client issuing `RCPT TO`). Target is acceptance well under 30 seconds from creation; typical is one reconfigure cycle (~20s ceiling).

Clean up any leftover runbook addresses via the admin app or `DELETE /revoke` when done.

## 2. Chrome Web Store

One-time bring-up; needed before the Chrome build can be distributed and before the extension's real redirect URI exists.

1. **Developer account.** Register a [Chrome Web Store developer account](https://chrome.google.com/webstore/devconsole) ($5 one-time) under an organization identity, not a personal one.
2. **First upload (manual).** Build the store variant and zip it — `cd extensions && CABALMAIL_CONTROL_DOMAIN=<control-domain> EXTENSION_STORE_BUILD=1 npm run build && (cd chrome/dist && zip -r ../chrome.zip .)` — and upload it as a **new item** in the developer console. `EXTENSION_STORE_BUILD=1` strips the manifest `key`: the Web Store rejects any new-item upload that carries one ("key field not allowed in manifest") and instead assigns the listing its own permanent ID at this first upload — record it, because its redirect URI must be registered alongside the dev one (section 4). The `key` stays in normal (dev) builds, where it pins the unpacked-extension ID to one known value on every machine. Also note: items can never be deleted from the dashboard, only abandoned — upload to a fresh item rather than fighting a stale draft. The listing needs the privacy-policy URL (section 6) before it can be published.
3. **API credentials for CI.** The upload automation authenticates with an OAuth refresh token. Google's console UI churns; follow the maintained recipe in the [chrome-webstore-upload key guide](https://github.com/fregante/chrome-webstore-upload/blob/main/How%20to%20generate%20Google%20API%20keys.md). In outline: pick a Google Cloud project, enable the **Chrome Web Store API**, configure the OAuth consent screen, create an OAuth client, then mint a refresh token authorized for the `https://www.googleapis.com/auth/chromewebstore` scope. Two things matter more than which project hosts the client: (a) **authorize as the Google account that owns the Web Store developer account** — the token acts as the publisher, and the GCP project is only where the OAuth client lives, so reusing an existing project (e.g. the Android/Firebase one; a new client disturbs neither FCM nor the Play-publisher service account) is fine; and (b) **set the consent screen's publishing status to "In production"**, because in "Testing" mode Google expires refresh tokens after seven days, which kills unattended CI uploads — the `chromewebstore` scope is not on the sensitive list, so production status needs no verification review (the one-time authorization just shows an "unverified app" interstitial).
4. **Secrets.** Store the four values as repository secrets: `CHROME_WEBSTORE_EXTENSION_ID`, `CHROME_WEBSTORE_CLIENT_ID`, `CHROME_WEBSTORE_CLIENT_SECRET`, `CHROME_WEBSTORE_REFRESH_TOKEN` (`gh secret set <NAME>`).
5. **CI.** The upload job in `extensions.yml` is deliberately absent until these exist; add it behind the same warn-green-when-secrets-absent pattern `android.yml` uses (trustedTesters track on `stage`, default track on `main`).

### 2.1 Privacy-practices disclosures

The listing's privacy tab requires a justification per requested permission. The manifest deliberately requests only `storage`, `identity`, and `history` (tab manipulation and the redirector interception ride the host permission instead, so `tabs` and `webNavigation` are not requested). Texts to paste, matching what the code actually does:

- **storage** — "Caches the user's sign-in session (OAuth tokens) and the Cabalmail server's configuration locally so the user does not have to sign in on every browser start. No browsing data is stored."
- **identity** — "Runs the OAuth 2.0 (PKCE) sign-in flow against the user's own Cabalmail server via launchWebAuthFlow. The extension never sees or stores the password."
- **history** — "When the user opens a mail link in a private window through the extension, the intermediate redirector URL (which embeds the target link) is deleted from normal-window history so the private link does not linger there. History is never read for any other purpose and never transmitted."
- **Host permissions** — "The extension contacts only the user's own self-hosted Cabalmail server: the admin origin for its API and configuration, and the Amazon Cognito domain for sign-in. The content script must run on sign-up pages to detect email fields and offer a freshly generated address — the same model as a password manager. No page content or browsing data is transmitted anywhere; the server is contacted only on explicit user action."
- **Remote code** — answer **No**: all JavaScript ships in the package; the extension does not use eval or load external scripts.

## 3. App Store Connect (Safari)

The Safari extension ships inside a minimal host app (`extensions/safari/`). One-time bring-up, using the same Apple Developer Program membership as the mail clients:

1. **App IDs.** In the developer portal, register two identifiers: `com.cabalmail.extension-host` (the macOS host app) and `com.cabalmail.extension-host.web-extension` (the extension; must be prefixed by the host's ID). No special capabilities are needed yet.
2. **ASC record.** Create a new macOS app in App Store Connect against `com.cabalmail.extension-host`. (The iOS/iPadOS/visionOS host is a later phase and gets its own record when it exists.)
3. **Secrets.** The App Store Connect API-key secrets used by `apple.yml` (`APPLE_APP_STORE_CONNECT_API_KEY_ID`, `..._ISSUER_ID`, `..._API_KEY`, `APPLE_DEVELOPER_TEAM_ID`) cover this app too — no new secrets, the key is account-scoped.
4. **CI.** Add the archive/upload leg to `extensions.yml` once the record exists (mirror `apple.yml`'s API-key auth pattern). Note the known pitfall from the mail app: the portal cannot mint macOS provisioning profiles for universal App IDs through the UI; if signing fights you, `scripts/make-mac-profile.py` is the workaround and the profile's `Platform` array must include `OSX`.

## 4. OAuth redirect URIs

The extension's Cognito app client (`cabal_extension_client`) is created with a loopback placeholder callback until the real redirect URIs are configured.

1. **Collect the URIs.** There are up to three, all of the form `https://<extension-id>.chromiumapp.org/` for Chrome:
   - **Chrome dev builds**: the ID is pinned by the manifest `key`, identical on every machine, known without any upload — printed by

     ```sh
     python3 - <<'EOF'
     import base64, hashlib, json
     key = json.load(open('extensions/chrome/manifest.template.json'))['key']
     digest = hashlib.sha256(base64.b64decode(key)).hexdigest()[:32]
     print(''.join(chr(ord('a') + int(c, 16)) for c in digest))
     EOF
     ```
   - **The Chrome store listing**: the Web Store strips-or-rejects the `key` on a new item and assigns its own permanent ID at first upload (section 2.2), so the store build gets a *different* redirect URI — read the ID off the listing and add its URI as a second entry.
   - **Safari**: whatever `browser.identity.getRedirectURL()` returns in the installed extension — open the extension's background console in Safari and evaluate it; don't guess.
2. **Set the variable.** `infra.yml` already feeds `extension_redirect_uris` from the GitHub environment variable `TF_VAR_EXTENSION_REDIRECT_URIS` (defaulting to `[]`). The value expands inside a double-quoted shell `echo` in the workflow, so the quotes around each list element must be backslash-escaped in the stored value or the shell eats them and Terraform receives unparseable HCL — the same convention `TF_VAR_MAIL_DOMAINS` and `TF_VAR_AVAILABILITY_ZONES` already follow. Set it per environment:

   ```sh
   gh variable set TF_VAR_EXTENSION_REDIRECT_URIS --env <environment> \
     --body '[\"https://<dev-id>.chromiumapp.org/\", \"https://<store-id>.chromiumapp.org/\"]'
   ```

   Append the Safari redirect to the list when it exists.
3. **Apply and check.** After `infra.yml` runs, the app client's callback URLs (Cognito console or `aws cognito-idp describe-user-pool-client`) should list the real URIs, and `https://admin.<control-domain>/config.json` should show `cognitoConfig.extensionClientId` and `cognitoConfig.hostedUiDomain`. The extension's "Sign in with Cabalmail" flow is now testable end to end.

## 5. Form-detection corpus

The committed corpus (`extensions/fixtures/synthetic/`) is hand-authored seed material. Accuracy in the wild depends on captured real pages — the plan targets ~50 sign-up, ~50 sign-in, and ~10 ambiguous fixtures across SaaS, e-commerce, news, government, banking, and localized sites.

```sh
cd extensions
npm i -D playwright && npx playwright install chromium   # local only; deliberately not a workspace dependency
node scripts/snapshot.mjs https://github.com/signup captured/signup/github-2026-08.html
npm run test --workspace shared                          # the corpus test picks the new fixture up automatically
```

The middle path segment (`signup`/`signin`/`ambiguous`) is the expected label the corpus test asserts. A fixture that misclassifies is the signal to tune `extensions/shared/src/detect/config.ts` (weights and thresholds) until the whole corpus passes — never special-case a site. Commit fixtures; do not commit the playwright dependency. Users can also report misdetections via the popup's "Report wrong detection" link, which opens a pre-labeled GitHub issue; each accepted report should become a fixture.

## 6. Privacy policy

Both store listings require a privacy-policy URL. The service policy at `https://www.<control-domain>/privacy.html` (source: `front-door/privacy.html`) is the natural home; before the first store submission, extend it with an extension section stating the key claims: the extension transmits no browsing data to anyone, contacts only the operator's own Cabalmail API, and only on explicit user action (see the plan's "No telemetry" principle).

## 7. Not operator work, but still open

- The Apple mail clients' "Open in Private Window" menu row (the sending side of the private-link handoff) is a separate code change, blocked on the plan's Open Question 9 (embed the Safari extension in the mail app vs. keep the standalone host).
- The store-upload CI jobs themselves (sections 2.5 and 3.4).
- The redirector page is already live at `https://admin.<control-domain>/private-link` and degrades gracefully without the extension, so nothing here blocks it.
