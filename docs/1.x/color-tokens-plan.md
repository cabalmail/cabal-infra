# Colour tokens: implementation plan

**Status:** Apple and Android adoption shipped to stage; React adoption in review 2026-09-08; only the tester re-measure remains. The audit
([color-audit.md](color-audit.md)) and the Design brief
([design_handoff_color_tokens/](design_handoff_color_tokens/README.md)) are
complete and Claude Design's palette passed the acceptance check.

## Progress

| # | Work item | Owner | Status |
|---|---|---|---|
| 1 | Audit and census | Claude Code | done 2026-09-07 |
| 2 | Token schema, checker, candidate values | Claude Code | done 2026-09-07 |
| 3 | Palette values | Claude Design | done 2026-09-07 |
| 4 | Correctness check and fold-in | Claude Code | done 2026-09-07; see findings under item 4 |
| 5 | Token source of truth and generators | Claude Code | done 2026-09-07 |
| 6 | Apple adoption | Claude Code | done 2026-09-07 (#1471) |
| 7 | Android adoption | Claude Code | done 2026-09-07 (#1473) |
| 8 | React adoption | Claude Code | in review 2026-09-08 |
| 9 | Tester re-measure | tester | next |

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

**Status:** done. The handoff folder was pushed to the "Design System"
project in Claude Design on 2026-09-07 and Claude Design returned
`color-tokens.json` with every value marked `final`, in OKLCH, including
`light-hc`/`dark-hc` high-contrast variants for every `.fg` token and for
`brand.forest`. It also generated its own design system around it
(component previews, per-platform UI kits, guideline pages); those are
Design's artefacts and stay in the project. The JSON is the contract and is
now the file in `design_handoff_color_tokens/`.

### 4. Correctness check and fold-in

**Status:** done. The checker reports zero failing pairs on the returned
JSON in both schemes, and zero with `--hc` (the high-contrast variants
checked against the same surfaces). `color-audit/final-report.txt` is the
run. `brand.forest` and `accent.forest.*` are the logo values to the byte.

Findings recorded for the implementer:

- **Dark values sit on the floor.** Every family's dark `.fg` measures
  4.50 to 4.53:1 on its hardest dark surface, the sidebar at (58,58,60); on
  the row and form surfaces they have 6:1 or more. That is within the
  contract, but a rounding difference at export could flip one (the #1457
  review found 0.02 of ratio in a rounding mode). The generator in item 5
  must round OKLCH to sRGB the same way the checker does and the drift test
  must re-run the checker on the *exported* sRGB values, not the OKLCH
  source. If any exported dark value lands under 4.5 the fix is to raise
  that token's dark lightness by 0.01 to 0.02, not to relax the floor.
- **Expected near-collisions, all accepted by the brief.** In OKLab, Amber
  accent versus `warning.fg` (ΔE 0.04 in both schemes), Amber versus
  `flagged.fg` (0.05), Oxblood dark versus `danger.fg` dark (0.03), and
  Azure versus `flag.blue` (0.02, a dot beside a name). Amber and Oxblood are
  selectable accents on the web and Android only; Apple's accent is Forest.
  Every affected site carries a glyph or a word, which the adoption items
  must preserve.
- **Flag fills sit next to their semantic siblings.** `flag.green` is near
  `success.fg`, `flag.red` near `danger.fg`, `flag.yellow` near
  `flagged.fg`. Flags are dots and swatches beside a name, never text, so
  this is fine; it is noted so nobody reads it as a defect later.
- **Success is distinct from Forest.** ΔE 0.10 light, 0.14 dark, with higher
  chroma and a yellower hue; it reads as "go".

### 5. Token source of truth and generators

**Status:** done. `design/color-tokens.json` is the source of truth (the
handoff copy stays as the record of what Design returned) and
`scripts/generate-color-tokens.py` exports it. Two things landed differently
from the sketch above, each for a reason found on the way:

- **One Apple catalog in CabalmailKit, not per app target.** All four app
  targets depend on the Kit, so
  `apple/CabalmailKit/Sources/CabalmailKit/Design/ColorTokens.xcassets` (one
  colorset per token, `.process`ed by the package) serves iOS, iPadOS,
  macOS, visionOS and watchOS at once. Each colorset carries the light and
  dark values, their Increase Contrast variants under the `contrast: high`
  appearance, and a `watch` idiom entry holding the dark values, since
  watchOS has no light appearance. Wash tokens carry their 12% alpha. The
  generated `ColorTokens.swift` beside it exposes `ColorTokens.dangerFg`,
  `ColorTokens.flag(named:)`, and `ColorTokens.accent(named:)`.
- **Android exports light/dark pairs, not `values-night`.** The Android
  theme resolves dark from the app's own preference (System/Light/Dark),
  so a `values-night` qualifier would follow the system and disagree with
  the chrome. `res/values/color_tokens.xml` holds `token_<name>_light` and
  `_dark`, and the generated `ui/theme/ColorTokens.kt` picks one via a new
  `LocalDarkTheme` composition local that `CabalmailTheme` now provides,
  the same rule the logo tint already follows.
- `react/admin/src/tokens.css` defines `--<name>` under the `stately`
  direction root, dark under the OS media query like `AppDark.css`, and the
  Increase Contrast variants under `prefers-contrast: more`. Wash tokens are
  `color-mix` at 12%. `App.jsx` imports it beside the theme files.
- **The generator checks its own exports.** Before writing, it runs the
  checker over the 8-bit sRGB values Apple and Android will draw, normal
  and high-contrast, and refuses to write if any pair dips under its floor.
  That is the answer to the item-4 finding about dark values on the floor.
- **Drift tests** run the generator in `--check` mode (regenerate, diff):
  `ColorTokensDriftTests` in the Kit suite (which also asserts the catalog
  compiled into the resource bundle), `ColorTokensDriftTest` in `:app:test`,
  and `src/tokens.test.js` in Vitest. `scripts-tests.yml` runs the checker
  and the same drift check on any `design/**` change.

### 6. Apple adoption

**Status:** done (#1471). Every site in the census now reads a token; the
list below is what was done, kept as the record. Two departures from the
sketch: the `AccentColor` and `LogoTint` colorsets in the app targets are
now *generated* from `accent.forest` / `brand.forest` rather than replaced
by hand, so `.tint` and `Color.accentColor` stay Forest without drift; and
the source scan that replaced `WarningTintSourceScanTests` forbids every
platform colour name (red, orange, yellow, green, blue, teal, indigo,
purple, pink) and `Color("AccentColor")` across all three app targets,
with an empty allowlist. `.gray` stays permitted as the neutral for the
debug log level and the un-favourite swipe.

Live check, iPad Pro 11" (M5) simulator, iOS 26.5, Light theme, INBOX with
the one flagged message, measured with the tester's instrument on the same
pixel box the #1461 verification used:

| site | pixel | predicted | contrast |
|---|---|---|---|
| flag glyph, `flagged.fg` | (124, 89, 0) | `#7C5900` | 6.39:1 on white |
| unread dot, `accent.forest.fg` | (46, 82, 53) | `#2E5235` | 8.84:1 on white |
| resume toast glyph, `info.fg` | (0, 105, 125) | `#00697D` | 5.17:1 on the capsule |

Every pixel landed on the exported value to the byte. Pre-change the flag
glyph measured 2.31:1 at the same box (#1456). The other converted sites
are code reads; the tester's re-measure (item 9) covers them.

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
  values); the generator can emit those colorsets too, or the sites can read
  `ColorTokens.accentForestFg`. `HTMLRewrite` link colours and
  `SidebarBranding` swatches read the tokens.
- Selection washes (`0.15`, `0.18`, `0.20`) collapse to `accent.forest.wash`.
- `FlagPaletteColor.color(for:)` maps names to `flag.<name>`.
- `AvatarView` pastels become `swatch.*` and `swatch.ink`.
- Delete the six unused `CabalmailTokens` colours.
- Changelog fragment with the `Apple:` prefix. Run `CabalmailMacTests` and
  the iOS build sanity check before merging.

### 7. Android adoption

**Status:** done (#1473). As sketched, with these specifics:

- Warning sites (attachment size, offline strip) read `warning.*`; the
  auth chips read `success.wash`/`success.fg` and `warning.wash`/
  `warning.fg`; the flag star, the favourite star, and the compose From
  picker's ★ read `flagged.fg`. All are token accessors, independent of the
  `ColorScheme`, so they hold under Material You.
- The six accent seeds are the `accent.<name>.fg` light tokens, read from
  the generated resources, so Forest is the logo's Forest and Amber is
  Design's adjusted value. The derived scheme (lighten/darken) is unchanged.
- `flagColor(...)` is a composable that delegates to `ColorTokens.flag`.
- The kit module is UI-free, so the generator also writes
  `com.cabalmail.kit.design.ColorTokenHex` (plain hex constants); the
  reader stylesheet takes its link colour from it.
- Sender avatars pick one of the ten `swatch.*` tokens by address hash and
  draw the initial in `swatch.ink`, replacing the HSV hash and white text.
- Material's `error` role stays for errors and destructive actions
  (`Delete`, `Revoke`, `Purge`, the dispose swipe): it is contrast-managed
  by Material in both schemes and under dynamic colour, and the audit
  scoped Android's move to the sites that meant something other than
  error. A later pass may align it with `danger.*` for cross-client
  uniformity; it is not a contrast defect today.

Live check, Pixel 8 emulator (API 35), Material You on, light theme, INBOX,
measured with the tester's instrument:

| site | pixel | predicted | contrast |
|---|---|---|---|
| auth-failure triangle, `warning.fg` | (149, 63, 0) | `#953F00` | 6.67:1 on the surface |
| flag star (Flagged filter), `flagged.fg` | (124, 89, 0) | `#7C5900` | 6.07:1 on the surface |

Both landed on the exported value to the byte, and the star is the same
gold the iPad drew for its flag glyph. Pre-change the triangle was
Material's error red and the star the accent's tertiary tone.

### 8. React adoption

**Status:** in review. React is second-class, but it owns the accent
definitions and the only existing semantic tokens, so it must not drift.

- `App.jsx` imports the generated `tokens.css` beside the theme files (since
  #1470). Each `data-accent` rule now aliases `--accent`, `--accent-fg` and
  `--accent-soft` to its token's fg, on-fill and wash, which carry their own
  light and dark values, so `AppDark.css` no longer holds an accent block.
  `--ink-danger` is an alias of `--danger-fg` in both themes.
- The token names are used directly at sites (`--warning-fg`, `--success-wash`
  and so on) rather than through a second set of aliases. The compose
  warning strip is `warning.wash` with `warning.fg` text and a 40% `fg`
  border; the undefined `--accent-softer` and `--danger` references are gone.
- `--auth-ok` is `success.fg`; a failing chip and the list's auth-warning
  indicator are `warning.fg` (the audit's auth-bad decision, matching Apple
  and Android). The DMARC page's verdicts are `success.fg` / `warning.fg`
  and its DNS-check banners the wash/fg pairs, with the dark overrides
  removed. The flag indicator is `flagged.fg`.
- The error toast and the destructive confirm button are `danger.fill` /
  `danger.on-fill`; the info toast is `info.fill` / `info.on-fill`. Success
  and warning toast variants are not added: the toast API has only an
  `error` flag today and nothing would call them.
- `addressSwatch.js` keeps four accents but as the theme-aware token vars.
  The `swatch.*` avatar pastels were tried on paper and rejected for this
  site: a 10px identity dot in a pastel would sit near 1.3:1 on the pane,
  while the accent fg tokens hold 4.5:1 or better.
- The accent picker swatches in `Nav.css` read the tokens; the twelve
  literals and their dark block are gone.
- Left alone, as the audit recorded: the attachment-family badges (they reuse
  accent light values as fixed fills with their own contrast story) and the
  legacy `prefers-color-scheme` rules marked "do not extend".

Rendered check, headless Chrome on a probe page that loads the real
stylesheets (`tokens.css`, both theme files, and the compose, reader,
envelope, DMARC and nav sheets) with `data-accent="forest"`, light scheme,
measured with the tester's instrument:

| element | pixel | predicted | contrast |
|---|---|---|---|
| compose warning strip text on its wash | (149, 63, 0) | `#953F00` | 5.82:1 |
| auth pass chip text on its wash | (0, 112, 33) | `#007021` | 5.25:1 |
| auth fail chip text on its wash | (149, 63, 0) | `#953F00` | 5.82:1 |
| flag indicator on white | (124, 89, 0) | `#7C5900` | 6.39:1 |
| DNS-check ok banner text on its wash | (0, 112, 33) | `#007021` | 5.25:1 |
| error toast, on-fill over fill | (253, 251, 250) on (170, 24, 22) | `#AA1816` fill | 7.14:1 |
| Amber picker swatch | (145, 79, 0) | `#914F00` | fill |
| Forest accent | (46, 82, 53) | `#2E5235` | fill |

Chrome's OKLCH conversion lands on the checker's sRGB to the byte, and the
`var()` and `color-mix()` chains resolve; the pre-change warning strip was
1.12:1 in the dark theme and the pass chip was the accent green.

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
