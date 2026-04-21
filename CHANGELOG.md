# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] - Unreleased

### Added

- **Phase 1 — Token foundation + Nav shell** (`docs/0.8.0/redesign-plan.md`):
  - Stately light/dark token set in `AppLight.css` / `AppDark.css` (`--bg`, `--reader-bg`, `--pane-bg`, `--surface`, `--surface-hover`, `--border`, `--border-faint`, `--ink` / `-soft` / `-quiet` / `-danger`, `--accent` / `-fg` / `-ink` / `-soft`, `--shadow-menu` / `-modal` / `-compose`), keyed off `:root[data-direction="stately"][data-theme="…"]` (theme gating replaced with `prefers-color-scheme` later in the cycle — see Changed).
  - Six accent palettes in both light and dark (`ink`, `oxblood`, `forest`, `azure`, `amber`, `plum`) keyed off `[data-accent="…"]`; default `forest`.
  - Theme-independent font, radius, and density tokens (`data-density="compact|normal|roomy"`); Source Serif 4 400/600/700, Inter Tight 400/500/600/700, and IBM Plex Mono 400 loaded via `<link>` in `index.html`.
  - `react/admin/src/assets/logo.svg` (created the folder) with `fill="currentColor"` preserved for the new brand tile.
  - `useTheme` hook — theme/accent/density with localStorage persistence and `data-*` attribute sync onto `<html>`. Cognito sync lands in Phase 7.
  - `Nav/` rebuilt per §4a: 56px top bar, wordmark (accent logo tile + "Cabalmail") left, centered search input with a Lucide search glyph and mono `⌘K` chip, theme toggle, and avatar menu with accent swatches + the existing view switcher (Email / Folders / Addresses / Users / DMARC / Log out). Logged-out state shows Log in + Sign up.
  - Preflight (1) decision: **Lucide**. `lucide-react` added; `Search` / `Sun` / `Moon` / `Check` used in the new Nav.
- **Phase 2 — Left rail (Folders + Addresses)** per §4b:
  - Folders with lucide icons, collapsible FOLDERS section, inline add row, selected-row left-edge 2px accent rail + `--surface-hover` fill.
  - Addresses with stable hash-to-swatch pills (djb2 → 4 accent swatches, case-insensitive), filter input, and `+ New address` row that opens the existing request modal.
  - Clicking an address writes a shared filter key on `Email` (consumed in Phase 3). Left rail total width 280px.
  - New utils: `utils/addressSwatch.js` (djb2 → swatch), `utils/folderMeta.js` (system-kind/label classification + §4b ordering). 29 new tests for utils and both rails.
- **Phase 3 — Message list + bulk mode** per §4c:
  - Middle-pane header (60px): folder title in display 24px, "N of M" count, **All / Unread / Flagged** pill tabs, sort strip.
  - `Envelope.jsx` rewired per §4c: 56px compact row, 8px leading rail (6px unread dot / checkbox in bulk mode), From line (13px, weight keyed to read state), Subject line (serif 14px), relative time (today → "3h", yesterday → "Yesterday", older → day-of-week, >1wk → "Apr 17"), trailing meta icons.
  - Bulk mode: header swaps to selection count + Archive / Move / Mark read/unread / Flag / Delete + ✕ exit. Shift+click range-select ported from the prototype.
  - Empty state: centered mono 13px `--ink-quiet`, "Inbox zero." with filter-empty variant.
  - New state bags on `App.jsx`: `filter`, `sortKey`, `sortDir`, `bulkMode`, `selected` per State Management §.
- **Phase 4 — Reader core** per §4d:
  - Action bar (48px sticky): Reply / Reply all / Forward (icon + label), separator, Archive / Move / Delete / Flag / Mark unread (icon-only), overflow ⋯ right.
  - Header block: subject in display 28px, sender name + `<email>`, "to …" line, right-aligned timestamp, 40px accent-soft avatar with initials.
  - Body: rich HTML renders in a sandboxed `<iframe srcdoc=…>` (per Preflight (4): raw HTML reaches the client, so the iframe sandbox — `allow-same-origin` without `allow-scripts` — is the safety surface) with a post-load height probe; plain-text alternative renders as `<pre>` with `white-space: pre-wrap`, `var(--font-reader)`, `var(--density-leading)`. Body max-width 720px, centered.
  - Attachments block: "Attachments (N)" heading, rows with 28px extension badge colored per family (pdf=oxblood, image=azure, archive=amber, doc=forest, default=ink), filename + size, download icon, row hover `--surface-hover`.
  - Overflow menu FORMAT group only: **Rich (HTML)** / **Plain text alternative** checkable items. `readerFormat` state ('rich' | 'plain', falls back to 'plain' if no HTML part) lifted into `App.jsx`.
- **Phase 5 — Reader advanced surfaces** per §4d:
  - **View source modal** — 880×80vh, `--shadow-modal`, `--radius-lg`. Header with "Message source" label + wrapped subject (ellipsis at 48ch) + Full / Headers / Body segmented control (selected = `--accent` fill) + Copy (→ clipboard) + Save .eml (→ `<subject>.eml` with `message/rfc822`) + close. Headers colorized via `<span class="hdr-name">`. RFC-822 parsing (header folding, first blank-line boundary) lives in a new `utils/emlSource.js` so the modal doesn't replay the prototype's line-counting trick.
  - **Match theme** — with Rich mode + Match theme both on, inject a `<style>` block into the iframe's `<head>` setting `body` background / color / font-family to **literal token values** resolved via `getComputedStyle(document.documentElement)` (CSS custom properties don't cross the iframe boundary). Also applies the README's naive background-neutralization pass (`[style*="background: #fff"]` and variants → `--reader-bg`); called out in the plan as acceptable-for-v1.
  - **Rest of the overflow menu**: View source, Show original headers (reuses the modal pre-set to Headers), Forward as attachment (stub), Print… (`window.print`), Archive, Mark as spam (moves to Junk), Block sender (danger, stub). Arrow-key / Home / End keyboard nav + focus-return to trigger on close.
  - Raw source lazy-loaded on first modal open via the pre-signed URL already returned by `fetch_message` (`message_raw`); `ApiClient.getRawMessage(url)` added so axios' response transform doesn't JSON-parse the eml bytes. `ReaderBody` gains a `matchTheme` prop and re-resolves the injected style whenever the toggle changes.
- **Phase 6 — Compose window** per §4e:
  - Floating 600×560 card pinned bottom-right with 24px offset, `--shadow-compose`, `--radius-xl`, 44px chrome (minimize / expand / close), 180ms slide-in animation. The existing TipTap rich editor (and Markdown tab) is retained inside the new chrome per the phase's explicit "retain the existing editor" scope note.
  - `composeFromAddress` state bag on `App.jsx` per State Management §; the From picker reads it as the default for a freshly-opened window and writes back on selection so the next window inherits the user's last choice.
  - From picker: address chip opens a menu of the user's addresses (swatch + address, current selection highlighted) reusing the Phase-2 djb2 mapping.
  - To / Cc / Bcc rows with 48px right-aligned labels. Cc / Bcc hidden behind a toggle on the To row. Recipient chips render inline; type-to-add preserved.
  - Bottom bar: accent Send button ("Sending…" while inflight), paperclip icon stub, "Saved just now" autosave label (local timestamp-only — no draft API yet), and Discard. Esc minimizes; Cmd/Ctrl+Enter sends from any field inside the window.
  - Multi-window: `Email/index.jsx` maintains a `composeWindows` array rather than a single `composeState`. Each window gets a unique id; `stackIndex` drives an inline right-offset so they stack horizontally with 8px gaps. The old `.compose-blackout` / `.compose-wrapper` scaffolding removed from `Email.css`.
  - Follow-up: `.compose-stack` and `.compose-overlay` raised to `z-index: 200000` so compose clears both the msglist and reader panes (pinned at 99999 in `Email.css`) and the address-request modal (100001), while staying under the AppMessage toast layer (999999).
  - Mobile full-screen variant deferred to Phase 8 per the plan.
