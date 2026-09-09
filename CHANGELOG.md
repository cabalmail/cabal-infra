# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.12.2] - 2026-09-09

### Added
- **RSS reader data layer (phase 1 of the RSS plan).** Five DynamoDB
  tables for canonical feeds, items (with a stream for the notification
  fan-out), per-user subscriptions and folders, and per-user per-item
  state; the `cabal-rss-fetch-queue` SQS queue and its dead-letter queue;
  and an `rss-cache` S3 bucket for proxied images (seven-day expiry) and
  oversized item bodies. The tables join the AWS Backup selection where
  backups are enabled. No application traffic yet; the fetcher and API
  follow in later phases. See `docs/1.x/rss-implementation-plan.md`.

## [1.12.1] - 2026-09-08

### Fixed
- Android: **Sign-in form clears the keyboard.** On a landscape tablet the software keyboard covered `Sign In` and `Verify`, and the form neither scrolled nor let the keyboard's own action key submit — the only way through was to dismiss the keyboard first. The auth form now gives back the space the keyboard takes and scrolls what is left, and the last field of each form submits from the keyboard.
- Android: **Expired session returns you to sign-in.** When a session had been idle long enough for the refresh token itself to expire, the app stayed in the mail shell with an error banner and no way out — the only recovery was knowing to go to Settings ▸ Account ▸ Sign Out. An expired session now drops to the sign-in screen with the reason attached, the way it always did when the server rejected a token mid-session.
- Apple: **Compose window follows the Theme setting.** On iPadOS, macOS, and visionOS the standalone compose window is its own scene, and only the main window and the macOS Settings window pinned the Theme preference — so a composer opened while the app was set to Dark (or Light) drew in whatever appearance the system was in instead. Every scene now asks one shared rule for the appearance it draws in.
- **Escape closes the composer, not the message behind it.** With a message open in the reader, opening a compose window and pressing Escape closed the reader underneath while leaving the composer exactly where it was — so the keypress looked like it had done nothing and quietly threw away your place in the message. Escape now always dismisses the topmost layer: the composer first, then the reader.
- **Unread indicator survives select mode.** Entering select mode in the web view put the checkbox in the unread dot's place and hid the dot, which made batch-marking messages read hard to aim — the rows you wanted were no longer marked. The leading rail now widens to hold both, so the dot stays where it was, and its tooltip keeps naming the read state alongside the selection hint.

## [1.12.0] - 2026-09-08

### Added
- **Colour-token contrast checker.** `scripts/check-color-tokens.py`
  measures a cross-platform colour-token file against the surfaces each
  token is drawn on, using the same WCAG maths as the tester's screenshot
  instrument, and reports every pair under its floor. It backs the colour
  audit and the Claude Design palette handoff in `docs/1.x/`.
- **Colour tokens: one source of truth for every client.**
  `design/color-tokens.json` holds the palette Claude Design produced for the
  colour audit, and `scripts/generate-color-tokens.py` exports it to an asset
  catalog in CabalmailKit (light, dark, Increase Contrast, and watch
  variants), Android colour resources with Compose accessors, and React
  custom properties. The generator re-checks the exported sRGB values
  against the WCAG floors before writing, and each client's test suite
  fails if the generated files drift from the token file. No call site
  changes yet; adoption follows per client.

### Fixed
- Android: **Shared warning, success and flag colours.** Warnings (the
  attachment-size notice, the offline strip) no longer borrow Material's
  error red; a passing authentication check is the shared success green
  and a failing one the shared warning orange rather than accent-derived
  and error containers; the flag and favourite star are one gold instead of
  the accent's tertiary tone, so they survive Material You; the custom flag
  palette uses the same values as the Apple clients; sender avatars use the
  shared swatch set with a dark ink; and the six accent seeds, Forest among
  them, are the same values the web and Apple clients draw. All from the
  shared colour tokens, each held to its contrast floor.
- Apple: **Readable warning, error, success and flag colours.** Every
  coloured label, glyph, chip and swipe action now draws from the shared
  colour tokens instead of the platform's default red, orange, yellow, green
  and blue, which failed the WCAG text-contrast floor on light rows (red at
  3.55:1 across twenty sites, orange at 2.31:1, green at 2.22:1, yellow at
  1.51:1). Warnings are one orange, flags and favourites one gold, errors
  and destructive actions one red, and a passing authentication check a
  green that no longer matches the brand accent. Authentication chips and
  the debug log's filter pills use proper wash backgrounds. The accent is
  now the logo's Forest Green everywhere, selection washes share one
  opacity, sender avatars use the shared swatch set, and Increase Contrast
  gets its own variants of every colour.
- **Web client draws from the shared colour tokens.** The accent palette,
  the danger red, the compose attachment-size warning (previously a fixed
  pale yellow that was unreadable in the dark theme), the reader's
  authentication chips, the message-list flag and authentication-warning
  indicators, the DMARC page's verdicts and DNS-check banners, the toasts,
  and the destructive confirm button all read the same tokens the Apple and
  Android clients draw, each held to its contrast floor in both themes.
  Increase Contrast users get the high-contrast variants through
  `prefers-contrast: more`.
