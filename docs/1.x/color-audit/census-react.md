# Colour census — React admin web client (+ browser extension)

Scope: `react/admin/src` (CSS/JS/JSX), `react/admin/index.html`, `react/admin/public` (manifest/favicon), `extensions/shared/src`, `extensions/chrome/src`. Tests and node_modules excluded. All paths relative to the repo root. Theme direction is always `stately` (`useTheme.js:4`); light/dark is chosen solely by `prefers-color-scheme` (`useTheme.js:46-47`) — there is no in-app light/dark toggle. Accent default is `forest`, options `ink, oxblood, forest, azure, amber, plum` (`useTheme.js:7-15`).

Chroma convention below: "neutral" = oklch chroma <= 0.015 or untinted hex; "tinted" = 0.003-0.008 warm tint on surfaces (hue 60-85).

## 1. Tokens

Semantic / chromatic custom properties. "used by" = count of `var(--token` references in `react/admin/src` (excluding the defining theme files' own `var()` chains).

| token | light value | dark value | defined at (file:line) | meaning | used by |
|---|---|---|---|---|---|
| `--ink-danger` | `oklch(0.5 0.15 25)` | `oklch(0.75 0.14 25)` | `react/admin/src/AppLight.css:17` / `react/admin/src/AppDark.css:18` | danger/destructive, error-state, auth-bad, important (single red serves all four) | 21 |
| `--accent` [data-accent=ink] | `oklch(0.25 0.03 250)` | `oklch(0.78 0.04 250)` | `AppLight.css:34` / `AppDark.css:35` | accent (user-selectable) | 99 (all accents share the one var) |
| `--accent` [data-accent=oxblood] | `oklch(0.42 0.12 25)` | `oklch(0.72 0.13 25)` | `AppLight.css:35` / `AppDark.css:36` | accent | (same) |
| `--accent` [data-accent=forest] (DEFAULT) | `oklch(0.45 0.09 150)` | `oklch(0.75 0.11 150)` | `AppLight.css:36` / `AppDark.css:37` | accent | (same) |
| `--accent` [data-accent=azure] | `oklch(0.52 0.12 250)` | `oklch(0.78 0.12 250)` | `AppLight.css:37` / `AppDark.css:38` | accent | (same) |
| `--accent` [data-accent=amber] | `oklch(0.55 0.13 70)` | `oklch(0.82 0.13 70)` | `AppLight.css:38` / `AppDark.css:39` | accent | (same) |
| `--accent` [data-accent=plum] | `oklch(0.45 0.12 330)` | `oklch(0.78 0.12 330)` | `AppLight.css:39` / `AppDark.css:40` | accent | (same) |
| `--accent-fg` | `oklch(0.99 0.003 60)` | `oklch(0.15 0.008 60)` | `AppLight.css:18` / `AppDark.css:19` | on-fill text/glyph for anything filled with `--accent` (also reused on `--ink-danger` fills) | 25 |
| `--accent-ink` | `var(--ink)` | `var(--ink)` | `AppLight.css:19` / `AppDark.css:20` | text on `--accent-soft` washes (avatars) | 2 |
| `--accent-soft` | `color-mix(in oklch, var(--accent) 10%, transparent)` | `color-mix(in oklch, var(--accent) 15%, transparent)` | `AppLight.css:20` / `AppDark.css:21` | accent wash: selected tabs, focus rings, avatars, match highlight | 15 |
| `--auth-ok` (local to `.reader-auth`) | `oklch(0.45 0.09 150)` | `oklch(0.75 0.11 150)` | `react/admin/src/Email/MessageOverlay/MessageOverlay.css:610` / `:617` | success (SPF/DKIM/DMARC pass chip); hard-copies the forest accent values, NOT `var(--accent)` | 1 (`:647`) |
| `--auth-chip` (local to `.reader-auth-chip`) | `var(--ink-quiet)` default; `var(--auth-ok)` on `--ok`; `var(--ink-danger)` on `--bad` | same | `MessageOverlay.css:634`, `:647`, `:648` | auth verdict chip colour (neutral / success / auth-bad) | 2 (`:640`, `:641`) |
| `--accent-softer` | UNDEFINED — fallback `#fff8e1` | UNDEFINED — fallback `#fff8e1` | referenced only at `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:591` | warning wash (attachment-size warning); pale yellow fixed in both themes | 1 |
| `--danger` | UNDEFINED — fallback `#b00020` | UNDEFINED — fallback `#b00020` | referenced only at `react/admin/src/Security/Security.css:37` | danger text (Security page button); not `--ink-danger` | 1 |
| `ADDRESS_SWATCHES[0]` (JS; comment name `--accent-1`) | `oklch(0.52 0.12 250)` (= azure light) | same (no dark variant) | `react/admin/src/utils/addressSwatch.js:14` | address-swatch (user-data hash) | via `swatchFor` x2 |
| `ADDRESS_SWATCHES[1]` (`--accent-2`) | `oklch(0.55 0.13 70)` (= amber light) | same | `addressSwatch.js:15` | address-swatch | (same) |
| `ADDRESS_SWATCHES[2]` (`--accent-3`) | `oklch(0.45 0.09 150)` (= forest light) | same | `addressSwatch.js:16` | address-swatch | (same) |
| `ADDRESS_SWATCHES[3]` (`--accent-4`) | `oklch(0.45 0.12 330)` (= plum light) | same | `addressSwatch.js:17` | address-swatch | (same) |

Tokens that do NOT exist (checked): no `--success`, `--warning`, `--info`, `--unread`, `--selected`, `--link`, `--accent-1..4` CSS vars. Unread/selected/flagged/link all resolve to `--accent`; success is either `--accent` (auth success icon) or hard-coded greens; warning is hard-coded ambers. `Dmarc.css:129-133` comment explicitly notes "there are no semantic success/warning tokens".

Neutral fallback-only tokens (out of scope, listed for completeness): `--text-secondary` (fallback `#666`, `Security.css:14`), `--border-color` (fallback `#ddd`, `Security.css:18`) — both undefined.

## 2. Surfaces

### 2a. Theme surface tokens (tinted neutrals semantic colours are drawn on)

| token/selector | light value | dark value | file:line | what it is the background of |
|---|---|---|---|---|
| `--bg` | `oklch(0.975 0.008 85)` | `oklch(0.17 0.006 60)` | `AppLight.css:7` / `AppDark.css:8` | `body` (`App.css:26`), auth pages (`AuthShell.css:13`), folder rail + address rail (`Email/Email.css:25,39,87`); page views (About, Dmarc, Users, Security, Caa) inherit it |
| `--reader-bg` | `oklch(0.995 0.003 85)` | `oklch(0.2 0.007 60)` | `AppLight.css:8` / `AppDark.css:9` | reader pane (`MessageOverlay.css:13`), source-view body (`:454`, `Dmarc.css:259`), compose editor/plain textarea (`ComposeOverlay.css:375,433`), From-picker menu (`FromPicker.css:111`) |
| `--pane-bg` | `oklch(0.99 0.004 85)` | `oklch(0.19 0.008 60)` | `AppLight.css:9` / `AppDark.css:10` | message list + envelope rows (`Messages.css:10,22`, `Envelopes.css:11,21`), reader header/action bar (`MessageOverlay.css:45,85,332`), search input (`Search.css:176`), DNS modal header + actual-record box (`Dmarc.css:168,356`), sheet/tab bar (`Email.css:159`) |
| `--surface` | `oklch(0.985 0.005 85)` | `oklch(0.22 0.008 60)` | `AppLight.css:10` / `AppDark.css:11` | nav bar (`Nav.css:18`), menus/popovers (`Nav.css:265,324`, `Messages.css:311`, `MessageOverlay.css:167,191`, `Addresses.css:191`), modals (`ConfirmDialog.module.css:14`, `Addresses.css:306`, `KeyboardHelp.css:23`, `Dmarc.css:151`, `MessageOverlay.css:314`), compose window (`ComposeOverlay.css:32`), inputs (`AuthShell.css:182`, `Request.css:71`, `Admin.css:85`), 51 refs total |
| `--surface-hover` | `oklch(0.955 0.008 85)` | `oklch(0.26 0.009 60)` | `AppLight.css:11` / `AppDark.css:12` | hover state of rows/buttons/menu items; compose header + footer (`ComposeOverlay.css:73,452`), kbd chips, skeleton shimmer; 73 refs |
| `--border` | `oklch(0.9 0.007 85)` | `oklch(0.3 0.01 60)` | `AppLight.css:12` / `AppDark.css:13` | primary hairlines (nav bottom, pane dividers, input borders); 64 refs |
| `--border-faint` | `oklch(0.94 0.005 85)` | `oklch(0.25 0.009 60)` | `AppLight.css:13` / `AppDark.css:14` | row separators (`Envelopes.css:17`), menu separators (`Nav.css:388`), section rules; 32 refs |

### 2b. Text neutrals (contrast reference for what semantic colours sit beside)

| token/selector | light value | dark value | file:line | what it is |
|---|---|---|---|---|
| `--ink` | `oklch(0.22 0.015 60)` | `oklch(0.94 0.005 80)` | `AppLight.css:14` / `AppDark.css:15` | primary text; 148 refs; also mixed into scrims (`color-mix(var(--ink) 35-40%)`) and hover washes (8-10%) |
| `--ink-soft` | `oklch(0.36 0.012 60)` | `oklch(0.8 0.006 80)` | `AppLight.css:15` / `AppDark.css:16` | secondary text / idle icon buttons; 61 refs |
| `--ink-quiet` | `oklch(0.55 0.01 60)` | `oklch(0.6 0.008 60)` | `AppLight.css:16` / `AppDark.css:17` | tertiary text, placeholders, neutral auth chip (`--auth-chip` default); 120 refs |

### 2c. Fixed (theme-independent) canvases

| token/selector | light value | dark value | file:line | what it is the background of |
|---|---|---|---|---|
| `.reader-body iframe` | `#ffffff` (+ `color-scheme: normal`) | `#ffffff` | `react/admin/src/Email/MessageOverlay/MessageOverlay.css:693-694` | HTML-email iframe backdrop, deliberately white in both themes |
| iframe injected `html, body` | `background: #ffffff; color: #111111` | same | `react/admin/src/Email/MessageOverlay/ReaderBody.jsx:26` | default canvas inside the sandboxed HTML email (no `!important`; sender CSS wins) |
| `.security__qr` | `#fff` | `#fff` | `react/admin/src/Security/Security.css:69` | white tile behind TOTP QR code |
| `.mfa-setup__qr` | `#fff` | `#fff` | `react/admin/src/MfaSetup/MfaSetup.css:6` | white tile behind locked-out TOTP QR code |
| `.compose-attachment-warning` | `#fff8e1` (via undefined `--accent-softer`) | `#fff8e1` | `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:591` | pale-yellow warning strip (text is `var(--ink)` — light text on pale yellow in dark mode) |
| `manifest.json background_color` | `#F4EBD6` (cream) | n/a | `react/admin/public/manifest.json:24` | PWA splash background |
| `favicon.svg` gradient `#bg` | `#FAF4E4` -> `#EFE2C0` | n/a | `react/admin/public/favicon.svg:6-7,10` | icon tile behind the brand glyph |

### 2d. Legacy `prefers-color-scheme` surfaces (still loaded; overridden for `body` by `App.css:25-27`; `.inverted`, `.forced`, `.highlight` have zero JSX references; `.default` used once at `ErrorBoundary.jsx:27`; bare `.active` used 24x in JSX but component rules out-specify or `!important`-override it — `Messages.css:117-119`, `MessageOverlay.css:401-406`)

| token/selector | light value | dark value | file:line | what it is the background of |
|---|---|---|---|---|
| `body, a, button, select, label, form` | `color #222` / `bg #eee` | `color #aaa` / `bg #111` | `AppLight.css:44-47` / `AppDark.css:46-49` | legacy document + control defaults (neutral) |
| `input, select, option, textarea, ul.recipient-list, .wysiwyg-editor ...` | `color #000` / `bg #fff` | `color #ccc` / `bg #000` | `AppLight.css:51-58` / `AppDark.css:53-60` | legacy form controls (neutral) |
| `button` | `color #333` / `bg #ddd` | `color #ccc` / `bg #111` | `AppLight.css:59-62` / `AppDark.css:61-64` | legacy buttons (neutral) |
| `*` | `border-color #999` | `border-color #333` | `AppLight.css:48-50` / `AppDark.css:50-52` | legacy universal border (neutral) |
| `body.inverted, .inverted a/button/select/div` | `color #aaa` / `bg #111` / `border #333` | `color #222` / `bg #ffe` / `border #999` | `AppLight.css:83-88` / `AppDark.css:84-89` | unused; dark value `#ffe` is a tinted cream |
| `input.inverted, .inverted input/select/option` | `color #ccc` / `bg #000` | `color #000` / `bg #ffd` | `AppLight.css:89-93` / `AppDark.css:90-94` | unused; `#ffd` tinted cream |
| `button.inverted, .inverted button` | `color #ccc` / `bg #111` | `color #333` / `bg #ddd` | `AppLight.css:94-97` / `AppDark.css:95-98` | unused (neutral) |

### 2e. Scrims and shadows (achromatic alpha blacks; listed so nothing is skipped)

| token/selector | light value | dark value | file:line | what it is the background of |
|---|---|---|---|---|
| `--shadow-menu` | `oklch(0.2 0.02 60 / .15)`, `/ .08` | `oklch(0 0 0 / .45)`, `/ .25` | `AppLight.css:22-24` / `AppDark.css:23-25` | menu drop shadow (7 refs) |
| `--shadow-modal` | `oklch(0.2 0.02 60 / .25)`, `/ .12` | `oklch(0 0 0 / .6)`, `/ .3` | `AppLight.css:25-27` / `AppDark.css:26-28` | modal shadow (5 refs; `KeyboardHelp.css:26` fallback `rgba(0,0,0,0.25)`) |
| `--shadow-compose` | `oklch(0.2 0.02 60 / .3)`, `/ .15` | `oklch(0 0 0 / .65)`, `/ .3` | `AppLight.css:28-30` / `AppDark.css:29-31` | compose window shadow (1 ref) |
| `.email__scrim` | `oklch(0 0 0 / 0.35)` | same | `react/admin/src/Email/Email.css:64` | phone drawer scrim (fixed) |
| `.email__rail--drawer`, `.email__addr-rail--drawer` | `box-shadow oklch(0 0 0 / 0.25)` | same | `Email.css:54`, `:102` | drawer shadows (fixed) |
| `.source-scrim` | `oklch(0 0 0 / 0.45)` | same | `MessageOverlay.css:299`, `Dmarc.css:142` | view-source / DNS modal scrim (fixed) |
| `.reader[data-layout="sheet"] .reader-tabbar` | `color-mix(var(--surface) 80%, transparent)` + `box-shadow oklch(0 0 0 / 0.18)` | theme-var | `MessageOverlay.css:817,822` | floating reader tab bar |
| `.scrim` (ConfirmDialog), `.addresses-rail__modal-scrim`, `.kbd-help__scrim` | `color-mix(in oklch, var(--ink) 40%/40%/35%, transparent)` | theme-var (ink flips, so scrim is dark-on-light / light-on-dark) | `ConfirmDialog.module.css:4`, `Addresses.css:296`, `KeyboardHelp.css:10` | modal scrims |
| `.appMessage` | `box-shadow oklch(0 0 0 / 0.2)` | same | `AppMessage.module.css:16` | toast shadow (fixed) |
| `label input[type=radio] ~ .radio-button:after` | `rgba(0,0,0,0)` / checked `currentcolor` | same | `App.css:102,106` | custom radio dot |

## 3. Direct uses

Roles: text-fg, glyph-fg, fill, on-fill, wash, border/stroke, control-tint, shadow, user-data, brand. Appearance: `theme-var` (varies per theme through a custom property), `fixed`, `prefers-color-scheme` (literal with an explicit dark override).

### 3a. React admin — CSS

| file:line | expression | role | meaning | drawn on | appearance handling |
|---|---|---|---|---|---|
| `react/admin/src/About/About.css:38` | `.about__subtitle a { color: var(--accent) }` | text-fg | link | `--bg` | theme-var |
| `react/admin/src/About/About.css:52` | `.about__back a { color: var(--accent) }` | text-fg | link | `--bg` | theme-var |
| `react/admin/src/About/About.css:83` | `.about__section p a { color: var(--accent) }` | text-fg | link | `--surface` | theme-var |
| `react/admin/src/Addresses/Addresses.css:91` | `.addresses-rail__search-input:focus { border-color: var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Addresses/Addresses.css:148` | `.addresses-rail__row-action.is-on { color: var(--accent) }` | glyph-fg | selected (favourite star on) | `--bg` | theme-var |
| `react/admin/src/Addresses/Addresses.css:261` | `.addresses-rail__row-action:hover { color: var(--ink-danger, var(--ink)) }` | glyph-fg | danger/destructive (hover on revoke) | `--surface` | theme-var |
| `react/admin/src/Addresses/Admin.css:92` | `.admin-addresses__filter:focus { border-color: var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Addresses/Admin.css:191` | `.admin-addresses__chip-remove:hover { color: var(--ink-danger) }` | glyph-fg | danger/destructive | `--surface` | theme-var |
| `react/admin/src/Addresses/Admin.css:212` | `.admin-addresses__add-user:hover { border-color: var(--accent) }` | border/stroke | accent (hover) | `--bg` | theme-var |
| `react/admin/src/Addresses/Admin.css:252` | `.admin-addresses__revoke { color: var(--ink-danger) }` | text-fg | danger/destructive | `--bg` | theme-var |
| `react/admin/src/Addresses/Request.css:92` | `.request__input:hover, .request__select:hover { border-color: color-mix(in oklch, var(--accent) 40%, var(--border)) }` | border/stroke | accent (hover) | `--surface` | theme-var |
| `react/admin/src/Addresses/Request.css:97` | `.request__input:focus, .request__select:focus { border-color: var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Addresses/Request.css:99` | `... :focus { box-shadow: 0 0 0 2px color-mix(in oklch, var(--accent) 25%, transparent) }` | border/stroke (focus ring) | accent | `--surface` | theme-var |
| `react/admin/src/Addresses/Request.css:144` | `.request__submit { background: var(--accent) }` | fill | accent (primary action) | `--bg` | theme-var |
| `react/admin/src/Addresses/Request.css:145` | `.request__submit { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Addresses/Request.css:153` | `.request__submit:focus-visible { outline: 2px solid var(--accent) }` | border/stroke | accent (focus) | `--bg` | theme-var |
| `react/admin/src/Addresses/Request.css:167` | `.request__secondary:hover { border-color: color-mix(in oklch, var(--accent) 40%, var(--border)) }` | border/stroke | accent (hover) | `--surface-hover` | theme-var |
| `react/admin/src/Addresses/Request.css:171` | `.request__secondary:focus-visible { outline: 2px solid var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/App.css:110` | `input.invalid select.invalid { border-color: #f00 }` | border/stroke | error-state | legacy input `#fff`/`#000` | fixed (selector is a typo — descendant `select` inside `input` — and no JSX applies `.invalid`; dead) |
| `react/admin/src/App.css:111` | `input.invalid select.invalid { box-shadow: inset 0 0 0.5em #f00 }` | shadow | error-state | (same) | fixed (dead) |
| `react/admin/src/AppMessage/AppMessage.module.css:35` | `.error { background-color: var(--ink-danger, oklch(0.48 0.17 25)) }` | fill | error-state (toast) | `--bg` (fixed bottom) | theme-var |
| `react/admin/src/AppMessage/AppMessage.module.css:36` | `.error { color: oklch(0.99 0.003 60) }` | on-fill | error-state | `--ink-danger` | fixed (near-white; dark-mode `--ink-danger` is L 0.75 so contrast drops) |
| `react/admin/src/AppMessage/AppMessage.module.css:37` | `.error { border: 1px solid color-mix(in oklch, var(--ink-danger, oklch(0.48 0.17 25)) 70%, black) }` | border/stroke | error-state | `--bg` | theme-var |
| `react/admin/src/AppMessage/AppMessage.module.css:42` | `.info { background-color: var(--accent) }` | fill | info (toast) | `--bg` | theme-var |
| `react/admin/src/AppMessage/AppMessage.module.css:43` | `.info { color: var(--accent-fg) }` | on-fill | info | `--accent` | theme-var |
| `react/admin/src/AppMessage/AppMessage.module.css:44` | `.info { border: 1px solid color-mix(in oklch, var(--accent) 70%, black) }` | border/stroke | info | `--bg` | theme-var |
| `react/admin/src/ConfirmDialog/ConfirmDialog.module.css:92` | `.confirm { background: var(--accent) }` | fill | accent (confirm action) | `--surface` | theme-var |
| `react/admin/src/ConfirmDialog/ConfirmDialog.module.css:93` | `.confirm { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/ConfirmDialog/ConfirmDialog.module.css:94` | `.confirm { border-color: color-mix(in oklch, var(--accent) 70%, black) }` | border/stroke | accent | `--surface` | theme-var |
| `react/admin/src/ConfirmDialog/ConfirmDialog.module.css:98` | `.confirm:hover { background: color-mix(in oklch, var(--accent) 88%, black) }` | fill | accent (hover) | `--surface` | theme-var |
| `react/admin/src/ConfirmDialog/ConfirmDialog.module.css:102` | `.confirmDestructive { background: var(--ink-danger, oklch(0.48 0.17 25)) }` | fill | danger/destructive | `--surface` | theme-var |
| `react/admin/src/ConfirmDialog/ConfirmDialog.module.css:103` | `.confirmDestructive { color: oklch(0.99 0.003 60) }` | on-fill | danger/destructive | `--ink-danger` | fixed |
| `react/admin/src/ConfirmDialog/ConfirmDialog.module.css:104` | `.confirmDestructive { border-color: color-mix(in oklch, var(--ink-danger, oklch(0.48 0.17 25)) 70%, black) }` | border/stroke | danger/destructive | `--surface` | theme-var |
| `react/admin/src/ConfirmDialog/ConfirmDialog.module.css:108` | `.confirmDestructive:hover { background: color-mix(in oklch, var(--ink-danger, oklch(0.48 0.17 25)) 88%, black) }` | fill | danger/destructive (hover) | `--surface` | theme-var |
| `react/admin/src/Dmarc/Dmarc.css:86` | `span.result.pass { color: #2e7d32 }` | text-fg | success (DMARC report verdict) | `--bg` | fixed |
| `react/admin/src/Dmarc/Dmarc.css:91` | `span.result.fail { color: #c62828 }` | text-fg | auth-bad (DMARC report verdict) | `--bg` | fixed |
| `react/admin/src/Dmarc/Dmarc.css:106` | `button.result-fail { color: #c62828 }` | text-fg | auth-bad (clickable fail) | `--bg` | fixed |
| `react/admin/src/Dmarc/Dmarc.css:225` | `.source-tool.dns-repair { background: var(--accent) }` | fill | accent (repair action) | `--pane-bg` | theme-var |
| `react/admin/src/Dmarc/Dmarc.css:226` | `.source-tool.dns-repair { border-color: var(--accent) }` | border/stroke | accent | `--pane-bg` | theme-var |
| `react/admin/src/Dmarc/Dmarc.css:227` | `.source-tool.dns-repair { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Dmarc/Dmarc.css:231` | `.source-tool.dns-repair:hover:not(:disabled) { background: color-mix(in oklch, var(--accent) 80%, black) }` | fill | accent (hover) | `--pane-bg` | theme-var |
| `react/admin/src/Dmarc/Dmarc.css:232` | `... { border-color: color-mix(in oklch, var(--accent) 80%, black) }` | border/stroke | accent (hover) | `--pane-bg` | theme-var |
| `react/admin/src/Dmarc/Dmarc.css:233` | `... { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Dmarc/Dmarc.css:300` | `.dns-banner.ok { background: oklch(0.95 0.05 150) }` | wash | success | `--surface` (modal) | prefers-color-scheme (dark `:372`) |
| `react/admin/src/Dmarc/Dmarc.css:301` | `.dns-banner.ok { border: 1px solid oklch(0.78 0.10 150) }` | border/stroke | success | `--surface` | prefers-color-scheme (`:373`) |
| `react/admin/src/Dmarc/Dmarc.css:302` | `.dns-banner.ok { color: oklch(0.32 0.12 150) }` | text-fg | success | its own wash | prefers-color-scheme (`:374`) |
| `react/admin/src/Dmarc/Dmarc.css:306` | `.dns-banner.warn { background: oklch(0.96 0.07 85) }` | wash | warning | `--surface` | prefers-color-scheme (`:377`) |
| `react/admin/src/Dmarc/Dmarc.css:307` | `.dns-banner.warn { border: 1px solid oklch(0.82 0.11 85) }` | border/stroke | warning | `--surface` | prefers-color-scheme (`:378`) |
| `react/admin/src/Dmarc/Dmarc.css:308` | `.dns-banner.warn { color: oklch(0.40 0.10 80) }` | text-fg | warning | its own wash | prefers-color-scheme (`:379`) |
| `react/admin/src/Dmarc/Dmarc.css:312` | `.dns-banner.err { background: oklch(0.94 0.06 25) }` | wash | error-state | `--surface` | prefers-color-scheme (`:382`) |
| `react/admin/src/Dmarc/Dmarc.css:313` | `.dns-banner.err { border: 1px solid oklch(0.78 0.13 25) }` | border/stroke | error-state | `--surface` | prefers-color-scheme (`:383`) |
| `react/admin/src/Dmarc/Dmarc.css:314` | `.dns-banner.err { color: oklch(0.40 0.15 25) }` | text-fg | error-state | its own wash | prefers-color-scheme (`:384`) |
| `react/admin/src/Dmarc/Dmarc.css:372` | `@media dark .dns-banner.ok { background: oklch(0.28 0.06 150) }` | wash | success | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Dmarc/Dmarc.css:373` | `@media dark .dns-banner.ok { border-color: oklch(0.45 0.10 150) }` | border/stroke | success | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Dmarc/Dmarc.css:374` | `@media dark .dns-banner.ok { color: oklch(0.88 0.12 150) }` | text-fg | success | its own wash | prefers-color-scheme |
| `react/admin/src/Dmarc/Dmarc.css:377` | `@media dark .dns-banner.warn { background: oklch(0.28 0.06 85) }` | wash | warning | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Dmarc/Dmarc.css:378` | `@media dark .dns-banner.warn { border-color: oklch(0.45 0.10 85) }` | border/stroke | warning | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Dmarc/Dmarc.css:379` | `@media dark .dns-banner.warn { color: oklch(0.88 0.11 85) }` | text-fg | warning | its own wash | prefers-color-scheme |
| `react/admin/src/Dmarc/Dmarc.css:382` | `@media dark .dns-banner.err { background: oklch(0.28 0.07 25) }` | wash | error-state | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Dmarc/Dmarc.css:383` | `@media dark .dns-banner.err { border-color: oklch(0.45 0.12 25) }` | border/stroke | error-state | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Dmarc/Dmarc.css:384` | `@media dark .dns-banner.err { color: oklch(0.85 0.13 25) }` | text-fg | error-state | its own wash | prefers-color-scheme |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:178` | `.compose-cc-toggle[aria-pressed="true"] { color: var(--accent) }` | text-fg | selected (Cc/Bcc toggle on) | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:262` | `.recipient-input--invalid { box-shadow: inset 0 -1px 0 0 var(--ink-danger) }` | border/stroke | error-state (bad recipient) | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:299` | `.editor-mode-tab.is-active { color: var(--accent) }` | text-fg | selected (editor mode tab) | `--accent-soft` | theme-var |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:300` | `.editor-mode-tab.is-active { background: var(--accent-soft) }` | wash | selected | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:353` | `.compose-overlay .wysiwyg-toolbar button.active { background: var(--accent-soft) }` | wash | selected (toolbar format on) | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:354` | `... button.active { color: var(--accent) }` | text-fg | selected | `--accent-soft` | theme-var |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:471` | `.compose-send { background: var(--accent) }` | fill | accent (primary Send) | `--surface-hover` (footer) | theme-var |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:472` | `.compose-send { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:590` | `.compose-attachment-warning { border: 1px solid var(--accent-soft, #f0c674) }` | border/stroke | warning (attachment size) | `#fff8e1` | theme-var (`--accent-soft` is defined, so the amber fallback never applies; the border is accent-tinted, not amber) |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:591` | `.compose-attachment-warning { background: var(--accent-softer, #fff8e1) }` | wash | warning | `--surface` | fixed (token undefined; pale yellow in dark mode too) |
| `react/admin/src/Email/ComposeOverlay/ComposeOverlay.css:638` | `.compose-chrome__text { color: var(--accent) }` | text-fg | accent (text-style chrome button) | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:45` | `.from-picker__trigger.is-open { border-color: var(--accent) }` | border/stroke | accent (open) | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:46` | `.from-picker__trigger.is-open { box-shadow: 0 0 0 3px var(--accent-soft) }` | border/stroke (ring) | accent | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:140` | `.from-picker__search:focus { border-color: var(--accent) }` | border/stroke | accent (focus) | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:141` | `.from-picker__search:focus { box-shadow: 0 0 0 2px var(--accent-soft) }` | border/stroke (ring) | accent | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:249` | `.from-picker__option-star.is-on { color: var(--accent) }` | glyph-fg | selected (favourite) | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:258` | `.from-picker__option-star.is-on:hover { color: var(--accent) }` | glyph-fg | selected (favourite) | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:262` | `.from-picker__hl { background: var(--accent-soft) }` | wash | other (search-match highlight) | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:303` | `.from-picker__create-cta:hover { background: var(--accent-soft) }` | wash | accent (hover) | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:313` | `.from-picker__create-plus { background: var(--accent) }` | fill | accent (create affordance) | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:314` | `.from-picker__create-plus { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:448` | `.from-picker__ac-input:focus, .from-picker__ac-select:focus { border-color: var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:449` | `... :focus { box-shadow: 0 0 0 2px var(--accent-soft) }` | border/stroke (ring) | accent | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:453` | `.from-picker__ac-input.is-invalid { border-color: var(--ink-danger) }` | border/stroke | error-state | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:469` | `.from-picker__ac-preview-row { background: var(--accent-soft) }` | wash | accent (preview) | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:541` | `.from-picker__note-input:focus { border-color: var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:542` | `.from-picker__note-input:focus { box-shadow: 0 0 0 2px var(--accent-soft) }` | border/stroke (ring) | accent | `--surface` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:583` | `.from-picker__btn.is-primary { background: var(--accent) }` | fill | accent (primary) | `--reader-bg` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:584` | `.from-picker__btn.is-primary { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Email/ComposeOverlay/FromPicker/FromPicker.css:585` | `.from-picker__btn.is-primary { border-color: var(--accent) }` | border/stroke | accent | `--reader-bg` | theme-var |
| `react/admin/src/Email/Email.css:128` | `.email__col-splitter:hover, :focus-visible { border-left-color: var(--accent) }` | border/stroke | accent (hover) | `--bg` | theme-var |
| `react/admin/src/Email/Email.css:129` | `... { border-right-color: var(--accent) }` | border/stroke | accent (hover) | `--bg` | theme-var |
| `react/admin/src/Email/Email.css:130` | `... { background: color-mix(in oklch, var(--accent) 12%, transparent) }` | wash | accent (hover) | `--bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:58` | `.reader-phone-back { color: var(--accent) }` | glyph-fg + text-fg | link (back nav) | `--pane-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:115` | `.reader-actions .reader-btn:focus-visible { outline: 2px solid var(--accent) }` | border/stroke | accent (focus) | `--pane-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:243` | `.reader-menu-check, .reader-menu-icon { color: var(--accent) }` | glyph-fg | selected / accent (menu icons + check) | `--surface` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:274` | `.reader-menu-item.danger { color: var(--ink-danger) }` | text-fg | danger/destructive (Block sender, Delete) | `--surface` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:278` | `.reader-menu-item.danger .reader-menu-icon { color: var(--ink-danger) }` | glyph-fg | danger/destructive | `--surface` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:282` | `.reader-menu-item.danger:hover:not(:disabled) { background: color-mix(in oklch, var(--ink-danger) 10%, var(--surface)) }` | wash | danger/destructive (hover) | `--surface` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:404` | `.source-seg-btn.active { background: var(--accent) !important }` | fill | selected (segmented control) | `--pane-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:405` | `.source-seg-btn.active { color: var(--accent-fg) !important }` | on-fill | selected | `--accent` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:469` | `.source-body .hdr-name { color: var(--accent) }` | text-fg | other (header-name syntax colour in view-source) | `--reader-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:532` | `.reader-avatar { background: var(--accent-soft) }` | wash | decorative (initials plate) | `--reader-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:533` | `.reader-avatar { color: var(--accent-ink) }` | text-fg | decorative | `--accent-soft` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:610` | `.reader-auth { --auth-ok: oklch(0.45 0.09 150) }` | (token def) | success | `--reader-bg` | prefers-color-scheme (`:617`) |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:617` | `@media dark .reader-auth { --auth-ok: oklch(0.75 0.11 150) }` | (token def) | success | `--reader-bg` (dark) | prefers-color-scheme |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:640` | `.reader-auth-chip { background: color-mix(in oklch, var(--auth-chip) 12%, transparent) }` | wash | auth verdict (neutral / success / auth-bad by modifier) | `--reader-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:641` | `.reader-auth-chip { color: var(--auth-chip) }` | text-fg | auth verdict | its own wash | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:647` | `.reader-auth-chip--ok { --auth-chip: var(--auth-ok) }` | text-fg + wash | success | `--reader-bg` | prefers-color-scheme (via `--auth-ok`) |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:648` | `.reader-auth-chip--bad { --auth-chip: var(--ink-danger) }` | text-fg + wash | auth-bad | `--reader-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:789` | `.reader-retry-btn { background: var(--accent) }` | fill | accent (retry) | `--reader-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:790` | `.reader-retry-btn { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:849` | `.reader-tab--danger { color: var(--ink-danger) }` | glyph-fg + text-fg | danger/destructive (sheet Delete tab) | `--surface` 80% | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:891` | `.reader-images button { background: var(--accent) }` | fill | accent (load remote images) | `--reader-bg` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:892` | `.reader-images button { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:953` | `.reader-attachment-badge { color: var(--accent-fg) }` | on-fill | attachment | badge fill | theme-var (flips to near-black in dark mode while the badge fills below stay dark) |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:955` | `.reader-attachment-badge { background: oklch(0.25 0.03 250) }` | fill | attachment (default family) | `--reader-bg` | fixed (= ink accent light) |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:958` | `.reader-attachment-badge.family-pdf { background: oklch(0.42 0.12 25) }` | fill | attachment (pdf) | `--reader-bg` | fixed (= oxblood light) |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:959` | `.reader-attachment-badge.family-image { background: oklch(0.52 0.12 250) }` | fill | attachment (image) | `--reader-bg` | fixed (= azure light) |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:960` | `.reader-attachment-badge.family-archive { background: oklch(0.55 0.13 70) }` | fill | attachment (archive) | `--reader-bg` | fixed (= amber light) |
| `react/admin/src/Email/MessageOverlay/MessageOverlay.css:961` | `.reader-attachment-badge.family-doc { background: oklch(0.45 0.09 150) }` | fill | attachment (doc) | `--reader-bg` | fixed (= forest light) |
| `react/admin/src/Email/Messages/Envelopes.css:57` | `.envelope-row.selected .envelope-content::before { background: var(--accent) }` | fill | selected (2px left rail) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:60` | `.envelope-row.checked .envelope-content { background: color-mix(in oklch, var(--accent) 10%, var(--surface)) }` | wash | selected (bulk-checked row) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:63` | `.envelope-row.checked:hover .envelope-content { background: color-mix(in oklch, var(--accent) 14%, var(--surface)) }` | wash | selected (hover) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:82` | `.envelope-dot { background: var(--accent) }` | fill | unread (6px dot) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:100` | `.envelope-checkbox { color: var(--accent-fg) }` | on-fill | selected (check glyph) | `--accent` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:103` | `.envelope-checkbox.checked { background: var(--accent) }` | fill | selected | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:104` | `.envelope-checkbox.checked { border-color: var(--accent) }` | border/stroke | selected | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:121` | `.envelope-avatar { background: var(--accent-soft) }` | wash | decorative (initials avatar) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:122` | `.envelope-avatar { color: var(--accent-ink) }` | text-fg | decorative | `--accent-soft` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:216` | `.envelope-row.flagged .indicator-flagged { color: var(--accent) }` | glyph-fg | flagged (star-fill icon) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:217` | `.envelope-row.important .indicator-important { color: var(--ink-danger) }` | glyph-fg | other (important/priority) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:220` | `.envelope-indicators .indicator-auth { color: var(--ink-danger) }` | glyph-fg | auth-bad (DMARC failure warning) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:231` | `.envelope-row.important .envelope-content::after { background: var(--ink-danger) }` | fill | other (important rail, 2px) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:252` | `.swipeable-list-item__leading-actions { background: color-mix(in oklch, var(--accent) 65%, transparent) !important }` | fill | other (swipe mark read/unread) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:253` | `.swipeable-list-item__leading-actions { color: var(--accent-fg) }` | on-fill | other (swipe label) | accent 65% | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:256` | `.swipeable-list-item__trailing-actions { background: var(--ink-danger) !important }` | fill | danger/destructive (swipe delete) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Envelopes.css:257` | `.swipeable-list-item__trailing-actions { color: var(--accent-fg) }` | on-fill | danger/destructive | `--ink-danger` | theme-var |
| `react/admin/src/Email/Messages/Messages.css:127` | `.msglist-tab.active .msglist-tab-count { color: var(--accent) }` | text-fg | selected (tab count) | `--surface-hover` | theme-var |
| `react/admin/src/Email/Messages/Messages.css:163` | `.msglist-sort-select:focus-visible { outline: 2px solid var(--accent) }` | border/stroke | accent (focus) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Messages.css:204` | `.msglist-select-toggle.on { background: var(--accent) }` | fill | selected (bulk mode on) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Messages.css:205` | `.msglist-select-toggle.on { border-color: var(--accent) }` | border/stroke | selected | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Messages.css:206` | `.msglist-select-toggle.on { color: var(--accent-fg) }` | on-fill | selected | `--accent` | theme-var |
| `react/admin/src/Email/Messages/Messages.css:217` | `.msglist-header.bulk { background: color-mix(in oklch, var(--accent) 8%, var(--pane-bg)) }` | wash | selected (bulk toolbar) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Messages/Messages.css:232` | `.msglist-bulk-progressbar { background: color-mix(in oklch, var(--accent) 20%, transparent) }` | fill (track) | info (bulk progress) | bulk wash | theme-var |
| `react/admin/src/Email/Messages/Messages.css:238` | `.msglist-bulk-progressbar-fill { background: var(--accent) }` | fill | info (bulk progress) | track | theme-var |
| `react/admin/src/Email/Messages/Messages.css:253` | `.msglist-bulk-num { color: var(--accent) }` | text-fg | selected (count) | bulk wash | theme-var |
| `react/admin/src/Email/Messages/Messages.css:296` | `.msglist .tool-btn.danger { color: var(--ink-danger) }` | glyph-fg | danger/destructive (bulk delete) | bulk wash | theme-var |
| `react/admin/src/Email/Search/Search.css:126` | `.search-filter-toggle.has-active { border-color: var(--accent) }` | border/stroke | selected (filters active) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Search/Search.css:127` | `.search-filter-toggle.has-active { color: var(--accent) }` | text-fg | selected | `--pane-bg` | theme-var |
| `react/admin/src/Email/Search/Search.css:138` | `.search-filter-badge { background: var(--accent) }` | fill | other (count badge) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Search/Search.css:139` | `.search-filter-badge { color: var(--accent-fg) }` | on-fill | other | `--accent` | theme-var |
| `react/admin/src/Email/Search/Search.css:185` | `.search-field input:focus, :focus-visible { border-color: var(--accent) }` | border/stroke | accent (focus) | `--pane-bg` | theme-var |
| `react/admin/src/Email/Search/Search.css:186` | `... { box-shadow: 0 0 0 1px var(--accent) }` | border/stroke (ring) | accent | `--pane-bg` | theme-var |
| `react/admin/src/Email/Search/Search.css:243` | `.search-btn--primary { background: var(--accent) }` | fill | accent (Search) | `--surface` | theme-var |
| `react/admin/src/Email/Search/Search.css:244` | `.search-btn--primary { border-color: var(--accent) }` | border/stroke | accent | `--surface` | theme-var |
| `react/admin/src/Email/Search/Search.css:245` | `.search-btn--primary { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Email/Search/Search.css:250` | `.search-btn--primary:hover:not(:disabled) { background: var(--accent) }` | fill | accent (hover, no darkening) | `--surface` | theme-var |
| `react/admin/src/Email/Search/Search.css:251` | `... { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Folders/Folders.module.css:94` | `.rail .compose { background: var(--accent) }` | fill | accent (Compose button) | `--bg` | theme-var |
| `react/admin/src/Folders/Folders.module.css:95` | `.rail .compose { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Folders/Folders.module.css:109` | `.rail .compose:focus-visible { outline: 2px solid var(--accent) }` | border/stroke | accent (focus) | `--bg` | theme-var |
| `react/admin/src/Folders/Folders.module.css:238` | `.folderItem.active::before { background: var(--accent) }` | fill | selected (folder rail bar) | `--surface-hover` | theme-var |
| `react/admin/src/Folders/Folders.module.css:246` | `.folderItem.active .folderIcon { color: var(--accent) }` | glyph-fg | selected | `--surface-hover` | theme-var |
| `react/admin/src/Folders/Folders.module.css:320` | `.favActive { color: var(--accent) }` | glyph-fg | selected (favourite folder) | `--surface` | theme-var |
| `react/admin/src/Folders/Folders.module.css:351` | `.addInput { border: 1px solid var(--accent) }` | border/stroke | accent (new-folder input) | `--surface` | theme-var |
| `react/admin/src/Login/AuthShell.css:50` | `.auth__brand-tile { color: var(--accent) }` | brand (glyph-fg) | brand/logo (`assets/logo.svg:4` is `fill="currentColor"`) | `--bg` | theme-var |
| `react/admin/src/Login/AuthShell.css:165` | `.auth__field-hint:hover { color: var(--accent) }` | text-fg | link | `--bg` | theme-var |
| `react/admin/src/Login/AuthShell.css:200` | `.auth__field input:focus, :focus-visible { border-color: var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Login/AuthShell.css:201` | `... { box-shadow: 0 0 0 3px var(--accent-soft) }` | border/stroke (ring) | accent | `--bg` | theme-var |
| `react/admin/src/Login/AuthShell.css:207` | `.auth__field.invalid input { border-color: oklch(0.55 0.18 25) }` | border/stroke | error-state | `--surface` | fixed (no JSX applies `.auth__field.invalid`; dead) |
| `react/admin/src/Login/AuthShell.css:211` | `.auth__field-error { color: oklch(0.48 0.2 25) }` | text-fg | error-state | `--bg` | fixed (no JSX renders `.auth__field-error`; dead; L 0.48 on dark `--bg` would fail contrast) |
| `react/admin/src/Login/AuthShell.css:262` | `.auth__strength-seg.on { background: var(--accent) }` | fill | other (password strength meter) | `--surface-hover` | theme-var |
| `react/admin/src/Login/AuthShell.css:271` | `.auth__btn-primary { background: var(--accent) }` | fill | accent (primary) | `--bg` | theme-var |
| `react/admin/src/Login/AuthShell.css:272` | `.auth__btn-primary { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Login/AuthShell.css:302` | `.auth__alt a, .auth__alt button { color: var(--accent) }` | text-fg | link | `--bg` | theme-var |
| `react/admin/src/Login/AuthShell.css:357` | `.auth__consent-box { accent-color: var(--accent) }` | control-tint | accent (native checkbox) | `--bg` | theme-var |
| `react/admin/src/Login/AuthShell.css:381` | `.auth__success-icon { background: var(--accent-soft) }` | wash | success (uses accent, not green) | `--bg` | theme-var |
| `react/admin/src/Login/AuthShell.css:382` | `.auth__success-icon { color: var(--accent) }` | glyph-fg | success (check stroke = currentColor, `ForgotPassword/index.jsx:35`) | `--accent-soft` | theme-var |
| `react/admin/src/Nav/Nav.css:110` | `.nav__brand-tile { color: var(--accent) }` | brand (glyph-fg) | brand/logo (`logo.svg` currentColor) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:156` | `.nav__search-input:focus, :focus-visible { border-color: var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:157` | `... { box-shadow: 0 0 0 1px var(--accent) }` | border/stroke (ring) | accent | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:186` | `.nav__search-input:hover ~ .nav__search-kbd, :focus ~ ... { color: var(--accent) }` | text-fg | accent (kbd hint) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:206` | `.nav__avatar { background: var(--accent) }` | fill | decorative (user avatar) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:207` | `.nav__avatar { color: var(--accent-fg) }` | on-fill | decorative | `--accent` | theme-var |
| `react/admin/src/Nav/Nav.css:220` | `.nav__avatar:focus-visible { box-shadow: 0 0 0 2px color-mix(in oklch, var(--accent) 40%, transparent) }` | border/stroke (ring) | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:240` | `.nav__text-btn--primary { background: var(--accent) }` | fill | accent (primary nav button) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:241` | `.nav__text-btn--primary { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Nav/Nav.css:242` | `.nav__text-btn--primary { border-color: var(--accent) }` | border/stroke | accent | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:247` | `.nav__text-btn--primary:hover { background: var(--accent) }` | fill | accent (hover) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:248` | `.nav__text-btn--primary:hover { color: var(--accent-fg) }` | on-fill | accent | `--accent` | theme-var |
| `react/admin/src/Nav/Nav.css:285` | `.nav__menu-avatar { background: var(--accent-soft) }` | wash | decorative (menu avatar) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:286` | `.nav__menu-avatar { color: var(--accent) }` | text-fg | decorative | `--accent-soft` | theme-var |
| `react/admin/src/Nav/Nav.css:339` | `.nav__menu-name-input:focus, :focus-visible { border-color: var(--accent) }` | border/stroke | accent (focus) | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:340` | `... { box-shadow: 0 0 0 1px var(--accent) }` | border/stroke (ring) | accent | `--surface` | theme-var |
| `react/admin/src/Nav/Nav.css:358` | `.nav__accent-swatch { color: var(--accent-fg) }` | on-fill | accent (check glyph on the chosen swatch) | swatch fill | theme-var |
| `react/admin/src/Nav/Nav.css:370` | `.nav__accent-swatch[data-accent="ink"] { background: oklch(0.25 0.03 250) }` | fill | accent (picker swatch) | `--surface` | prefers-color-scheme (`:378`) |
| `react/admin/src/Nav/Nav.css:371` | `.nav__accent-swatch[data-accent="oxblood"] { background: oklch(0.42 0.12 25) }` | fill | accent (picker) | `--surface` | prefers-color-scheme (`:379`) |
| `react/admin/src/Nav/Nav.css:372` | `.nav__accent-swatch[data-accent="forest"] { background: oklch(0.45 0.09 150) }` | fill | accent (picker) | `--surface` | prefers-color-scheme (`:380`) |
| `react/admin/src/Nav/Nav.css:373` | `.nav__accent-swatch[data-accent="azure"] { background: oklch(0.52 0.12 250) }` | fill | accent (picker) | `--surface` | prefers-color-scheme (`:381`) |
| `react/admin/src/Nav/Nav.css:374` | `.nav__accent-swatch[data-accent="amber"] { background: oklch(0.55 0.13 70) }` | fill | accent (picker) | `--surface` | prefers-color-scheme (`:382`) |
| `react/admin/src/Nav/Nav.css:375` | `.nav__accent-swatch[data-accent="plum"] { background: oklch(0.45 0.12 330) }` | fill | accent (picker) | `--surface` | prefers-color-scheme (`:383`) |
| `react/admin/src/Nav/Nav.css:378` | `@media dark ...[data-accent="ink"] { background: oklch(0.78 0.04 250) }` | fill | accent (picker) | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Nav/Nav.css:379` | `@media dark ...[data-accent="oxblood"] { background: oklch(0.72 0.13 25) }` | fill | accent (picker) | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Nav/Nav.css:380` | `@media dark ...[data-accent="forest"] { background: oklch(0.75 0.11 150) }` | fill | accent (picker) | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Nav/Nav.css:381` | `@media dark ...[data-accent="azure"] { background: oklch(0.78 0.12 250) }` | fill | accent (picker) | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Nav/Nav.css:382` | `@media dark ...[data-accent="amber"] { background: oklch(0.82 0.13 70) }` | fill | accent (picker) | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Nav/Nav.css:383` | `@media dark ...[data-accent="plum"] { background: oklch(0.78 0.12 330) }` | fill | accent (picker) | `--surface` (dark) | prefers-color-scheme |
| `react/admin/src/Nav/Nav.css:417` | `.nav__menu-item--danger { color: var(--ink-danger) }` | text-fg | danger/destructive (Sign out) | `--surface` | theme-var |
| `react/admin/src/Security/Security.css:37` | `.security__btn--danger { color: var(--danger, #b00020) }` | text-fg | danger/destructive (disable MFA) | legacy button `#ddd`/`#111` | fixed (token undefined; dark red on dark button in dark mode) |
| `react/admin/src/Users/Users.css:103` | `span.address-chip.shared { border-color: #c88 }` | border/stroke | other (shared-address chip) | `--bg` | fixed |
| `react/admin/src/Users/Users.css:107` | `span.address-chip.highlighted { background-color: #844 }` | fill | selected (hovered/sticky address) | `--bg` | fixed |
| `react/admin/src/Users/Users.css:108` | `span.address-chip.highlighted { border-color: #fcc }` | border/stroke | selected | `--bg` | fixed |
| `react/admin/src/Users/Users.css:109` | `span.address-chip.highlighted { color: #fff }` | on-fill | selected | `#844` | fixed |
| `react/admin/src/AppLight.css:70` | `body .highlight, body .active, body .default, ...rdw-option-active { border-color: #d00 !important }` | border/stroke | selected (legacy) | legacy `#eee` | prefers-color-scheme (dark `AppDark.css:72` `#800`) |
| `react/admin/src/AppLight.css:75` | `body .highlight, body .active, body .default, ... { background-color: #a33 !important }` | fill | selected (legacy) | legacy `#eee` | prefers-color-scheme (dark `AppDark.css:77` `#300`) |
| `react/admin/src/AppLight.css:76` | `... { color: #ff9 !important }` | on-fill | selected (legacy) | `#a33` | prefers-color-scheme (dark `AppDark.css:71` `#dda`) |
| `react/admin/src/AppLight.css:99-101` | `body .inverted .highlight/.active/.default { color: #dda; background-color: #300; border-color: #800 }` | on-fill / fill / border | selected (legacy, inverted) | `#111` | prefers-color-scheme (dark `AppDark.css:100-102` `#000` / `#a33` / `#d00`); no JSX uses `.inverted` |
| `react/admin/src/AppDark.css:71-72` | `@media dark body .highlight, .active, .default { color: #dda; border-color: #800 }` | on-fill / border | selected (legacy) | `#300` | prefers-color-scheme |
| `react/admin/src/AppDark.css:77` | `@media dark ... { background-color: #300 !important }` | fill | selected (legacy) | `#111` | prefers-color-scheme |
| `react/admin/src/AppDark.css:100-102` | `@media dark body .inverted .highlight/.active/.default { color: #000; background-color: #a33; border-color: #d00 }` | on-fill / fill / border | selected (legacy, inverted) | `#ffe` | prefers-color-scheme (unused) |

### 3b. React admin — JS / JSX / HTML / assets

| file:line | expression | role | meaning | drawn on | appearance handling |
|---|---|---|---|---|---|
| `react/admin/src/utils/addressSwatch.js:14-17` | `ADDRESS_SWATCHES = ['oklch(0.52 0.12 250)', 'oklch(0.55 0.13 70)', 'oklch(0.45 0.09 150)', 'oklch(0.45 0.12 330)']` | user-data | address-swatch (djb2 hash of lowercased address mod 4) | `--reader-bg` / `--surface` | fixed (light accent values; no dark variants) |
| `react/admin/src/Email/ComposeOverlay/FromPicker/index.jsx:60` | `style={{ background: swatchFor(item.address) }}` on `.from-picker__swatch` | user-data (fill) | address-swatch (option row) | `--reader-bg` | fixed |
| `react/admin/src/Email/ComposeOverlay/FromPicker/index.jsx:480` | `style={{ background: selectedSwatch }}` (`selectedSwatch = swatchFor(selected)`, `:448`) | user-data (fill) | address-swatch (trigger) | `--surface` | fixed |
| `react/admin/src/Email/MessageOverlay/Attachments.jsx:58` | `className={\`reader-attachment-badge family-${family}\`}` (`familyFor`, `FAMILY_BY_EXT` `:9-17`) | user-data (class -> fill) | attachment | `--reader-bg` | fixed (see CSS `:955-961`) |
| `react/admin/src/Email/MessageOverlay/index.jsx:462` | `className={\`reader-auth-chip reader-auth-chip--${methodVerdict(...)}\`}` (`utils/authResults.js:64-69`: pass->ok, fail/permerror->bad, else neutral) | user-data (class -> text+wash) | success / auth-bad / neutral | `--reader-bg` | theme-var / prefers-color-scheme |
| `react/admin/src/Email/Messages/Envelope.jsx:93-97, 154-161` | row classes `unread`, `flagged`, `important`, `selected`, `checked`; icons `indicator-auth`, `indicator-important`, `indicator-flagged` | user-data (class) | unread / flagged / important / selected / auth-bad | `--pane-bg` | theme-var |
| `react/admin/src/AppMessage/index.jsx:5` | `const level = error ? styles.error : styles.info` | (variant switch) | error-state vs info toast | `--bg` | theme-var |
| `react/admin/src/ConfirmDialog/index.jsx:54` | `className={destructive ? styles.confirmDestructive : styles.confirm}` | (variant switch) | danger/destructive vs accent | `--surface` | theme-var |
| `react/admin/src/Email/MessageOverlay/OverflowMenu.jsx:51` | `className={\`reader-menu-item ${danger ? 'danger' : ''}\`}` | (variant switch) | danger/destructive | `--surface` | theme-var |
| `react/admin/src/Email/MessageOverlay/ReaderBody.jsx:26` | `html, body { background: #ffffff; color: #111111; }` injected into iframe srcdoc | fill + text-fg | other (HTML-email canvas) | iframe | fixed (deliberate) |
| `react/admin/src/Email/Messages/icons.jsx:15,22,41,49,56,71` | `fill="currentColor"` / `stroke="currentColor"` | glyph-fg | inherits (flag-fill, star, important, auth icons) | n/a | theme-var (via parent colour) |
| `react/admin/src/Addresses/Rail.jsx:40`, `FromPicker/index.jsx:83` | `<Star fill={isFavorite ? 'currentColor' : 'none'} />` | glyph-fg | selected (favourite) | n/a | theme-var |
| `react/admin/src/ForgotPassword/index.jsx:35` | `<svg fill="none" stroke="currentColor">` (success check) | glyph-fg | success (inherits `--accent`) | `--accent-soft` | theme-var |
| `react/admin/src/assets/logo.svg:4` | `fill="currentColor"` | brand | brand/logo (inherits `--accent` via `.nav__brand-tile` / `.auth__brand-tile`) | `--surface` / `--bg` | theme-var |
| `react/admin/src/ErrorBoundary.jsx:27` | `<button className="default">` | (class -> legacy fill) | selected (legacy `#a33`/`#ff9`, `#300`/`#dda`) | legacy `#eee`/`#111` | prefers-color-scheme (only live consumer of the legacy chromatic rules) |
| `react/admin/index.html:8` | `<meta name="theme-color" content="#2E5235">` | brand | brand/logo (dark forest green) | browser chrome | fixed |
| `react/admin/public/manifest.json:23` | `"theme_color": "#2E5235"` | brand | brand/logo | OS chrome | fixed |
| `react/admin/public/manifest.json:24` | `"background_color": "#F4EBD6"` | fill | brand (cream splash) | OS | fixed |
| `react/admin/public/favicon.svg:6-7` | `<stop stop-color="#FAF4E4">`, `<stop stop-color="#EFE2C0">` | fill (gradient) | brand (cream tile) | n/a | fixed |
| `react/admin/public/favicon.svg:11` | `<g fill="#2E5235">` | brand (glyph) | brand/logo | favicon tile gradient | fixed |
| `react/admin/src/App.jsx:54` | comment: dark theme loads after light so `@media (prefers-color-scheme: dark)` wins | n/a | (load order) | n/a | prefers-color-scheme |

### 3c. Browser extension (`extensions/chrome`, `extensions/shared`)

`extensions/shared/src` defines no colours (pure logic). All extension colour lives in `extensions/chrome/src/theme.css` (tokens on `:root` for the popup and `:host` for the overlay shadow root, dark via `prefers-color-scheme`, `color-scheme: light dark` at `:22`) plus a few inline literals.

Tokens:

| token | light value | dark value | defined at (file:line) | meaning | used by |
|---|---|---|---|---|---|
| `--cm-accent` | `#1d4ed8` | `#2563eb` | `extensions/chrome/src/theme.css:37` / `:58` | accent (fill) | 2 |
| `--cm-accent-fg` | `#ffffff` | `#ffffff` | `theme.css:38` / `:59` | on-fill | 1 |
| `--cm-accent-text` | `#1d4ed8` | `#60a5fa` | `theme.css:39` / `:60` | link / accent text on `--cm-bg` | 2 |
| `--cm-danger` | `#aa0000` | `#f87171` | `theme.css:41` / `:62` | error-state text | 1 |
| `--cm-bg` | `#ffffff` | `#1f1f23` (cool tint) | `theme.css:26` / `:50` | popup body + overlay card + badge background | 3 |
| `--cm-fg` | `#1a1a1a` | `#e9e9ec` | `theme.css:27` / `:51` | primary text | 2 |
| `--cm-muted` | `#555555` | `#a2a2ac` | `theme.css:28` / `:52` | secondary text (defined, never referenced) | 0 |
| `--cm-border` | `#d0d0d0` | `#3c3c44` | `theme.css:29` / `:53` | card border, `hr` | 2 |
| `--cm-control-bg` | `#f6f6f6` | `#2c2c33` | `theme.css:31` / `:55` | button fill | 1 |
| `--cm-control-border` | `#c0c0c0` | `#4c4c56` | `theme.css:32` / `:56` | button + badge border | 2 |
| `--cm-shadow` | `rgba(0,0,0,0.18)` | `rgba(0,0,0,0.55)` | `theme.css:43` / `:66` | card shadow | 1 |
| `--cm-scrim` | `rgba(0,0,0,0.4)` | `rgba(0,0,0,0.6)` | `theme.css:44` / `:67` | modal scrim | 1 |

Direct uses:

| file:line | expression | role | meaning | drawn on | appearance handling |
|---|---|---|---|---|---|
| `extensions/chrome/src/popup/popup.html:14` | `body { color: var(--cm-fg); background: var(--cm-bg) }` | text-fg / fill | neutral canvas | n/a | theme-var |
| `extensions/chrome/src/popup/popup.html:15` | `a { color: var(--cm-accent-text) }` | text-fg | link | `--cm-bg` | theme-var |
| `extensions/chrome/src/popup/popup.html:16` | `hr { border-top: 1px solid var(--cm-border) }` | border/stroke | neutral | `--cm-bg` | theme-var |
| `extensions/chrome/src/popup/popup.tsx:230` | `<p style={{ color: '#555' }}>{status}</p>` | text-fg | info (status line) | `--cm-bg` | fixed (mid-grey on dark `#1f1f23` in dark mode; `--cm-muted` exists but is unused) |
| `extensions/chrome/src/popup/popup.tsx:231` | `<p style={{ color: '#a00' }}>{error}</p>` | text-fg | error-state | `--cm-bg` | fixed (bypasses `--cm-danger`; dark red on dark bg) |
| `extensions/chrome/src/popup/popup.tsx:233` | `<p style={{ fontSize: '12px', color: '#555' }}>` | text-fg | other (footer) | `--cm-bg` | fixed |
| `extensions/chrome/src/popup/popup.tsx:247` | `style={{ ..., color: '#06c' }}` ("Change server" link-button) | text-fg | link | `--cm-bg` | fixed (bypasses `--cm-accent-text`) |
| `extensions/chrome/src/overlay/overlay.tsx:35` | `font = { color: 'var(--cm-fg)' }` | text-fg | neutral | `--cm-bg` | theme-var |
| `extensions/chrome/src/overlay/overlay.tsx:41-44` | `card = { background: 'var(--cm-bg)', border: '1px solid var(--cm-border)', boxShadow: 'var(--cm-shadow)' }` | fill / border / shadow | neutral card | host page | theme-var |
| `extensions/chrome/src/overlay/overlay.tsx:54-55` | `buttonStyle = { border: '1px solid var(--cm-control-border)', background: 'var(--cm-control-bg)' }` | border / fill | neutral control | `--cm-bg` | theme-var |
| `extensions/chrome/src/overlay/overlay.tsx:61` | `primaryButton.background: 'var(--cm-accent)'` | fill | accent (primary) | `--cm-bg` | theme-var |
| `extensions/chrome/src/overlay/overlay.tsx:62` | `primaryButton.borderColor: 'var(--cm-accent)'` | border/stroke | accent | `--cm-bg` | theme-var |
| `extensions/chrome/src/overlay/overlay.tsx:63` | `primaryButton.color: 'var(--cm-accent-fg)'` | on-fill | accent | `--cm-accent` | theme-var |
| `extensions/chrome/src/overlay/overlay.tsx:174` | `<div style={{ color: 'var(--cm-danger)' }}>{error}</div>` | text-fg | error-state | `--cm-bg` | theme-var |
| `extensions/chrome/src/overlay/overlay.tsx:220` | `background: 'var(--cm-scrim)'` | wash | other (modal scrim) | host page | theme-var |
| `extensions/chrome/src/overlay/overlay.tsx:337-339` | badge `border: '1px solid var(--cm-control-border)', background: 'var(--cm-bg)', color: 'var(--cm-accent-text)'` | border / fill / glyph-fg | accent (in-page suggest badge) | host page | theme-var |

## 4. Rules and mappings

### 4a. Accent palette per direction

Only one direction exists: `stately` (`useTheme.js:4`, hard-coded; `data-direction` is always `"stately"`). Light values are in `AppLight.css:34-39`, dark in `AppDark.css:35-40` under `@media (prefers-color-scheme: dark)`. The same 12 literals are duplicated verbatim as picker swatch fills in `Nav.css:370-383`.

| accent | light `--accent` | dark `--accent` | notes |
|---|---|---|---|
| `ink` | `oklch(0.25 0.03 250)` | `oklch(0.78 0.04 250)` | near-neutral navy; also the default attachment-badge fill |
| `oxblood` | `oklch(0.42 0.12 25)` | `oklch(0.72 0.13 25)` | same hue (25) as `--ink-danger` — with oxblood selected, accent and danger are indistinguishable by hue |
| `forest` (default) | `oklch(0.45 0.09 150)` | `oklch(0.75 0.11 150)` | same values copied into `--auth-ok` (`MessageOverlay.css:610/617`) and `family-doc` badge |
| `azure` | `oklch(0.52 0.12 250)` | `oklch(0.78 0.12 250)` | = `ADDRESS_SWATCHES[0]`, `family-image` |
| `amber` | `oklch(0.55 0.13 70)` | `oklch(0.82 0.13 70)` | = `ADDRESS_SWATCHES[1]`, `family-archive`; hue 70-85 is also the hard-coded warning hue in `Dmarc.css` |
| `plum` | `oklch(0.45 0.12 330)` | `oklch(0.78 0.12 330)` | = `ADDRESS_SWATCHES[3]` |

Derived: `--accent-soft` = accent at 10% (light) / 15% (dark) over transparent; `--accent-fg` near-white (light) / near-black (dark); `--accent-ink` = `--ink`. Darkened hover/border variants are computed inline: `color-mix(in oklch, var(--accent) 70%|80%|88%, black)` (`ConfirmDialog.module.css:94,98`, `Dmarc.css:231-232`, `AppMessage.module.css:44`).

Theme hook (`react/admin/src/hooks/useTheme.js`): `DEFAULTS = { accent: 'forest', density: 'compact' }` (`:7-10`); `VALID.accent = ['ink','oxblood','forest','azure','amber','plum']` (`:13`); persisted in `localStorage['cabalmail.theme.v1']` (`:3`) and synced to `get_preferences`/`set_preferences` (`:68-103`); sets `data-direction`, `data-accent`, `data-density` on `<html>` (`:60-66`). No light/dark preference is stored.

### 4b. Address swatch mapping (`react/admin/src/utils/addressSwatch.js`)

`swatchIndexFor(address)` = djb2 hash of `String(address).toLowerCase()`, absolute value, `% 4` (`:20-28`). `swatchFor(address)` = `ADDRESS_SWATCHES[index]` (`:30-32`):

| index | value | equals accent | comment name |
|---|---|---|---|
| 0 | `oklch(0.52 0.12 250)` | azure (light) | `--accent-1` |
| 1 | `oklch(0.55 0.13 70)` | amber (light) | `--accent-2` |
| 2 | `oklch(0.45 0.09 150)` | forest (light) | `--accent-3` |
| 3 | `oklch(0.45 0.12 330)` | plum (light) | `--accent-4` |

Applied as inline `style.background` only in `FromPicker/index.jsx:60` (option row dot) and `:480` (trigger dot). Not theme-aware: the light-accent values are used in dark mode too. Independent of the user's chosen accent (a forest-accent user still sees azure/amber/plum dots).

### 4c. Flag / state colour mappings

There is no user-flag-colour map (no `$label` / colour keyword support). Message-state classes set in `Envelope.jsx:93-97`:

| state | class | colour | file:line |
|---|---|---|---|
| unread (`!\Seen`) | `.unread` -> `.envelope-dot` | `var(--accent)` | `Envelopes.css:82,86` |
| flagged (`\Flagged`) | `.flagged .indicator-flagged` | `var(--accent)` | `Envelopes.css:216` |
| important (`isImportant`) | `.important .indicator-important` + `::after` rail | `var(--ink-danger)` | `Envelopes.css:217,231` |
| auth warning (`authState === AUTH_WARNING`) | `.indicator-auth` | `var(--ink-danger)` | `Envelopes.css:220` |
| selected (open in reader) | `.selected ::before` rail | `var(--accent)` | `Envelopes.css:57` |
| bulk-checked | `.checked` row wash / checkbox | `color-mix(accent 10%/14%, surface)` / `var(--accent)` | `Envelopes.css:60,63,103` |

Attachment family (`Attachments.jsx:9-17` -> `MessageOverlay.css:955-961`): `pdf` -> oxblood `oklch(0.42 0.12 25)`; image (`jpg jpeg png gif webp bmp svg heic tiff`) -> azure `oklch(0.52 0.12 250)`; archive (`zip tar gz tgz rar 7z bz2`) -> amber `oklch(0.55 0.13 70)`; doc (`doc docx xls xlsx ppt pptx odt ods rtf txt`) -> forest `oklch(0.45 0.09 150)`; anything else -> `default` ink `oklch(0.25 0.03 250)`. Text on all badges is `var(--accent-fg)` (`:953`), which becomes near-black in dark mode against fills that stay light-mode dark.

Auth verdict chips (`authResults.js:64-69` -> `MessageOverlay.css:634-648`): `pass` -> `--ok` -> `--auth-ok` (forest green, own dark value); `fail`/`permerror` -> `--bad` -> `--ink-danger`; else -> `--neutral` -> `--ink-quiet`. Chip = 12% wash of that colour + text in that colour.

DMARC report page (`Dmarc/index.jsx:31-44` -> `Dmarc.css:86-106`): `pass` -> `#2e7d32`, anything else -> `#c62828` (fixed Material greens/reds, no dark variant). DNS check banners (`DnsCheckModal.jsx:77-93` -> `Dmarc.css:298-314, 370-385`): `ok` green hue 150, `warn` amber hue 80-85, `err` red hue 25, each with explicit dark overrides.

### 4d. Toast variant colours (`AppMessage/index.jsx:5`, `AppMessage.module.css:33-45`)

| variant | background | text | border |
|---|---|---|---|
| `error` (`error` prop truthy) | `var(--ink-danger, oklch(0.48 0.17 25))` | `oklch(0.99 0.003 60)` fixed near-white | `color-mix(var(--ink-danger) 70%, black)` |
| `info` (default) | `var(--accent)` | `var(--accent-fg)` | `color-mix(var(--accent) 70%, black)` |

No success/warning toast variants exist. `ConfirmDialog.module.css:91-109` mirrors the same two recipes for `.confirm` (accent) and `.confirmDestructive` (danger, fixed near-white text).

## 5. Counts

### Tokens per meaning (section 1, React; extension tokens in 3c)

| meaning | tokens |
|---|---|
| accent (incl. 6 palette entries + fg/ink/soft) | 10 (`--accent` x6, `--accent-fg`, `--accent-ink`, `--accent-soft`; `--accent-softer` undefined) |
| danger/destructive / error-state / auth-bad / important | 2 (`--ink-danger`; `--danger` undefined fallback) |
| success | 2 (`--auth-ok`, `--auth-chip` local) |
| warning | 1 (`--accent-softer` undefined -> fixed `#fff8e1`) |
| address-swatch (user-data) | 4 (JS constants) |
| info, unread, selected, flagged, link | 0 dedicated (all alias `--accent`) |
| surfaces (tinted neutrals) | 7 (`--bg`, `--reader-bg`, `--pane-bg`, `--surface`, `--surface-hover`, `--border`, `--border-faint`) |
| text neutrals | 3 (`--ink`, `--ink-soft`, `--ink-quiet`) |
| shadows | 3 |
| extension (chromatic) | 4 (`--cm-accent`, `--cm-accent-fg`, `--cm-accent-text`, `--cm-danger`) + 8 neutral |

### Direct uses per role (259 rows in 3a + 3b + 3c direct-use tables; multi-role rows counted by their first-listed role)

| role | count |
|---|---|
| border/stroke (incl. 10 focus rings/outlines) | 62 |
| fill | 59 |
| text-fg | 42 |
| on-fill | 33 |
| wash | 23 |
| glyph-fg | 19 |
| user-data | 6 |
| brand | 6 |
| control-tint | 1 |
| shadow | 1 |
| non-colour rows (variant switches, local token defs, legacy class consumer, load-order note) | 7 |

### Direct uses per appearance handling (same 259 rows)

| handling | count |
|---|---|
| theme-var | 183 |
| prefers-color-scheme (literal with an explicit dark rule) | 42 |
| fixed | 34 |

Notable fixed-in-both-themes chromatic literals: `Dmarc.css:86,91,106` (report verdicts), `Users.css:103-109` (address chips), `Security.css:37` (`#b00020`), `ComposeOverlay.css:591` (`#fff8e1`), `MessageOverlay.css:955-961` (attachment badges), `addressSwatch.js:14-17`, `AuthShell.css:207,211` (dead), `App.css:110-111` (dead), `ConfirmDialog.module.css:103` + `AppMessage.module.css:36` (near-white on `--ink-danger`), `popup.tsx:230,231,233,247`.