- **Phase 7 — Auth screens + preferences persistence + keyboard shortcuts**:
  - **Auth (§§1–3)**: Login, SignUp, ForgotPassword, Verify, and ResetPassword rebuilt on a shared `AuthShell` (header, footer, eyebrow + title, narrow/wide variants). SignUp grows a 4-segment password-strength meter and inline validators for username/phone/password/confirm; Login gains a Show/Hide password adornment + Forgot-password hint + Sign-up link; ForgotPassword branches on a lifted `submitted` flag to render a "Check your phone" success state with "Enter reset code" progression and "Back to sign in" fallback. Nav is gated behind `!isPreLoginView` so auth screens own the viewport.
  - **Preferences persistence**: Preflight (2) resolved in favor of DynamoDB over Cognito custom attributes. New `cabal-user-preferences` DynamoDB table (`PAY_PER_REQUEST`, PITR, SSE); `get_preferences` / `set_preferences` Lambdas with claim-scoped reads/writes and strict value validation; IAM + env wiring in `terraform/infra/modules/app`. `useTheme` accepts an `ApiClient`, hydrates once per mount, and debounces persistence at 1 s; localStorage remains the fast path for first render and offline. A fresh `ApiClient` is memoised in `App.jsx` keyed on `loggedIn` + `api_url` + `imap_host`.
  - **Keyboard shortcuts (Interactions §)**: new `useKeyboardShortcuts` hook installs one document `keydown` listener resolving j/k/Enter/e/#/r/a/f/s/u/c/x/Esc/?, ⌘K and `/` for search, and a 1.5 s `g`-prefix chord for `g i` / `g a` / `g s` / `g t` / `g d` folder navigation. `isTypingTarget` skips INPUT/TEXTAREA/contentEditable except for ⌘K. App-level callbacks handle the `?` toggle, Esc, bulk mode, and search focus; a `shortcutHandlersRef` bridge lets `Email` register `onCompose` / `onGoToFolder` / `onEscape` (closes top compose or reader) without lifting its internals. `KeyboardHelp` overlay is a scrim-backed modal with 4 grouped sections (Navigation, Message actions, App, Go to folder) and fade/scale motion.
  - Preferred subdomain at sign-up was explicitly removed from scope (see Changed).
- **Phase 7.5 — Cosmetic alignment pass** (eight ad hoc rounds on `claude/0.8.0-phase7.5`, summarized in `docs/0.8.0/redesign-plan.md` §Phase 7.5):
  - **Embrace the mockup's accidental serif for UI text.** The mockup set `data-direction="stately"` on `.app` rather than `<html>`, so `body { font-family: var(--font-ui) }` resolved undefined and body fell back to Times; the design owner preferred that serif look. `.folderItem`, `.folderName`, `.addresses-rail__address`, `.envelope-from`, `.msglist-tab`, and the `.reader-sender` / `.reader-sender-name` / `.reader-sender-email` / `.reader-timestamp` / `.reader-to` rules switched to `var(--font-display)` (Source Serif 4). `:root[data-direction="stately"] body` gained `font-feature-settings: "ss01", "cv11"` to match the mockup.
  - **Layout + chrome tweaks.** `div.msglist` gained `border-right: 1px solid var(--border)` at ≥900px. `.reader-actions` z-index `5 → 10` (icons were paint-occluded). `.reader-header` border-bottom replaced by an 80%-wide centered `::after` pseudo-element. `.nav__brand-tile` height `37px → 36px`. `.rail .compose` (Folders "New message" button) pinned at 36px with `flex: 0 0 36px; min-height: 36px; box-sizing: border-box; line-height: 1`.
  - **Legacy CSS swept.** `App.css` lost the `*:not(...)` Tahoma/small override, the `button { font-size: x-small !important }` rule, the global `* { border-radius: 0.2em }` + `img { border-radius: 0 }` pair, and the legacy input/button width/margin rules that were forcing the Sort select to 30em and every button to 10em-wide with 1em top margin. `html { -webkit-text-size-adjust: 100% }` preserves mobile-font-boost suppression without the wildcard. Legacy `div.message-list` / `.email_list` `!important` blocks removed from `AppLight.css` / `AppDark.css`. `.msglist-tab.active` retains targeted `!important` on color/background/border-color to beat the remaining legacy `body .active` `!important` rule (documented for a future Phase 8+ sweep).
  - **Filter pill shape.** Msglist filter tabs rewritten to match the spec: transparent default, `--surface-hover` on hover/active, with only the count number taking `--accent` on the active tab (replacing the heavy solid-accent pill).
  - **Logo inlined.** `logo.svg` imported via `?raw` so `fill="currentColor"` resolves against the brand tile's color token; dark-mode brand tile switches to `#0b0b0b` letters on the light dark-mode accent.
  - **`--font-ui` mapped to Inter** (not Inter Tight) to match the design spec; Google Fonts `<link>` updated accordingly.
  - **Token plumbing fixes.** Email left-rail background `var(--pane-bg) → var(--bg)` for the warm-paper rail/list/reader ladder. `.reader-header` gained a 1px `--border-faint` bottom separator. Envelope hover/selected background extends to the swipeable wrapper so the highlight covers the full row. `Addresses` address rows dropped `var(--font-mono)` — the prototype renders them in `--font-ui` at 12px. `.email` / `.email__middle` got explicit token backgrounds so the legacy `@media (prefers-color-scheme)` `div { background }` rules can't bleed through.
  - **Envelope priority bug.** `Envelope.jsx` `isImportant` previously treated any non-empty `priority` array as important; now only `priority-1` / `priority-2` render the important rail.
  - **Reader toolbar icons.** `.reader-actions .reader-btn svg` pinned at 16×16 with `stroke: currentColor; fill: none; stroke-width: 2` to force paint — `lucide-react@^1.8.0` emits bare SVGs without size attributes, and the remaining legacy `button { color }` rule breaks `currentColor` inheritance until the sweep lands.
  - Compose "From" picker full rebuild (searchable picker + Favorites + inline Create-new-address + per-address descriptive labels) was deferred from the ad hoc pass and landed as its own phase — see the Phase 6.5 entry below.
- **Phase 8 — Responsive + loading/error state polish**:
  - Mobile-first layout with `@media` guards at 768px (tablet) and 1200px (desktop). Phone collapses to a single pane; tablet runs two panes; desktop keeps the three-pane layout.
  - `Folders` becomes a slide-over drawer under 1200px, triggered by a Nav hamburger via a scoped `CustomEvent`. Selecting a folder or address from the drawer closes any open reader so hamburger → folder returns a fresh list instead of stranding the old message on screen.
  - `Email/MessageOverlay` adopts a sheet posture + floating tab bar (reply / reply-all / forward / archive / trash) on phone; toolbar-row hidden below 768px. Phone reader gains a slim top bar with an `ArrowLeft` Back button wired to the existing `hide()` callback; the label comes from `folderMeta()` (so Inbox, Trash, etc. render their display label; custom folders fall through to their own name) rather than a hard-coded "Inbox".
  - `Email/ComposeOverlay` sheet mode on phone with top chrome (Cancel / New message / Send).
  - Loading states: shimmer skeletons in the msglist (4 fake envelopes) and reader (header + 3 body paragraphs); "Sending…" button label during compose send.
  - Error states: AppMessage red-variant toasts reworked to use `--ink-danger` rather than legacy burgundy hexes; reader load failures render an inline retry card rather than a disappearing toast.
  - Viewport tests at 375×812 / 834×1194 / 1440×900 cover the Nav hamburger, Folders drawer chrome, Messages phone header controls, and the MessageOverlay tab bar + retry flow. 150 tests passing.