- Apple: **Warning orange readable in the light theme everywhere it is drawn.** The message list's flag and authentication indicators, the reader's authentication warning and its SPF/DKIM/DMARC chips, the `Suspended` caption under an address and the Diagnostics log's warning lines all drew in the platform orange, which measures 2.31:1 over a light row — under the WCAG AA floor. They now share the scheme-aware tint the compose attachment warning already used, which is darkened a little further so it also clears the chips' own tinted background (#1456).

## [1.11.2] - 2026-09-07

### Added
- Android: **Autofill hints on the sign-in form.** The username, password,
  and verification-code fields now carry autofill content types, so a
  password manager offers the saved login and its one-time code instead
  of guessing. The admin origin also publishes `assetlinks.json` when
  `TF_VAR_ANDROID_SIGNING_CERT_FINGERPRINTS` is set, which links the app
  to the web login without the manager asking first. See
  `docs/password-autofill.md`.
- Apple: **Password managers can fill the one-time code.** The iOS and
  macOS apps now declare `admin.<control-domain>` as an associated
  domain, baked from `TF_VAR_CONTROL_DOMAIN` at build time, and the admin
  origin publishes the matching `apple-app-site-association` file once
  `TF_VAR_APPLE_TEAM_ID` is set. Password AutoFill and third-party
  managers such as 1Password can then match the native sign-in form to
  the login saved for the web app, including its verification code on
  the MFA step. Needs the Associated Domains capability on both App IDs;
  see `docs/password-autofill.md`.

### Fixed
- Apple: **Revoking an address from the Addresses list now confirms
  itself.** The row vanished and nothing else happened, while revoking the
  same address from a message's per-address menu showed a "Revoked …"
  banner and creating one from that very screen showed a "Created …" one.
  The list now raises the same confirmation — and only when the revoke
  actually landed; a failure still surfaces as the list's error banner.
- Apple: **The compose attachment-size warning is readable in the Light
  theme.** The row that warns you a message may be too large to deliver
  drew in the system orange, which measured 2.31:1 against the compose
  form's light background — below the contrast floor for text and below
  even the floor for icons and other non-text. It now darkens that orange
  in the Light theme, where it measures 5.04:1, and keeps the system colour
  in the Dark theme, where it was already comfortable.

## [1.11.1] - 2026-09-05

### Fixed
- **A timed-out App Store Connect request no longer fails a TestFlight
  upload job.** The retry added in 1.11.0 covered refusals Apple actually
  answered; a request that never reached a status code — a connect
  timeout, a read timeout, a DNS failure, a reset connection — still
  failed the job on its first attempt, twice on the same day. Those now
  retry on the same terms as a transient 5xx, with the same bound and the
  same rule about which calls a repeat is safe for.
- **A transient Play Console refusal no longer loses an Android stage
  build.** A single 503 from Google failed the upload job after the bundle
  had already been built and signed, and since the artifact lives only
  inside that job, the commit produced no internal-track build at all. The
  publish now retries a transient refusal a few times with backoff — but
  only when the run's own output shows the Play edit was never committed,
  since re-running a publish that committed would publish the bundle twice.

## [1.11.0] - 2026-09-04

### Added
- Android: **Warning when attachments get too big.** The composer now shows an advisory line under the attachment
  chips once they total more than 20 MB — "Attachments total 24.0 MB. Many mail servers reject messages over 25 MB;
  delivery may fail." — matching the React and Apple composers. Like both of them it is advisory only and does not
  block the send: the recipient's server may accept more. Previously the first sign of the problem was the server's
  400 at send time, after every attachment had already uploaded.
- Apple: **Safari extension on iPhone and iPad.** The address-suggesting
  extension now ships inside the iOS mail app too — enable it under
  Settings → Apps → Safari → Extensions, no separate install. It learns
  which server to use from the mail app's sign-in. Opening links in a
  private window stays a Mac-only feature; iOS Safari has no way for an
  extension to do that.
- Apple: **Open in Private Window.** The reader's link menu on macOS gains
  a row that opens the link in a private browsing window, by way of the
  Cabalmail browser extension. The row appears when Safari is the default
  browser and the extension bundled with the app is enabled; with another
  default browser it is offered and the extension's own page explains the
  setup if nothing catches the link.

### Changed
- Android: **Messages with many attachments send.** Attachment staging now mints presign grants in batches of 32 —
  the most `/upload_url` will issue in one call — and uploads each batch before minting the next. What a message may
  carry is bounded by its total size rather than by how many attachments one staging request may name, and grants no
  longer have to outlive the endpoint's 120-second expiry while later uploads finish.
- **Batched attachment staging in the React composer.** `/upload_url` mints at most 32 presign grants per call, so a
  message with more attachments than that failed the moment it was staged — after every file had already uploaded to
  S3. The composer now stages in batches of 32, minting each batch immediately before its own uploads, so what a
  message may carry is bounded by its total size rather than by the shape of one staging request. Minting late also
  keeps every grant inside the endpoint's 120-second expiry, which a single up-front mint for a large bundle can
  outlive.
- Apple: **Unlimited photo selection when attaching.** The compose photo
  picker on iOS and visionOS no longer caps a single selection at five
  images. What affects deliverability is the total size of a message, not
  how many items went into it, and the composer already warns once all
  attachments together cross 20 MB — whatever their number, kind, or
  origin.
- Apple: **Status banners are dismissable, and sit at the bottom.** The launch
  resume offer hung from the top of the list, covering the filter pills and
  clipping the first message row, and nothing the user could do would get rid
  of it — it cleared itself after ten seconds and that was the only way out.
  Banners now hang from the bottom of the window, as on the Android client, and
  carry a close button plus a swipe-to-dismiss in any direction.
- Apple: **Search says which folders it searched.** The search banner reported
  its scope as a bare "in 2 folders", stacked directly over the match count —
  so "1 of 1 match" read as self-contradictory, and "No matches" read as "that
  word is nowhere in your mail" when the message was sitting in a folder the
  search never covered. The banner now names the folders ("Searched INBOX and
  Archive"), and an empty result adds where it looked and how to widen it:
  folders you are not subscribed to are not searched, and Trash never is.
- Apple: **Search opens ready to type.** Tapping the Search tab on iPhone left
  the field unfocused, so reaching a search term cost a second tap on the field
  itself. The tab now takes keyboard focus as it opens — unless a previous
  search is still in the field, where the keyboard would cover the results you
  came back to read.
- **Fixture capture names a bot interstitial and carries its own CSS.** `extensions/scripts/snapshot.mjs` used to fail a challenged page with Playwright's bare selector timeout, which named the locator and nothing else; it now reports the status and page title, says when that title is an interstitial, and takes `--headed` to retry in a visible browser. Captures also inline their external stylesheets, so a fixture preserves the `visibility` and `display` the live page computed instead of losing them when the sheets are re-requested at replay time — and any sheet the capture could not fetch is named rather than dropped silently.

### Removed
- **Per-message attachment count limit.** Sending a message with more than
  ten attachments no longer fails with a 400. The cap was introduced on the
  premise that the clients never attach more than a handful, which the
  uncapped photo picker retires; total message size is what a recipient's
  server actually rejects, and the 25 MB server-side ceiling still bounds
  that. Clients now stage uploads in batches so the presigned-URL
  endpoint's own per-request limit no longer caps a message either.

### Fixed
- **A single App Store Connect hiccup no longer strands a TestFlight build.**
  The scripts that attach an upload to its TestFlight group and set its "What
  to Test" notes made every App Store Connect call without any retry, so one
  transient 500 from Apple failed the whole upload job — after the binary had
  already been accepted, leaving it on App Store Connect attached to no group
  and needing a manual fix-up. Those calls now retry a transient refusal (5xx
  or 429) a few times with backoff, honouring Apple's own `Retry-After` when
  it sends one. Only calls that a repeat cannot double are retried: reads
  always, and the two writes whose effect is the same however many times they
  land; creating the notes record is deliberately left alone.

## [1.10.0] - 2026-09-03

### Added
- Apple: **Safari extension built into the Mac app.** The address-suggesting
  browser extension now ships inside the macOS mail app — enable it in
  Safari's Extensions settings, no separate install. It learns which server
  to use from the mail app's own sign-in, so it works without any setup, and
  the extension popup can still point it elsewhere explicitly.
- **Sign-up detection on passwordless first-step pages.** A sign-up flow that
  asks only for an email address on its first step carries none of the
  password-shaped signals the detector leans on, so pages like WordPress's
  `/start/account/user` stayed in the ambiguous band and never offered an
  address on their own. The detector now also reads the legal agreement such a
  page asks you to make — "by continuing you agree to our Terms of Service",
  next to the form rather than only inside a checkbox — which is what account
  creation involves and what signing in, subscribing to a newsletter, or
  sending a contact form does not. Both halves are required, so a page footer
  that merely links the terms still counts for nothing.

### Fixed
- **Extension's view of your existing addresses.** The browser extension read
  the address list in a shape the API never returns, so it silently believed
  every account had no addresses. Typing an address you already own therefore
  drew an offer to create it again, and the notice about reusing a subdomain
  could never appear. It now reads the real response, and a response it does
  not recognize is reported as an error rather than as an empty account.

## [1.9.8] - 2026-09-01

### Changed
- **Server chosen at runtime, not at build time.** The browser extension asks
  which Cabalmail server to use and remembers it per install, instead of
  having one compiled in, so a single build works against any deployment and
  can be pointed elsewhere from the popup. Host permissions follow: the
  extension now requests access to your server's origins once you name it,
  rather than holding broad access from the moment it is installed.

## [1.9.7] - 2026-09-01

### Fixed
- **Sign-up detection on `/sign_up`-style URLs.** The detector's path
  vocabulary matched `signup` and `sign-up` but not the underscore spelling, so
  a page like `login.gov/sign_up/enter_email` — an email-only first step with
  no password field to score — fell into the ambiguous band and offered
  nothing. Both underscore variants are now recognized.
- **Sign-up detection on pages with a heading in the way.** The detector
  consulted exactly one heading — the nearest one above the form — and gave
  up when it matched neither sign-up nor sign-in vocabulary. A single
  non-committal heading in between, such as the terms-of-service line
  WordPress puts above its account form, was enough to lose an otherwise
  clear "Create your account". The walk now continues past headings that say
  neither, up to three back.
- **Hidden forms no longer draw the extension's attention.** The detector
  filtered inputs by HTML `type`, never by CSS, so a login page that also
  ships a hidden sign-up modal — a common shape — had our listeners and, on
  an ambiguous form, our badge attached to a form the user cannot see. Forms
  hidden with `display: none` or `visibility: hidden` are now skipped, and
  reconsidered the moment the page reveals one.
- **Sign-up forms whose own markup calls them sign-in.** A site that tags its
  new-account password `autocomplete="current-password"` — Discourse's older
  sign-up form does, on a form whose id is `login-form` — outweighed every
  other signal, and the extension stayed silent on a genuine sign-up page. A
  form that collects an email *and* a separate username *and* a name is now
  scored as the registration shape it is, which is enough to reach the
  ambiguous band, where the badge is there to click.
- Apple: **Sort menu states which sort is in effect.** The message list's
  sort menu marked the active field with a drawn checkmark image and the
  direction with an arrow, so an assistive client reading the menu was told
  neither. Both groups now use the native menu mark, and the direction is a
  marked Ascending / Descending pair rather than a single flip row.

### Security
- **Mail-tier images now build against current Amazon Linux packages.** AL2023
  resolves `$releasever` from the base image's own release snapshot, so `dnf`
  in the `imap`, `smtp-in`, `smtp-out`, and `sinkhole` builds only ever saw the
  package set frozen when that base image was published — security updates AWS
  shipped afterwards were invisible, and rebuilding picked up none of them.
  Base packages such as `openssl-libs` were worse off still: named in no
  install line, they kept the base image's versions indefinitely. All four
  Dockerfiles now track the current snapshot and upgrade before installing.
  This clears the standing Trivy backlog on `apr-util`, `openssl`, and
  `rsyslog`, whose fixed builds had been published for weeks.

## [1.9.6] - 2026-09-01

### Added
- **System light and dark mode in the browser extensions.** Both surfaces —
  the toolbar popup and the in-page overlay (suggest popover, adopt banner,
  submit-guard modal, ambiguous badge) — now follow the operating system's
  appearance setting instead of always rendering light. Colours come from a
  shared token file that the popup links and the overlay injects into its
  shadow root, and `color-scheme` is set so the native text inputs, the
  apex-domain picker, and the popup's buttons adopt the dark palette too.
  The overlay deliberately tracks the system setting rather than the host
  page's, so a light-only site does not force a white popover onto a dark
  desktop.
- **Browser-extension section in the privacy policy.** States in full what the
  extension does and does not do: form detection happens entirely in the
  browser, no browsing data is transmitted anywhere, the only two network
  destinations are the operator's own server and its Cognito sign-in domain,
  and history access exists solely to remove the private-window redirector
  from normal browsing history. Both store listings require this before the
  extension can be published.

### Fixed
- **TestFlight uploads of the Safari extension host.** The host app never
  declared its export-compliance status, so every upload landed in App Store
  Connect as "Missing Compliance" — a state in which the build is not
  internally testable, which made the automatic TestFlight group assignment
  fail outright rather than merely awaiting paperwork.

## [1.9.5] - 2026-08-31

### Fixed
- Apple: **Invisible icon on the selected folder.** A selected folder row's
  icon was pinned to white on iPhone, iPad and Vision Pro, on the premise
  that the sidebar paints the selected row in the accent colour. iPadOS
  paints a light grey, and behind the second row the "All folders" section
  draws for the already-selected path it paints nothing at all — so the icon
  measured 1.52:1 against the fill and was simply not drawn on the other row.
  It now keeps the row's own foreground while selected and the brand accent
  otherwise, on every platform.

## [1.9.4] - 2026-08-31

### Fixed
- **Extension config cache crossing environments.** The cached `config.json`
  was not scoped to the control domain it came from, so a bundle rebuilt
  against a different environment kept using the previous one's Cognito
  client for up to a day — sign-in then failed at the Hosted UI with
  `redirect_mismatch`, before any login form appeared.

## [1.9.3] - 2026-08-31

### Added
- **Branch-routed TestFlight groups for the Safari extension host.** Uploads
  now attach to the internal test group matching the branch they were built
  from — `stage` pushes to `stage`, `main` to `prod` — the same routing the
  mail apps use. The control domain is baked into an extension build, so a
  stage build and a prod build are different products and must not reach the
  same testers.

### Fixed
- Apple: **Message body typed blind under the iPhone keyboard.** Focusing the
  compose body barely scrolled the form, so the keyboard and its
  input-accessory bar covered the Rich Text / Markdown picker, the whole
  formatting toolbar and every character typed — the only way to read the
  message back was to dismiss the keyboard. The body is a `WKWebView`, whose
  focus SwiftUI's focus system never sees, and the UIKit behaviour that used
  to scroll the form for it is not dependable. The composer now brings the
  message row to the top itself, both when the editor takes focus and when
  the keyboard arrives after it.
- **Browser extension icons.** The extension shipped with no icons at all, so
  browsers showed a generic placeholder in the toolbar and extension manager,
  and the macOS App Store rejected the upload outright. Both bundles now carry
  the standard icon set, generated from the same source vector as every other
  Cabalmail icon.
- **Safari extension packaging.** The web bundle was copied into the app
  extension one directory too deep, so `manifest.json` never sat where Safari
  and App Store validation look for it, and the host app shipped without an
  icon. Both blocked the macOS App Store upload.
- **Safari sign-in in the browser extension.** The Hosted UI flow no longer
  waits on a promise that Safari can discard: the PKCE verifier is persisted
  for the duration of the flow and the background's redirect interception
  completes it, so sign-in survives the popup closing and the background
  worker being suspended. The popup now also asks Safari for the host
  permissions it needs (Safari grants those per site, not at install), and
  reports any failure instead of leaving the button looking inert — a
  config fetch that cannot reach the admin origin now times out with an
  explanation rather than hanging.

## [1.9.2] - 2026-08-30

### Added
- **Scripted browser-extension build and release chores.**
  `scripts/build-extension.sh` builds the Chrome and Safari bundles and
  packages the Web Store zip, refusing one that still carries the manifest
  `key` the store rejects; `scripts/extension-redirect-uris.py` derives the
  Chrome OAuth redirect URIs from that key and sets
  `TF_VAR_EXTENSION_REDIRECT_URIS` with the escaping `infra.yml` needs;
  `scripts/mint-chrome-webstore-token.py` runs the Web Store API
  refresh-token consent round-trip end to end; and
  `scripts/verify-pending-addresses.py` drives the whole pending-address
  lifecycle — create, list, confirm, confirm-again 409, backdate, reap —
  against a live environment.

### Changed
- **Browser-extension documentation consolidated.**
  [`docs/browser-extension.md`](docs/browser-extension.md) is now the
  single build, distribution, and operations guide, written for someone
  who has forked the repository and knows nothing else about Cabalmail;
  `extensions/README.md` is a pointer to it. The plan document's errata
  are folded into its text as first-class corrections.

### Fixed
- Apple: **Bulk action bar captions no longer break mid-word.** Selecting two
  or more messages in a narrow message-list column — macOS at its default
  column width — drew the bar's captions hyphenated and stacked ("Ar-chive",
  "Rea d", a four-line "2 se-lect-ed") because nothing kept them on one line.
  Each caption now stays whole, and where the column is too narrow for the
  whole bar it drops the selection count, then the captions, rather than
  breaking words.
- **Safari sign-in driver lint break.** The tab-based auth driver declared
  its timeout handle with `let` and assigned it once, which fails the
  workspace's `prefer-const` rule and was reddening every `extensions`
  CI run. Behaviour is unchanged.
- Apple: **Deleting a custom flag no longer quits the app.** Confirming
  "Delete Flag" in Settings ▸ Flags terminated the app outright and lost the
  deletion — the palette still held the flag on the next launch — whenever
  the flag was the last one in the list, which is every flag just added and
  the only flag in a one-flag palette. The editor addressed its entry by
  position, so the Name field and Enabled toggle read past the end of the
  shortened palette while they were still on screen. Every read and write in
  the editor now addresses the flag by its slot and copes with the flag
  being gone, including when another device deletes it mid-edit.
- Apple: **Reader menus follow the option you just chose.** On macOS the
  mark-read and dispose menus in the reading pane kept whatever they drew
  the first time they were opened: change the after-marking-read or
  Archive/Delete default — from the menu itself or in Settings, with the
  message still open — and re-opening the menu showed the checkmark still
  on the old row, with the mark-read rows drawn as if they were still
  available on a message that had just been read. Both menus now redraw
  whenever anything they show changes.
- **Safari extension sign-in.** Clicking "Sign in with Cabalmail" in the
  Safari extension did nothing: Safari implements no WebExtensions
  `identity` API, which the sign-in flow depended on. Safari now runs the
  Hosted UI in a regular tab redirecting to a new
  `https://admin.<control-domain>/extension-auth` page that the extension
  intercepts and closes automatically (PKCE and the state check carry the
  security, as before); the redirect URI is registered on the Cognito
  client automatically, so Safari needs no per-install configuration.
  Chrome keeps its existing identity-API flow.

## [1.9.1] - 2026-08-30

### Changed
- **Extension permission surface trimmed to storage/identity/history.** The
  private-link interception now rides `tabs.onUpdated` (whose URL visibility
  comes from the extension's own host permission, and closing the redirector
  tab needs no permission at all), so the `tabs` and `webNavigation`
  permissions are no longer requested — a smaller store-review surface with
  identical behavior. A failed private-window open is also logged now
  instead of swallowed. The content script likewise no longer matches
  plain-http sites (localhost excepted, for development): no sign-up form
  should be handed a fresh address over cleartext, and the narrower match
  halves the extension's site-access surface.

### Fixed
- **Extension popup no longer wedges when the control domain is
  unreachable.** A dev build made without `CABALMAIL_CONTROL_DOMAIN` (or
  any network failure reaching the admin origin) left the popup stuck on
  "Loading…" with a raw `TypeError: Failed to fetch`. Auth-state and
  sign-out now work from local token storage without touching the network,
  and fetch failures render as an actionable message naming the origin.
  The Chrome extension ID is also now pinned via a manifest `key` for
  unpacked dev builds, so the dev Cognito OAuth redirect URI is one known
  value on every machine (the Web Store rejects a `key` on new-item
  uploads and assigns the listing its own ID; `EXTENSION_STORE_BUILD=1`
  strips it for store zips).

## [1.9.0] - 2026-08-30

### Added
- **Browser extension (initial implementation, not yet distributed).** A
  new `extensions/` workspace holds the address-suggesting extension for
  Chrome (MV3) and Safari: sign-up-form detection via a tunable scoring
  engine with a fixture corpus, 1Password-style suggest popover that
  eagerly creates the address while the form is being filled, an adopt flow
  for hand-typed addresses with a submit-time guard, Cognito Hosted UI +
  PKCE sign-in, and the private-window link handoff for the mail clients
  (redirector page at `https://admin.<control-domain>/private-link`).
  Store distribution and in-browser verification are still pending; see
  docs/1.x/browser-extension-plan.md for phase status.
- **Eager-create pending addresses.** `POST /new` accepts a `pending` flag
  that marks an address created ahead of use (the browser extension's
  commit-time create, giving DNS and the sendmail tier runway before a
  verification mail arrives). A new `POST /confirm_address` endpoint clears
  the flag on form submit; the imap tier clears it the moment mail actually
  arrives at the address (a generated procmail rule spools a signal that a
  root drain daemon applies); and an hourly `reap_pending_addresses`
  scheduler Lambda revokes addresses still pending after 24h, including
  their DNS records and mail-tier configuration. `GET /list` now reports
  the flag so clients can badge unconfirmed addresses.

### Fixed
- Apple: **The reader's flag menu shows what is actually applied.** On macOS
  the menu kept the checkmarks it opened with, so a flag applied from the menu
  itself read as unapplied — and picking that row again removed it. The menu is
  now replaced whenever the rows it draws change.
- Apple: **Mail rules no longer opens on "Couldn't reach the server."** On
  iPhone the Rules screen is torn down and rebuilt during the navigation
  transition, which cancelled its first fetch; the cancellation was painted as
  a server failure and nothing retried it, so every push after the first one in
  a session needed Retry. A cancelled load now leaves the screen loading and
  the fetch is taken over by the rebuilt screen.

## [1.8.1] - 2026-08-29

### Fixed
- **Extra inbox copies from flag-tagging rules.** A rule that tags a
  message with a custom flag delivered the tagged message correctly but
  also left an extra untagged copy in the inbox: the delivery helper
  could not remove the append drain's root-owned response file from the
  sticky spool, misread its own success as a failure, and fell through
  to an additional delivery. The drain now hands the response file to
  the requesting user, and the helper treats response collection as
  best-effort.

## [1.8.0] - 2026-08-29

### Added
- Android: **Custom flag palette.** Settings gains a Flags category:
  define up to 20 named, colored flags, reorder them, disable or delete
  them (with a caveat-aware confirmation), and they follow your account
  to every device. This release manages the palette; putting the flags
  on messages ships in a following release.
- Apple: **Custom flag palette.** Settings gains a Flags category: define
  up to 20 named, colored flags, reorder them, disable or delete them
  (with a caveat-aware confirmation), and they follow your account to
  every device. This release manages the palette; putting the flags on
  messages ships in a following release.
- Android: **Tag messages with your flags.** The flags you define in
  Settings can now go on messages: colored dots in the message list,
  chips in the reader header, and check-marked flag entries on a
  message's long-press menu and the reader's overflow menu. Tags sync
  through your account and follow a message between folders; a tag
  whose flag was deleted stays removable from the reader.
- Apple: **Tag messages with your flags.** The flags you define in
  Settings can now go on messages: colored dots in the message list,
  chips in the reader header, a Flags submenu on a message's context
  menu, and the reader's flag button grows a menu with one toggle per
  flag (the button itself still toggles the classic flag). Tags sync
  through your account and follow a message between folders; a tag
  whose flag was deleted stays removable from the reader.
- **Flag-then-file rule composition.** A rule with Flag and/or Mark as read,
  destination None, and Continue on now decorates the message instead of
  silently compiling to nothing: the marks ride per-message pending state in
  the rules engine and are applied wherever the message ends up — a later
  rule's destination folder or the inbox fallback. "Flag anything from
  billing" above "file receipts into Receipts" produces a flagged message in
  Receipts and nothing extra in the inbox. Rule sets without decorate-only
  rules compile byte-identically to before.
- Android: **Rules can set your flags.** The rule editor's Flag extra
  now lists your custom flags alongside the classic flag, so a rule can
  tag arriving mail — including on a continuing decorator rule, whose
  tags are carried to wherever the message is filed. A flag later
  deleted from the palette shows in the rule by its slot id until you
  clear it (the rule is skipped while it remains).
- Apple: **Rules can set your flags.** The rule editor's Flag extra now
  lists your custom flags alongside the classic flag, so a rule can tag
  arriving mail — including on a continuing decorator rule, whose tags
  are carried to wherever the message is filed. A flag later deleted
  from the palette shows in the rule by its slot id until you clear it
  (the rule is skipped while it remains).
- **Rules can set custom flags.** A mail rule can now tag arriving
  messages with the flags defined in Settings → Flags, both on a filing
  rule (the message lands in its folder already tagged) and on a
  decorate-then-file rule (a continuing rule's tags are carried to
  wherever the message ends up, custom flags included). Tagged
  deliveries go through Dovecot itself so per-folder keyword state
  stays consistent; a rule whose flag was deleted or disabled from the
  palette is skipped, like a rule whose folder is gone.

### Changed
- Android: **Decorate-only rules are saveable.** A rule that flags or marks
  read, files nowhere, and continues to the next rule is a valid rule again —
  the engine now carries its marks to wherever the message is eventually
  delivered — and its summary line reads "flag · continue" instead of
  "no filing · flag · continue".
- Apple: **Decorate-only rules are saveable.** A rule that flags or marks
  read, files nowhere, and continues to the next rule is a valid rule again —
  the engine now carries its marks to wherever the message is eventually
  delivered — and its summary line reads "flag · continue" instead of
  "no filing · flag · continue".

### Fixed
- Apple: **Readable folder names in the sidebar.** Colouring names by unread
  state had made the selected folder white on the light selection fill —
  1.52:1 on iPadOS, and invisible outright in the second row "All folders"
  draws for the folder already selected — while a caught-up folder's name
  dimmed to 4.00:1 there and 2.90–3.31:1 on macOS 27, all under the 4.5:1
  WCAG AA floor. The selected row now keeps whatever foreground its
  selection fill calls for instead of pinning one, and caught-up names dim
  by a fixed fraction of the label colour rather than by `.secondary`, whose
  alpha the OS picks without regard to contrast. The unread signal is
  unchanged; every state measured now clears AA on iPadOS and macOS.
- **Arch packaging failed where makepkg splits debug symbols.** `cargo xtask
  package arch` read the `-debug` package that a build environment with `debug`
  in its `OPTIONS` produces — which is what the `archlinux:base-devel` image
  ships — as a leftover from an earlier build, and refused to lint anything. It
  now names the package it built and reports both artifacts.
- **Linux CI ran its container steps under the wrong shell.** `linux.yml` now
  declares `bash` as its run default. The runner falls back to `sh` where it is
  not told otherwise, and the `ubuntu:24.04` container's `sh` rejects
  `set -o pipefail`, so the API-floor build and the widget tests failed on every
  run of that workflow since it landed. The path filters of both gates that run
  `cargo xtask ci` — `linux.yml` on a push, `lint.yml`'s `rust` job on a pull
  request — now also cover every file those tests read from outside `linux/`,
  and a test fails if one is registered but missing from either.

## [1.7.7] - 2026-08-28

### Changed
- Android: **Truthful Continue in the rule editor.** The
  continue-to-next-rule toggle now leads the rule editor and gates the
  destination: a continuing rule offers only Copy and None (Move, Archive,
  and Delete stay visible but disabled, with an explanation), and turning
  Continue on converts a selected Move or Archive to Copy, carrying the
  folder — the delivered mail was already identical, only the label changes.
  Stored Move/Archive rules with Continue on are shown and saved as Copy,
  rule summaries read "copy to Receipts · continue", and the editor refuses
  to save a continuing rule that neither files, forwards, nor replies
  instead of letting it silently compile to nothing.
- Apple: **Truthful Continue in the rule editor.** The continue-to-next-rule
  toggle now leads the rule editor and gates the destination: a continuing
  rule offers only Copy and None (Move, Archive, and Delete stay visible but
  disabled, with an explanation), and turning Continue on converts a selected
  Move or Archive to Copy, carrying the folder — the delivered mail was
  already identical, only the label changes. Stored Move/Archive rules with
  Continue on are shown and saved as Copy, rule summaries read
  "copy to Receipts · continue", and the editor refuses to save a continuing
  rule that neither files, forwards, nor replies instead of letting it
  silently compile to nothing.

## [1.7.6] - 2026-08-28

### Changed
- **Dashboards refresh when their tab regains focus.** The release, triage,
  and Apple release dashboards re-fetch their data when the browser tab
  becomes visible or the window regains focus, so a dashboard left open in
  the background is current the moment you switch back to it. Focus-driven
  refreshes are throttled to one per 15 seconds so rapid window-switching
  doesn't hammer GitHub or App Store Connect.
- Android: **Settings reorganized into categories.** The single
  scrolling settings screen is now a selectable category list — shown
  beside the selected category's options on wide screens (tablets,
  landscape foldables), drilling into a sub-screen with a back arrow on
  phones. Rules is a category like any other and opens the rules list
  directly, without the old header-plus-launcher-row indirection.
