# Handoff: Mail Rules (Cabalmail)

## Overview

A user-facing **mail rules editor** for Cabalmail — the procmail-style
automatic mail-handling rules a user defines from inside their account.
Every incoming message is matched against this ordered rule list
top-to-bottom; the first time a rule's conditions match, its actions
fire, and unless the rule asks to continue, processing stops there.

This handoff covers a single new page that links from the existing
user menu (where Sign-out and Accent color live) under the entry
**"Mail rules…"**. There is no other route into it.

## About the design files

The HTML/JSX/CSS in this folder is a **design reference** — a working
prototype showing the intended visual design and interaction model. It
is not production code. The implementer should recreate the design in
the Cabalmail web client's actual environment (React 18, Vite, CSS
custom properties — the same stack as `inbox-explorations.html`),
reusing the existing design tokens, icon set, `<UserMenu>`, toggle, and
`<TweaksPanel>` chrome instead of re-implementing them.

The prototype uses inline `<script type="text/babel">` and React from
unpkg purely for in-browser preview; in the real app it should be
ordinary modules that the Vite build compiles.

## Fidelity

**High-fidelity.** Colors, typography, spacing, and interactions are
all final. Recreate pixel-perfectly using existing tokens. The only
liberty taken is the in-page Tweaks panel that toggles between
condition / action / ordering UI styles — the chosen production design
is `rows / segmented / drag`. The other variants can be discarded.

The five chosen production decisions:

| Choice               | Production setting                              |
| -------------------- | ----------------------------------------------- |
| Default density      | `comfortable`                                    |
| Conditions UI        | `rows` — one row per condition                   |
| Actions UI           | `segmented` — exclusive destination as tabs      |
| Ordering UI          | `drag` — handle on each row                      |
| Spillthrough UI      | single toggle "Continue to next rule"            |

## Route & entry point

The page is reachable only from the user menu. In the existing
`UserMenu` component (`inbox-explorations.html` → `App.jsx`), add an
item between *Accent color* and *Preferences…*:

```jsx
<a className="user-menu-item" href="/rules">
  <Icon name="rules" />
  <span>Mail rules…</span>
</a>
```

When the user is on the rules page, that same item should render with
the `.current` modifier (accent-soft background, accent icon, semibold
weight) — see the prototype's UserMenu copy in `rules-app.jsx`.

