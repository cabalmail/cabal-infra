# Handoff: Cabalmail Redesign

## Overview

This package contains a complete redesign for **Cabalmail**, a subdomain-based web email client. (Apple clients out of scope.) The designs cover:

1. **The full inbox application** — folder nav, message list, reader pane, compose window, bulk selection, search, address book, keyboard-first interactions
2. **Pre-auth flows** — login, signup, forgot password
3. **The wordmark / app logo** (new SVG)

The redesign takes Cabalmail from its current utilitarian shell to a considered, keyboard-first mail client with a distinct editorial voice ("Stately" direction). It is tweakable along four axes — **direction**, **theme**, **accent**, **density** — all implemented as CSS custom properties and `data-*` attributes on the root.

---

## About the Design Files

**The files in `designs/` are design references — prototypes written in a single HTML file with inline React + Babel, inline CSS, and synthetic data.** They are not production code to copy.

The task is to **recreate these designs inside the existing Cabalmail React codebase**, using the folder structure, state patterns, styling conventions, and libraries already in place (`axios`, `amazon-cognito-identity-js`, React 18, CSS / CSS modules, Jest). Do not introduce new dependencies (no Tailwind, no CSS-in-JS library, no component kit) unless explicitly asked.

The existing codebase layout is already a near-perfect map to what the designs need. Files in this repo map as follows:

| Design area | Target folder in repo |
| --- | --- |
| Folder nav (left rail, top half) | `Folders/` |
| Address book (left rail, bottom half) | `Addresses/` |
| Message list (middle pane) | `Email/Messages/` |
| Reader pane (right pane) | `Email/MessageOverlay/` |
| Compose window | `Email/ComposeOverlay/` |
| Top bar / search / account menu | `Nav/` |
| Toasts / banners | `AppMessage/` |
| Login | `Login/` |
| Signup | `SignUp/` |
| Forgot password | `ForgotPassword/` |
| Shared theme tokens (new) | `AppLight.css` / `AppDark.css` — extend these |

Rule of thumb: **if a folder already exists for a concept, put the redesigned version there.** Don't create parallel folders.

---

## Fidelity

**High-fidelity (hifi).** Final colors, typography, spacing, iconography, interaction states, and copy are all set. Recreate pixel-perfectly. Every value the developer needs — hex/oklch colors, font stacks, CSS variables, spacing scale, border radii — is enumerated in this README and defined in the design HTML.

Where the prototype uses synthetic data (e.g. the 19 envelopes in the inbox list), the real app will of course pull from the existing IMAP/Cognito backend via `ApiClient.js`. The **visuals, layout, and interactions** are what's hifi — not the data.

---

## Design Tokens

All tokens are defined as CSS custom properties, keyed off `data-direction` × `data-theme` × `data-accent` attributes on a root element.

### Directions (visual character)

Only **Stately** is the primary target for production. The other two directions are explorations kept in the prototype as tweakable alternatives — if you want to ship direction-switching later, the pattern is simple. For the first cut, **implement Stately only**.

| Direction | Character | Typefaces |
| --- | --- | --- |
| **Stately** (primary) | Editorial, serif-led, warm paper palette | Display/reader: `"Source Serif 4", Georgia, serif`. Mono: `"IBM Plex Mono", monospace`. UI: `"Inter Tight", "Inter", system-ui, sans-serif` |
| Workbench (alt) | Neutral sans, tighter, cooler | `"Inter", system-ui, sans-serif` / `"JetBrains Mono"` |
| Quiet Mono (alt) | Mono-first minimalism | `"Inter"` / `"JetBrains Mono"` |

Google Fonts used (import from `fonts.googleapis.com` or bundle): **Source Serif 4** (400, 600, 700), **Inter Tight** (400, 500, 600, 700), **IBM Plex Mono** (400).

### Theme tokens — Stately / Light

```css
:root[data-direction="stately"][data-theme="light"] {
  --bg:           oklch(0.975 0.008 85);   /* app chrome background (warm paper) */
  --reader-bg:    oklch(0.995 0.003 85);   /* reader pane — slightly brighter */
  --pane-bg:      oklch(0.99  0.004 85);   /* list pane */
  --surface:      oklch(0.985 0.005 85);   /* cards, inputs */
  --surface-hover:oklch(0.955 0.008 85);
  --border:       oklch(0.9   0.007 85);
  --border-faint: oklch(0.94  0.005 85);
  --ink:          oklch(0.22  0.015 60);   /* primary text */
  --ink-soft:     oklch(0.36  0.012 60);   /* secondary text */
  --ink-quiet:    oklch(0.55  0.01  60);   /* meta/tertiary */
  --accent-fg:    oklch(0.99  0.003 60);   /* text ON accent */
  --accent-ink:   var(--ink);
}
```