- Apple: **Settings reorganized into categories.** Account, Reading,
  Composing, Rules, and the rest are now a selectable category list,
  System-Settings style: side by side with the selected category's
  options where there's room (the macOS Settings window, the visionOS
  Settings tab), drilling into a sub-screen with a back chevron on
  iPhone and in the iPad settings sheet. The Rules category opens the
  rules list directly, replacing the old Rules section with its single
  "Mail rules" launcher button, and the macOS sheet workarounds for
  Rules, Acknowledgements, and the notification folder picker are gone —
  those screens now push in place, and the Debug Log link works on
  macOS.

## [1.7.5] - 2026-08-28

### Fixed
- Apple: **Settings footers wrap instead of truncating.** On macOS the
  explanatory grey text under a settings section was clamped to a single line
  and cut off mid-sentence — most visibly under the mail-rules list, where the
  clause explaining "continue to the next rule" was the part that disappeared.
  Every section footer now wraps to as many lines as it needs.

## [1.7.4] - 2026-08-27

### Added
- **Arch package for the Linux client.** `linux/packaging/arch/PKGBUILD` builds
  the `cabalmail` binary, its man page, desktop entry, AppStream metadata, icon,
  and a commented configuration reference, and `cargo xtask package arch` builds
  it from the working tree and lints it with `namcap`. A `package-arch` job runs
  the same command in an `archlinux:base-devel` container on every push, so the
  thing a user installs is built on the push that changed it rather than at
  release time. The package's dependency arrays come from
  `linux/packaging/deps/arch.txt`, the same per-distro list the CI containers
  install from, and the composer's vendored marked and turndown are pinned
  upstream tarballs rather than an `npm` build dependency. Tests fail the build
  if the PKGBUILD and that list disagree, if the pinned JavaScript drifts from
  `react/admin/package-lock.json`, or if the package stops installing a file it
  ships. Publishing to the AUR stays a manual step.

### Fixed
- Apple: **Enabled toggle and actions menu in the macOS rules list.** Both sat
  inside the row's navigation link, which macOS treats as a single hit target,
  so every click in a rule row — including one dead-centre on the toggle or the
  `⋯` glyph — opened the rule editor instead. They now sit beside the link, and
  clicking the rule's name still opens the editor.

## [1.7.3] - 2026-08-27

### Fixed
- Android: **Discarded drafts leave the list.** Discarding a draft removed it from the server straight away, but the composer never told an open Drafts list what it had done, so the row — and the count pill still counting it — sat there for up to a minute until the next foreground poll, which read exactly like a discard that had failed. The composer now announces every change it makes to the Drafts folder on the same event bus every other screen uses, so a discarded draft disappears at once, a draft saved on close appears at once, and a sent message's draft copy goes with it. A discard the server declines is now logged and refetched rather than swallowed. Separately, a composer resumed from the Drafts folder is titled "Draft" rather than "New message".

## [1.7.2] - 2026-08-27

### Changed
- Android: **Unread folders stand out in the list.** Folder names with
  unread messages now render in the theme highlight color, while caught-up
  folders dim, so the folders needing attention read at a glance.
- Apple: **Unread folders stand out in the sidebar.** Folder names with
  unread messages now render in the accent color, while caught-up folders
  dim to secondary, so the folders needing attention read at a glance.
- Android: **Three-pane windows launch into INBOX.** Windows wide enough
  for the folder + list + reader mail view now open on the INBOX message
  list at launch, like phones, instead of the standalone folder hub — the
  folder list is already on screen as the leading pane. Medium-width
  windows (list and reader only) still launch on the folder list.

### Fixed
- Android: **Resumed folder opens its own list.** After a cold launch the remembered folder's title sat over INBOX's messages and pills, and tapping a row opened — and flagged, or trashed — whatever message held that uid in the remembered folder. The resume cursor now rewinds to the folder list before opening its target instead of reusing the INBOX launch entry, so title, list, pills and taps all name the same folder.
- Android: **Expired sessions say so.** A refresh token that has aged out or been revoked draws the same `NotAuthorizedException` from Cognito as a mistyped password, and the client mapped both to "Invalid username or password". The refresh path now reports "Your session expired — sign in again" while a genuine sign-in failure still reports the credential.
- Apple: **Expired sessions no longer read as a rejected password.** A refresh token that has aged out or been revoked draws the same `NotAuthorizedException` from Cognito as a mistyped password, and the client mapped both to "That username or password wasn't accepted." The refresh path now reports "Your session expired. Sign in again." while a genuine sign-in failure still reports the credential.

## [1.7.1] - 2026-08-26

### Added
- **Mail-rules alarms and documentation.** Always-on CloudWatch alarms
  for the rules pipeline — compiler self-test failures at imap start,
  rule-skip counts breaking from their baseline, rule-driven
  forward/reply bursts (loop indicator), and set_rules p99 write
  latency past the 1s editor budget — plus docs/mail-rules.md, the
  as-shipped user and operator reference, linked from the user manual
  and operations docs.

## [1.7.0] - 2026-08-26

### Added
- Android: **Retry for failed message loads.** When the reader can't load a
  message body, the error now comes with a Retry button that re-fetches the
  message, matching the Apple clients.
- Android: **Collapsible folder list sections.** The mail tab's folder
  list now mirrors the Apple clients' two sections: Subscribed, expanded
  by default, and All folders, collapsed by default. Each section's
  disclosure is remembered on the device, and unread badges now refresh
  proactively for subscribed folders only.
- Android: **Mail rules editor.** Settings gains a Mail rules screen:
  author, reorder, enable, duplicate, and delete the server-side mail
  rules the IMAP tier applies to arriving messages. Rules match
  From / To / Cc / Subject / Body, file into existing folders (move,
  copy, archive, delete), and can flag, mark read, forward, or
  auto-reply. Edits auto-save with cross-device conflict detection,
  matching the Apple clients.
- Apple: **Mail rules editor.** Settings gains a Rules section on every
  platform: author, reorder, enable, duplicate, and delete the server-side
  mail rules the IMAP tier applies to arriving messages. Rules match
  From / To / Cc / Subject / Body, file into existing folders (move, copy,
  archive, delete), and can flag, mark read, forward, or auto-reply.
  Edits auto-save with cross-device conflict detection; on macOS the
  editor opens as a sheet from the Settings window.

