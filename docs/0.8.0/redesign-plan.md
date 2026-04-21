# Cabalmail Redesign — Phased Plan (0.8.0)

## Context

`react/design_handoff_cabalmail_redesign/README.md` specifies a complete, high-fidelity redesign of the Cabalmail web client. It replaces the current utilitarian shell with a keyboard-first, editorial three-pane client tweakable along four axes (direction, theme, accent, density), all driven by CSS custom properties and `data-*` attributes on the root element.

The redesign touches nearly every user-facing surface: the design token system, nav, folder rail, address book, message list, reader, compose window, login, signup, forgot-password, preferences persistence, keyboard shortcut system, and responsive strategy. The handoff README itself enumerates **ten** implementation steps and explicitly suggests that Step 5 (reader) be split across multiple PRs.

**It cannot be implemented in a single session.** Even under the most aggressive scoping, a single session that attempts all ten steps would end with multiple half-finished surfaces, broken tests, and a diff too large to review. This document breaks the work into eight independently-shippable phases.

All work is performed from the `0.8.0` branch. Each phase results in a PR into `0.8.0`. When the branch is ready, `0.8.0` merges into `stage` and then `main` per the usual deploy flow.

## Scope notes

- **Stately direction only** for v1. The other two directions (Workbench, Quiet Mono) stay as prototype references; the token plumbing supports them but we do not ship their values.
- **No new runtime dependencies** without explicit sign-off — no Tailwind, no CSS-in-JS library, no component kit. Fonts are the one exception (Google Fonts for Source Serif 4, Inter Tight, IBM Plex Mono).
- **Lucide icons are deferred.** Phase 1 assumes we extend `icons.jsx` in-house; if the team later approves `lucide-react`, a small follow-up swaps the imports.
- Each phase is scoped so that merging it in isolation leaves `0.8.0` in a shippable state. Nothing visible to users breaks mid-way through the rollout; unfinished surfaces either keep their current styling or are gated behind a layout flag on the root.

## Preflight — resolve before Phase 1 begins

The handoff README closes with four open questions. Two of them block real code; two only block specific phases. Answer these before starting:

1. **Icons**: Lucide or in-house? — blocks Phase 1 icon extension work.
2. **Preferences storage**: Cognito custom attributes (requires user-pool schema change in `terraform/infra/modules/user_pool`) vs. a new DynamoDB `UserPreferences` table? — blocks Phase 7.
3. **Subdomain availability check**: live API call vs. format-only validation? — blocks Phase 7 signup work.
4. **HTML sanitization**: does the server-side `ApiClient` / `fetch_message` Lambda already sanitize, or does raw HTML reach the client? — blocks Phase 4 reader safety posture and Phase 5 Match-theme injection.

If (4) lands on "raw HTML reaches the client," Phase 4 picks up a small sandboxing spike (iframe `sandbox` attributes, no-script policy) before the reader ships.

---

## Phase 1 — Token foundation + nav shell

**Goal:** establish the theming system and the new top bar. No user-facing surface below the top bar changes yet.

**Work:**

- Extend `AppLight.css` / `AppDark.css` with the full Stately token set from the README (`--bg`, `--reader-bg`, `--pane-bg`, `--surface`, `--surface-hover`, `--border`, `--border-faint`, `--ink`, `--ink-soft`, `--ink-quiet`, `--accent`, `--accent-soft`, `--accent-fg`, `--accent-ink`, `--ink-danger`, `--shadow-menu`, `--shadow-modal`, `--shadow-compose`, radii, density vars).
- Key all selectors off `:root[data-direction="stately"][data-theme="…"][data-accent="…"][data-density="…"]`. Set these attributes on `<html>` from `App.jsx`. Direction is hard-coded to `stately` for v1.
- Add the six accent palettes (`ink`, `oxblood`, `forest`, `azure`, `amber`, `plum`) in both light and dark. Default: `forest`.
- Load the three Google Fonts (Source Serif 4 400/600/700, Inter Tight 400/500/600/700, IBM Plex Mono 400) via `<link>` in `index.html`. Define `--font-display`, `--font-reader`, `--font-mono`, `--font-ui` tokens.
- Drop `logo.svg` into `react/admin/src/assets/` (create the folder). Ensure `fill="currentColor"` is preserved.
- Rebuild `Nav/` per §4a: wordmark (logo + "Cabalmail") left, centered search input with `⌘K` chip, theme toggle + account avatar right. Height 56px. `--pane-bg` with 1px `--border` bottom.
- Add a minimal `useTheme` hook that reads/writes `theme` / `accent` / `density` to localStorage only (Cognito sync deferred to Phase 7).
- Extend `icons.jsx` with the new glyphs listed in the README: `check`, `download`, `paperclip`, `flag`, `flag-fill`, `star`, `star-fill`, `chevron-down`, `sun`, `moon`, `command`. Only if Preflight (1) lands on "in-house."