### Theme tokens — Stately / Dark

```css
:root[data-direction="stately"][data-theme="dark"] {
  --bg:           oklch(0.17  0.006 60);
  --reader-bg:    oklch(0.2   0.007 60);
  --pane-bg:      oklch(0.19  0.008 60);
  --surface:      oklch(0.22  0.008 60);
  --surface-hover:oklch(0.26  0.009 60);
  --border:       oklch(0.3   0.01  60);
  --border-faint: oklch(0.25  0.009 60);
  --ink:          oklch(0.94  0.005 80);
  --ink-soft:     oklch(0.8   0.006 80);
  --ink-quiet:    oklch(0.6   0.008 60);
  --accent-fg:    oklch(0.15  0.008 60);
  --accent-ink:   var(--ink);
}
```

### Accent palette (tweakable, user preference)

Store the selection per-user (Cognito custom attribute, or localStorage as a fallback). The accent is used for: primary buttons, unread-dot indicator, flag/star, selected-row edge, link hover, the per-address swatches, and the newsletter masthead band.

| Key | Light | Dark |
| --- | --- | --- |
| `ink`     | `oklch(0.25 0.03 250)` | `oklch(0.78 0.04 250)` |
| `oxblood` | `oklch(0.42 0.12 25)`  | `oklch(0.72 0.13 25)`  |
| `forest`  | `oklch(0.45 0.09 150)` | `oklch(0.75 0.11 150)` |
| `azure`   | `oklch(0.52 0.12 250)` | `oklch(0.78 0.12 250)` |
| `amber`   | `oklch(0.55 0.13 70)`  | `oklch(0.82 0.13 70)`  |
| `plum`    | `oklch(0.45 0.12 330)` | `oklch(0.78 0.12 330)` |

`--accent-soft` is always `color-mix(in oklch, var(--accent) 10%, transparent)` in light mode, `15%` in dark.

**Default accent: `forest`.**

### Density

`data-density="compact" | "normal" | "roomy"` controls row padding in the message list and paragraph leading in the reader. Compact is the default. Stored the same way as accent.

| Density | List-row padding-y | Reader line-height |
| --- | --- | --- |
| compact | `6px`  | `1.55` |
| normal  | `10px` | `1.65` |
| roomy   | `14px` | `1.75` |

### Spacing scale

4px base. Inline values in the prototype use: `4, 6, 8, 10, 12, 14, 16, 20, 24, 32, 40, 48`.

### Border radii

```
--radius-sm:   4px    /* inputs, small buttons, badges */
--radius-md:   6px    /* chips, menu items */
--radius-lg:   10px   /* cards, menus, modals */
--radius-xl:   14px   /* compose window, tweaks panel */
--radius-pill: 999px  /* avatar, bulk-action chip, tag pills */
```

### Shadows

Deliberately restrained. Stately uses near-flat UI — only overlays (menus, modals, compose window) have shadows.

```
--shadow-menu:    0 4px 16px -4px oklch(0.2 0.02 60 / 0.15), 0 1px 2px oklch(0.2 0.02 60 / 0.08);
--shadow-modal:   0 20px 48px -12px oklch(0.2 0.02 60 / 0.25), 0 2px 6px oklch(0.2 0.02 60 / 0.12);
--shadow-compose: 0 24px 64px -16px oklch(0.2 0.02 60 / 0.3),  0 2px 8px oklch(0.2 0.02 60 / 0.15);
```

In dark mode these use `oklch(0 0 0 / …)` with slightly higher opacity.

---

## Screens / Views

### 1. Login  — `Login/`

**Purpose:** authenticate an existing user against Cognito.

**Layout:** centered card, 360px wide, vertically mid-page. Above the card, the wordmark (`logo.svg` + "Cabalmail" in the display font) at 40px. Below the card, "Don't have an account? Sign up" link. Background: `--bg`.