### Fixed
- Android: **Filter pills search the whole folder.** The Unread and Flagged
  pills narrowed only the already-loaded rows, so on a large folder they
  showed an empty list whenever the matches sat deeper than the loaded
  window — on a very large folder, effectively always. They now run the same
  folder-scoped server search as the Apple clients and page through every
  match as the list scrolls.
- Apple: **Search and filter results page in as you scroll.** The Unread and
  Flagged pills (and text search) loaded a fixed first batch — at most 200
  rows for a pill — and stopped, so on a large folder most matches were
  unreachable. Results now load a page at a time as the list scrolls, all the
  way through the match set, and a refresh of an active search keeps the
  depth already loaded instead of snapping back to the first page.
- **Envelope decoding tolerates non-UTF-8 bytes in BODYSTRUCTURE.** A message
  whose MIME metadata carries raw 8-bit bytes (an unencoded Latin-1 attachment
  filename, for instance) failed the whole envelope page with a server error:
  one such message broke every `/search_envelopes` or `/list_envelopes`
  response whose page contained it, which surfaced as the Unread filter
  showing an empty list. Byte strings in a BODYSTRUCTURE now decode with a
  Latin-1 fallback instead of failing the request.
- Apple: **Add and delete rules on macOS.** Once a first rule existed, the
  macOS rules window offered no way to add another or delete one: the
  toolbar add button doesn't render in the Settings sheet, and row deletion
  hid behind iOS-only swipe gestures and an unadvertised right-click menu.
  The list now carries an explicit "Add rule" row and a per-row menu with
  Duplicate and Delete.
- Android: **Reliable rule auto-save.** Typing in the rules editor could
  cancel an in-flight save that the server had already committed, leaving
  the app behind the server's rule-set version; the next auto-save was then
  misreported as "Rules updated on another device", and Reload threw away
  the newer edits. The debounce timer and the save request are now
  independent, so a keystroke only resets the timer.
- Apple: **Reliable rule auto-save.** Typing in the rules editor could
  cancel an in-flight save that the server had already committed, leaving
  the app behind the server's rule-set version; the next auto-save was then
  misreported as "Rules updated on another device", and Reload threw away
  the newer edits. The debounce timer and the save request are now
  independent, so a keystroke only resets the timer.

## [1.6.0] - 2026-08-25

### Added
- Android: **Three-pane mail layout on wide screens.** When the window
  fits it — a phone in landscape, a tablet, a wide foldable — the mail
  view adds the folder list as a leading pane beside the message list and
  reading pane, with the open folder highlighted. Picking a folder swaps
  the message list in place, the two message panes split the remaining
  width evenly (medium-width windows previously showed only one at a
  time), and the message list drops its now-redundant back arrow while
  the folder pane is visible.
- **User-defined mail rules (server side).** The IMAP tier now
  evaluates per-user mail rules on every incoming delivery, ahead of
  default delivery: conditions match From / To / Cc / Subject / Body
  (case-insensitive contains, ANDed), rules run in the user's chosen
  order, the first match fires, and each rule can opt into
  continue-to-next. Actions: move, copy, archive, and delete, plus
  the independent extras flag, mark as read, forward (loop-guarded,
  so a forward that routes back to the same mailbox is forwarded
  exactly once), and auto-reply (reply comes from the address the
  message was delivered to, marked per RFC 3834, with a 7-day
  per-sender suppression window and a 100-per-day cap). Rule sets are
  stored server-side with optimistic concurrency and a 90-day audit
  history, and are compiled to procmail with every user-supplied
  value escaped or the rule skipped - user input never lands as raw
  procmail syntax, and a rule that fails to compile never affects
  delivery of the message. BCC is deliberately not offered as a
  condition field: it is not present in delivered mail and would
  silently never match. Managed via the new `get_rules` /
  `set_rules` endpoints; the rule editors in the client apps ship
  separately.

### Fixed
- **Blank push notifications from a truncated delivery.** A local delivery
  interrupted mid-write (the mail tier's periodic sendmail restart) can leave
  a zero-byte message file in the mailbox. `/push_envelope` treated the empty
  fetch as valid content, so every Apple device enriched its alert into empty
  title and body instead of the designed "New mail" fallback, and the empty
  bytes were written to the message cache, where they also made the message
  open blank forever after. Empty raw content is now treated as the message
  being gone: the endpoints answer 404, nothing is cached, and an
  already-poisoned cache entry is deleted and refetched on the next read.
  Relatedly, Message-IDs containing `/` (every GitHub notification) were
  failing the enrichment endpoint's validation and silently degrading to the
  wake signal's stale UID hint, which mis-targets enrichment during delivery
  bursts; a dedicated Message-ID validator now lets them resolve by search.
- Android: **Reply from Sent addresses the recipients.** Replying to your
  own message in the Sent folder used to target yourself and leave From
  unset. Reply and Reply All now invert the addressing: From is the alias
  the original was sent from, Reply goes to the original To, and Reply All
  carries the original To, Cc, and Bcc (for mail sent after the Sent copy
  began retaining Bcc). Your own addresses never land in the recipient
  lists.
- Apple: **Reply from Sent addresses the recipients.** Replying to your own
  message in the Sent folder used to target yourself and lose the alias you
  sent from. Reply and Reply All now invert the addressing: From is the
  alias the original was sent from, Reply goes to the original To, and
  Reply All carries the original To, Cc, and Bcc (for mail sent after the
  Sent copy began retaining Bcc). Your own addresses never land in the
  recipient lists.
- **Reply from Sent addresses the recipients (web).** Same inversion as the
  native clients: replying to your own message in the Sent folder seeds From
  with the alias the original was sent from and targets the original To
  (plus Cc and Bcc on Reply All) instead of replying to yourself, without
  the spurious blind-copy warning. Serving this, `/list_envelopes` and
  `/search_envelopes` now expose a `bcc` field, populated for messages whose
  stored copy carries a Bcc header. A reply-seeded From the user no longer
  owns is cleared once the address list loads instead of wedging Send.
- **Sent copies keep the Bcc header.** `/send` used to strip `Bcc` from the
  copy it stages for the Sent folder, permanently destroying the sender's
  only record of who they blind-copied. The stripping protected nothing:
  only the mailbox owner can read Sent, and blind recipients were never at
  risk on the wire (smtplib strips `Bcc` from the transmitted message, and
  delivery uses an explicit recipient list). Sent copies now retain `Bcc`,
  matching drafts and mainstream mail clients. Messages sent before this
  change are unaffected - their Bcc information was never stored and cannot
  be recovered.

## [1.5.0] - 2026-08-23

### Added
- Android: **Mark as read and Archive from the notification.** New-mail
  notifications now carry both actions: a tap dismisses the alert
  immediately and applies the change on the server in the background,
  retrying on transient failure — no need to open the app. Archive uses
  the same Archive mailbox as the in-app action and is omitted when the
  mail is already there.
- Android: **Per-folder push opt-in.** A "Notification folders" picker in
  Settings scopes instant push alerts on this device to the inbox only (the
  default), every folder, or an explicit selection — matching the Apple
  clients' per-device behavior. The fallback background check still covers
  the inbox only.

### Changed
- Android: **Disposed rows animate out of the list.** The optimistic
  removal after a swipe-dispose, move, or purge was instantaneous, abrupt
  enough for the eye to miss. The departing row now fades out over a
  quarter second while the rows below glide up to close the gap, in both
  the message list and search results. Rows still appear instantly; only
  removal animates.

## [1.4.0] - 2026-08-23

### Added
- Android: **Instant new-mail push notifications.** Where Google Play
  services is available, new mail now raises a notification within seconds
  via FCM instead of waiting for the 15-minute background check (which
  remains as the fallback). The push itself is content-free — sender and
  subject are fetched from the mail server by the app, so Google's
  infrastructure never sees message content. Registration is tied to the
  existing notifications opt-in in Settings and is removed on sign-out.
  Builds without Firebase config (all CI builds) are unaffected. Phase 3 of
  docs/1.x/android-push-notifications.md.
- **FCM sender in the push-notification pipeline.** `push_dispatch` now
  routes each registered device token to its platform's sender — Apple rows
  to APNs, `android` rows to Firebase Cloud Messaging (HTTP v1, data-only,
  content-free wake signals) — and `/push_register` / `/push_deregister`
  accept the Android app's bundle id and FCM token format. The credential
  lives at `/cabal/fcm/service_account` (Terraform-seeded placeholder,
  operator-provisioned); until it is seeded, Android sends drop cleanly
  with Apple delivery untouched, mirroring the APNs posture. Adds a
  `Platform` dimension to the `Cabal/Push` CloudWatch metrics. Phase 1 of
  docs/1.x/android-push-notifications.md.

### Security
- **The API Gateway access log has a log group of its own, and the execution log now ages out.** The stage's access log was written into the execution log group — the one whose per-method overrides had been running at `INFO` with request/response tracing on, so it holds truncated request bodies and `Authorization` headers alongside the per-request access records. One group meant one retention for both, and the only lever for ageing the body history out would have taken the access log with it. The two are now separate groups: the access log keeps the stack's standard year, while the execution log drops to 30 days so the body history it accumulated retires within a month. Entries already written stay in the group that received them, so the pre-split access-log records age out with the execution log.

## [1.3.5] - 2026-08-22

### Changed
- Android: **Message rows show the delivered-to address.** The first line
  of each message-list row now reads "sender → address", matching the
  Apple clients: the dimmed destination is the address the message was
  delivered to — preferring a recipient on one of the deployment's mail
  domains (subdomain-aware), falling back to the first To/Cc entry, and
  dropping the arrow when there are no recipients.
- **Release dashboard holds Promote while merged fixes await tester
  sign-off.** When an open tester/fixer-cycle issue has a claimed fix
  (a `fixer/N-…` branch, a closing reference, or an "Addresses #N"-style
  mention) merged on stage but not yet released, the Promote buttons are
  disabled and a banner lists the pending issues with their PRs — closing
  the issue, which the retest pass does, releases the hold. Bare `#N`
  context mentions deliberately don't count, and released-vs-pending is
  decided per merge commit against main, so an already-shipped fix never
  re-blocks.

### Fixed
- Apple: **Picking a folder during a search now goes there.** On iPad and macOS, choosing a mailbox in the sidebar while search results were showing marked the row selected and left the message column on the results, still titled "Search" — and re-choosing the mailbox that was already selected did not even dismiss the folder panel. A folder pick now ends the search the way the search field's own clear button does, and lands the column on that mailbox.
- Apple: **The watch's confirmation dialogs offer a labelled way out too.** "Revoke <address>?" and "Suspend <address>?" on the watch each came up showing one labelled control — the irreversible one — because watchOS drops a cancel-role button exactly as iPhone and visionOS do. Both now take the back-out role from the same shared rule the other nine dialogs use, so a **Cancel** is drawn beneath the destructive button.

### Security
- **Every admin mutation now carries the per-caller ceiling and the audit line.** `confirm_user`, `assign_address`, `unassign_address` and `repair_dns_record` ran the admin-group guard and neither of the other two controls their five siblings have had since 0.10.x, so confirming an account, rewriting a `cabal-addresses` row and UPSERTing a Route 53 record were each unbounded per caller and left no greppable `AUDIT` record of who did what. All four now emit an audit line on success and on failure and are bounded at the same 30-actions-per-minute ceiling. Read-only admin endpoints are unchanged, and are now named individually in the test that pins the rule rather than left to be inferred.
- **Per-method API Gateway overrides no longer opt out of the logging policy.** API Gateway resolves method settings by longest match rather than by merge, so the per-method entries the gateway writes for caching replaced the `*/*` defaults wholesale instead of inheriting them. The `*/*` entry read correctly as `ERROR` with request/response tracing off, while the overrides that actually governed each call did not: 29 of 51 methods in prod and 35 of 51 in stage were running at `INFO` with `dataTraceEnabled`, writing address and envelope metadata into an execution log group kept for a year. The observability policy is now stated once and restated by every override, so no method can silently fall back to the API's own defaults.

## [1.3.4] - 2026-08-22

### Added
- Android: **Unread dot in message lists.** Unread rows now lead with a
  primary-color dot ahead of the sender avatar, complementing the bold
  text (which was too subtle on its own) and matching the Apple clients'
  unread indicator. The dot's slot is always reserved, so marking a row
  read never shifts its layout.

### Changed
- Android: **Instant message-list actions.** Swipe-to-dispose, move,
  purge, and read/flag changes now update the message list, filter pills,
  and counts immediately instead of waiting for the server, from the list,
  the reader, and search results alike. On the rare server-side failure
  the list surfaces the error and reconciles by refetching, and background
  polling holds off while a change is still being confirmed so it cannot
  resurrect a row the user watched leave.

### Fixed
- Android: **Flag changes from other clients land on refresh.** The message
  list served already-cached rows without re-fetching them, so a flag set or
  cleared elsewhere never reached the screen — a star cleared in another
  client survived pull-to-refresh (and app restarts) indefinitely. A cached
  band now paints only as a warm start while the row is re-fetched, and the
  server copy wins unless that row's own flag write is still in flight.

## [1.3.3] - 2026-08-21

### Added
- Android: **Dispose button honors its settings.** The reader's dispose
  button now shows what it will do — an archive box when the preference is
  Archive (previously always a trash can), red trash only for Trash-bound
  actions, restore inside Archive, and permanent delete inside Trash — and
  afterwards opens the message your "After disposing" preference names
  (next, next unread, previous unread, or first unread; new Settings row,
  synced with the Apple clients) instead of always bouncing to the list.
  Long-pressing the button opens the Apple-style split menu of every
  action-and-advance pair; picking one makes it the new default and runs
  it immediately.
- Android: **Brand mark above the folder list.** The folder list's top bar
  now shows the Cabalmail mark in place of the app-name text — forest in
  light, mint in dark — matching the Apple clients' sidebar branding. The
  drawable is generated from the shared source vector by
  scripts/generate-logo-assets.
- Android: **Link menu in the reader.** Tapping a link in a message body now
  opens an action sheet — matching the Apple clients' link popover — showing
  the full destination URL with copy, open (in the browser, or the handling
  app for `mailto:` and other schemes), and share actions. Previously the
  reader's hardened WebView swallowed link taps outright, leaving links
  inert. Plain-text bodies get the same treatment: web URLs, `www.` hosts,
  and email addresses are detected and feed the same menu. Executable and
  local schemes (`javascript:`, `data:`, `file:`, `intent:`, …) stay
  silently swallowed, and the HTML body no longer reloads — losing the
  reading position — when unrelated screen state changes.

### Changed
- Android: **Phones launch into the INBOX list.** On phone-width windows the
  app now opens straight to the INBOX message list, with the folder list one
  Back press beneath it; wide windows keep the folder-list hub. The
  pick-up-where-you-left-off prompt moves to the app-wide snackbar so it
  still appears over the launch view.

### Fixed
- Android: **Dispose icons match the action.** The dispose swipe's reveal
  and the selection toolbar's dispose button always showed a trashcan;
  they now show the archive box unless the dispose actually deletes
  (preference set to Trash, or purging inside Trash), matching their
  labels and the reader's dispose button.
- Apple: **Confirmation dialogs offer a labelled way out again.** On iPhone
  and visionOS, "Revoke <address>?", "Suspend <address>?", "Delete Forever?",
  "Empty Trash?", the folder-delete prompt and the large-selection guard each
  rendered as a popover showing only their destructive button — SwiftUI drops
  a cancel-role button in popover presentation, so the sole labelled control
  was the irreversible one. All nine dialogs now take the back-out role from
  one shared rule, which macOS still resolves to a proper cancel for Escape.
- Apple: **A send that races the draft autosave no longer leaves a copy in
  Drafts.** Tapping Send while the 60-second server autosave was mid-round
  trip delivered the message and kept a full, re-sendable copy of it in
  `Drafts` for good. `/send` carries the draft cleanup, so a send ends the
  session's server copy exactly as Discard does — it now runs through the
  same mutation queue, waiting behind any save in flight and refusing every
  tick that follows. A send that *fails* leaves the composer up and the
  session open, so the close-without-send push still reaches the server.

### Security
- **Refreshed the pinned `amazonlinux:2023` base digest again.** The `imap`,
  `smtp-in`, `smtp-out`, and `sinkhole` Dockerfiles now pin the latest
  upstream `amazonlinux:2023` multi-arch index digest, picking up patched
  `python3`, `python3-libs`, `glib2`, and `gawk` packages on next rebuild.

## [1.3.2] - 2026-08-20

### Changed
- **Approval gate before the Play Console upload.** `android.yml` now
  runs its upload behind the same `gate-prod`/`gate-stage` environments
  as the Terraform, app-deploy, and TestFlight workflows, so a prod
  upload waits for the gate environment's required reviewers; a gate
  environment with no protection rules (currently `gate-stage`) passes
  on its own.

### Fixed
- Android: **Brand launcher icon.** The installed app now shows the
  Cabalmail mark instead of a placeholder envelope glyph: an adaptive icon
  (forest glyph on the cream plate, with a monochrome layer for themed
  icons) generated as vector drawables from the authoritative brand vector,
  matching the Play Store listing icon. The splash screen background now
  uses the brand forest green.
- Android: **Reader mode stays dark at phone widths.** The reader
  stylesheet was appended after the author's styles and relied on cascade
  order to win, but that only beats author rules of equal CSS specificity.
  Marketing emails carry `@media (max-width: ...)` class rules with
  `!important` white backgrounds for their "mobile" layout, so the reader
  went light-text-on-white on phones (and narrow windows) while looking
  fine at tablet width. Reader mode now strips author `<style>` blocks and
  stylesheet links outright; inline styles are still overridden by the
  reader stylesheet.
- Apple: **Sidebar sections can be collapsed and reopened again.** The
  Folders list's "Subscribed" and "All folders" headers now carry their own
  disclosure control. "All folders" ships collapsed, and neither macOS nor
  visionOS drew anything to open it with — on visionOS that stranded `Sent`,
  `Trash` and `Drafts`, and on macOS only an unmarked click on the header
  text would reach them; on iPadOS the header was equally inert but every
  folder was drawn whatever the stored state said. All three now honour the
  same rule and the same control.

## [1.3.1] - 2026-08-19

### Added
- Android: **Play Store listing icon.** `make logo` (and the Logo Assets
  workflow) now also renders `android/app/src/main/ic_launcher-playstore.png`,
  the 512×512 opaque PNG the Google Play Console requires for the store
  listing, from `vector/cabalmail-logo.svg` alongside the Apple, React, docs,
  and front-door derivatives.

### Changed
- Android: **Targets Android API 37; build toolchain refresh.** The client
  now compiles against and targets API 37 (Android 17 compatibility-mode
  behaviour applies) — forced by the Compose BOM 2026.08 line, whose
  artifacts require compileSdk 37 and whose `OldTargetApi` lint check the
  build treats as an error. Alongside: Gradle 8.14 → 9.7, AGP 8.10 → 9.3
  (built-in Kotlin support, so the standalone `org.jetbrains.kotlin.android`
  plugin is gone), Kotlin 2.1 → 2.4, KSP 2.3, ktlint plugin 14, JUnit 6,
  Room 2.8, ktor 3.5, coroutines 1.11, kotlinx-serialization 1.11, Amplify
  2.39, coil 3.5, and gradle-play-publisher 4.1. `material-icons-core` is now
  an explicit dependency (material3 no longer pulls it in transitively).
  Supersedes the dependabot group PR #1147, which could not build as-is.
- Android: **Sign-in says what the control domain looks like.** The
  sign-in form now carries always-visible supporting text under "Control
  domain" naming the expected shape (`admin.example.com` — the host that
  serves the admin web app), and a domain that does not resolve is reported
  as "No such host" with that shape, instead of the generic
  check-your-connection line that also covers being offline. A tester
  typing a mail domain instead of the control domain had no way to tell
  which of the two was wrong.