The rules page itself adds a *"Back to mail"* link at the top of the
menu and removes the `Mail rules…` item's "click target" affordance
(it's the current page). Both are implemented in `rules-app.jsx`.

## Data model

```ts
type Field = 'from' | 'to' | 'cc' | 'bcc' | 'subject' | 'body';

interface Condition {
  field: Field;
  value: string;       // substring; the only supported operator is "contains"
}

type Action = 'move' | 'copy' | 'delete' | 'archive';

interface Rule {
  id: string;
  name: string;
  enabled: boolean;
  conditions: Condition[];     // ANDed; empty array matches every message
  action: Action;              // mutually exclusive destination
  moveFolder: string;          // used only when action === 'move'
  copyFolders: string[];       // used only when action === 'copy'
  flag: boolean;               // independent — n/a when action === 'delete'
  markRead: boolean;           // independent — n/a when action === 'delete'
  forward: string[];           // 0+ email addresses; n/a when action === 'delete'
  continueToNext: boolean;     // spill-through; n/a when action === 'delete'
}
```

Notes:
- `conditions` is **always ANDed**. There is no OR. To express OR,
  the user creates two rules.
- `contains` is the only operator. It is a case-insensitive substring
  match on the raw header value (or the decoded body for the `body`
  field). Don't expose an operator selector in the UI.
- `action` is one of four mutually-exclusive choices. When the user
  picks `delete`, persist the previously-set `flag`, `markRead`,
  `forward`, `continueToNext` values but ignore them at evaluation
  time — that way switching back to `move` restores their prior state.
- `forward` is allowed to contain transiently-invalid strings (the
  user is typing). Save only when the entry passes
  `/^[^\s@]+@[^\s@]+\.[^\s@]+$/`. The UI surfaces invalid chips with a
  danger styling so the user can see why their save doesn't take.
- Order in the `Rule[]` array is the precedence order. The first rule
  in the array runs first.

## Screens & views

There is **one** page with two coexisting layouts (master/detail on
desktop, single-pane swap on mobile) plus an **empty state** that
replaces the editor pane when the rule list is empty.

### Topbar

Three columns: `auto 1fr auto`.

- **Brand** (left) — Cabalmail pixel logo + wordmark, links to
  `/inbox` (or wherever the inbox lives). Tile is `accent` background,
  pixel art rendered with `shape-rendering: crispEdges`.
- **Breadcrumbs** (center-left) — `Mail / Rules`, where `Mail` is a
  link and `Rules` is the active crumb.
- **Right cluster** — Help (?) button, then the existing `UserMenu`
  avatar.

#### Help popover

A `?` button in the topbar opens a 360px-wide popover containing the
context that previously lived in a page header. Contents:

- Eyebrow: `HOW RULES WORK` (mono, uppercase, ink-quiet)
- Title: `Sort, file, and forward mail automatically.` (Source Serif 4)
- Body paragraph: `Each rule is checked top-to-bottom against every
  incoming message. The first time all of a rule's conditions match,
  its actions run — and unless you ask it to continue, processing
  stops there.`
- A bullet list of four key points (Conditions, Move/Copy/Archive/Delete,
  Flag/Mark/Forward, Drag for precedence). Inline `<code>`-style chips
  use mono font with a faint accent-tinted background.
- Footer: `CHANGES SAVE AUTOMATICALLY.`

Closes on outside click (same pattern as the existing `UserMenu`).

### Workspace — master / detail

Two-column grid `340px 1fr` (becomes `380px 1fr` at `density:
comfortable`). 1px gap rendered by setting the grid container's
background to `--border`.

#### Master: rules list

Sidebar (`.rules-pane`):

- Header row: `Rules` (display font, 17px/600) + meta `N/M active`
  (mono, 11px, ink-quiet)
- Scrollable list of `.rule-item`s with `grid-template-columns:
  18px 16px 1fr auto`:
  1. Drag handle (`Icon: drag` — 6-dot grip, ink-quiet)
  2. Index number (mono, 10.5px, ink-quiet, accent when selected)
  3. Body — name (13px/600) + description (mono 10.5px, single line,
     ellipsis)
  4. Enable toggle (the tiny variant — 26×15px pill, accent when on)
- Footer: a single `New rule` button (full-width, secondary `.btn`).
- Selected row: `accent-soft` background, index goes accent-colored.
- Disabled row (`enabled === false`): name and description go to
  `ink-quiet`.
- Description format (see `describeRule` in `rules-data.jsx`):
  `from~"aws.amazon.com" & subject~"invoice"  → Receipts  · read`

#### Detail: rule editor

The editor pane is a scrollable column with three numbered sections
plus a footer.

**Editor header**

- Name input — `.rule-name-input`, Source Serif 4 26px/600. No border;
  bottom-border on focus. Placeholder italic, ink-quiet.
- Below the name: `id: r-xxxxxx` (mono, 10.5px, ink-quiet).
- Right of the title block: `ENABLED` / `DISABLED` label (10.5px mono,
  uppercase, accent when on) + the big toggle (32×18px).

**Section 01 — Conditions**

- Section heading: mono `01` + display "When mail arrives that
  matches…" (16px/600) + italic right-hint "all conditions must match (AND)".
- A `.section-card` with one `.cond-row` per condition.
- Each row: `[Field-select with rowLabel]  [value input]  [×]`
  - Field-select shows `From address contains`, `To address contains`,
    `CC address contains`, `BCC address contains`, `Subject contains`,
    `Body contains`. Do **not** render a separate `contains` dropdown.
  - The value input is mono (12.5px) with placeholder
    `name@example.com or substring` for address fields, `substring to
    match` for subject/body.
- The first row has a subtle accent tint (`color-mix(accent 4%,
  surface)`).
- "AND another condition" CTA at the bottom of the card.
- Empty conditions are allowed — show italic copy "No conditions —
  this rule will match every incoming message."

**Section 02 — Actions**

- Heading mono `02` + "…do this" + italic hint "one destination, plus
  any extras".
- A `.section-card.actions-card` with two stacked blocks:

  **Destination (exclusive)** — segmented control with four pills:
  Move to / Copy to / Archive / Delete. Active pill has accent
  background, accent-fg text.
  - When **Move** is active: a `.dest-target` card shows "→ [folder
    select]" beneath the segmented control.
  - When **Copy** is active: a `.dest-target` shows "↳ [folder chips +
    add button]". Adding folders opens an inline `<select>` populated
    with folders not yet picked.
  - **Archive** and **Delete** show nothing beneath.

  **Also** — three auxiliary actions as a 3-column grid of
  `.aux-action` buttons (Flag, Mark as read, Forward). Active state
  flips the icon tile to accent background.

  Below the aux grid: when **Forward** is on, the `.forward-block`
  appears — a chip-input for email addresses. Chips are mono
  11.5px-ish pills; invalid addresses render in danger styling. On
  Enter/comma/space, commit the draft. On Backspace in an empty
  draft, remove the last chip. Show "N addresses are not valid"
  below the chip row when any fail validation.