- **Phase 6.5 — Compose "From" picker rebuild** (the `docs/0.8.0/redesign-plan.md` §7.5 "Deferred" item):
  - New `Email/ComposeOverlay/FromPicker/` component: trigger renders the selected address + descriptive label with its djb2 swatch and a caret; clicking opens a popover with a search input, a Favorites section, a "More addresses" / "Your addresses" section, a "Type to search N more addresses…" hint when the unfiltered list is capped, and a "No address matches" empty state.
  - Search filters by address, subdomain, and the DynamoDB `comment` field; unfiltered view caps at 12 rows, filtered view at 40. Matching substrings are highlighted inline via `<mark class="from-picker__hl">`.
  - Per-row star toggles favorites, persisted to `localStorage` under `cabalmail.compose.favorites.v1` (per-device; kept out of the preferences Lambda to avoid scope creep on Phase 7's DynamoDB schema).
  - Keyboard nav from the search input: ArrowUp/ArrowDown cycle (with wrap), Enter picks the active row, Escape closes. Active row auto-scrolls via `scrollIntoView({ block: 'nearest' })`.
  - Inline "Create a new address" CTA expands the menu into a create form with a back button, a Shuffle "Random" generator, a three-input composer (`username @ subdomain . domain` — domain is a `<select>` of the user's domains), a live preview row, a Note field that maps to DynamoDB `comment`, validation (regex-gated Create & use button), and a hint that notes are searchable.
  - Submit calls `api.newAddress(username, subdomain, tld, comment, address)`, selects the new address on success, fires `onCreated` so `ComposeOverlay` re-fetches the address list (picking up the new row with its note), and writes an `AppMessage` toast — all without closing the compose window.
  - `ComposeOverlay` now stores the full address items (so the picker has access to `comment`) and exposes `domains` + `setMessage` to the picker; the old inline From dropdown (menu state, outside-click handler, and ~100 lines of `.from-picker__*` CSS) was removed from `ComposeOverlay.css` since the picker now owns its own `FromPicker.css`.
  - 13 new Vitest cases cover trigger open/close, search filtering, favorites toggle + persistence, favorites hydration from localStorage, keyboard nav, create flow submit, validation gating, and cancel.
  - UAT follow-ups (same phase):
    - **No default From address.** Fresh compose windows start with the picker empty; the user must pick (or create) an address before sending. `handleSend`'s existing `addresses.indexOf(address) !== -1` guard catches the empty-string case and surfaces the "Please select an address from which to send." toast. Reply / reply-all / forward still pre-fill `address` with the original envelope recipient, and a user-picked `composeFromAddress` still carries over into the next compose window.
    - **No default domain in the inline Create form.** The domain `<select>` opens on a disabled placeholder (`"domain"`, or `"(no domains)"` when the user has none); Create & use stays disabled until `username`, `subdomain`, and `domain` are all set.
    - **Password-manager autofill suppressed** on the three Create-form inputs. A `username` input next to a second text field reads as a credentials form to 1Password / LastPass / Bitwarden, so each input (and the domain select) got `autoComplete="off"`, neutral `name` values (`cabal-local-part` / `cabal-subdomain` / `cabal-domain`), and the vendor-specific `data-1p-ignore` / `data-lpignore` / `data-bwignore` / `data-form-type="other"` attributes.
- **Logo vector refresh.** `react/admin/src/assets/logo.svg` replaced with the smooth paths from `apple/handoff/cabalmail-mark.svg` (circle-with-flag + envelope). The prior SVG was traced from a raster source, so its vectors followed the stair-step of the original pixels and rendered visibly jagged at the brand-tile size. ViewBox set to `0 80 400 200` to match the 2:1 brand tile; `fill="currentColor"` preserved so the existing Nav / AuthShell light/dark behavior (`--accent` background, `--surface` / `#0b0b0b` foreground) carries through unchanged.

### Changed

- **Theme preference dropped in favor of `prefers-color-scheme`.** Phase 1 shipped a manual sun/moon toggle in the nav; before Phase 7.5 landed, the toggle was removed and all Stately-direction tokens (`AppLight.css`, `AppDark.css`, `Nav.css` accent swatches, `AuthShell.css`) rewired to respond to `@media (prefers-color-scheme: dark)` instead of a `data-theme` attribute. `useTheme` still manages accent/density (localStorage + API sync) but no longer tracks theme. The Cognito schema was never touched for theme as a result; only accent and density round-trip to the new `cabal-user-preferences` DynamoDB table.
- **Stylesheet load order: `AppDark.css` now loads after `AppLight.css`.** `AppLight.css` defines unconditional `:root[data-direction="stately"]` tokens as the default; `AppDark.css` overrides them inside `@media (prefers-color-scheme: dark)`. The previous order put AppLight last, so in system dark mode its light tokens won by source order at equal specificity and `--reader-bg` (and siblings) resolved light. Swapping the imports lets the dark-media-query rules win in dark mode.
- **Preferred subdomain removed from sign-up.** The redesigned SignUp form no longer asks for a preferred subdomain; the field and its validators are gone from `react/admin/src/SignUp/` and Phase 7's Definition of Done is updated accordingly.

## [0.7.0] - Unreleased

## [0.6.1] - Unreleased

### Fixed

- Apple client: IMAP envelope subject and address display names now pass through `HeaderDecoder.decode`, so RFC 2047 encoded-words (`=?utf-8?B?…?=`, `=?utf-8?Q?…?=`) render as their decoded text instead of appearing literally. Matches the Python `decode_header` behavior in `lambda/api/list_envelopes/function.py`. Regression coverage added in `ImapParserTests`.

## [0.6.0] - 2026-04-20

### Added

- `apple/` — Phase 1 scaffolding for the native Apple client (iOS/iPadOS/visionOS app target + native macOS app target + shared `CabalmailKit` Swift package with `Configuration` model and smoke tests)
- `apple/project.yml` — XcodeGen spec; the `.xcodeproj` is generated at build time rather than committed
- `apple/Local.xcconfig.example` — template for a gitignored per-developer xcconfig supplying `DEVELOPMENT_TEAM`
- `.github/workflows/apple.yml` — Phase 2 CI/CD for the Apple client: `kit-test` (SwiftLint + CabalmailKit tests across macOS/iOS/visionOS), `app-build` (unsigned build of both app targets), `upload-ios` (archive + TestFlight upload, main/stage only), `upload-mac` (archive + TestFlight upload + developer-id notarization + workflow artifact, main/stage only)
- `apple/.swiftlint.yml` — permissive SwiftLint configuration tuned for the current scaffold
- `apple/ci/ExportOptions-iOS.plist`, `apple/ci/ExportOptions-macOS.plist`, `apple/ci/ExportOptions-macOS-DeveloperID.plist` — archive export configurations used by the upload jobs
- `apple/scripts/generate-placeholder-icons.sh` + `generate-placeholder-icon.swift` — one-shot generator for a 1024×1024 placeholder app icon (rendered via CGContext for exact pixel dimensions) and sips-derived macOS icon catalog sizes. Replace output with real artwork before non-internal distribution
- `CFBundleIconName: AppIcon` and `ITSAppUsesNonExemptEncryption: false` set on both app targets via `project.yml` — required by App Store validation for icon-catalog apps and pre-answers the TestFlight export-compliance prompt for HTTPS-only traffic
- Terraform: `aws_s3_object.website_config_json` in `terraform/infra/modules/app/s3.tf` — publishes `/config.json` alongside `/config.js` so the Apple client has a parseable runtime configuration source
- Documentation: Phase 1 decisions recorded in `apple/README.md` (native macOS target over Mac Catalyst; `config.json` delivery over bundled `.xcconfig`); Phase 2 CI layout and required GitHub secrets documented in the same file
- **Apple client Phase 3 — Authentication & Transport** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.AuthService` protocol + `CognitoAuthService` actor — hand-rolled Cognito `USER_PASSWORD_AUTH` / `REFRESH_TOKEN_AUTH` over `URLSession`, plus sign-up, confirm, forgot-password, resend flows. Matches the pool's `explicit_auth_flows = ["USER_PASSWORD_AUTH"]` so no AWS Amplify dependency is required.
  - `CabalmailKit.SecureStore` protocol with a Security-framework-backed `KeychainSecureStore` (data-protection keychain, shared iOS/macOS) and an `InMemorySecureStore` for tests. Tokens persist as a single JSON blob; IMAP username/password live in separate keychain items so sign-out clears them alongside the tokens.
  - `CabalmailKit.ApiClient` protocol + `URLSessionApiClient` actor — attaches the Cognito ID token to every request, transparently retries once on 401 after forcing a refresh, and surfaces a second 401 as `.authExpired`. Backs `/list`, `/new`, `/revoke`, and `/fetch_bimi`.
  - `CabalmailKit.ImapClient` protocol + `LiveImapClient` actor — TLS-from-connect IMAPS (993) via a `NetworkByteStream` built on `NWConnection`. Supports LOGIN, LIST/LSUB with `/`↔`.` delimiter translation, CREATE/DELETE/SUBSCRIBE/UNSUBSCRIBE, STATUS, SELECT, UID FETCH (ENVELOPE/FLAGS/BODYSTRUCTURE/RFC822.SIZE/INTERNALDATE/BODY[]), UID STORE, UID MOVE (with COPY+STORE+EXPUNGE fallback for servers without RFC 6851), UID SEARCH, APPEND, LOGOUT, and IDLE (via a dedicated second connection yielding an `AsyncThrowingStream<IdleEvent, Error>`).
  - `CabalmailKit.SmtpClient` protocol + `LiveSmtpClient` actor — submission over implicit TLS on port 465 (the submission listener in `terraform/infra/modules/elb/main.tf` binds both 587 and 465; 465 sidesteps `NWConnection`'s lack of STARTTLS upgrade support). AUTH PLAIN against the same Cognito credentials Dovecot uses, RFC 5322 message assembly via `MessageBuilder` (multipart/alternative, multipart/mixed with attachments, RFC 2047 header encoding, RFC 2045 base64 wrapping, RFC 5321 dot-stuffing).
  - `CabalmailKit.EnvelopeCache` — per-folder JSON snapshot keyed by UIDVALIDITY, sized for the "STATUS + UID FETCH since UIDNEXT" reconnect flow from the plan.
  - `CabalmailKit.MessageBodyCache` — disk-backed LRU for `BODY.PEEK[]` payloads with a configurable byte cap (default 200 MB), evicting by file mtime.
  - `CabalmailKit.AddressCache` — in-memory actor mirroring the React app's `localStorage[ADDRESS_LIST]` invalidation pattern.
  - `CabalmailClient` actor rebuilt as the top-level facade: owns the auth session and exposes every service + cache; `CabalmailClient.make(configuration:secureStore:...)` wires production against the real Cognito/API/IMAP/SMTP tiers in one call.
  - `CabalmailKit` test target coverage for: Cognito sign-in happy path and refresh-on-expired, `NotAuthorizedException` mapping, `ApiClient` token attachment and 401→refresh→retry behavior, IMAP LIST/STATUS/FETCH-with-literal/STORE/MOVE-with-fallback + folder-delimiter translation, SMTP AUTH-failure mapping and dot-stuffing, and the IMAP response parser across tagged/untagged/FETCH/SEARCH shapes.
- **Apple client Phase 4 — Mail Reading** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.ConfigLoader` — fetches `/config.json` from a user-supplied control domain. The sign-in form passes the domain once; subsequent launches reuse the cached `Configuration` so the same binary works against dev/stage/prod.
  - `CabalmailKit.MimeParser` — hand-rolled multipart tree walk over raw `BODY.PEEK[]` bytes. Decodes RFC 2045 `Content-Type` / `Content-Disposition` / `Content-Transfer-Encoding` parameters, traverses arbitrarily-nested `multipart/*`, and exposes leaf parts, attachment candidates, and a `cid:` → decoded-body map for inline images.
  - `CabalmailKit.MimeDecoders` — quoted-printable and base64 body decoders; lenient on malformed input so one broken part doesn't blank the whole message.
  - `CabalmailKit.HeaderDecoder` — RFC 2047 encoded-word decoder (UTF-8 / ISO-8859-1 / Windows-1252 / US-ASCII; Q and B), including the §6.2 rule that whitespace between adjacent encoded-words is stripped.
  - 9 new `MimeParserTests` cover plain text, base64 bodies, quoted-printable with soft-break and hex escapes, `multipart/alternative`, `multipart/mixed` with attachments, encoded-word headers, mixed-encoding header values, and folded-header unfolding. Total `CabalmailKit` tests: 39 (was 30).
  - App target (`apple/Cabalmail/`): `AppState` (`@Observable @MainActor`) as the root state; `SignInView` (control domain + user/pass); `FolderListView` with per-folder `STATUS (UNSEEN)` badges, Inbox-pinned-first ordering, and pull-to-refresh; `MessageListView` with UIDNEXT-based sliding-window fetch, on-scroll pagination, `.searchable` wired to IMAP `UID SEARCH`, swipe-to-archive / swipe-to-flag; `MessageDetailView` with headers block, body renderer, attachment strip, and a toolbar "Load remote content" toggle; `HTMLBodyView` wrapping `WKWebView` with non-persistent data store, JS disabled, and a `WKNavigationDelegate` that rejects every non-`file://` / non-`data:` request unless the user has flipped the toggle; `AttachmentStrip` opens downloads via `QLPreviewController` on iOS / visionOS and `NSWorkspace.open(_:)` on macOS.
  - `MailRootView` branches on horizontal size class: iPhone gets a `NavigationStack` (folder → messages → detail), iPad / macOS / visionOS get a three-column `NavigationSplitView`.
  - macOS target (`apple/CabalmailMac/`): now shares the iOS view sources via `project.yml` (`Cabalmail/ContentView.swift`, `Cabalmail/AppState.swift`, `Cabalmail/Views/`, `Cabalmail/ViewModels/`). The Phase 1 "separate views per target" decision relaxed to "shared SwiftUI, separate bundles + entry points"; the Settings scene and hardened-runtime entitlement stay macOS-only.
  - Root envelope-list cache integration: `MessageListViewModel` hydrates from `EnvelopeCache` on open (so reopen is instant), merges refreshed envelopes back, and invalidates both caches on a `UIDVALIDITY` change. `MessageDetailViewModel` consults `MessageBodyCache` before issuing `UID FETCH BODY.PEEK[]`.
- **Apple CI hardening — manual code signing for archive + export:**
  - Both `upload-ios` and `upload-mac` archive steps now sign manually (`CODE_SIGN_STYLE=Manual`, `PROVISIONING_PROFILE_SPECIFIER=<UUID>`, `CODE_SIGN_IDENTITY="Apple Distribution"`) against a provisioning profile installed from a new per-target GitHub secret. `-allowProvisioningUpdates` and the `-authenticationKey*` args are dropped from `xcodebuild archive` and `exportArchive`; auto-provisioning never touches Development certs, so Apple's per-team cert cap no longer fails the build.
  - New composite action `.github/actions/install-provisioning-profile` decodes a base64-encoded profile (iOS `.mobileprovision` or macOS `.provisionprofile`) into `~/Library/MobileDevice/Provisioning Profiles/`, reads the UUID from the CMS-signed plist, and exports it via `$GITHUB_ENV` so the archive step can reference it as `PROVISIONING_PROFILE_SPECIFIER`.
  - Export-options plists are now generated at CI time via heredoc with the profile UUID embedded in `provisioningProfiles`; the static `apple/ci/ExportOptions-*.plist` files are removed. Removes the risk of archive-vs-export profile drift.
  - Mac App Store `.pkg` signing: the `upload-mac` job now imports a **Mac Installer Distribution** cert alongside the Apple Distribution cert (the outer `.pkg` wrapper needs its own cert), and the generated export-options plist references it via `installerSigningCertificate = "3rd Party Mac Developer Installer"`. New required secrets: `MAC_INSTALLER_CERT_P12` / `MAC_INSTALLER_CERT_PASSWORD`. The keychain password is now persisted to `$RUNNER_TEMP/keychain-password` (chmod 600) so the optional Developer ID import later in the same job can unlock the same keychain.
  - `CURRENT_PROJECT_VERSION` is now a Unix timestamp (`date -u +%s`) rather than `github.run_number`. `CFBundleVersion` must be strictly monotonic per marketing version across everything that has ever uploaded to the App Store Connect record, and `run_number` can drift below the highest previously-uploaded build (e.g. after a workflow rename). Timestamps are always higher than the last upload.
  - New required secrets: `IOS_APP_STORE_PROFILE` (gates `upload-ios`), `MAC_APP_STORE_PROFILE` + `MAC_INSTALLER_CERT_P12` + `MAC_INSTALLER_CERT_PASSWORD` (gate `upload-mac`), and optionally `MAC_DEVID_PROFILE` (paired with `DEVELOPER_ID_CERT_P12` to produce the notarized direct-distribution artifact; missing either pair member skips that artifact cleanly).
  - App Store Connect API key role can drop from **Admin** to **App Manager** — CI no longer calls the profile-creation API. Documented in `apple/README.md`.
- **Apple client Phase 5 — Mail Composition & On-the-Fly From** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.ReplyBuilder` — pure value-type helper that turns an `Envelope` + its decoded plain-text body + the user's owned addresses into a seeded `Draft`. Implements idempotent `Re:` / `Fwd:` subject prefixing, `In-Reply-To` / `References` threading, reply-all deduplication and self-exclusion, reply-attribution + `>`-prefixed quoting, forward-banner quoting, and the "default From to the original's addressee" rule that makes the per-correspondent address minted for one reply reusable across the whole thread.
  - `CabalmailKit.Draft` + `CabalmailKit.DraftStore` — Codable model and atomic on-disk store (`{cacheDirectory}/drafts/{uuid}.json`) with corrupt-file recovery. `ComposeViewModel` autosaves every 5 s while the sheet is open so a mid-compose app kill is recoverable.
  - `CabalmailClient.send(_:)` facade — stamps a shared `Message-ID`, submits the payload via SMTP, then best-effort-`APPEND`s the identical payload to the `Sent` IMAP folder with `\Seen` set. Matches the React app's `send` Lambda behavior so both clients produce the same Sent-folder view; a failed APPEND after a successful submission does not surface as a send error.
  - `OutgoingMessage.messageId` — optional, lets the sender supply a pre-generated Message-ID so the Sent copy and the wire copy thread as one message.
  - App target: `Cabalmail/Views/ComposeView.swift` (SwiftUI form sheet — From picker, To/Cc/Bcc token fields, Subject, plain-text `TextEditor`, attachment strip, Cancel/Attach/Send toolbar, discard-draft confirmation); `Cabalmail/Views/FromPicker.swift` (Menu with "**Create new address…**" as the first, always-visible item per the Cabalmail on-the-fly-From idiom, alphabetized existing addresses below); `Cabalmail/Views/NewAddressSheet.swift` (inline address-creation form mirroring `react/admin/src/Addresses/Request.jsx`, including the Random button); `Cabalmail/ViewModels/ComposeViewModel.swift` (state, autosave loop, send/cancel/discard flows, `canSend` gating, PhotosPicker + fileImporter ingestion).
  - `MessageDetailView` gains a Reply / Reply All / Forward menu in its toolbar; `MessageListView` gains a New Message toolbar button. Both present the same `ComposeView` sheet, differentiated only by the `Draft` seed passed in (`ReplyBuilder.build(from:body:mode:userAddresses:)` vs `ReplyBuilder.newDraft()`).
  - `MailRootView` seeds `selectedFolder` to INBOX the first time the folder list loads, so a freshly-signed-in user lands in a state where the New Message button on the message-list toolbar is reachable instead of on an empty "Select a folder" screen.
  - `URLSessionApiClient.listAddresses()` decodes the real `/list` Lambda wire shape (`{"Items": [...]}`, mirroring the DynamoDB scan response), with the previous `{"addresses": [...]}` and bare-array fallbacks kept as lenient alternates. Pinned with a test against the exact Lambda output so the compose From picker can't silently fail to decode again.
  - `CabalmailKit` test coverage: 12 `ReplyBuilderTests` (subject prefixing idempotence, default-From selection from owned addresses including case-insensitive match and "no owned match → nil" fallthrough, reply-to-list primary/cc split, reply-all dedup + self-exclusion, Reply-To-over-From precedence, forward-has-no-recipients, reply-body `>` quoting + attribution line, forward banner, threading-headers with and without the original's In-Reply-To, ReplyBuilder → OutgoingMessage → MessageBuilder integration asserting the wire payload includes the right `In-Reply-To` / `References` / `Re:` subject); 8 `DraftStoreTests` (round-trip, empty-draft-not-persisted, empty-draft-cleans-stale-file, list-sorted-newest-first, remove, corrupt-file-skipped-and-removed, load-missing-returns-nil, save-replaces-existing); 1 new `ApiClientTests.testListAddressesDecodesItemsWrapperFromLambda` pinning the `/list` wire shape.
  - `CabalmailClient` stored properties marked `nonisolated` (immutable, `Sendable`) so SwiftUI views can read `client.configuration.domains` and other references synchronously — mutating flows still funnel through the actor's methods.
  - `ImapClient.swift` split into three files to stay under SwiftLint's 400-line cap and keep the public protocol separate from the actor: `ImapClient.swift` (public protocol + `IdleEvent` + connection-factory types), `LiveImapClient.swift` (actor + IMAP commands + transport-retry + internals extension), and `LiveImapClient+Idle.swift` (public IDLE extension). Behavior unchanged; `LiveImapClient.move(_:)` hoists the quoted destination string into a local to stay under the 120-col line-length cap.
- **Apple client Phase 6 — Address & Folder Management** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.Preferences` — `@Observable @MainActor` preferences object covering the five Phase 6 surfaces (Reading: `MarkAsReadBehavior` + `LoadRemoteContentPolicy`; Composing: default From address + plain-text signature; Actions: `DisposeAction`; Appearance: `AppTheme`). Backed by a pluggable `PreferenceStore` protocol. `UbiquitousPreferenceStore` persists locally to `UserDefaults` and syncs across devices via `NSUbiquitousKeyValueStore`, mirroring every change both ways; `InMemoryPreferenceStore` backs tests and SwiftUI previews. An `isReloading` guard keeps an incoming iCloud push from re-persisting through the property `didSet` hooks.
  - `CabalmailKit.SignatureFormatter` — pure value-type helper that inserts the signature into a compose body with the RFC 3676 `-- ` delimiter on its own line. Handles the three entry points (empty new message / reply-or-forward with a leading blank-line-attribution-quoted-original base / arbitrary base) so compose always lands with the user's signature in the expected position.
  - App target: `Cabalmail/Views/AddressesView.swift` (my-addresses list with revoke-via-swipe + context menu + confirmation dialog; "+" toolbar presents the same `NewAddressSheet` the compose From picker uses, so address creation is identical between the two entry points); `Cabalmail/Views/FoldersAdminView.swift` (subscribed / not-subscribed sections, per-row subscription toggle, swipe-to-delete on user folders with confirmation, system folders protected from delete; "+" toolbar opens a `NewFolderSheet` with an optional parent picker seeded from the current folder list); `Cabalmail/Views/SettingsView.swift` (Account, Reading, Composing, Actions, Appearance, About sections mapped to the plan's preference table); `Cabalmail/Views/SignedInRootView.swift` (`TabView(selection:)` + `Tab { … }` with `.sidebarAdaptable` style — iPhone gets a bottom tab bar, iPad/visionOS/macOS get a sidebar; macOS hides the Settings tab because the Settings scene at ⌘, handles it); `Cabalmail/ViewModels/AddressesViewModel.swift` + `Cabalmail/ViewModels/FoldersAdminViewModel.swift` (wrap `CabalmailClient.addresses` / `revokeAddress` and the IMAP LIST / CREATE / DELETE / SUBSCRIBE / UNSUBSCRIBE commands with list state and error banners).
  - `MessageListViewModel.dispose(_:)` now reads `Preferences.disposeAction` at call time — Archive or Trash — instead of hardcoding Archive; `MessageListView`'s trailing swipe label and icon follow the preference in real time. `MessageDetailViewModel` honors the three mark-as-read modes: `.manual` is a no-op (Phase 4 default), `.onOpen` sets `\Seen` the moment the body loads, and `.afterDelay` schedules a cancellable 2-second task that the detail view cancels on disappear so a message the user only previewed for a moment stays unread. `MessageDetailViewModel` also seeds `remoteContentAllowed` from `Preferences.loadRemoteContent` (`.off` / `.ask` start blocked, `.always` opens the gate).
  - `ComposeViewModel` gains a `Preferences` parameter; `fromAddress` defaults to `Preferences.defaultFromAddress` only when the seed didn't already pick one (so the reply-builder "default From to the original's addressee" rule from Phase 5 still wins on replies), and the body is seeded through `SignatureFormatter.seedBody` so a configured signature lands in the right place for new messages, replies, and forwards.
  - `CabalmailApp` / `CabalmailMacApp` now own the `AppState` and `Preferences` instances at the App level (previously the iOS target's `ContentView` owned an inline `@State AppState`). Hoisting them lets the macOS `Settings` scene bind the same `Preferences` instance the main window uses, and gives both targets a single place to wire `.preferredColorScheme` off the theme preference so Theme = Dark flips the whole app immediately without a round-trip through the mail views. The `FolderListView` toolbar's sign-out button is removed — Settings is the canonical place for account controls now.
  - `CabalmailKit` test coverage: 9 `PreferencesTests` (defaults match the plan; every preference persists through the store; nil-assignment removes the key; initial values are read from a populated store on init; garbage raw values fall back to the enum default; external changes refresh every property; external reload doesn't re-persist through `didSet`; DisposeAction → IMAP folder name mapping); 5 `SignatureFormatterTests` (empty signature is a no-op; empty base lands signature below a blank line; reply base inserts signature above the quoted block; arbitrary base prefixes signature with a line break; multi-line signatures preserved).
- **Apple client Phase 6 follow-ups** (`docs/0.6.0/ios-client-plan.md`, TestFlight feedback):
  - **Archive marks as read, matching the React webmail.** `MessageListViewModel.dispose(_:)` now sets `\Seen` on the message before the `UID MOVE` (after the move the UID is no longer in the current folder, so STORE would be rejected). A failed mark-read short-circuits the move the same way a failed move short-circuits the cache prune.
  - **Dispose and refresh now prune the envelope + body caches, fixing "archived messages reappear after relaunch."** `EnvelopeCache` gains `remove(uids:folder:)` and `replace(envelopes:uidValidity:uidNext:keepingRange:into:)`; the former drops specific UIDs from a folder's snapshot, the latter rewrites the refresh-window portion of the cache so any cached UID the server didn't return in the fetch response is pruned (outside-window older pages are preserved). `MessageBodyCache` gains a per-UID `remove(folder:uidValidity:uid:)`. `dispose(_:)` calls both after a successful move; `refresh()` computes the set of UIDs in the refresh window that the server no longer returns and prunes them from both the in-memory array and the persistent cache.
  - **Re-entrant-dispose guard against the UIKit assertion crash.** Previously, rapid-fire swipe-archive on several rows fired overlapping `Task { await model.dispose(...) }` invocations, each of which mutated `envelopes` on completion. The resulting SwiftUI diffs during an in-flight layout could trip `NSInternalInconsistencyException` from UIKit's CollectionView diffing path (observed in a TestFlight crash report). `MessageListViewModel` now tracks `pendingDisposeUIDs: Set<UInt32>` and short-circuits a second dispose for a UID while the first is in flight; `loadMoreIfNeeded` additionally defers pagination while any dispose is pending and stops spinning when an empty fetch returns (instead of decrementing `lowestUID` one at a time until it reaches the bottom).
  - **Swipe direction swap to match Mail.app conventions.** Leading (left-to-right) swipe now toggles `\Seen` (Mark as Read / Mark as Unread, `envelope.open` / `envelope.badge` icons); trailing (right-to-left) stays Archive/Trash per the Dispose preference. Flag is still reachable via the row's context menu, which also exposes Mark-as-Read and Dispose for pointer-only callers (Mac / iPad with trackpad).
  - **Launch auto-restore via Keychain-persisted Cognito tokens.** `AppState` adds a `.restoring` status and a `restoreIfPossible()` method that, on launch, reads `controlDomain` + `lastUsername` from `UserDefaults` and the Cognito tokens from the Keychain, loads `Configuration` from the control domain, constructs a `CabalmailClient`, and calls `authService.currentIdToken()` to force a silent refresh (cached token → no-op; expired ID token → refresh via stored refresh token; revoked refresh token → `invalidCredentials`). On success the app transitions straight to `.signedIn` and skips the sign-in form. On `authExpired` / `invalidCredentials` / `notSignedIn` the keychain is wiped so the form starts clean (username / control domain stay pre-filled). On transient network errors (airplane mode at launch) the keychain is preserved so a later retry can recover without forcing a password re-entry. `CabalmailApp` and `CabalmailMacApp` wire `await appState.restoreIfPossible()` via `.task` at the root scene; `ContentView` branches on `.restoring` to show a neutral splash rather than flashing the sign-in form for a frame.
  - `CabalmailKit` test additions: 6 `EnvelopeCacheTests` (remove-drops-UIDs, remove-no-op-for-unknown, remove-no-op-without-snapshot, replace-prunes-missing-UIDs-inside-range, replace-with-nil-range-replaces-everything, replace-clears-old-on-UIDValidity-mismatch). Total `CabalmailKit` tests: 88 (was 82). The AppState restore branching is covered indirectly by the existing `AuthServiceTests` pins of `currentIdToken()` refresh success, `NotAuthorizedException` → `invalidCredentials`, and `signIn` keychain persistence.

### Changed

- **Let's Encrypt production CA in every environment.** `lambda/certbot-renewal/handler.py` no longer branches on `USE_STAGING`, and the `certbot_renewal` Terraform module drops its `prod` input variable. Staging certs (previously used for non-prod environments) aren't trusted by iOS/macOS root stores, so an Apple client hitting `smtp-out.<control_domain>` on port 465 (TCP passthrough, Dovecot presents the Let's Encrypt cert directly) couldn't complete the implicit-TLS handshake. The certbot Lambda re-issues against production on its next run; force a manual invocation after deploy if you want the swap immediately rather than on the scheduled renewal.
- **Certbot Lambda `image_uri` rotates per deploy.** The module had `image_uri = "${repo_url}:latest"` hardcoded, which Terraform treats as a string that never changes — the Lambda kept running whichever image had been pushed the first time it was created, even when CI pushed a new `:latest` tag. The module now takes an `image_tag` input wired from `/cabal/deployed_image_tag` (the same SSM parameter the ECS task definitions consume), so the Lambda's image reference rotates on every deploy.

## [0.5.0] - 2026-04-20

### Known Issues

- Forgot Password and Verify Phone were delivered untested due to delays in provisioning an SMS number in AWS

### Added

- **Admin dashboard with user management (Phase 1 of `docs/0.5.0/user-management-plan.md`):**
  - Cognito admin group (`aws_cognito_user_group "admin"`) with master user placed in it via `aws_cognito_user_in_group`
  - 5 new admin-only Lambda functions: `list_users`, `confirm_user`, `disable_user`, `enable_user`, `delete_user`
  - Lambda IAM policy extended with Cognito permissions (`ListUsers`, `AdminConfirmSignUp`, `AdminDisableUser`, `AdminEnableUser`, `AdminDeleteUser`) scoped to the user pool ARN
  - `USER_POOL_ID` env var added to all Lambda functions
  - `ApiClient` methods: `listUsers`, `confirmUser`, `disableUser`, `enableUser`, `deleteUser`
  - React `Users` tab — lists pending and confirmed users with Confirm/Disable/Enable/Delete actions; visible only to members of the admin group (detected via the `cognito:groups` JWT claim)
  - React `Dmarc` tab placeholder (wired into routing for Phase 3)
  - Admin-gated nav visibility via `is-admin` CSS class
  - Self-deletion guard in `delete_user`
  - Master system account filtered from the Users view so it cannot be modified
- **DMARC report ingestion and display (Phase 3 of `docs/0.5.0/user-management-plan.md`):**
  - `dmarc` system Cognito user (osid=9998) with a dedicated mailbox, address `dmarc-reports@mail-admin.<first-mail-domain>` created in `cabal-addresses`, and DNS records for the `mail-admin` subdomain (MX/SPF/DKIM/DMARC CNAMEs)
  - Global DMARC DNS record updated to use the configured mail domain instead of a hardcoded value
  - DynamoDB table `cabal-dmarc-reports` (composite key: `header_from#date_end` / `source_ip#report_id`, PITR, server-side encryption)
  - `process_dmarc` Lambda (Python 3.13, arm64, 512MB, 120s) — authenticates to IMAP via the master-user pattern (`dmarc*admin`), fetches the `dmarc` inbox, parses zip/gzip/raw XML DMARC aggregate reports (RFC 7489), writes records to DynamoDB in batches, then moves processed messages to `INBOX.Processed`
  - Handles RFC 2047 encoded-word attachment filenames and `application/octet-stream` attachments from mail clients that don't set specific MIME types
  - EventBridge Scheduler triggers `process_dmarc` every 6 hours with a flexible 30-minute window
  - `list_dmarc_reports` admin-only Lambda — paginated DynamoDB scan with base64-encoded `next_token`
  - `ApiClient.listDmarcReports(nextToken)` method
  - React `Dmarc` tab — full implementation with org/domain/source IP/count/disposition/DKIM/SPF columns, color-coded pass/fail badges, refresh button, and "Load more" pagination
  - `dmarc` system user filtered from the Users admin view (same pattern as `master`)
- Mobile hamburger menu — below 959px (covers portrait and landscape phones) the nav tabs collapse into a hamburger dropdown so admin tabs like DMARC stay reachable on narrow screens
- **Multi-user address management (Phase 4 of `docs/0.5.0/user-management-plan.md`):**
  - Surfaces the latent multi-user delivery already supported by `docker/shared/generate-config.sh` (slash-separated `user` field expanded via `/etc/aliases.dynamic`)
  - 4 new admin-only Lambda functions: `assign_address` (PUT), `unassign_address` (PUT), `new_address_admin` (POST), `list_addresses_admin` (GET)
  - Cognito `AdminGetUser` added to the shared Lambda IAM policy so admin endpoints can validate that target users exist before writing
  - `assign_address`/`unassign_address`/`new_address_admin` all publish to the existing address-change SNS topic to trigger container reconfiguration, matching the `new`/`revoke` pattern
  - `unassign_address` refuses to remove the last user from an address (use `revoke` to delete instead)
  - `ApiClient` methods: `listAllAddresses`, `assignAddress`, `unassignAddress`, `newAddressAdmin`
  - Admin-only "All Addresses" tab in the Addresses view (`Addresses/Admin.jsx`) — filter/search, New Address form with multi-user assignment checkboxes, per-row chips showing assigned users with inline × removal, and a "+ User" picker to assign additional users
  - Confirmed users in the Users tab now display their assigned addresses as chips, with inline × removal on shared addresses and a "+ Address" picker to assign existing addresses to a user
  - Hover/tap on a shared-address chip in the Users tab highlights identical chips under other users (tap toggles a sticky highlight on touch devices)
  - `master` and `dmarc` system users excluded from the admin Assign-to picker

### Fixed

- `SignUp` form inputs were uncontrolled — App.jsx now passes `username`, `password`, and `phone` props so typing is reflected in the SignUp form instead of leaking into Login's shared state
- Stale per-user cache after logout — `ADDRESS_LIST`, `FOLDER_LIST`, and `INBOX` localStorage keys are now cleared in `doLogout`, preventing the next user from seeing the previous user's folders and addresses
- DMARC report list couldn't be scrolled when long because `Email.css` globally sets `body` to `position: absolute; overflow: hidden`; scoped `overflow: auto` and `max-height` to `div.App div.Dmarc` so it scrolls independently
- Nav dropdown was hidden on the Email tab because `div.email_list` has `z-index: 99999`; raised the nav's `z-index` to `100000` so the hamburger menu stays above view-level overlays
- `lambda/api/list` filter was an exact match on the `user` field, so callers who were one of several users on a multi-user address lost it from their "My Addresses" view — switched to a `contains()` DynamoDB scan filter plus a Python slash-split membership check (avoids false positives like `chris` matching `christopher`)
- API Gateway was caching `/list` for 60 seconds, serving stale results after admin-side address assignment changes — disabled the Gateway cache on `/list`
- Client-side `ADDRESS_LIST` localStorage cache not invalidated by admin address-mutation endpoints — `assignAddress`, `unassignAddress`, and `newAddressAdmin` now bust it

## [0.4.1] - 2026-04-13

### Added

- Terraform module `terraform/infra/modules/certbot_renewal/` — container-image Lambda on EventBridge schedule (every 60 days) that runs certbot with `certbot-dns-route53`, writes certs to SSM, and forces ECS redeployments, replacing the ACME Terraform provider
- `lambda/certbot-renewal/` — Dockerfile and Python handler for the certbot renewal Lambda (arm64)
- React contexts: `AuthContext` and `AppMessageContext` to replace prop drilling for auth state and toast notifications
- React hook: `useApi` — centralizes `ApiClient` instantiation using auth context
- `ErrorBoundary` component wrapping Email, Addresses, and Folders views with fallback UI
- Code splitting with `React.lazy` + `Suspense` for Email, Folders, and Addresses views
- Dual Rich Text / Markdown editing modes in the compose editor
- Unit tests for React components (`AppMessage`, `Nav`, `Login`, `SignUp`, `ComposeOverlay`, `MessageOverlay`, `Envelopes`, `Messages`, `ErrorBoundary`)
- Vitest + jsdom test runner for React app
- ENI trunking for ECS (`awsvpcTrunking` account setting, `ECS_ENABLE_TASK_ENI` agent config, managed policy attachment) to support `awsvpc` tasks on Graviton instances
- IMDSv2 hop limit increased to 2 on ECS launch template for container metadata access
- Documentation: `docs/0.4.1/react-modernization-plan.md`, `docs/unreleased/sendmail-replacement.md`

### Fixed

- NAT instance iptables rules lost on reboot — replaced nested heredoc (which created an empty systemd unit file) with `printf`-based generation
- Sendmail crash loop on `smtp-out` caused by orphan daemon holding port 25 — added `sendmail-wrapper.sh` with PID file cleanup and supervisord retry configuration
- `this.stage` typo in `MessageOverlay/index.js`
- Nav layout: scoped absolute positioning to logout button only
- Race condition in `Envelopes` where multiple async `getEnvelopes` calls could overwrite pagination state
- Sequential `setState` calls in `MessageOverlay` that could overwrite each other
- Memory leak risk from timers in `Messages` — consolidated 5 timer IDs into properly cleaned-up effects
- JWT token security: moved from `localStorage` to module-level memory variable (no longer persisted to disk)
- `App.jsx` `setState` override no longer serializes password to `localStorage`
- `App.jsx` message toast timer leak — stale `setTimeout` could fire after unmount; now tracked in a ref and cleared properly
- Compose toolbar button alignment and formatting issues

### Changed

- **ECS architecture migrated from x86_64 to ARM64 (Graviton)** — AMI filter changed from `amzn2-ami-ecs-hvm` (x86_64) to `al2023-ami-ecs-hvm` (arm64); instance type changed from T3/T4g to M6g
- **React upgraded from 17 to 18** — `ReactDOM.render` replaced with `createRoot`, Strict Mode enabled
- **React build tooling migrated from Create React App to Vite** — new `vite.config.js`, `index.html` moved to root, scripts updated to `vite`/`vitest`, output directory changed from `build/` to `dist/`
- **All React components converted from class-based to functional** with hooks (`useState`, `useEffect`, `useRef`, `useContext`, `useCallback`)
- **Compose editor replaced**: draft-js (abandoned) replaced with TipTap — native HTML support, toolbar with formatting/lists/alignment/color/links, heading levels 1-4, rich text paste preservation
- CSS Modules migration — `AppMessage.css`, `Login.css`, `SignUp.css`, `Folders.css` renamed to `.module.css` with scoped `styles.className` imports
- React CI workflow (`.github/workflows/react.yml`) — switched from `yarn` to `npm`, updated build commands and artifact paths for Vite
- Docker CI workflow (`.github/workflows/docker.yml`) — added `certbot-renewal` to build matrix, uses native arm64 runner, pushes `:latest` tag for certbot image
- `App.jsx` converted from class to functional component — uses hooks, functional state updates, separated transient UI state (message/error/hideMessage) from persisted app state
- All React `.js` component files renamed to `.jsx`
- Cloud Map namespace renamed from `cabal.local` to `cabal.internal`
- `docs/0.4.1/user-management-plan.md` moved to `docs/0.5.0/` (deferred to next release)

### Removed

- **Chef/EC2 infrastructure decommissioned (Phase 7 cutover complete):**
  - `chef/` directory — entire Chef cookbook (recipes, templates, libraries, resources)
  - `.github/workflows/cookbook.yml` — cookbook build and S3 upload workflow
  - `terraform/infra/modules/asg/` — Auto Scaling Group module (launch templates, IAM instance profiles, security groups, userdata)
  - `cabal_chef_document` SSM document and its output/variable plumbing (`modules/app/ssm.tf`, `modules/user_pool/variables.tf`)
  - `lambda/counter/node/` — legacy Node.js counter Lambda that invoked Chef via SSM (replaced by Python version in 0.4.0)
  - Instance-type NLB target groups and conditional listener routing in `modules/elb/` — listeners now forward directly to ECS target groups
  - `chef_license`, `imap_scale`, `smtpin_scale`, `smtpout_scale` variables and their CI/CD tfvars wiring
- `terraform/infra/modules/cert/acme.tf` — ACME/Let's Encrypt Terraform provider approach (replaced by certbot Lambda)
- `acme` and `tls` provider requirements from `terraform/infra/modules/cert/versions.tf`
- `prod` and `email` variables from cert module (only used by ACME)
- `draft-js`, `react-draft-wysiwyg`, `draftjs-to-html`, `html-to-draftjs`, `markdown-draft-js` — 5 packages replaced by TipTap
- `yarn.lock` (switched to npm/`package-lock.json`)
- `.github/scripts/react-documentation.sh` and `react-docgen`-generated docs (`react/admin/docs/`)
- Unused React dependencies: `react-lazyload`, `react-docgen`
- `greet_pause` from `smtp-out` sendmail template

## [0.4.0] - 2026-03-15

### Added

- Documentation `docs/0.4.0/containerization-plan.md` — detailed migration plan documenting the containerization strategy
- Terraform module `terraform/infra/modules/ecs/` — ECS cluster with three services (IMAP, SMTP-IN, SMTP-OUT), task definitions, auto-scaling, capacity provider, Cloud Map service discovery, and all associated IAM roles
- Terraform module `terraform/infra/modules/ecr/` — container image repositories for the three mail services
- Docker images and scripts — three Dockerfiles (`imap`, `smtp-in`, `smtp-out`), shared entrypoint/reconfiguration/user-sync scripts, supervisord configs, Dovecot/sendmail/OpenDKIM configs, PAM auth integration, and sendmail `.mc` templates
- SNS/SQS fan-out for notifying containers of address changes (replacing SSM `SendCommand`)
- `address_changed_topic_arn` to all API Lambda functions
- `sns:Publish` IAM permissions to Lambda execution roles
- `nlb_arn` output
- `terraform/infra/modules/vpc/ROLLBACK.md`** — NAT instance migration rollback instructions
- DNS module — `locals.tf` with CI/CD build workflow metadata
- Workflow: `docker_build_push.yml` for building and pushing Docker images
- Terraform workflow: `image_tag` input and SSM update step for Docker image deployments
- Counter workflow: pylint step for Python linting

### Fixed

- `assign_osid` Lambda: removed SSM permissions, added `ecs:UpdateService` permission to trigger redeployments
- Minor whitespace formatting change in `dovecot-15-mailboxes.conf` (no behavioral impact)

### Changed

- Three API functions and the Cognito post-confirmation trigger were rewritten from Node.js to Python:
    - **`list`** — rewritten from `lambda/api/node/list/index.js` to Python
    - **`new`** — rewritten from `lambda/api/node/new/index.js` to Python
    - **`revoke`** — rewritten from `lambda/api/node/revoke/index.js` to Python, now includes proper authorization checks (`user_authorized_for_sender`) and shared-subdomain safety checks
    - **`assign_osid`** (counter) — rewritten from Node.js to Python, now triggers ECS redeployments instead of Chef via SSM
    - **Added `lambda/api/new_address/function.py`** — new function with DKIM key generation
- Directory restructuring: Python Lambda functions moved from `lambda/api/python/` to `lambda/api/` (cleaner layout now that Node.js versions are removed).
- Python Lambda layer runtime upgraded from `python3.9` to `python3.13`
- Removed Node.js Lambda layer (no longer needed)
- Lambda functions no longer carry a `type` field — all are Python with a unified layer and handler
- Added S3 pre-flight checks that gate layer/function creation on zip existence
- SSM Parameter Store replaced with remote state — the `infra` stack now reads zone data via `terraform_remote_state` from the `dns` stack instead of SSM parameters (`/cabal/control_domain_zone_id`, `/cabal/control_domain_zone_name`)
- All four NLB listeners (IMAP/143, relay/25, submission/465, STARTTLS/587) now include ECS cutover conditionals, allowing gradual traffic migration from ASG to ECS target groups
- Added private DNS records for Cloud Map service discovery
- S3 bucket hardening — explicit `acl = "private"` on cache and React app buckets
- Backup vault — `prevent_destroy` changed from `true` to `false` (flexibility during active development)
- Counter build script: converted from Node.js npm to Python pip packaging
- React workflow: upgraded `actions/upload-artifact` and `actions/download-artifact` from v3 to v4

### Removed

- `ssm:SendCommand` and `ssm:StartSession` permissions (no longer targeting EC2 directly)
- `lambda_api_node.yml` and `build-api-node.sh` (Node.js Lambda no longer needed)
- `build-api-python.sh` → `build-api.sh` (Python is now the sole Lambda runtime)

### Deprecated

- Chef will be removed in 0.4.1
- ACME/Let's Encrypt certificate will be removed in 0.4.1