**Card:**
- Surface: `--surface`, 1px `--border`, `--radius-lg`, 32px internal padding.
- Fields: label above input (label is 12px, `--ink-quiet`, uppercase tracked `0.05em`). Input is 100% width, 40px tall, `--surface-hover` fill, no border, `--radius-md`, 12px horizontal padding, `--ink` text. Focus: 1px `--accent` ring via `box-shadow: 0 0 0 1px var(--accent)`.
- Fields in order: **Username** (or email), **Password**.
- Primary button: full-width, 40px tall, `--accent` background, `--accent-fg` text, `--radius-md`, 500 weight, label "Sign in".
- Below the button: "Forgot password?" link, right-aligned, 13px, `--ink-quiet`, hover `--accent`.

**Behavior:**
- Submit → `CognitoUser.authenticateUser` via existing `AuthContext`.
- On `NEW_PASSWORD_REQUIRED` challenge, swap to the ResetPassword flow.
- Errors render in an `AppMessage` toast (red variant).
- Enter key submits from either field.

**State:** `username`, `password`, `submitting`, `error`. Keep these in `App.jsx` as they are today; the Login component stays presentational.

---

### 2. Signup — `SignUp/`

**Purpose:** create a new account.

**Layout:** same shell as Login. Card is 400px wide to accommodate the extra helper text.

**Fields in order:**
1. **Email address** — standard email input; this becomes the Cognito username.
2. **Preferred subdomain** — with `.cabalmail.com` suffix shown as a static trailing decoration inside the input, `--ink-quiet`. Validate: lowercase, digits, hyphens; 3–32 chars; not starting/ending with hyphen.
3. **Password** — with inline strength meter below (4 segments, each lights up `--accent` as zxcvbn-style checks pass: length ≥ 8, has number, has symbol, mixed case).
4. **Confirm password**.

**Below fields:** small paragraph: "By creating an account you agree to the Terms and Privacy Policy." with links `--ink-soft` underline.

**Primary button:** "Create account". Disabled until all fields valid.

**Below card:** "Already have an account? Sign in" link.

**Behavior:** POST to Cognito signup, navigate to Verify screen (which already exists in `Verify/`).

---

### 3. Forgot password — `ForgotPassword/`

**Purpose:** send a reset code.

**Layout:** same card shell. Single field: **Email**. Primary button: "Send reset link".

After submit → success state replaces the form with: checkmark glyph (`--accent`, 40px, using a simple stroked SVG), heading "Check your email", body text "If an account exists for `<email>`, you'll receive a code shortly.", and a link "Back to sign in".

Hook into the existing `ForgotPassword` flow — no new Cognito call.

---

### 4. Inbox — the main view

Composes folders, addresses, messages, reader, and compose into a single three-pane layout. This is the bulk of the redesign.

#### 4a. Top bar — `Nav/`

- Full width, 56px tall, `--pane-bg` background, 1px `--border` bottom.
- Left: wordmark (`logo.svg` + "Cabalmail"). Height 28px. The SVG uses `fill="currentColor"`; set its color with `color: var(--accent)`.
- Center (max 640px, flex-grow): search input. Placeholder "Search mail, senders, attachments…". Right side of the input shows a `⌘K` keyboard hint chip (`--surface-hover` fill, `--radius-sm`, 11px mono). Focus: 1px `--accent` ring.
- Right: theme toggle (sun/moon icon, 32px square, hover `--surface-hover`) and account avatar (32px pill, shows initials on `--accent` with `--accent-fg` text; click → account menu).

#### 4b. Left rail

280px wide. Two sections stacked, separated by a thin rule.

**Top half — "New message" CTA + folder list** (from `Folders/`):

- "New message" button: full-width minus 16px gutter, 36px tall, `--accent` fill, `--accent-fg` text, `--radius-md`, icon + label.
- Section label "FOLDERS" — 11px, `--ink-quiet`, uppercase, tracked `0.08em`, a small chevron toggle at right collapses the list.
- Folder rows: 32px tall, 12px horizontal padding, icon (18px) + name (14px, `--ink`) + unread count (11px, `--ink-quiet`, right-aligned; hidden when 0).
- Selected row: `--surface-hover` fill, left edge has a 2px `--accent` bar inset. Hover unselected: `--surface-hover` at 50%.
- Folder list in order: Inbox, Drafts, Sent, Archive, Trash, Junk, then custom folders (Receipts, Travel, Newsletters, Work, Staying Home in the prototype).