- Android: **Sign-in asks for the server.** The sign-in screen now takes the
  control domain alongside the username and password, the same as the Apple
  client, and remembers it per install so it is prefilled next time. Nothing
  environment-specific is baked into the build any more: one build works
  against any Cabalmail deployment, and Settings shows the server under
  Account. Existing installs whose build carried a domain keep their session;
  any other install is asked to sign in once, entering the server.
- Android: **Sign-in tokens now use an Android Keystore key the app manages
  itself.** The library the client relied on for at-rest token encryption,
  `androidx.security:security-crypto`, has been retired upstream rather than
  replaced, so its `EncryptedSharedPreferences` is gone from the auth path.
  Tokens are now encrypted with an AES-GCM key held in the Android Keystore —
  the same protection, without an abandoned dependency guarding the session.
  An existing session is migrated on the first launch after updating, so
  signing in again should not be necessary.
- **Monitoring probes the IMAP path that carries mail.** The blackbox job that
  probed the removed `imap.<control-domain>:993` listener is replaced by an
  `imap_starttls` probe of `imap.cabal.internal:143` - plain TCP upgraded with
  STARTTLS, which is what the API Lambdas do. Cert-expiry coverage is
  unchanged: the ACM control-domain cert is observed on the CloudFront HTTPS
  probe and the Let's Encrypt mail cert on submission `:465`. The Kuma
  monitor, its `alert_sink` runbook key, the Mail Tiers dashboard panels, the
  cert-expiry and probe-failure runbooks, and `docs/monitoring.md` follow;
  a new unit test pins the monitor names in the docs to the runbook map so
  the two cannot drift apart silently again.

### Fixed
- Android: **Archive marks read; no duplicate moves.** Archiving (swipe,
  reader, bulk, search) now marks the message read in the same
  `/move_messages` call, as the Apple and React clients do — it was being
  moved unread. The swipe surface fired its action twice when a row was
  dragged all the way to its edge (foundation invokes `confirmValueChange`
  both as the drag ends and again from settle), and the view models accepted
  the repeat; Dovecot runs two concurrent MOVEs of one message
  independently, so the archive gained a duplicate copy, or the later MOVE
  failed with "Could not move message" after the first had already expunged
  the source. Swipes now fire once per gesture, and a move or purge already
  in flight for a UID drops any repeat request.
- Apple: **Bulk "Archive" button no longer trashes the selection.** The
  multi-select action bar's first button drew "Archive" but ran the
  account's *Dispose action* preference, so with that set to Trash it
  deleted the selection instead of filing it — on iPhone, iPad and macOS,
  with no confirmation for a small selection. Its caption, glyph and
  operation now come from one rule that reads the folder and not the
  preference; Restore inside Archive and the rescue out of Trash are
  unchanged, and the preference-driven surfaces (row swipe, reader dispose
  button, Cmd+Delete) still follow it.
- Apple: **Clearing the body now clears the draft.** Typing in the composer's
  Rich Text pane and then deleting it all left the composer dirty for the rest
  of the session: Cancel still raised "Discard draft?" over a visibly empty
  message, autosave still wrote one to the server, and sending it carried
  WebKit's leftover block markup as the body. The composer now asks whether
  the pane holds anything *now* rather than whether it was ever touched, and
  an emptied pane is treated as empty. A reply's quoted original and a resumed
  draft's body are still content, as they were.
- Apple: **Discard Draft no longer leaves the draft on the server.** Pressing
  Discard while the 60-second background save was mid-round-trip expunged the
  copy the composer was holding and then let the completing save append a
  fresh one, so a draft the user had explicitly thrown away stayed in Drafts —
  and Edit Draft on it reopened the message with Send live. Discarding now
  waits for any save already in flight and drops the copy that save landed,
  and a save that arrives after a discard is refused outright.
- Apple: **One disclosure chevron on the compose From pop-up.** On macOS the
  control drew two side by side inside the same capsule — the label's own, plus
  the one AppKit's bordered menu adds. The label now draws its chevron only on
  the platforms whose menus don't supply one.
- **IMAPAuthFailureSpike runbook and alert text describing a threat that no
  longer exists.** Both told the operator that a spike is most likely an
  internet brute force against the public IMAP listener, and the runbook's
  remediation blocked port 993 at a security group and a NACL — controls that
  have been dead since that listener was removed. The runbook now names the two
  causes that remain (the API Lambdas failing to authenticate, or an unexpected
  in-VPC source attempting logins), points at the task-ENI security group as
  the control surface, and records that a plaintext-dialling consumer locks
  itself out *without* firing this alert. A new unit test pins every port a
  runbook prescribes acting on to a port the mail tiers actually publish.
- Apple: **macOS File ▸ New Message with every window closed.** ⌘N and the File menu item reported themselves enabled and silently did nothing once the last window was closed — the state the menu-bar residency exists to make ordinary. Both now open the compose window directly, the way the menu-bar extra's identically-named item already did. Mailbox ▸ Refresh, which shared the fault and has no list to reload in that state, dims instead of advertising a dead command.
- Apple: **Photo attachments keep their real format.** Pictures attached from
  the photo library on iPhone, iPad and Vision Pro went out announced as
  `image/jpeg` with a `.jpg` name whatever they actually were — the bytes
  were never converted, so a PNG or a camera HEIC arrived intact inside a
  part describing it as something else. Recipients that trust the declared
  type could fail to render it, and "save attachment" wrote a `.jpg` that was
  not a JPEG. The composer now reads the format out of the bytes it is about
  to send.
- Apple: **Settings pickers that name a setting now show that name.** The
  dispose-action row rendered as a bare `Archive | Trash` segmented control on
  iOS and iPadOS — the two rows directly beneath it were labelled, so it read
  as a heading-less oddity, and VoiceOver announced "Trash, selected" with no
  indication of what was being set. The Appearance theme row had the same
  problem. Both now carry their label, on every platform.

### Security
- **IMAP tier requires TLS and trusts only loopback.** Dovecot on the `imap`
  container now sets `ssl = required` instead of `ssl = yes`, and its
  `login_trusted_networks` narrows from the NLB public-subnet CIDRs to
  `127.0.0.1`. Both settings existed to let the load balancer's
  TLS-terminated 993 listener forward plain TCP to 143 and still
  authenticate; that listener was removed in 0.11.x, and every consumer now
  dials 143 and issues STARTTLS before LOGIN. This closes the residual
  allowance that anything in the public subnets could attempt plaintext auth.
  The in-container IMAPS listener on 993 is switched off and its task-def
  port mapping and `LOGIN_TRUSTED_NETWORKS` env are gone.

## [1.3.0] - 2026-08-18

### Added
- Android: **First alpha - not yet for production use.** The native client
  described in the entries below lands in this release for the first time.
  It is an alpha: it builds, tests, and publishes to the Play Console
  internal track from CI, but it is not yet ready for production use - keep
  the Apple or web client as your primary mail access.
- Android: **Automated Play internal-track uploads.** `lint.yml` gains a
  `kotlin` job running the client's quality gate (unit tests, ktlint,
  Android Lint with warnings promoted to errors) on every PR touching
  `android/**`; the new `android.yml` runs the same gate plus an unsigned
  release build on `stage`/`main` pushes, then uploads a signed bundle to
  the Play Console internal track via gradle-play-publisher, warn-green
  until the signing/Play secrets are seeded. Dependabot now also watches
  the Android version catalog.
- Android: **Material 3 app shell with dynamic color.** New `android/`
  Gradle workspace starting the native client (Phase 1): `app` module
  (Jetpack Compose + Material 3 shell with dynamic color and platform splash
  screen) and `kit` module (runtime `config.json` fetch/cache service and
  the placeholder `CabalmailClient`), Kotlin-only, min SDK 31, JUnit 5 unit
  tests, and ktlint. See `docs/1.x/android-client-plan.md`.
