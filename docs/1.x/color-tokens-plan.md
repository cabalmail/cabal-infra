# Colour tokens: implementation plan

**Status:** planning. The audit ([color-audit.md](color-audit.md)) and the
Design brief ([design_handoff_color_tokens/](design_handoff_color_tokens/README.md))
are complete; palette values are with Claude Design.

## Progress

| # | Work item | Owner | Status |
|---|---|---|---|
| 1 | Audit and census | Claude Code | done 2026-09-07 |
| 2 | Token schema, checker, candidate values | Claude Code | done 2026-09-07 |
| 3 | Palette values | Claude Design | pending |
| 4 | Correctness check and fold-in | Claude Code | pending 3 |
| 5 | Token source of truth and generators | Claude Code | pending 4 |
| 6 | Apple adoption | Claude Code | pending 5 |
| 7 | Android adoption | Claude Code | pending 5 |
| 8 | React adoption | Claude Code | pending 5 |
| 9 | Tester re-measure | tester | pending 6, 7, 8 |

## Principles

- **Contrast is the requirement; darkening is the mechanism.** A token clears
  a floor against every surface it is drawn on, in both schemes, or the build
  fails. Whether that means darker in light and lighter in dark falls out.
- **Uniform at the token, not the value.** A green toast fill and a green
  flag glyph are the same meaning in different roles, and get different values.
- **One source of truth, generated outward.** `design/color-tokens.json`
  generates the Apple asset catalog, the Android colour resources, and the
  React custom properties. No client holds a hand-typed semantic colour.
- **Colour is never the sole carrier.** Every semantic site keeps its glyph or
  word. This is what makes accent collisions on Android survivable.
- **Names are data.** Flag names and accent names on the wire never change.

## Work items

### 1. Audit and census

**Status:** done. See [color-audit.md](color-audit.md) and the three census
files under `color-audit/`.

### 2. Token schema, checker, candidate values

**Status:** done. `scripts/check-color-tokens.py` and
`design_handoff_color_tokens/color-tokens.json`. The checker reproduces the
tester's measured ratios from #1453 and #1456 to the hundredth. Candidate
values clear every floor; they are placeholders for Design.

### 3. Palette values

**Status:** pending. Claude Design replaces every candidate value in the JSON
per the brief. Setup: run `/design-login` once from an interactive Claude
Code session on this machine so `/design-sync` can push the handoff folder as
a design-system project; until then the folder is the handoff.

### 4. Correctness check and fold-in

**Status:** pending item 3. Run the checker on the returned JSON; zero
failing pairs is the acceptance test. Then:

- Confirm `brand.forest` and `accent.forest.*` are still the logo values.
- Confirm no `.fg` token is within a just-noticeable difference of another
  family's `.fg` in the same scheme (a quick ΔE in OKLab, add to the checker
  if it is not obvious by eye).
- Record the accepted values in this document's item 5 and move the JSON to
  its permanent home.

### 5. Token source of truth and generators

**Status:** pending item 4.

- Move the JSON to `design/color-tokens.json` at the repository root.
- `scripts/generate-color-tokens.py` writes:
  - `apple/Cabalmail/Assets.xcassets/Colors/<token>.colorset/Contents.json`
    for iOS, macOS, and visionOS, with light and dark, and High Contrast
    variants where the JSON supplies `light-hc`/`dark-hc`. The watch target
    gets the dark values as its universal value.
  - `android/app/src/main/res/values/color_tokens.xml` and
    `values-night/color_tokens.xml`, plus a generated Kotlin object exposing
    them as `Color` for Compose.
  - `react/admin/src/tokens.css` defining `--<token>` for light and dark.
- Each client gains a drift test that regenerates into a temp dir and diffs,
  in the style of the Linux client's `CABALMAIL_UPDATE_DOCS` check:
  `CabalmailTests`, `:app:test`, and Vitest respectively.
- A `scripts-tests.yml` job runs the checker on `design/**` changes with
  `--fail-under`, so a value edit that breaks a floor fails the PR.

### 6. Apple adoption

**Status:** pending item 5. Ordered by the measured failures.

