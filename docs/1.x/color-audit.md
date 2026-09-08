# Colour audit: semantic colour across the clients

**Date:** 2026-09-07. **Scope:** the Apple clients (iOS, iPadOS, macOS, visionOS,
watchOS), the Android client, and the React admin app. The Linux client is
excluded for now; the token file is shaped so it can consume it later.
**Output:** the token proposal in `design_handoff_color_tokens/` and the
implementation plan in [color-tokens-plan.md](color-tokens-plan.md).

## Why

Three ad-hoc tint rules landed in the Apple app in ten days (`FolderNameTint`
#1297, `FolderIconTint` #1318, `WarningTint` #1453/#1456), each fixing one
measured contrast failure by adjusting one colour at one site. The sweep for
#1456 (PR #1461) had to retune a shared constant to satisfy its worst-case
site, which changed the pixel a merged fix had shipped. That is the signature
of a missing palette: every semantic colour is chosen at its call site, from
platform defaults that were never designed as text on white.

This audit records every site, groups them by meaning and role, and proposes
one cross-platform token set for Claude Design to fill in.

## Method

Three per-client censuses, one row per site, with role, meaning, the
background it is drawn on, and appearance handling:

- [census-apple.md](color-audit/census-apple.md) — 150 sites
- [census-android.md](color-audit/census-android.md) — 133 sites
- [census-react.md](color-audit/census-react.md) — 364 rows (tokens, surfaces, uses)

Contrast is computed by `scripts/check-color-tokens.py`, which uses the same
WCAG maths as the tester's screenshot instrument. It reproduces every ratio the
tester reported in #1453 and #1456 to the hundredth (2.31, 5.04, 6.53, and the
composited chip at 5.48), so its numbers are the numbers the screen produces.
`color-audit/baseline-current.json` holds the colours shipping today and
`color-audit/baseline-report.txt` is the checker's output for them.

## Findings

1. **Every Apple semantic colour is a platform default, and every one fails
   on white.** `.red` (20 sites) measures 3.55:1, `.orange` 2.31:1, `.green`
   2.22:1, `.yellow` 1.51:1, `.blue` 4.02:1. The dark appearance is not clean
   either: `.red` and `.blue` fail on the dark form row at 4.09:1 and 3.82:1.
   The orange sweep in #1456 is the tip of this.
2. **Android has no warning colour.** Warnings (attachment size, offline
   banner) draw in Material's error red. Success and flagged are derived from
   the accent seed, so they cannot be told from the accent, and under Material
   You (on by default) they follow the wallpaper.
3. **React's warning strip is unreadable in dark mode.** The attachment-size
   warning is a fixed pale yellow behind theme ink, 1.12:1 in dark. It relies
   on an undefined custom property. The DMARC page uses fixed Material greens
   and reds that fail in dark at about 3:1.
4. **Forest Green has three values.** Logo tint `#2E5235`/`#8DC899` on Apple
   and Android; accent Forest `#2B633A`/`#79C289` on Apple and React; Android's
   accent Forest seed `#1F5B3A`. They are near-identical greens that are not
   the same, the worst of both outcomes.
5. **The accent choice is not a synced preference.** Apple pins Forest as its
   accent. Android has a local six-seed picker that Material You overrides by
   default. React has its own six-accent picker. So "distinct from the accent"
   means distinct from Forest on Apple, from any of six on React, and from
   anything at all on Android.
6. **Like meanings use unlike colours across clients.** Auth failure is orange
   on Apple, red on Android and React. Success is system green on Apple, the
   accent on Android and React. Flagged is orange on Apple, accent-derived on
   Android, accent on React. The user flag palette is ten system colours on
   Apple and ten fixed Material 700 hexes on Android.
7. **The accent wash has five opacities.** Selection and toggle washes draw
   the accent at 0.10, 0.12, 0.15, 0.18, and 0.20 across the three clients.
8. **Two current accent values fail as text.** React's Amber accent measures
   4.37:1 on a hovered row in light. React's Oxblood measures 4.33:1 on the
   Apple sidebar value in dark. Android's Amber primary measures 4.34:1 on the
   Material surface. These are Design's to adjust in the same pass.

## Cross-client census by meaning