- Android: **Sign-in (TOTP/SMS) and the full API client.** Hand-rolled
  Cognito `USER_PASSWORD_AUTH` client with TOTP/SMS challenge handling,
  automatic token refresh, and Keystore-encrypted session storage; the full
  Lambda API surface (`ApiClient` - folders, envelopes, search, messages,
  attachments, flags/moves, compose/drafts, preferences, nav state) with
  single-replay 401 recovery; and a working sign-in screen (Phase 3 core).
  15 new unit tests pin the wire contract's quirks (uid-keyed envelope maps,
  `REVERSE ` sort order, 409 duplicate-in-flight, maintenance 503s).
- Android: **Envelope, body, and address caches.** Room-backed envelope
  cache (LRU-bounded working window, UIDVALIDITY-mismatch invalidation),
  disk LRU cache for fetched message bodies (200 MB default cap, atomic
  writes), and an in-memory address repository whose favorites-first
  ordering feeds both the address list and the compose From picker
  (Phase 3 remainder).
- Android: **Folder list, message list, and reader.** Folder list with
  unread badges and pull-to-refresh; index-addressed sliding-window message
  list (placeholder rows, band loading through the envelope cache) with
  read/flagged emphasis, attachment, priority, and auth-failure indicators;
  and a message reader - hardened WebView (no JavaScript, remote content
  blocked until a per-message opt-in), plain-text fallback, flag/read
  toggles, archive-or-purge dispose, and body caching (Phase 4 core).
- Android: **Filters, sort, swipe/bulk actions, and search.** The message
  list gains All/Unread/Flagged filter pills with live `/folder_status`
  counts (patched locally as flags change), a sort menu (date received/
  date sent/sender/subject, either direction), swipe actions (toggle read,
  archive - or purge-with-confirmation in Trash), a long-press context
  menu, and bulk multi-select with a contextual action bar (read/unread,
  flag/unflag, move, dispose). Search arrives as a first-class cross-folder
  scope over `/search_envelopes` with a structured filter sheet and
  cursor paging; each result is labeled with, and operates on, its source
  folder. The reader adds To/Cc headers, SPF/DKIM/DMARC and priority
  chips, BIMI sender logos (colored-initials fallback, also in list rows),
  an Original/Reader render-mode toggle, inline `cid:` images resolved to
  data URIs, an attachment row that downloads via presigned URL and opens
  through a scoped FileProvider, and a move action. The folder list gets
  an Empty Trash action, and the cross-device resume cursor lands via
  `/get_nav_state` / `/set_nav_state`: same-install cursors restore
  silently on launch, foreign ones offer an opt-in "pick up where you
  left off" prompt (Phase 4 remainder).
- Android: **Compose with on-the-fly From and synced drafts.** The client
  can now write mail (Phase 5). The compose screen leads with a From picker
  that has no preselection - Send stays disabled until an owned address is
  chosen - with favorites first and "Create new address..." as its last item
  (a bottom sheet with local part, subdomain, permitted-domain picker,
  comment, and a Random fill), so minting a fresh relationship-scoped
  address is one tap away from every message. Recipients are chips with a
  learned autocomplete; the body is Markdown-canonical (a formatting
  toolbar over the Markdown buffer, rendered to the HTML part on the wire)
  so drafts round-trip losslessly with the Apple and web clients; photos
  and documents attach through the system pickers and stage to S3 via
  `/upload_url`. Reply / reply-all / forward open from a new bottom bar in
  the reader - From defaults to the owned address the original was sent
  to, subjects prefix idempotently, replies thread through the fetched
  body's headers overlaid on the envelope, and forward deliberately starts
  a new thread; a sent reply marks the original answered. Drafts follow the
  Apple sync model: a 5-second local buffer that survives a kill (offered
  at the next launch), a 60-second `/save_draft` sync that replaces the
  prior server copy, close-without-send saves to the server (or asks for a
  From, or drops an empty draft), Discard removes both copies, and messages
  in the Drafts folder offer Edit Draft with Bcc and threading recovered
  from the raw headers. Sending mints a session-stable Message-ID so a
  retry can never double-deliver, and hands the superseded draft to
  `/send` for cleanup. Cabalmail also registers as a share target: text,
  images, and files shared from other apps open a pre-filled compose.
- Android: **Address/folder management, synced settings.** Three new
  destinations behind the folder list's menu (Phase 6). **Addresses** lists
  the user's addresses favorites-first with a star toggle, swipe or
  long-press to revoke (behind a confirmation), pull-to-refresh, and a
  "request new" action that reuses the compose picker's creation sheet - a
  favorite sorts to the top of both this list and the From picker.
  **Manage folders** shows every folder with a subscription switch and
  message count, a "new folder" dialog with a parent picker, and delete for
  empty user folders. **Settings** covers Account (display name, sign out),
  Reading (mark as read, remote content, render mode, folder count display,
  default sort), Composing (default From address, signature), Actions
  (dispose to Archive or Trash), Appearance (theme, dynamic color, accent,
  density) and About. The shared subset - display name, theme, accent,
  density, and the per-client behaviours the Apple client already syncs -
  round-trips through `/get_preferences` / `/set_preferences` (server wins
  on launch; the server merges per key), so a change here shows up on the
  web and Apple clients and vice versa; dynamic color and the default sort
  stay on the device. Every consumer follows the setting live: theme and
  system bars, accent seed when dynamic color is off, row density, folder
  badges, default sort, dispose target and its labels, mark-read-on-open,
  remote content "always", default render mode, and the default From and
  signature seeded into new composes.
- Android: **Tablet split view, offline mode, and notifications.** The
  client grows into each form factor (Phase 7): Mail / Addresses / Folders /
  Settings become top-level destinations in a bottom navigation bar on
  phones and a navigation rail from medium widths up; on tablets and
  foldables the message list and the open message sit side by side
  (hinge-aware), the open row is highlighted, and the resume cursor lands in
  that split with the message preselected. Hardware keyboards get Ctrl+N
  (compose), Ctrl+R / Ctrl+Shift+R (reply / reply-all), Ctrl+Shift+U /
  Ctrl+Shift+L (toggle read / flag) and a j/k row cursor with Enter to
  open. Visible lists poll quietly every minute; an "Offline - showing
  cached mail" banner appears while there is no validated internet path,
  cached messages stay readable, and a send that fails offline is queued
  with a stable Message-ID and sent automatically on reconnect (the server
  deduplicates a retry it already delivered). Optional new-mail
  notifications check INBOX in the background about every 15 minutes (opt
  in from Settings; the permission is requested on Android 13+); tapping
  one opens the message. Reader-side flag and dispose changes now mirror
  into the list without a refresh, every failure gets a plain-language
  message, an expired session returns to sign-in with a reason, predictive
  back is enabled, and release builds are shrunk and obfuscated with R8
  (37.8 MB debug -> 4.9 MB release).
- **Play Console release notes from the changelog.** The prod Android upload
  in `android.yml` now writes release notes for gradle-play-publisher from
  the released `CHANGELOG.md` section: the bold headline of every
  `Android:`-prefixed entry, grouped by category under a "See CHANGELOG.md
  for details." lead, trimmed on whole lines to Google Play's 500-character
  cap (`.github/scripts/play-release-notes.py`). The `Android:` prefix is
  the Android counterpart of `Apple:` - a new `android-changelog.yml` gate
  requires it on PRs touching the client sources (both gates now share
  `check-client-changelog.sh`), and `scripts-tests.yml` fails a PR whose
  pending Android headlines no longer fit the budget.

### Changed
- Apple: **Narrower reader-view margins.** The reader-mode stylesheet's
  side padding is halved (20px to 10px per side), giving the message body
  more width; vertical padding and the reading-width cap are unchanged.

### Fixed
- **Cached message bodies now really go away when a message does.** The API
  Lambdas share one IAM policy that granted only `s3:GetObject`/`s3:PutObject`
  on the raw-message cache bucket, so every endpoint that retires a cached
  body — `send` discarding a superseded draft, `save_draft` replacing or
  discarding one, `purge_messages`, and `empty_trash` — had its delete refused.
  An expunged draft or purged message stayed readable through `fetch_message`
  until the bucket lifecycle rule aged it out. Those four endpoints now hold
  `s3:DeleteObject` on that bucket; the rest of the fleet is unchanged.
  `empty_trash` failed silently on top of this, because the batch delete it
  uses reports a refused key inside a successful response instead of raising —
  that response is now inspected, so a future failure is logged rather than
  reported as success.
- Apple: **Column-resize handle detaches its pan recognizer on the main actor.**
  The iPad message-list resize coordinator removed its window-level gesture
  recognizer from `deinit`, which runs on whichever thread drops the last
  reference — a UIKit call with no main-thread guarantee. The teardown now
  hops to the main actor, so a coordinator released off the main thread can
  no longer leave a recognizer installed on a live window, where it would
  cancel drags anywhere in the app.
- Apple: **A signature on its own no longer counts as a draft.** With a
  signature configured in Settings, every new message the composer opened
  arrived with the signature already in the body — so abandoning one raised
  the "Discard draft?" dialog on macOS and iPad, and leaving one open long
  enough saved a draft to the server containing nothing but the signature.
  The composer now asks whether the *user* wrote anything rather than whether
  the body is empty. A reply's quoted original and a resumed draft's body are
  still content, as they were.
- Apple: **One compose model per composer.** Opening a compose window or
  sheet built the compose view model twice — and with it a second WebKit
  rich-text editor — before SwiftUI discarded the extra copy, so every
  composer cost twice the memory and startup work it needed. The model is
  now built once, on every platform.
- Apple: **Editing in the Rich Text pane no longer sends a stale plain-text
  part.** A composer that opens with a body already in it — a resumed draft,
  a reply, or any message at all once a signature preference is set — used to
  ship that untouched seed as the message's `text/plain` part while the
  `text/html` part carried what was actually typed. A plain-text recipient
  read text the sender never wrote, and reopening the draft (which prefers
  the plain part) brought back the pre-edit body, so the edit looked lost.
  The two parts now agree: the pane the user actually wrote in wins.
- Apple: **Compose windows stop accumulating.** On macOS, iPadOS, and
  visionOS the compose scene group was keyed by the seed draft, and every
  compose session mints a new one, so SwiftUI retained a whole composer —
  view model, rich-text editor, and its web view — per session for the life
  of the app. Compose windows now take a recycled slot instead, which keeps
  a reply and a forward open side by side while bounding what is retained
  by how many composers are open at once. Measured on macOS: the per-session
  cost drops from ~8 MB to under 1 MB, flat across ten sessions.
- Apple: **Closing an untouched compose window no longer demands a decision.**
  On macOS, Cmd+W and the red close button put up the three-way "Discard
  draft?" dialog even over a composer nobody had typed in, where every answer
  threw away the same nothing. Both now run the same check the toolbar Cancel
  button does and close straight away, and still ask whenever there is a draft
  worth deciding about.
- **Web app: the folder rail no longer opens in the previous account's
  shape.** Collapse state for the Subscribed and All folders sections, and
  for individual folders, is now stored per user rather than under one
  browser-wide key, so a second account signing in gets its own rail
  instead of inheriting the first account's collapsed sections. The old
  unscoped keys — which also held the previous account's folder names — are
  cleared at the next login or logout.
- **Web app: cached folder and address lists no longer leak between
  accounts on a shared browser.** The localStorage caches are now keyed
  per user and swept at login as well as logout, so signing in as a
  different account fetches that account's data instead of serving the
  previous user's cache (which login only cleared if the previous user
  had used the Logout button).
- Apple: **Ghost folder row over the sidebar section header.** On macOS, creating or
  deleting a folder left the selected folder's row image painted over the "All folders"
  header, hiding the header text until the app was relaunched. The sidebar's two sections
  are now list sections rather than disclosure groups holding the rows, so a section
  header is no longer part of the row-recycling pool.
- **Triage dashboard finds PRs on locked issues.** The PR column relied on
  GitHub cross-reference events, and GitHub records none on a locked
  conversation - so once bot-opened issues began locking at creation
  (`lock-bot-issues.yml`, 2026-08-16) every fixer PR vanished from the board
  (e.g. #1129 showed no PR although #1135 addressed it). The dashboard now
  also scans the repo's PRs for a closing reference, a `#N` mention in the
  body, or a `fixer/N-...` head branch, and unions that with the timeline.

## [1.2.3] - 2026-08-17

### Added
- **BIMI backfill script.** `scripts/backfill-bimi-records.py` publishes the
  standard `default._bimi` TXT record for address subdomains created before
  BIMI publishing shipped. It reads the domain map and control domain from
  the deployed `new` Lambda, skips subdomains whose DNS is not live, leaves
  any existing BIMI record untouched, and is a dry run unless `--apply` is
  passed. Intended to be run once per environment from CloudShell.
- **Rust in the pull-request lint gate.** The `Lint` workflow now runs
  `cargo xtask ci` — rustfmt, clippy `-D warnings`, the kit and repo-shape
  tests, and the widget tests under xvfb — for PRs touching `linux/**`, on
  Ubuntu 24.04 (the GTK 4.14 / libadwaita 1.4 API floor). Edits to
  `lambda/api/set_preferences/function.py` trigger it too, so a
  preference-key divergence between the Lambda and the Linux client fails
  at review time rather than as a 400 at runtime.
- **CI for the Linux client.** `linux.yml` gates every push to `main` and
  `stage` under `linux/**`, running one `cargo xtask ci` step per job so the
  workflow and the pre-push gate run the same commands: formatting, the kit
  tests, the workspace and Lambda-contract checks, and — inside an
  `ubuntu:24.04` container — the workspace build and the widget tests under
  Xvfb. The container is what enforces the GTK 4.14 API floor on every push
  rather than at packaging time, and the job asserts the version it got. A
  test fails the build if a step has no job, a job names a step that does not
  exist, a job spells a `cargo` command of its own, or a file a job reaches for
  is missing from the workflow's path filter. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
- **Lifecycle flow-chart on the triage dashboard.** An SVG diagram below the
  issue table maps every lifecycle label and the routes between them — entry
  via `needs-verification` or `tester-found`, the verify pass's verdicts,
  triage, the `accepted`/`fix-in-review`/`needs-retest` chain, and each
  terminal state — in the same label colors as the table, themed for light
  and dark. The Accept button is now also disabled while an issue still
  awaits verification, since accepting an unverified report wedges the
  tester's verify pass (its verdict transitions are all forbidden on an
  accepted issue).