**Bottom half — Address book** (from `Addresses/`):

- Section label "ADDRESSES".
- Filter input: 28px tall, `--surface-hover` fill, placeholder "Filter addresses…".
- Address rows: 12px, with a 6px pill swatch colored per-address (the app generates a stable hash-to-swatch mapping; see the prototype). Address in mono 12px, `--ink-soft`. Clicking an address filters the message list to that recipient address.
- **"+ New address"** at the bottom — opens a small modal to request a subdomain address. Wires to `Addresses/Request.jsx`.
- Hint line below, `--ink-quiet` 11px italic: "Type to search N more addresses".

#### 4c. Middle pane — Message list — `Email/Messages/`

Width: flex-grow with min 360px, max 520px.

**Header (60px tall):**
- Title: current folder name in display font 24px (`var(--font-display)`), 600 weight, `--ink`.
- Right side: "N of M" count, `--ink-quiet` 12px.
- Below title: pill tab row **All / Unread / Flagged** with numeric counts. Selected pill: `--accent` fill, `--accent-fg` text. Unselected: `--surface-hover` fill, `--ink-soft` text.
- Sort + select strip: "Sort · Date sent ▾" on the left (opens small popover with sort options from `constants.js`: ARRIVAL / DATE / FROM / SUBJECT, ASC/DESC). "✓ Select" on the right toggles bulk mode.

**Row (compact density shown; `Envelope.jsx`):**
- 56px tall (compact), 12px horizontal padding.
- Leading column: 8px-wide rail that shows a 6px `--accent` unread dot (filled when unread). In bulk mode, a checkbox replaces the dot.
- Content: two lines.
  - Line 1: **From** (13px, 500 weight when unread, 400 when read, `--ink`) on the left; **relative time** on the right (12px, `--ink-quiet`; today → "3h", yesterday → "Yesterday", older → day-of-week, >1 week → "Apr 17").
  - Line 2: **Subject** (14px serif, `var(--font-reader)`, 500 weight when unread) truncated with ellipsis; trailing paperclip 📎 / star ⭐ / thread-count icon (14px, `--ink-quiet`) on the right.
- Hover: `--surface-hover`.
- Selected: `--surface-hover` fill, a 2px `--accent` bar inset on the left.

**Bulk mode:**
- Header replaces itself with: selection count ("3 selected"), Archive, Move, Mark read/unread, Flag, Delete action buttons (text + icon), and an ✕ to exit bulk mode.
- Shift+click range-select between rows (prototype implements this; bring the same handler to `Envelopes.jsx`).

**Empty state (per folder):** centered in the pane — small mono note, 13px, `--ink-quiet`: "Inbox zero." + a "Pick a folder →" hint if addressed from a filter with no results.

#### 4d. Right pane — Reader — `Email/MessageOverlay/`

The most feature-rich surface in the app.

**Action bar (48px tall, sticky top):**
- Left: Reply, Reply all, Forward (icon + label, button height 32px, `--ink-soft`, hover `--surface-hover`).
- Separator (1px `--border-faint`, 16px tall).
- Archive, Move, Delete, Flag, Mark unread (icon-only, 32px square).
- Right: **⋯ overflow menu** (32px square button).

**Overflow menu** (opens as a dropdown under the ⋯ button, 240px wide, `--surface`, `--shadow-menu`, `--radius-lg`, 4px padding):

Structure:
- **Group label "FORMAT"** (11px, `--ink-quiet`, uppercase, tracked, 8px horizontal padding, 4px top) — *only shown when the current message is multipart/alternative*.
- Checkable item **"Rich (HTML)"** — when selected, renders the HTML body. Checkmark slot on left; a 16px wide slot is always reserved so items line up.
- Checkable item **"Plain text alternative"** — renders the text/plain body.
- Separator (1px `--border-faint`, 4px vertical margin).
- Checkable item **"Match app theme"** — *only shown in Rich mode*. When checked, the app injects its own theme tokens into the HTML body's styles so dark/accent choices apply to the message content (see "Match theme" behavior below).
- Separator.
- Action items: "View source", "Show original headers", "Forward as attachment", "Print…".
- Separator.
- Destructive items: "Archive", "Mark as spam", "Block sender" (last one uses `--ink-danger` = `oklch(0.5 0.15 25)` light / `oklch(0.75 0.14 25)` dark).