- Replace every `.red`, `.orange`, `.yellow`, `.green`, `.blue` in the
  census with the token: `danger.fg` for error labels and the important
  marker, `danger.fill` for destructive swipe actions and dispose tints,
  `warning.fg` for the nine warning sites and auth-bad, `success.fg` for
  RulesView, the watch Created label, and the auth-ok chip, `info.fg` for
  info toasts, log info, Restore and Read swipes, `flagged.fg` for the flag
  glyph and favourite star and swipe.
- `ToastBanner.tint`, `AuthResultsLine.color(for:)`, `DebugLogView.tint(for:)`
  and `LogRow.tint` map their enums to tokens.
- The auth chip wash becomes `<meaning>.wash`, not the foreground at 0.12.
- Retire `WarningTint` and `AttachmentWarningTint` and their tests; keep the
  `WarningTintSourceScanTests` idea as a scan that forbids the platform
  colour names in the two app targets, with the allowlist reduced to the
  flag-palette swatch mapping (which itself moves to `flag.<name>`).
- `AccentColor` in all three asset catalogs becomes `accent.forest` (the logo
  values). `HTMLRewrite` link colours and `SidebarBranding` swatches are
  generated from the tokens.
- Selection washes (`0.15`, `0.18`, `0.20`) collapse to `accent.forest.wash`.
- `FlagPaletteColor.color(for:)` maps names to `flag.<name>`.
- `AvatarView` pastels become `swatch.*` and `swatch.ink`.
- Delete the six unused `CabalmailTokens` colours.
- Changelog fragment with the `Apple:` prefix. Run `CabalmailMacTests` and
  the iOS build sanity check before merging.

### 7. Android adoption

**Status:** pending item 5.

- Introduce `warning`, `success`, `info`, `flagged` as Compose colours from
  the generated resources, independent of the ColorScheme so they survive
  Material You. `error` sites that mean warning (attachment size, offline
  banner) move to `warning.*`; `secondaryContainer` for the auth-pass chip
  moves to `success.wash`; `tertiary` for flagged and favourite moves to
  `flagged.fg`.
- The Forest seed becomes the logo value. Amber is adjusted per Design.
- `flagColor(...)` maps to `flag.<name>` from resources, theme-qualified.
- The reader CSS link colour is generated from `accent.forest.fg`.
- The sender avatar HSV hash moves to `swatch.*` with `swatch.ink`.
- Changelog fragment with the `Android:` prefix; headline under 40 chars.
  Run `ktlintCheck lint` and `:app:testDebugUnitTest`.

### 8. React adoption

**Status:** pending item 5. React is second-class, but it owns the accent
definitions and the only existing semantic tokens, so it must not drift.

- `AppLight.css`/`AppDark.css` import the generated `tokens.css`. `--accent`
  per `data-accent` is defined from `accent.<name>.fg`; `--accent-soft` from
  the wash; `--accent-fg` from on-fill. `--ink-danger` becomes an alias of
  `danger.fg`.
- Define `--success`, `--warning`, `--info`, `--flagged` and their fills and
  washes. The compose warning strip uses `warning.wash` with `warning.fg`
  text; the undefined `--accent-softer` and `--danger` references are removed.
- `--auth-ok` becomes `success.fg`; the DMARC page's fixed greens and reds
  become `success.*` and `danger.*`.
- The info toast uses `info.fill` and `info.on-fill`; add success and warning
  toast variants while there.
- `addressSwatch.js` maps to `swatch.*` with theme-aware values.
- The accent picker swatches in `Nav.css` read the tokens instead of
  duplicating twelve literals.

### 9. Tester re-measure

**Status:** pending items 6 to 8. The tester's next full sweep re-measures
the sites that were measured in #1297, #1318, #1453, and #1456 on each
client, plus one site per new token family. Issues stay open until the
re-measure clears them.

## Out of scope

- The Linux client. The token file and generator are shaped for it (a
  `cabalmail-gtk` CSS export is a small addition) but nothing in `linux/` is
  touched until its owner picks it up.
- Neutral greys and surfaces.
- The React attachment-family badges and sidebar wash blobs.