### Changed
- **Stage-only promotion to prod.** The direct-to-prod scaffolding
  carve-out is retired: every change now reaches `main` by promoting
  `stage` through the release flow (`make promote`), with no
  feature-branch -> `main` PRs.

### Fixed
- **BIMI record published for admin-created addresses.** The admin
  address-create endpoint published four of the five canonical address DNS
  records, omitting the `default._bimi` TXT, so mail sent from an address
  created that way carried no Cabalmail mark — until a suspend/reinstate cycle
  silently added the record it never had. Both create paths now publish the
  canonical record set from one place, so a record added in future cannot reach
  only one of them.
- **Reserved infrastructure labels refused on both address-create endpoints.**
  `/new` refuses to put an address on one of the control domain's
  infrastructure labels (`admin`, `www`, `imap`, `smtp`, `smtp-in`, `smtp-out`,
  `mail-admin`), where the record would either collide with an existing CNAME or
  overwrite an auth record. The admin "create on behalf of a user" endpoint
  reached the same Route 53 change through its own copy of the create path and
  carried no such check. Both endpoints now apply one shared guard, and that
  guard additionally refuses `mail-admin` on *every* mail domain, not just the
  control domain: it is the subdomain the system sender is provisioned on, and
  an address there could send mail that DKIM-signs and SPF-aligns exactly like
  a Cabalmail notification.
- Apple: **A discarded draft could be reopened and sent.** Discarding a draft
  that had been opened from the Drafts list expunged the server copy but told
  neither the list nor the reader, so the row stayed and the reader kept
  rendering the thrown-away draft — and Edit Draft on it reopened the whole
  message with Send live, which delivered. Cancelling a resumed draft whose
  body had been emptied dropped its server copy just as quietly. Both exits
  now prune the rows they retired and let the reader go.
- Apple: **Cancelling an untouched composer no longer asks what to do with it.**
  New Message → Cancel put up the three-way "Keep a copy of the draft for later,
  discard it now, or go back to editing" dialog over an empty buffer, where every
  answer keeps nothing. The composer now just closes; anything worth keeping —
  including a body the editor failed to hand back — still asks.
- Apple: **A newly saved draft appears in an open Drafts list at once.** Saving
  a brand-new message while sitting in the Drafts folder left the list unchanged
  until its status poll came round, anywhere up to 30 seconds later — the three
  compose exits that already reported (send, save on a resumed draft, discard)
  all announce a copy going away, and a first save only adds one. The save now
  reports the copy it created, so the list refreshes on the spot; nothing is
  pruned and whatever you were reading stays put.
- Apple: **Taps on the trailing edge of an iPad message row.** The drag handle
  that sizes the message-list column was a hit-testable strip, so the trailing
  22pt of every row — including part of the date and the `Select` glyph —
  silently swallowed taps and the row never opened. The handle now claims no
  touches of its own: a pan recognizer above the list begins only for a
  horizontal drag that starts at the column's edge, and everything else reaches
  the row.
- Apple: **Phantom Drafts row after sending an autosaved draft.** A draft left
  open past the 60-second server autosave was saved back under a new UID, and
  sending it only retired that newest copy — so the Drafts list kept showing a
  row for the copy the autosave had already replaced. The row opened a fully
  populated reader with Edit Draft, from which the message could be sent a
  second time. Sending now retires every Drafts copy the compose session
  created.
- Apple: **Saving a draft from the reader dropped the edit you just saved.**
  Save Draft on a draft opened from the Drafts list replaces the server copy
  under a new UID, and neither the list nor the reader the app returns to
  learned about the swap — so the reader kept rendering the retired copy.
  Edit Draft from there reopened the pre-edit text, and sending it delivered
  that stale version while leaving the newer saved copy behind in Drafts. The
  list now prunes the retired copies and moves the reader onto the one that
  survived.

### Security
- **Comment lockdown on pipeline-created issues.** A new workflow locks every
  issue opened by the automation account at creation, so only repository
  collaborators can comment on it. Issues the agent pipelines file and later
  read back are no longer writable by arbitrary accounts on the public repo
  (prompt-injection hardening); human-opened issues are unaffected.

## [1.2.2] - 2026-08-14

### Changed
- Apple: **Reworked macOS reader toolbar.** Every reader action is now its own
  toolbar button — Move, Show plain text, View source, View headers and Print
  join the existing seven — and the app's own "…" menu is gone from macOS. The
  buttons are ordered so a narrowing window folds them into the system's
  toolbar-overflow popup least-important-first (Print first, Reply and
  Archive/Delete last), instead of eating the filing actions first, and every
  button now carries a label so the popup's rows aren't blank. Keyboard
  shortcuts ride the window rather than individual buttons, so they keep
  working at any window width. The global search field moved from above the
  reading pane to above the message list, whose results it shows, and the
  "…" menu's alternate Archive/Delete item is gone everywhere — the dispose
  button's own option menu already offers every destination.

### Fixed
- Apple: **Cmd+Delete in a narrow macOS window.** The chord rode the reader's
  dispose toolbar button, so once the window was narrow enough for the system
  to fold that button into its "more toolbar items" popup, the chord silently
  did nothing. It now rides a control the toolbar can't evict, and works at any
  window width.
- Apple: **Deleting the folder you are looking at now moves you to INBOX.**
  The sidebar row disappeared but the selection kept pointing at the deleted
  folder, so the window title stayed on it, the message list stayed empty, and
  refreshing from there rendered a bare "Internal server error." — the only way
  out was picking another folder. Deleting a folder other than the selected one
  is unaffected, as is a selected child of a deleted parent.
- Apple: **Global search and the Addresses panel are reachable again on iPad.**
  The message-list column draws its own navigation bar at column width, and the
  search field plus the four fixed buttons overran it, so iPadOS folded the
  field and the Addresses button into a system overflow that never opened —
  leaving both with no entry point. The field now draws in the column itself,
  above the list, where it takes the column's width, keeps its magnifier and
  full placeholder, and shrinks with the column when the Addresses panel opens
  instead of hanging under the neighbouring pane. macOS keeps its toolbar
  search field unchanged.
- Apple: **The sidebar's unread badge keeps up with the message list.** New
  mail found by the list's own refresh (the toolbar button, pull-to-refresh or
  the background poll) moved the list's Unread count but left the sidebar badge
  on its old value until the sidebar was refreshed separately, so two counts of
  the same thing disagreed in one window. Both now come from the same server
  reply.
- Apple: **The New Folder sheet shows its example inside the name field
  again.** On macOS the `e.g. Projects` hint was drawn as the row's leading
  label, to the left of the box and under the `Name` header, so the sheet read
  as a field labelled with an example that never went away. It is now grey
  placeholder text inside the empty field, as on iOS.
- Apple: **A message queued while the outbox was draining no longer waits for
  the next network change.** Sending while an earlier queued message was being
  retried enqueued the new message behind a drain that had already listed the
  outbox, and the kick meant to catch it was dropped because a drain was
  running — so the message sat unsent until reachability next changed, which on
  a stable connection could be a long time. A kick that arrives mid-drain is now
  held and runs another pass as soon as the current one finishes.
- Apple: **Long recipients in the reader header.** A recipient wider than the
  reading pane — easy to reach on iPad once the Addresses panel takes a third
  column — was placed at its full width and hard-cut mid-string by the pane
  edge, with no ellipsis and no wrap. The header's flow layout now proposes an
  oversized recipient the width of the line, so it truncates or wraps the way
  the sender line above it already did.
- Apple: **Search field clipped by the neighbouring column.** On iPad, opening
  the Addresses panel left the toolbar's search field wider than the space it
  had: its magnifier and the first letter of "Search all mail" were hidden
  behind the message list. The field now sizes itself to the toolbar area it
  actually has, and keeps its full width everywhere it fits.

## [1.2.1] - 2026-08-13

### Changed
- Apple: **Reader option menus on touch-and-hold.** The reading pane's
  dispose and mark-read controls now carry their option menus on iOS,
  iPadOS, and visionOS too: tap runs the default as before, and
  touch-and-hold (pinch-and-hold on visionOS) opens the same
  Archive/Delete × after-dispose and mark-read-and-go-to menus the macOS
  split buttons offer, checkmarked default included — the same idiom as
  holding Mail's own trash button. The buttons look and act unchanged on
  a plain tap, and the Settings pickers remain the discoverable route.

### Fixed
- Apple: **Compose Contacts buttons under limited Contacts access.** When
  Contacts is granted for a chosen subset of the address book and nothing in
  that subset has an email address, the buttons beside To / Cc / Bcc went inert
  and read "No contacts with email addresses to pick from" — a statement about
  the device that was false, on a phone full of contacts the app simply had not
  been shown, with no way forward from compose. They now stay live, say that
  only the shared contacts are visible, and open the privacy pane where the
  selection is widened. Coming back re-reads the selection, so the pickers arm
  themselves without a relaunch.
- **Search finds a word whatever capitalization it was written in.** The
  full-text index stored each word with its original casing while the search
  side also tried the query lowercased, so the two only ever met for words
  written all-lowercase or in Title case. A word in ALL CAPS (`OTP`, `AWS`, a
  shouty subject, a ticket prefix) was unreachable by any query casing, and a
  word with a capital inside it (`PayPal`) only by retyping it exactly — in
  subjects and bodies alike, and silently, as an empty result rather than an
  error. Terms are now folded to lowercase on the way into the index. Mail
  already indexed keeps the old terms until the index is rebuilt; the operator
  step is in `docs/operations.md`.
- Apple: **Readable mail domain in the Create Address sheet.** On iPhone the
  domain menu was squeezed down to a single character and an ellipsis by the
  username and subdomain fields beside it, hiding which of the configured mail
  domains a new address would use — and hiding it exactly when domains differ
  only in their ending. The domain is now sized before the two fields share
  what is left.
- **A reply sent from the web client marks the message it answers.** The
  answered state was recorded only by the native clients, so a reply written in
  the browser left the original reading as unanswered — in the web client's own
  message list and on every other device. Sending a reply or reply-all from the
  browser now records it where the mailbox keeps it, so the replied indicator
  agrees wherever the message is read.
- Apple: **A typed-but-unsubmitted search no longer looks like "no matches".**
  Search runs when you press Return, but until then the results area went
  blank — indistinguishable from a search that had run and found nothing, even
  though the matching message was there the whole time. A typed term now says
  "Press Return to search", and a search that really did come back empty says
  so and names the term.

## [1.2.0] - 2026-08-12

### Added
- Apple: **Replied indicator in the message list.** Messages you have
  replied to now show the familiar left-turn reply arrow alongside the
  flag and attachment icons. Sending a reply also records the answered
  state on the server, so the indicator appears immediately and follows
  the message to every device.
- **Application shell for the Linux client.** `cabalmail` now opens a GTK4 and
  libadwaita window: an `AdwApplication` under the `com.cabalmail.Cabalmail`
  application ID, a Blueprint-defined main window compiled to a GResource at
  build time, a quit action on Ctrl+Q, and the `theme` preference applied to
  libadwaita's style manager, so `system`, `light`, and `dark` are honoured from
  the first launch. Underneath it is the piece that would be painful to
  retrofit: one tokio runtime owned by the application and a `spawn_to_ui!`
  helper that runs a future on it, hands the result to a `glib` main-context
  task, and captures widgets weakly — the single spelling every later phase's
  requests use, tested end to end before there is a request to make. Ships the
  `.desktop` entry, AppStream metadata, and application icon that packaging
  installs. The build requires `blueprint-compiler`, and it says so by name
  rather than falling back to a second UI format. There is still nothing to
  sign in to; that is Phase 3. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
- **Task runner for the Linux client.** `cargo xtask ci` runs what CI runs, in
  CI's order — `cargo fmt --check`, `clippy -D warnings`, kit tests, workspace
  checks, app tests — stopping at the first failure and repeating the command
  so it can be re-run by hand, and reaching for `xvfb-run` only when there is no
  session for the widget tests to use. The step list lives in one place, so the
  pre-push gate and the workflow that lands in Phase 2 cannot drift apart.
  `cargo xtask sync-vendored` materializes the composer's marked and turndown
  bundles from `react/admin/node_modules`, which stays the single source of
  their version pins across the React, Apple, and Linux clients; the bytes are
  gitignored, and a test fails if a file is added to the script without an
  ignore line. `package`, `smoke`, and `fixtures` are declared rather than
  omitted — asking for one names the work item that implements it — so the plan
  and the workflow can spell an operation before it exists. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
- Apple: **Disposal options on the reader's dispose button.** On macOS the
  reading pane's dispose button is now a split button: the face runs the
  current default, and the chevron opens every Archive/Delete combination
  with where to go next — next message, next unread, previous unread, or
  first unread. Choosing an option makes it the new default, and a
  checkmark marks the option currently in effect. Every Apple
  client gains a matching "After disposing" setting (synced across
  devices) controlling which message the reading pane advances to after
  an archive or delete; previously it always advanced to the next unread.