Menu item height: 32px. Hover: `--surface-hover`. Checkmark is the filled accent check glyph (see `icons.jsx`). Use the existing keyboard-menu pattern (arrow keys, Enter, Esc).

**Header block:**
- Subject: display font, 28px, 600 weight.
- Below: sender name in 14px 500 weight + "<email>" in mono 12px `--ink-quiet`. "to <addresses>" on a second line, 12px `--ink-quiet`.
- Right side of this block: timestamp — "Friday, Apr 17 · 1:10 PM" format, 12px, `--ink-quiet`.
- Avatar: 40px pill with sender initials on `--accent-soft`, `--accent-ink` text.

**Body:**
- For rich HTML messages: render inside a sandboxed `<iframe>` whose `srcdoc` is the message HTML. Size the iframe to content (post-load height probe). Base font: whichever font the HTML specifies; fall back to `var(--font-reader)`.
- For plain text: `<pre>` with `white-space: pre-wrap`, `var(--font-reader)`, 16px, `--ink`, line-height `var(--density-leading)`.
- Max body width: 720px, centered within the reader pane; reader pane itself can be wider. 24px horizontal padding on smaller widths.

**Match theme** (when toggled on in a Rich message):
- Inject into the iframe's `<head>` a `<style>` block that sets `body { background: var(--reader-bg); color: var(--ink); font-family: var(--font-reader); }` with the current theme tokens inlined (you can't cross the iframe boundary with CSS variables; compute the resolved values and write literal colors into the style tag).
- Also neutralizes `background-color` on any element whose color is close to white, using a crude rule like `[style*="background: #fff"]` → `background: var(--reader-bg)`. The prototype takes a slightly naive approach here; production should use a CSS-in-iframe sanitizer pass. Acceptable to land a simplified version first.

**View source modal:**
- Full-screen-ish modal, 880px wide, 80vh tall, `--surface`, `--shadow-modal`, `--radius-lg`.
- Header strip: "Message source" label + two-line subject (wraps at 48ch), right side has **Full / Headers / Body** segmented control (3 buttons, `--surface-hover` group, selected = `--accent` fill + `--accent-fg` text), then "Copy" and "Save .eml" action buttons, and an ✕ close.
- Body: scrollable `<pre>`, mono 12px, line-height 1.55. Headers are colorized: `<span class="hdr-name">` for the "Return-Path:", "Received:" etc. labels uses `--accent` and 500 weight; the rest of each line stays `--ink-soft`.
- Full view = colored headers + 1 blank line separator + raw body. Headers view = colored headers only. Body view = raw body only. (See the prototype for the line-counting trick that keeps multi-line header values from duplicating into the body portion.)
- Copy copies the raw eml to clipboard. Save downloads it as `<subject>.eml` with MIME type `message/rfc822`.

**Attachments block (below the body, if any):**
- Section heading "Attachments (N)" in 12px uppercase tracked `--ink-quiet`.
- Table of attachments. Each row: 40px tall.
  - 28px extension badge: a small filled square, `--radius-sm`, colored per extension family (pdf = oxblood, image = azure, archive = amber, doc = forest, default = ink), showing the extension in uppercase mono white on `--accent-fg`.
  - Filename (14px, `--ink`) + size (12px, `--ink-quiet`) on a second line underneath.
  - Right: Download icon button, 32px square.
- Row hover: `--surface-hover`.

#### 4e. Compose window — `Email/ComposeOverlay/`