**Section 03 — Spill-through**

- Heading mono `03` + "After this rule runs…".
- A single `.spillthrough` card: label "Continue to the next rule" + a
  short Source-Serif description (with `<code>` chips on `delete` and
  `move`) + the big toggle on the right.

**Editor footer**

A row of: Duplicate (ghost btn), Delete (danger btn), spacer, "Saved
locally" mono label with a small accent dot.

#### Delete locks down dependent fields

When `rule.action === 'delete'`:

1. The **Also** block (Flag / Mark read / Forward + forward chips) and
   the entire **Spill-through** section get `.is-disabled`:
   `opacity: 0.4; pointer-events: none; filter: saturate(0.6);`
2. The **Also** label flips to the danger color and appends an italic
   note: `· delete is final, so these don't apply.`
3. Stored values are preserved — toggling back to Move/Copy/Archive
   restores the previously-set flag, markRead, forward, continueToNext.

Don't reset state on the action transition; only ignore it at
evaluation time on the server.

#### Empty state

When the user has zero rules, the editor pane becomes a centered
column with:

- A small fake-list "illustration" — 4 thin bars with one accent bar
  and a `→ Receipts` mono caption. Hand-drawn-feeling but built with
  divs + accent color, no SVG.
- Display title: `No rules yet.` (Source Serif 4, 24px/600)
- Reader-font subtitle explaining what rules do.
- A 3-column grid of `.tmpl` cards — quick-start templates (see
  `TEMPLATES` in `rules-data.jsx` for the seed). Clicking one calls
  `addRule(t.build())`.
- A mono `or` divider, then a primary `Start with a blank rule`
  button.

The sidebar in the empty state still renders its header + footer
button + an italic "Your rules will appear here in the order they
run." note. No rule rows.

### Mobile (≤ 760px)

Single-pane swap controlled by a `data-mobile-view` attribute on the
workspace ("list" | "editor").

- Topbar shrinks: brand wordmark + crumbs hidden, logo down to 28×56.
- Workspace becomes 1-column.
- `[data-mobile-view="list"]` hides the editor pane; `[="editor"]`
  hides the rules pane.
- Editor gains a `← Rules` back button at the top that sets
  `mobileView` back to `'list'`.
- Conditions stack: field select on row 1, value input on row 2,
  remove `×` aligned to the right of row 1.
- Action segmented becomes 2×2 grid; dest-target stacks vertically.
- Aux actions become a single column.
- Spillthrough stacks label-then-toggle.
- Tweaks panel becomes a full-width bottom sheet (max-height 60vh,
  internally scrollable). In production the panel goes away — it's an
  authoring affordance only.