- Apple: **Mark-read options on the reader's read/unread button.** On macOS
  the reading pane's mark-read button is now a split button like the dispose
  button next to it: the face still toggles read/unread, and on an unread
  message the chevron offers Mark Read and Stay Here / Move to Next Unread /
  Move to Previous Unread / Move to First Unread, with a checkmark on the
  option currently in effect. Choosing an option makes it the new default
  for the face; on an already-read message the options are disabled and the
  button simply marks unread. Every Apple client gains a matching "After
  marking read" setting (synced across devices); the default, Stay Here,
  matches the previous behavior.

### Fixed
- Apple: **Message-list divider in a narrow macOS window.** Below about 920pt
  the list column's cap had collapsed onto its floor, so the divider had no
  travel and the drag silently widened the folder sidebar instead — taking the
  width out of the reading pane the drag was meant to widen. The column now
  keeps a resize range at every window width, bought by letting the list be
  squeezed rather than by letting it grow into the reader.
- **A send retry is no longer refused past the dedupe window.** `/send` claims
  a Message-Id for ten minutes so a retry a client makes after a lost response
  cannot deliver twice, but the claim was released only by DynamoDB's TTL
  reaper, which runs best-effort and can be hours late. A repeat of the same
  Message-Id - the Apple outbox re-submits its stored one on every drain - was
  therefore refused for as long as the row happened to survive, silently,
  behind a `200 "submitted"`. The claim now expires on schedule.
- Apple: **A queued message is no longer discarded when the server refuses to
  send it twice.** `/send` claims a Message-Id across the SMTP handoff, and the
  outbox re-submits its stored id on every drain. Any duplicate used to get the
  same `200 "submitted"` a real delivery gets, so the outbox deleted the queued
  message and logged it as sent - even when the claim was left behind by a
  submission that died before delivering anything, in which case the message
  was simply gone, with no error and no copy in Sent. `/send` now answers only
  a claim it can show delivered that way; one it cannot is a `409`, and the
  outbox holds the message until the claim clears instead of spending a retry
  on it.
- **String-shaped threading headers no longer swallow later sends.** A
  `/send` or `/save_draft` payload carrying `other_headers.message_id` (or
  `in_reply_to`/`references`) as a bare string instead of a one-element list
  composed a Message-Id of the string's first character; `/send` then claimed
  that same character as its dedupe key for every such request, so each one
  after the first was silently discarded behind a `200 "submitted"`. The three
  threading fields now earn the same named 400 a bare-string `to_list` does.
- Apple: **Mac Spotlight results open Cabalmail.** Clicking a Cabalmail
  message in macOS Spotlight opened Apple Mail — the system's default
  handler for the result's email content type — because the macOS app
  didn't declare Core Spotlight continuation. The click now routes back
  to Cabalmail and opens the message. iOS was unaffected.
- Apple: **Spotlight results now appear on iOS and open Cabalmail on
  macOS.** Indexed messages were invisible in iOS Spotlight (iOS 17+
  requires a display name the entries didn't set), and on macOS clicking
  a result still opened Apple Mail — the system routes results typed
  `public.email-message` to the default mail handler no matter what the
  donating app declares, so entries are now donated under a neutral text
  type and macOS delivery goes through the AppKit continuation callback
  (SwiftUI's handler never fires there). The index rebuilds itself once
  on first launch after updating.

## [1.1.0] - 2026-08-10

### Added
- Apple: **Add calendar invites to Calendar.** Tapping an `.ics` attachment on
  iOS / visionOS now opens an event sheet showing the invite's details
  (time, location, organizer, recurrence) with an Add to Calendar button that
  launches the system event editor prefilled — previously the attachment
  preview was a dead end, since iOS gives third-party apps no share-sheet or
  Files route into Calendar. Multi-event files list every event; invites the
  parser can't read still fall back to the QuickLook preview. On macOS,
  opening an `.ics` attachment already triggers Calendar's own import prompt.
- **Cargo workspace for the native Linux client.** `linux/` holds a three-crate
  workspace — `cabalmail-kit` (the GUI-free core), `cabalmail-gtk` (the
  application, which builds the `cabalmail` binary), and `xtask` (build and
  packaging automation) — with the Rust toolchain pinned to an exact 1.97.1,
  edition 2024, a committed `Cargo.lock` for offline distro packaging, and
  shared rustfmt and clippy configuration. No user-facing functionality yet;
  this is the scaffolding the rest of the client is built through. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
- **Layered configuration for the Linux client.** Settings live in a
  hand-editable `$XDG_CONFIG_HOME/cabalmail/config.toml`, resolved through a
  precedence stack — command-line flag, `CABALMAIL_*` environment variable,
  user file, `$XDG_CONFIG_DIRS` entries in order, server-synced preferences,
  built-in default — with every key recording which of those it came from.
  Three sections say how far a value travels: `[preferences]` to every device,
  `[preferences.linux]` to the user's other Linux machines, `[local]` nowhere;
  a key written in the wrong one is an error naming the section it belongs in,
  as is an unknown key or an unacceptable value, each reported with the file,
  line, and column. Client writes are atomic and preserve comments, key order,
  and alignment, so the file can be shared with an open editor. `cabalmail
  --print-config`, `cabalmail config set`, and `cabalmail config reset` drive
  it from a terminal; `config.example.toml` and the `cabalmail.5` key list are
  generated from the same table the parser reads, and a test asserts the synced
  key set matches the `set_preferences` Lambda's so a divergence fails CI
  rather than 400ing on a push. The propagation machinery that watches the file
  and pushes to the server lands with the Settings window in Phase 6. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
- **Core library skeleton for the Linux client.** `cabalmail-kit` gains its
  module layout — config, auth, secret storage, API client, models, MIME,
  caches, compose, outbox, policy, and preferences — together with the
  `CabalmailError` taxonomy every one of them returns. Errors classify
  themselves as transient or permanent, which is what lets the outbox queue a
  send that lost the network while surfacing one the server refused, and each
  case renders a plain sentence rather than a debug form. Still no user-facing
  functionality; the crate has no GTK, libadwaita, or WebKit dependency, so its
  tests run with no display server. See
  [`docs/1.1.x/linux-client-plan.md`](docs/1.1.x/linux-client-plan.md).
- Apple: **Spotlight search for messages.** Messages in subscribed folders
  are indexed on-device with Core Spotlight: search by subject, sender, or
  recipient from system search, plus full text once a message has been
  read, and tap a result to open the message in Cabalmail. The index stays
  on the device and tracks the mailbox — moves, deletes, unsubscribes, and
  sign-out all remove the matching entries.

### Fixed
- Apple: **Contacts buttons in compose no longer sit there looking live.** The
  picker button beside To / Cc / Bcc rendered at full accent strength even when
  it was inert, and it went inert whenever the contact list came back empty —
  including when that was because Contacts access had never been granted, with
  no way to grant it from compose. It now asks for access when access has never
  been decided, opens the system privacy pane when access was refused, and dims
  only in the one case where there is genuinely nothing to pick.
- Apple: **Reading pane could be squeezed out of the macOS window.** The
  message-list column declared no width of its own, so the split gave it what it
  asked for and charged its neighbours: the list froze at its launch width and
  the reading pane absorbed every resize alone, down to 60pt in a small window.
  A reader that narrow shows nothing, so selecting a message looked like it did
  nothing. The list now opens bounded and gives ground as the window shrinks, so
  the reader keeps a readable share at every window size.
- Apple: **Clicking a message row selects it again on macOS 27.** The row's
  click target is now a button rather than a bare tap gesture, which macOS 27
  never delivered the click to — the reading pane stayed on "No message
  selected", no row highlighted, and the Message menu acted on nothing. The row
  also answers `AXPress` now, so VoiceOver and automation can activate it.
- Apple: **macOS folder sidebar opens wide enough to read its folder names.**
  The sidebar took SwiftUI's default column width, which left `INBOX` and
  `Archive` rendering as `I…` and `Arc…` on every launch once the disclosure
  indent, unread badge and row menu had taken their share. It now opens at a
  width sized for a folder name, still resizes by the native divider, and
  remembers the width the user drags it to.
- Apple: **The macOS and iPadOS Message menu dims commands that have nothing
  to act on.** Reply, Reply All, Forward, Mark as Read/Unread, Flag/Unflag and
  Move to Folder… stayed enabled with no message selected and did nothing when
  chosen; each is now enabled only when it has a message to act on.
- Apple: **Filter-pill counts on visionOS.** The All / Unread / Flagged counts
  above the message list were drawn in a secondary foreground fill, which over
  passthrough glass composites to no visible contrast — the row read as three
  bare labels with the numbers missing. They now draw at the same strength as
  their labels on visionOS; iPhone, iPad and the Mac are unchanged.

### Security
- **Every remote-content vector in the web reader is now withheld until you
  load images.** Blocking previously covered only `<img src>`, so a message
  could still reach a tracking host through a CSS `background-image`, an
  `@import`, a `srcset`, or a `<video poster>` — and a message whose only
  remote references were in CSS showed no "remote images are blocked" banner
  at all, leaving no way to opt in. The reader document now carries a
  content-security policy that denies remote subresources outright, and the
  banner appears for all of those vectors.
- Threat protection's responses are now pinned instead of inheriting
  Cognito's defaults: account-takeover risk answers with a TOTP challenge for
  enrolled users (never a hard block, so the password-only service accounts
  that carry the mail path cannot be cut off by a risk misfire), low-level
  noise is ignored, and sign-ins with a breach-corpus password are blocked
  outright. The configuration is inert in audit mode; it defines exactly what
  enforced mode does when `TF_VAR_THREAT_PROTECTION_ENFORCED` is flipped.

## [1.0.0] - 2026-08-08

The [compatibility contract](docs/compatibility.md) is now in effect.

### Added
- **Reference docs for shipped features.** New top-level docs for BIMI
  (`docs/bimi.md`), inbound sender authentication (`docs/inbound-auth.md`),
  durable relay queues (`docs/mail-queues.md`), and IMAP deploy behavior
  (`docs/imap-deploys.md`), linked from operations.md; scan-gate section in
  terraform.md; `/send` idempotency semantics in
  draft-sync-and-threading.md; `TF_VAR_SINKHOLE` and the MFA-enforcement
  variables in github.md. The user manual is rewritten around the native
  clients (sign-in and MFA, suspend vs revoke, mail features, Siri, Watch,
  Contacts) and now documents the in-app admin dashboard.
- **Terraform configuration validation check.**
  `.github/scripts/terraform-validate.sh` runs `terraform init -backend=false`
  and `terraform validate` over a stack, catching the cross-file configuration
  errors the scanners cannot see because they never initialise Terraform — a
  module argument with no matching variable, a reference to an output the
  module does not declare, a wrong type. The pull-request lint workflow runs it
  over both stacks whenever a Terraform path changes. It needs no credentials
  and no backend.

### Changed
- **Clicking an address copies it.** The web app's addresses sidebar no
  longer filters the message list to the clicked address; clicking a row
  now copies the address to the clipboard. The separate per-row copy
  button is gone — the whole row is the copy affordance.
- Apple: **Tapping an address copies it.** The address sidebar no longer
  filters the message list to the tapped address — the "Filtered to …"
  chip is gone, and tapping (or clicking) an address row now copies the
  address to the clipboard, same as the row's Copy Address context-menu
  action.
- **In-container health checks for the imap and smtp-out tiers.** With
  their public NLB listeners gone, these tiers are no longer probed by
  the load balancer; each task definition now checks its own service
  ports (143; 465 and 587) directly. The probe gates deployments (the
  circuit breaker rolls back a task that never becomes healthy) and
  replaces a hung-but-running task in steady state. Inbound relay (25)
  still uses the NLB's own health checks.
- Apple: **iPad reader actions adapt to the pane width.** The pane-scoped
  action bar under the iPad reader now sizes its item set to the pane's
  measured width instead of the iPhone-derived five-item budget: when the
  (user-resizable) reading pane is wide enough, the remote-content and
  reader-view toggles return to the bar and leave the ••• menu; narrowing
  the pane demotes them back to the menu.

### Removed
- **Public IMAP access.** The NLB's IMAPS listener (993) is gone; mailbox
  access is now exclusively through the Cabalmail clients via the Lambda
  API, which reaches the imap tier privately. The `_imaps._tcp` SRV
  record now advertises "not offered" (RFC 6186) like `_imap._tcp`
  already did, and the imap tier's security group no longer admits
  public traffic - 143 is VPC-only (health checks and the Lambda API),
  993 is closed entirely. Outbound submission (465/587) is unaffected.
- **Public SMTP submission.** The NLB's submission listeners (465 and
  587) are gone; sending is now exclusively through the Cabalmail
  clients via the Lambda API, which reaches the smtp-out tier privately.
  The `_submission._tcp` SRV record now advertises "not offered"
  (RFC 6186), and the smtp-out tier's security group no longer admits
  public traffic - 465/587 are VPC-only (health checks and the send
  Lambda). Inbound relay (25) is unaffected - MX delivery requires it.

### Fixed
- Apple: **Status banners no longer cover the iPhone navigation bar title.**
  The offline notice, the toasts and the launch resume offer floated over the
  compact-width navigation bar's centre slot, hiding the name of the folder you
  had just landed in for as long as the banner was up. They now hang just below
  the bar, as they already did on iPad.
- **Plan-document errata sweep.** Audited every versioned plan directory
  (`docs/0.4.x` through `docs/2.0.x`) against the code and git history and
  recorded 64 dated erratum blocks where a plan's claims were falsified by
  what actually shipped — notably the #371 API-backed-transport reversal
  across the 0.6.x/0.11.x Apple plans, the never-built fail2ban replacement,
  the inverted DNSSEC rollout sequence, and the stale Amplify/SNS/1.0.x
  premises in the 1.1.x–2.0.x plans.

Continued in [CHANGELOG-0.md](CHANGELOG-0.md).