- Floating card, 600px wide, ~560px tall, pinned bottom-right of viewport with 24px offset. `--surface`, `--radius-xl`, `--shadow-compose`.
- Chrome (44px, `--surface-hover` fill, `--radius-xl` top corners): "New message" label left, — minimize / ⤢ expand / ✕ close icons right (each 28px square).
- From picker — first row in the body: label "From" (12px, `--ink-quiet`, 48px wide, right-aligned) + an address chip that when clicked opens a small menu of the user's addresses (showing swatch + address), with the current selection highlighted. Picker width is content-sized; accounts wider than ~260px truncate with ellipsis.
- To / Cc / Bcc rows: same label pattern. Cc and Bcc hidden behind a "Cc Bcc" toggle on the right of the To row. Recipient chips inline; type-to-search against the address book.
- Subject row: single line, no label (placeholder "Subject").
- All the above sit in a 48px-labeled grid. Rows are separated by 1px `--border-faint`.
- Body area: flex-grow, serif 16px `var(--font-reader)`, 24px padding. Placeholder text "Write your reply…" in `--ink-quiet`. Supports Enter / Shift-Enter. Plain text only in the prototype; production can swap in the existing rich editor.
- Bottom bar (52px, 1px `--border` top, `--surface-hover` fill):
  - Left: **Send** button (`--accent`, `--accent-fg`, 36px tall, 16px padding, `--radius-md`, label "Send"), then a small attachment icon button (32px square) and a mono/serif toggle (prototype's toy; skip in prod).
  - Right: "Saved just now" status label (12px `--ink-quiet`), then a Discard ✕ icon button.

**Behavior:**
- Autosave draft every 2s of idleness → existing `Email/ComposeOverlay` save flow. Status label reflects last save.
- Cmd/Ctrl+Enter sends.
- Esc minimizes (does not discard).
- Multiple compose windows can exist simultaneously — they stack horizontally with 8px gaps, each 600px wide. Mobile: full-screen modal.

---

## Interactions & Behavior

**Keyboard shortcuts** (all already partially present; bring them under one handler and document in a ? help overlay):
- `j` / `k` — next / prev message in list
- `Enter` — open selected message in reader
- `e` — archive
- `#` — delete
- `r` — reply, `a` — reply all, `f` — forward
- `s` — flag / unflag
- `u` — mark unread
- `c` — compose
- `/` or `⌘K` — focus search
- `g i` — go to Inbox (prefix sequence; `g a`, `g s`, `g t`, `g d` similarly)
- `x` — toggle bulk-select on focused row
- `Esc` — close overlays / exit bulk mode

**Transitions:**
- Row selection: no animation (instantaneous; this is a productivity app).
- Reader opens in place — no slide. Content swap is immediate.
- Compose window slide-in-from-bottom, 180ms ease-out.
- Modals fade-and-scale, 140ms ease-out (scale from 0.98 to 1).
- Menus fade 80ms — essentially feel instant.

**Hover states:** use `--surface-hover` for fills, `--accent` for icon/label accent changes. Avoid scale or shadow changes on hover for list rows — keep motion minimal.

**Loading states:**
- Message list loading: shimmer rows (4 fake envelopes with `--surface-hover` blocks for sender / subject / time), driven by CSS animation, 1.2s cycle.
- Reader loading: same shimmer pattern for the header block and 3 body paragraphs.
- Compose sending: button label swaps to "Sending…", button disabled.

**Error states:**
- Global errors: `AppMessage` toast (existing) with a red variant using `--ink-danger`.
- Reader load failure: inline card in the reader pane — "Couldn't load this message. Retry" with an accent retry button.

**Responsive behavior** (stretch goal — can ship desktop-first):
- ≥1280px: three panes visible.
- 960–1279px: left rail collapses to icons only (folders show icon + count; hover expands to labels). List + reader share the rest.
- <960px: single-pane stack; list full-width, clicking a row navigates to reader full-width, back button returns. Compose becomes full-screen modal.

---

## State Management

Keep today's pattern: top-level state in `App.jsx`, component props for presentation. A few new state bags the redesign needs:

```
// in App.jsx or a new context
const [direction, setDirection] = useState('stately');  // locked to 'stately' for v1
const [theme, setTheme]         = useState('light');     // 'light' | 'dark'; persist to localStorage + Cognito attr
const [accent, setAccent]       = useState('forest');    // see palette
const [density, setDensity]     = useState('compact');   // 'compact' | 'normal' | 'roomy'

// reader
const [selectedId, setSelectedId]     = useState(null);
const [readerFormat, setReaderFormat] = useState('rich');  // 'rich' | 'plain'; falls back to 'plain' if no HTML part
const [matchTheme, setMatchTheme]     = useState(false);

// list
const [filter, setFilter]       = useState('all');       // 'all' | 'unread' | 'flagged'
const [sortKey, setSortKey]     = useState(DATE);        // from constants.js
const [sortDir, setSortDir]     = useState(DESC);
const [bulkMode, setBulkMode]   = useState(false);
const [selected, setSelected]   = useState(new Set());

// compose — existing; extend with `fromAddress` so the From picker works:
const [composeFromAddress, setComposeFromAddress] = useState(defaultAddress);
```

Apply theme tokens by setting `data-direction`, `data-theme`, `data-accent`, `data-density` on `<html>` (or the top app div). All CSS selectors in the designs are written against those attributes.

Persist theme / accent / density:
1. localStorage for instant apply on next load.
2. Cognito custom attribute (`custom:theme`, `custom:accent`, `custom:density`) for cross-device sync. Update on change with debounce 1s.

---

## Responsive Strategy

Three tiers, same tokens everywhere. See `designs/mobile-explorations.html` for the phone + tablet mockups.

| Breakpoint | Width | Layout | Folders | Envelope list | Reader |
| --- | --- | --- | --- | --- | --- |
| **Phone** | `< 768px` | single-pane, route-driven | full screen at `/` | full screen at `/folder/:name` | full screen at `/folder/:name/message/:id` |
| **Tablet** | `768 – 1199px` | two-pane + drawer | slide-over drawer (hamburger in header) | left, ~340px | right, flex |
| **Desktop** | `≥ 1200px` | three-pane (current `inbox-explorations.html` layout) | left, ~260px | middle, ~380px | right, flex |

### Key patterns

**Route-driven pane switching.** On phone, each pane is its own route. Back button pops naturally. Don't manage this with local component state — let `react-router` (or equivalent) drive it. On tablet/desktop, the same routes still resolve, but side panes stay visible via responsive CSS; the URL just affects which envelope / message is selected.

**Overlays go full-sheet below `768px`.** `MessageOverlay` and `ComposeOverlay` currently render as floating cards. On phone they should be full-bleed with a header bar (Cancel / title / primary action). Use a single CSS class (e.g. `.overlay--sheet`) gated on a `matchMedia('(max-width: 767px)')` hook, not a fork of the component.

**Tab bar vs. toolbar row.** On phone, the reader replaces its inline toolbar with a floating tab bar docked above the home indicator — thumb-reachable. Same actions: reply, reply-all, forward, divider, archive, trash. Implement as a sibling element inside `MessageOverlay` that's hidden above 767px.

**Folder drawer.** One component, two presentations. On tablet, render as a fixed 82%-width slide-over with a scrim; slide transform from the left. On desktop, render in-flow in the left rail. Controlled by the same `foldersOpen` state — desktop just ignores it.

**Hit targets.** Every tappable row is `≥ 44px` tall on phone. Envelope rows use 14px vertical padding to hit this without the content feeling stretched. Folder rows have `min-height: 52px`. Icon buttons in headers are 36×36px with internal padding bringing effective hit area to 44×44px.

**Search.** The desktop top-bar search becomes a row under the envelope-list header on phone. Same input, same behavior; just relocated via media query.

**Compose floating action.** On desktop the "Write" button sits in the top bar. On phone, surface it from the envelope-list header (right side, next to settings). Don't add a FAB — it fights the floating reader tab bar.

**Account switcher.** Lives pinned to the bottom of the folder list on phone (full-width row with avatar + name + email + plus icon). On desktop it tucks into the top-bar user menu. Same `AccountContext`, two render paths.

### Implementation per existing folder

- **`Email/index.jsx`** — add breakpoint logic here (one `useMediaQuery` hook). Decide whether to render one pane, two, or three. Pass `isPhone` / `isTablet` down as props or via context.
- **`Folders/index.jsx`** — accept an `asDrawer` prop. When true, render inside a fixed-position container with scrim; when false, render in-flow. Same children either way.
- **`Email/Messages/index.jsx`** — on phone, hide when a message is open (route controls it). The header gains a back button and the compose icon on phone only.
- **`Email/MessageOverlay/index.jsx`** — add the floating tab bar element; toggle toolbar-row vs. tab-bar via `data-layout="sheet"` attribute set by the breakpoint.
- **`Email/ComposeOverlay/index.jsx`** — same pattern. Sheet mode adds a top chrome row (Cancel / New message / Send) and removes the draggable frame.
- **`Nav/index.jsx`** — collapse to just wordmark + menu icon on phone. Search, theme toggle, and account menu relocate.

### CSS approach

Use a single mobile-first base plus two `@media` guards in each component's stylesheet:

```css
/* phone base */
.email-layout { display: flex; flex-direction: column; }
.email-layout__list { flex: 1; }
.email-layout__reader,
.email-layout__folders { display: none; }

@media (min-width: 768px) {
  .email-layout { flex-direction: row; }
  .email-layout__list { width: 340px; }
  .email-layout__reader { display: block; flex: 1; }
  /* folders still toggle via drawer */
}

@media (min-width: 1200px) {
  .email-layout__folders { display: block; width: 260px; }
  .email-layout__list { width: 380px; }
}
```

Don't introduce a CSS-in-JS runtime or a breakpoint library. The app already uses plain CSS / CSS modules; one `useMediaQuery` hook (10 lines) is enough.

### Testing

Add to the existing Jest setup: each of the four redesigned screens should have a test at three viewports (375×812, 834×1194, 1440×900) confirming the right panes render and the correct nav controls are visible. `@testing-library/react` with `window.matchMedia` mocked is sufficient.

---

## Assets

- **`logo.svg`** — the new wordmark glyph. `fill="currentColor"` so it inherits the text color of its container (use `color: var(--accent)` for the accent tile, or `color: var(--ink)` in monochrome contexts). `logo.png` is included as a fallback raster; prefer the SVG.
- Icons — the existing `icons.jsx` file covers most of what's needed. New icons you may need: `check` (for menu tick), `download`, `paperclip`, `flag`, `flag-fill`, `star`, `star-fill`, `chevron-down`, `sun`, `moon`, `command`. Draw these as simple 16px stroked SVGs matching the existing icon set's 1.5px stroke weight. If you'd rather, swap in **Lucide** (`lucide-react`) — the prototype's aesthetic matches it 1:1. (New dependency, so ask the team first.)

---

## Files in this handoff

- `designs/inbox-explorations.html` — the full inbox app (desktop), all states, all tweaks
- `designs/mobile-explorations.html` — phone + tablet mockups: folder list, envelope list, reader, compose sheet, login, settings, drawer state
- `designs/login.html` — login screen
- `designs/signup.html` — signup screen
- `designs/forgot.html` — forgot-password screen
- `designs/logo.svg` — new wordmark (use this)
- `designs/logo.png` — raster fallback
- `README.md` — this document

Open any HTML file in a browser to see it live. The inbox file has a "Tweaks" panel (bottom-right) that cycles direction / theme / accent / density / sample message — use it to see all the states you'll need to build.

---

## Implementation order (suggested)

1. **Tokens.** Extend `AppLight.css` / `AppDark.css` with all the `--ink`, `--surface`, `--accent` variables, wire `data-theme` / `data-accent` / `data-density` onto `<html>`. Nothing visible changes yet.
2. **Logo + top bar.** Drop `logo.svg` into the project, update `Nav/` to use it and to render the new top bar layout (wordmark + search + theme toggle + avatar).
3. **Folders + Addresses rail.** Rebuild the two sections per the spec. Wire to existing `ADDRESS_LIST` / `FOLDER_LIST` contexts.
4. **Message list.** Rebuild `Envelope.jsx` row, `Envelopes.jsx` header + filter + sort + bulk-mode. This is the biggest single piece.
5. **Reader.** Rebuild `MessageOverlay`, including action bar, overflow menu, and Match theme behavior. **View source modal and attachments block are the largest net-new surfaces** — land them as separate PRs if useful.
6. **Compose.** Add the From picker; retain the existing editor. Make the window floating per the spec.
7. **Auth screens.** Login, Signup, Forgot — smallest changes; do these last or in parallel.
8. **Preferences persistence.** Wire theme/accent/density to Cognito custom attributes.
9. **Keyboard shortcuts.** Unify under one hook.
10. **Responsive + loading/error states.** Polish pass. Follow the **Responsive Strategy** section: mobile-first CSS, `useMediaQuery` in `Email/index.jsx`, sheet mode for `MessageOverlay` / `ComposeOverlay`, drawer mode for `Folders`, floating tab bar in the reader. Reference `designs/mobile-explorations.html` for every screen.

---

## Questions for the team (before starting)

- Lucide icons OK, or keep drawing in-house?
- Cognito custom attributes for preferences — is the Cognito user pool schema editable, or store prefs in a separate DynamoDB `UserPreferences` table?
- Should subdomain pickers in Signup validate availability (live API call) or just format?
- HTML message sanitization — is there already a sanitizer in the backend (`ApiClient.js` pre-processes before shipping to client), or does it arrive raw?

Resolve these before Implementation Step 2.