At ≤ 420px (phone portrait): the drag handle is hidden (use a long-
press reorder gesture instead in the real app), and the `ENABLED`
label collapses to just the toggle.

## Interactions & behavior

### Selecting a rule
Click anywhere on a `.rule-item` (except the toggle / drag handle / sort arrows / priority input). Selection is single — show selected with `accent-soft` background. On mobile, selection switches `mobileView` to `'editor'`.

### Enable / disable
Toggle on the rule row, and the big toggle in the editor head. Disabled rules still match at the engine level only when explicitly requested by the user — by default, disabled rules are skipped. The list view shows them desaturated.

### Reorder (drag)
HTML5 `dragstart`/`dragover`/`drop`. The hover row shows a 2px accent line on its top or bottom edge depending on whether the cursor is in its upper or lower half. On drop, splice the moved rule into the new position (`above` ⇒ at the target's index, `below` ⇒ at the target's index + 1, after removing the source). Don't allow dropping onto self. See `RulesList.onDrop` in `rules-editor.jsx`.

### Add / Duplicate / Delete
- **Add** appends a `blankRule()` to the end and selects it.
- **Duplicate** inserts a copy directly after the source, named
  `"... (copy)"`, and selects the copy.
- **Delete** confirms via `confirm()` (replace with the codebase's
  modal dialog component in production).

### Auto-save
The prototype writes to `localStorage` on every mutation. In production this maps to a debounced `PUT /api/rules` (200–400ms) or per-mutation calls — the "Saved locally" label in the editor footer should become a real save-state indicator: idle / saving / saved / error.

### Forward validation
Validate on commit (Enter, comma, space, or blur). Don't gate the chip from being added — let the user see invalid chips in danger styling. Surface a count below.

### Keyboard shortcuts (nice-to-have, not in mock)
- `?` opens the help popover (matches the existing `Keyboard shortcuts` item in the user menu)
- `↑/↓` moves selection in the rules list
- `Enter` focuses the name input of the selected rule
- `Esc` closes the help popover / blurs focused inputs

## State management

The prototype uses local React state + localStorage. In production:

- Rules list is server-owned. Fetch on mount, keep a local mutable
  copy, and `PUT` mutations.
- The selected rule id should live in the URL (`?rule=r-xxx`) so deep
  links work.
- Debounce auto-save (300ms) and reflect state in the footer "Saved"
  indicator.
- Use optimistic updates for toggle / reorder, with rollback on
  error.
- Tweaks state (theme, accent, density) is **user preferences** and
  goes wherever the existing inbox stores them — these should be
  shared with the inbox, not duplicated here. The condition / action /
  ordering UI tweaks are authoring-only and should not ship.

## Design tokens

All tokens are inherited from the Stately direction defined in
`inbox-explorations.html`. The handoff CSS reproduces them verbatim.
Do **not** redefine tokens here — pull from the shared design system
file in the real app.

Key tokens used:

| Token              | Light value                          |
| ------------------ | ------------------------------------ |
| `--app-bg`         | `oklch(0.98 0.005 85)`               |
| `--chrome-bg`      | `oklch(0.985 0.006 85)`              |
| `--sidebar-bg`     | `oklch(0.975 0.006 85)`              |
| `--reader-bg`      | `oklch(0.995 0.003 85)`              |
| `--surface`        | `oklch(0.985 0.005 85)`              |
| `--surface-hover`  | `oklch(0.955 0.008 85)`              |
| `--border`         | `oklch(0.9 0.007 85)`                |
| `--border-faint`   | `oklch(0.94 0.005 85)`               |
| `--ink`            | `oklch(0.22 0.015 60)`               |
| `--ink-soft`       | `oklch(0.36 0.012 60)`               |
| `--ink-quiet`      | `oklch(0.55 0.01 60)`                |
| `--danger`         | `oklch(0.5 0.18 25)`                 |
| `--accent (forest)`| `oklch(0.45 0.09 150)`               |
| `--accent-fg`      | `oklch(0.99 0.003 60)`               |