**Out of scope:** folders styling, message list styling, reader, compose, auth. Those keep today's CSS; the token change affects only Nav and document-level background colors until their respective phases.

**Definition of done:** toggling `data-theme` between `light` and `dark` from devtools flips the nav and app background correctly. Accent switching updates the avatar pill and the ⌘K chip hover color. All tokens resolve (no undefined vars in devtools).

---

## Phase 2 — Left rail: Folders + Addresses

**Goal:** rebuild the left-rail two-section layout.

**Work:**

- Rebuild `Folders/` per §4b top-half: "New message" CTA, "FOLDERS" section label with collapse chevron, folder rows with icon + name + unread count, selected-row treatment (left edge 2px accent bar inset, `--surface-hover` fill), hover states.
- Rebuild `Addresses/` per §4b bottom-half: "ADDRESSES" section label, filter input (28px, placeholder "Filter addresses…"), address rows with stable hash-to-swatch mapping (port the prototype's hash function), mono 12px address text, "+ New address" bottom row that opens the existing request modal, italic hint line.
- Wire clicking an address to filter the message list to that recipient. This requires a new filter key in the shared state (coordinate with Phase 3).
- Left rail total width 280px; internal divider is a thin rule.

**Out of scope:** message list, reader, compose. The middle pane can still be today's `Messages` — it just sits next to a freshly-styled rail.

**Definition of done:** rail matches the prototype. All existing actions (select folder, open address request modal, revoke address) still work. Tests for `Folders` and `Addresses` updated to match new DOM.

---

## Phase 3 — Message list (Envelopes)

**Goal:** rebuild the middle pane. Per the README, this is "the biggest single piece."

**Work:**

- Rebuild `Email/Messages/` header (60px): folder title in display font 24px, "N of M" count, **All / Unread / Flagged** pill tabs with counts, sort strip (Sort · Date sent ▾ left; ✓ Select right).
- Rebuild `Envelope.jsx` row per §4c: 56px tall at compact density, 8px leading rail (6px unread dot / checkbox in bulk mode), From line (13px, weight depends on read state), Subject line (serif 14px), relative time (today → "3h", yesterday → "Yesterday", older → day-of-week, >1wk → "Apr 17"), trailing meta icons.
- Bulk mode: header swaps to selection count + Archive / Move / Mark read/unread / Flag / Delete actions + ✕ exit. Shift+click range-select (port the prototype's handler).
- Empty state: centered mono 13px, `--ink-quiet`, "Inbox zero." with filter-empty variant.
- Add `filter`, `sortKey`, `sortDir`, `bulkMode`, `selected` state bags to `App.jsx` (or the appropriate parent) per the README's State Management section.

**Out of scope:** reader pane internals, compose. The reader can keep its current styling — this phase is about the list.

**Definition of done:** list matches the prototype at all density values. Bulk mode works including shift+click range. Sort popover pulls options from `constants.js`. All existing tests for `Envelope` / `Envelopes` updated.

---

## Phase 4 — Reader core

**Goal:** rebuild the right-pane reader up through attachments. Leave the two advanced surfaces (View source modal, Match theme) for Phase 5.

**Work:**

- Action bar (48px sticky): Reply / Reply all / Forward (icon + label) | separator | Archive / Move / Delete / Flag / Mark unread (icon-only) | overflow ⋯ right.
- Header block: subject in display 28px, sender name + `<email>` mono, "to …" line, timestamp right-aligned, 40px accent-soft avatar with initials.
- Body:
  - Rich HTML → sandboxed `<iframe srcdoc=…>`, post-load height probe to size to content.
  - Plain text → `<pre>` with `white-space: pre-wrap`, `var(--font-reader)`, `var(--density-leading)`.
  - Max body width 720px, centered.
- Attachments block: "Attachments (N)" heading, rows with 28px extension badge colored per family (pdf=oxblood, image=azure, archive=amber, doc=forest, default=ink), filename + size, download icon button, row hover `--surface-hover`.
- Overflow menu minimum viable version: **Rich (HTML)** / **Plain text alternative** checkable items (only the FORMAT group lands this phase). Rest of the menu is stubbed out — disabled or hidden.
- Add `readerFormat` state ('rich' | 'plain', falls back to 'plain' if no HTML part).

**Out of scope:** Match theme injection, View source modal, destructive menu items, Forward-as-attachment, Print.

**Definition of done:** Reader renders rich and plain variants correctly, iframe sizes to content, attachments list renders with correct badge colors and downloads work. Overflow menu opens and the Rich/Plain toggle behaves.

---

## Phase 5 — Reader advanced surfaces

**Goal:** land the two large net-new surfaces and the rest of the overflow menu.

**Work:**

- **View source modal** per §4d: 880px × 80vh modal, `--shadow-modal`, `--radius-lg`. Header with label + wrapped subject + Full / Headers / Body segmented control + Copy / Save .eml / ✕. Body is a scrollable `<pre>` mono 12px with header colorization (`<span class="hdr-name">` → `--accent` 500 weight). Implement the line-counting trick that keeps multi-line header values from leaking into Body view. Copy → clipboard. Save → `<subject>.eml` as `message/rfc822`.
- **Match theme** per §4d: when Rich mode + Match theme are both on, inject a `<style>` block into the iframe `<head>` setting `body { background / color / font-family }` with the current theme tokens **resolved to literal values** (cross-boundary CSS variables won't work). Apply the README's naive background-neutralization pass (`[style*="background: #fff"]` → `--reader-bg`). Noted in the README as acceptable-for-v1.
- Overflow menu: add remaining items per §4d — View source, Show original headers, Forward as attachment, Print…, Archive, Mark as spam, Block sender. Wire "View source" → modal. Wire "Show original headers" → reuse the View source modal pre-set to Headers. Keyboard-menu pattern (arrow keys, Enter, Esc) — reuse the existing pattern from elsewhere in the app.

**Out of scope:** compose and auth.

**Definition of done:** View source modal fully functional at all three segmented-control states, Copy and Save verified. Match theme toggles cleanly between stock and themed renders. All overflow menu items either work or stub clearly.

---

## Phase 6 — Compose window

**Goal:** rebuild the floating compose window, with the existing rich editor retained inside.

**Work:**

- Floating card 600px × ~560px, pinned bottom-right with 24px offset. `--shadow-compose`, `--radius-xl`, 44px chrome with minimize / expand / close.
- From picker: new address chip that opens a menu of the user's addresses (swatch + address, highlighting current selection). Wire to a new `composeFromAddress` state bag.
- To / Cc / Bcc rows with 48px right-aligned labels. Cc / Bcc hidden behind a toggle.
- Subject row with placeholder.
- Body area: keep the existing rich editor inside; wrap it so the outer chrome / padding matches the spec.
- Bottom bar: Send (accent) + attachment icon + "Saved just now" status + Discard.
- Multi-window support: stack horizontally with 8px gaps.
- Animations: slide-in-from-bottom 180ms ease-out. Esc minimizes.

**Out of scope:** the editor itself is unchanged. Mobile full-screen variant lands in Phase 8.

**Definition of done:** compose opens as a floating card, From picker lists all user addresses with swatches, Cc/Bcc toggle works, multiple compose windows can coexist, Cmd/Ctrl+Enter sends, Esc minimizes without discarding.

---

## Phase 7 — Auth screens + preferences persistence + keyboard shortcuts

**Goal:** finish the smaller surfaces. These three are grouped because each on its own is too small for a PR, and they share no code but also no blocking dependencies.

**Work:**

- **Login** (`Login/`) per §1: centered 360px card with wordmark above, fields (Username, Password), Sign in button, Forgot password link, "Don't have an account? Sign up" below. Existing Cognito flow unchanged.
- **Signup** (`SignUp/`) per §2: 400px card, fields (Email, Preferred subdomain with `.cabalmail.com` static suffix, Password with zxcvbn-style 4-segment strength meter, Confirm password), terms / privacy paragraph, Create account button disabled until valid.
- **ForgotPassword** (`ForgotPassword/`) per §3: single Email field, Send reset link, success state with checkmark and "Check your email" copy.
- **Preferences persistence** per README State Management §: localStorage already landed in Phase 1; this phase adds the Cognito custom attribute writeback (`custom:theme`, `custom:accent`, `custom:density`) with 1s debounce. Depends on Preflight (2) — if the user pool schema isn't editable, substitute the DynamoDB `UserPreferences` table path (separate Terraform change, tracked in its own sub-task).
- **Keyboard shortcuts** per Interactions §: new `useKeyboardShortcuts` hook centralizing j/k/Enter/e/#/r/a/f/s/u/c/⌘K/x/Esc and the `g` prefix sequences (`g i`, `g a`, `g s`, `g t`, `g d`). Remove the scattered handlers these replace. Add a `?` help overlay that enumerates the shortcut set.

**Out of scope:** responsive variants of the auth screens (mobile column-stretch lands in Phase 8).

**Definition of done:** all three auth screens match the prototype. Theme/accent/density persist to Cognito and survive a fresh login on a different device. All keyboard shortcuts route through the single hook and show up in the `?` overlay.

---

## Phase 8 — Responsive + loading/error state polish

**Goal:** mobile-first CSS rework and the remaining UX polish.

**Work:**

- Implement the responsive strategy from the README's Responsive Strategy section. One `useMediaQuery` hook (≤10 lines), mobile-first base styles, two `@media` guards per component (768px, 1200px).
- `Email/index.jsx` picks the one / two / three pane layout from breakpoint.
- `Folders/index.jsx` gains an `asDrawer` prop: on tablet, renders as 82%-width slide-over with scrim; on desktop, in-flow.
- `Email/Messages/index.jsx`: on phone, adds a back button and compose icon to its header.
- `Email/MessageOverlay/index.jsx`: adds the floating tab bar (reply / reply-all / forward / | / archive / trash) docked above the home indicator, gated on `data-layout="sheet"`. Toolbar-row hidden below 768px.
- `Email/ComposeOverlay/index.jsx`: sheet mode with top chrome (Cancel / New message / Send).
- Loading states per Interactions §: shimmer rows (4 fake envelopes) in the list, shimmer header + 3 body paragraphs in the reader, "Sending…" button label during compose send.
- Error states: AppMessage red-variant toasts, reader inline "Couldn't load this message. Retry" card.
- Jest viewport tests: each of the four redesigned screens (auth, folder rail, inbox desktop, inbox phone) at 375×812 / 834×1194 / 1440×900, mocking `window.matchMedia`.

**Definition of done:** all three breakpoints render correctly. Sheet / drawer / tab bar behaviors match `designs/mobile-explorations.html`. Loading shimmers visible when latency is simulated. Viewport tests pass in CI.

---

## Cross-phase concerns

### Sequencing constraints

- **Phase 1 blocks everything.** Until tokens and fonts are live, nothing else can match the designs.
- **Phase 2 and Phase 3 can overlap** (different component trees, shared only through `App.jsx` state bags). Two developers — one on each — is fine.
- **Phase 4 must precede Phase 5** (view source modal depends on the new reader frame).
- **Phase 6 is independent** of Phases 2–5; it can overlap with any of them after Phase 1.
- **Phase 7** (auth + prefs + shortcuts) is independent of 2–6. Could be threaded in earlier if schedule pressure requires.
- **Phase 8 is last.** Responsive rework touches every component that earlier phases just rebuilt; doing it last avoids re-doing work.

### State bag ownership

The redesign adds state: `direction`, `theme`, `accent`, `density`, `selectedId`, `readerFormat`, `matchTheme`, `filter`, `sortKey`, `sortDir`, `bulkMode`, `selected`, `composeFromAddress`. Per the README, these live in `App.jsx` today. If `App.jsx` gets unwieldy, consider extracting a `PreferencesContext` (theme / accent / density) in Phase 1 and a `ReaderStateContext` (selectedId / readerFormat / matchTheme) in Phase 4. Do not introduce Redux.

### Testing posture

- Unit tests per phase stay in Vitest / jsdom as today.
- Snapshot tests should be avoided for the redesigned screens (too much churn during layout iteration); prefer `@testing-library/react` queries on semantic DOM.
- Viewport tests land in Phase 8 only — running them earlier churns as the layouts change.

### Risk areas to watch

- **Iframe height probe** (Phase 4). Real mail HTML is adversarial — uncompressed `<style>` blocks, explicit pixel heights, dynamically-loaded images. Budget extra time for edge cases.
- **Match theme injection** (Phase 5). The README calls the v1 approach "naive." Expect a follow-up ticket post-launch once real users hit edge cases.
- **Cognito schema change** (Phase 7). If the user pool allows custom attributes without breaking existing users, this is trivial; if it doesn't (and schema migrations require a new pool), fall back to the DynamoDB `UserPreferences` path.
- **Keyboard shortcut collisions** (Phase 7). The `g` prefix requires a short timeout state machine; make sure it doesn't swallow legitimate `g` keystrokes in inputs.

---

## Summary

| Phase | Scope | Rough PR size |
|---|---|---|
| 1 | Tokens, fonts, logo, top bar | Medium |
| 2 | Left rail (Folders + Addresses) | Medium |
| 3 | Message list with bulk mode | Large |
| 4 | Reader core (header, body, attachments, Rich/Plain) | Large |
| 5 | View source modal + Match theme + rest of overflow | Medium |
| 6 | Compose window (From picker, multi-window, floating card) | Medium |
| 7 | Auth screens + prefs persistence + keyboard shortcuts | Medium |
| 8 | Responsive + loading/error polish + viewport tests | Medium |

Eight phases, each a coherent PR. Total: roughly what the README's ten-step list describes, compacted where steps are small enough to merge.