| Meaning | Apple | Android | React |
|---|---|---|---|
| success | `.green` at RulesView, watch Created, success toast, auth-ok chip | `secondaryContainer` (accent-derived) auth-pass chip | `--auth-ok` hard-copies the Forest accent; DMARC `#2e7d32` fixed |
| warning | `.orange` at 9 sites, now `WarningTint` (#1461) | none: `error` red for attachment size, `errorContainer` for offline | none: fixed `#fff8e1` strip; DNS-check amber hue 80 |
| danger / error | `.red` at 20 sites: error labels, destructive swipes, remove buttons, important | `error` at 28 sites, `errorContainer` at 5 | `--ink-danger` at 21 sites; undefined `--danger` falls back to `#b00020`; DMARC `#c62828` |
| info | `.blue`: info toast, log info, Restore and Read swipes | none | none: info toast uses the accent |
| unread | `AccentColor` dot and folder name | `primary` dot and folder name | `--accent` dot |
| selected | accent wash at 0.15, 0.18, 0.20 | `secondaryContainer`, `primary` wash | `--accent-soft` at 10% light, 15% dark |
| flagged (`\Flagged`) | `.orange` flag glyph | `tertiary` (accent-derived) star | `--accent` |
| favourite address | `.yellow` star, `.yellow` swipe | `tertiary` star | n/a |
| important | `.red` glyph | n/a | `--ink-danger` glyph and rail |
| auth-bad | `.orange` glyph, sentence, and chip | `error` glyph, `errorContainer` chip | `--ink-danger` chip |
| link | `#2b633a`/`#79c289` restating the accent | `#2e6b30`/`#9ccc9c` reader CSS | `--accent` |
| brand / logo | `LogoTint` `#2E5235`/`#8DC899`; six unused Kit tokens | `logo_forest`/`logo_mint`, same values | favicon and manifest cream only |
| accent | fixed Forest `#2B633A`/`#79C289` | six seeds, Forest `#1F5B3A`; Material You on by default | six OKLCH accents, Forest default `oklch(0.45 0.09 150)` = `#2B633A` |
| user flag palette | ten system colours by name | ten fixed Material 700 hexes by name | none (no flag colours) |
| sender / address swatch | ten fixed pastels with a warm ink | HSV from a hash, white initials | four accent lights, fixed in both themes |
| log level | gray, blue, orange, red | n/a | n/a |
| attachment family | `.tint` | n/a | oxblood, azure, amber, forest by file type |

## Different but should be similar

- **Auth failure.** Orange on Apple, red on Android and React. Proposed:
  `warning`. It is advisory about the message, not a failure of the app, and
  red stays reserved for errors and destructive actions.
- **Success.** System green, accent-derived, and a Forest copy. Proposed: one
  `success` token on all three.
- **Flagged and favourite.** Orange flag, yellow star, accent star, accent
  flag. Proposed: one `flagged` token, gold, for both the `\Flagged` indicator
  and the favourite star.
- **Warning.** Apple has one, Android and React do not. Proposed: `warning`
  on all three, replacing Android's error red for warnings and React's fixed
  yellow strip.
- **Info.** Only Apple has one. Proposed: `info` on all three, so React's
  info toast stops borrowing the accent.
- **Forest.** Three values. Proposed: one, the logo's, everywhere.
- **User flag palette.** Two value sets for one wire vocabulary. Proposed:
  one `flag.<name>` set with light and dark values, used as fills only.
- **Accent wash.** Five opacities. Proposed: one wash token per accent.
- **Sender swatches.** Three unrelated schemes. Proposed: one `swatch.*` set
  with a shared `swatch.ink`, with Apple's pastels as the starting point.

## Similar but should be different

- **Success versus Forest.** React's auth-pass chip and Android's success
  container are the accent green, so a passing check reads as a selected or
  interactive element. Success gets its own green, distinct from Forest in
  lightness and chroma, not just hue.
- **Danger versus Oxblood, warning versus Amber, info versus Azure.** With a
  user-selectable accent, any semantic hue can coincide with the accent. The
  palette keeps them apart where it can, and every semantic state also carries
  a glyph or a word, so colour is never the sole carrier (WCAG 1.4.1). On
  Android under Material You this is the only guarantee available.
- **Warning versus flagged.** Both are orange on Apple today. The flag becomes
  gold so a flagged message does not look like a warning.
- **Error state versus destructive control.** Same hue, different roles: text
  on a surface versus a filled control with text on it. One meaning, two
  roles, two values.
- **Accent as text versus accent as fill.** Unread names need 4.5:1 on the
  surface. Primary buttons need 4.5:1 for the label on the fill. These
  constrain the same colour from opposite sides; the token set separates
  `accent.<name>.fg`, `.fill`, `.on-fill`, and `.wash`.

## Forest Green

The brand colour is the logo tint: `#2E5235` in light, `#8DC899` in dark.
Proposed rule: every green either equals it or is visibly distinct from it.

- `brand.forest` and `accent.forest` become the same value. Apple's
  `AccentColor` and React's Forest accent move from `#2B633A`/`#79C289` to the
  logo values; Android's Forest seed moves from `#1F5B3A`. The contrast cost
  is nil: `#2E5235` is 8.84:1 on white and `#8DC899` is 8.79:1 on the dark row.
- `success` is a different green, and the brief asks Design to make it read as
  "go" rather than "brand" at a glance.
- Reader link colours on Apple and Android restate the accent by hand and
  will be generated from the token file instead.
- The six unused brand tokens in CabalmailKit (`cmForest`, `cmForestDeep`,
  `cmCream`, `cmParchment`, `cmInk`, `cmInkSoft`) are retired; the cream and
  parchment values survive only in the favicon and PWA manifest.

## Proposed tokens

A token is meaning × role × appearance. The full set with candidate values
is `design_handoff_color_tokens/color-tokens.json`; the brief for Design is
[the README beside it](design_handoff_color_tokens/README.md).

| Family | Tokens | Floor |
|---|---|---|
| `brand.forest` | one | 4.5:1 as a glyph on any surface |
| `accent.<ink,oxblood,forest,azure,amber,plum>` | `.fg`, `.fill`, `.on-fill`, `.wash` | fg 4.5:1 on every surface; on-fill 4.5:1 over the fill; wash measured through the fg drawn on it |
| `success`, `warning`, `danger`, `info`, `flagged` | `.fg`, `.fill`, `.on-fill`, `.wash` | same as accent |
| `flag.<red … gray>` | one fill each | 3:1 non-text; used only for dots and swatches beside a name |
| `swatch.<ten>` + `swatch.ink` | fills and one ink | ink 4.5:1 over every swatch |

Things that are deliberately not tokens: unread, selected, and link are
roles of the accent, not colours. Log levels map onto info, warning, danger,
and a neutral. The important marker uses `danger.fg` to match the Mail
convention. Attachment-family badges in React reuse accent values and are
left alone.

The candidate values clear every floor on every surface in both schemes; the
checker's report is `color-audit/candidate-report.txt`. Design owns the final
values and the checker owns the verdict.

> **Update (2026-09-07):** Claude Design returned final values the same
> day; they pass the checker with zero failing pairs, including the
> high-contrast variants (`color-audit/final-report.txt`). Findings from the
> acceptance pass are recorded under item 4 of
> [color-tokens-plan.md](color-tokens-plan.md).

## Baseline

Selected rows from `color-audit/baseline-report.txt`, light appearance on
white unless stated:

| Colour today | Ratio |
|---|---|
| Apple `.red` | 3.55 (dark form row 4.09) |
| Apple `.orange` | 2.31 (chip wash 2.09) |
| Apple `.yellow` | 1.51 |
| Apple `.green` | 2.22 |
| Apple `.blue` | 4.02 (dark form row 3.82) |
| Apple `WarningTint` at 0.65 on the sidebar | 4.16 |
| React Amber accent on a hovered row | 4.37 |
| React warning strip ink, dark theme | 1.12 |
| React DMARC pass and fail, dark theme | 3.04 to 3.73 |
| Android Amber primary on surface | 4.34 |
| Android flag yellow, orange, green on surface | 1.92, 2.64, 4.01 |

## Not changed by this audit

- The React attachment-family badges, sidebar wash blobs, and the favicon
  and manifest cream.
- Neutral greys: `.primary`/`.secondary`, Material `onSurface*`, React `--ink*`
  and surfaces. They are the backgrounds the tokens are measured against, not
  tokens themselves.
- The stored names in the user flag palette and the accent preference wire
  values. Names are user data; only their rendered values change.
- Colour as the sole carrier of state. Every semantic site already pairs its
  colour with a glyph or a word, and the plan keeps it that way.