Typography (Stately):

- UI: `Inter`, fallback `system-ui`, `sans-serif`
- Display: `Source Serif 4`, fallback `Fraunces`, `Georgia`, `serif`
- Reader: `Source Serif 4`, `Georgia`, `serif`
- Mono: `IBM Plex Mono`, `monospace`

Spacing & radii:

- Base radius `--radius: 6px`
- Cards (`.section-card`, `.spillthrough`) use `8px`
- Segmented & destination targets use `5–7px`
- Section spacing: 30px between sections (22px at `compact`)
- Editor scroll padding: 32px / 40px desktop, 24px / 32px compact, 16px mobile

Focus state:

```css
--focus: 0 0 0 2px color-mix(in oklch, var(--accent) 40%, transparent);
```
Apply via `box-shadow` on `:focus-visible`.

## Folder list

The folder picker (`Move to → folder`, `Copy to → [chips]`) is a
seeded list in the prototype (`FOLDERS` in `rules-data.jsx`). In
production this should come from the same source as the inbox sidebar
folders pane (`FOLDERS_TREE` + user folders in the existing data
layer). Show nested folders with `Parent/Child` paths or a hierarchy —
the prototype uses flat `Work/Cabalmail`-style paths.

## Assets

- **Cabalmail brand logo** — pixel art SVG path, identical to the one
  in `App.jsx > LOGO_PATH_D` of the inbox. Reuse the existing
  component, don't copy.
- **Icons** — single-source stroke icons (`<Icon name="...">`).
  Reuse the existing `icons.jsx` from the inbox. New icons added for
  this page: `rules`, `help`, `drag`, `duplicate`, `keyboard`,
  `arrowRight`, `copy`. Their SVG paths are in `rules-data.jsx` and
  should be merged into the central icon set.

## Files in this bundle

- `rules.html` — page shell, loads React + 3 babel scripts
- `rules.css` — all styles (tokens are duplicated for preview; in
  production, import shared tokens + only the page-specific rules)
- `rules-data.jsx` — `FIELDS`, `FOLDERS`, `SEED_RULES`, `TEMPLATES`,
  `Icon`, `describeRule`, `isValidEmail`, `blankRule`
- `rules-editor.jsx` — `RulesList`, `RuleEditor`, the three
  `Conditions*` variants, the three `Actions*` variants, `EmptyState`,
  `TweaksPanel`
- `rules-app.jsx` — `App`, `UserMenu`, `HelpMenu`, top-level state
  management, persistence, host postMessage hooks (Tweaks panel only —
  remove from production)

The Tweaks panel and its three "style" tweaks (Conditions / Actions /
Ordering) **do not ship**. Pick the production setting per the table
in the Fidelity section and delete the alternates.

## Acceptance checklist

- [ ] User menu has `Mail rules…` between Accent color and Preferences,
      and renders `.current` on the rules page.
- [ ] Sidebar lists rules in precedence order; drag-reorder works.
- [ ] Add / Duplicate / Delete / Enable toggle on each rule.
- [ ] Conditions are field-rows with `<field> contains` selects and a
      single value input. No separate `contains` dropdown.
- [ ] Action segmented control has Move / Copy / Archive / Delete and
      enforces mutual exclusion.
- [ ] Move shows a single folder select; Copy shows folder chips with
      add.
- [ ] Flag / Mark read / Forward are independent toggles when action
      ≠ delete; disabled when action = delete.
- [ ] Forward expands a chip input with email validation.
- [ ] Spill-through is a single "Continue to next rule" toggle;
      disabled when action = delete.
- [ ] Empty state shows three templates + blank CTA when no rules.
- [ ] Help popover replaces the in-page header copy.
- [ ] Mobile (≤ 760px) collapses to single pane with a back button.
- [ ] All copy matches the prototype exactly unless explicitly noted.

