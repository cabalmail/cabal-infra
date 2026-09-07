# Handoff: Colour tokens (Cabalmail)

## Overview

Cabalmail needs one semantic colour palette shared by its native Apple
clients (iOS, iPadOS, macOS, visionOS, watchOS), its Android client, and its
React web client, in a light and a dark appearance. Today each client picks
semantic colours at the call site from platform defaults, and most of them
fail WCAG AA as text on the surfaces they are drawn on (the audit is
[../color-audit.md](../color-audit.md)).

This handoff asks for **values**, not components. The token names, roles,
and the surfaces each token must clear are fixed by the engineering side and
live in `color-tokens.json` beside this file. Every value in that file marked
`"status": "candidate"` is a placeholder that clears the floors but was not
chosen for beauty. Replace them. Values marked `"current"` ship today and may
also be adjusted where the brief says so.

## Deliverable

`color-tokens.json` with every candidate value replaced, in OKLCH (the web
client already uses it and it keeps lightness honest across hues). Engineering
exports sRGB for Apple and Android from the same file, so do not hand-tune
per platform.

Verification is mechanical: from the repository root,

```
python3 scripts/check-color-tokens.py docs/1.x/design_handoff_color_tokens/color-tokens.json
```

prints every token against every surface it is drawn on in both schemes and
ends with the count of failing pairs. The deliverable is accepted when that
count is zero. If a value you want cannot clear a floor, say which pair and
why; the floor may be wrong for that role, but that is a conversation, not a
silent exception.

## The brand colour

Forest Green is the logo colour: `#2E5235` in light, `#8DC899` in dark
(`brand.forest`). Keep it exactly. The Forest accent (`accent.forest.*`)
adopts the same value, so there is one Forest. Every other green in the
palette must be visibly distinct from it, and `success` in particular should
read as "go" rather than "brand" at a glance: different lightness and chroma,
not only a hue shift.

## Token families

Each token is meaning × role, with a light and a dark value.

| Family | Tokens | What it colours |
|---|---|---|
| `brand.forest` | one | the app mark and the Forest accent |
| `accent.<name>` for ink, oxblood, forest, azure, amber, plum | `.fg`, `.fill`, `.on-fill`, `.wash` | the user-selectable accent: unread names and dots, links, folder icons, selection washes, primary buttons |
| `success`, `warning`, `danger`, `info`, `flagged` | `.fg`, `.fill`, `.on-fill`, `.wash` | semantic states: auth chips, error labels, destructive swipe actions, toasts, the flag and favourite star |
| `flag.<name>` for red, orange, yellow, green, teal, blue, indigo, purple, pink, gray | one fill each | the user's custom flag colours, drawn as dots and swatches beside their name |
| `swatch.<ten>` plus `swatch.ink` | fills and one ink | sender and address identity avatars with initials over them |

Roles:

- `.fg` is text or a glyph drawn directly on a surface. Floor 4.5:1 on every
  surface in the list, and also over its own `.wash`.
- `.fill` is a filled control or banner. Its label is `.on-fill`, floor 4.5:1
  over the fill.
- `.wash` is the same colour at 12% over a surface, used under chips and
  selected rows. It is not measured itself; the `.fg` drawn on it is.
- `flag.*` fills are non-text, floor 3:1. They are never used as text.
- `swatch.*` are decorative; only `swatch.ink` over them is measured.

## Surfaces

The backgrounds every `.fg` must clear, from measured screenshots and the
theme files. They are in the JSON under `surfaces`.

| Surface | Light | Dark | Where |
|---|---|---|---|
| apple-row | white | (28,28,30) | list rows, reader header |
| apple-form | white | (44,44,46) | inset-grouped form rows, the compose form |
| apple-grouped | (242,242,247) | (28,28,30) | grouped-form section captions |
| apple-sidebar | (228,234,240) | (58,58,60) | iPad and macOS sidebar |
| watch | black | black | watchOS, dark values only |
| android-surface | `#FFFBFE` | `#1C1B1F` | Material 3 surface |
| react-bg, react-pane, react-hover | warm near-whites | warm near-blacks | body, panes, hovered rows |

The sidebar in light and the hovered React row are the hardest light
surfaces; the Apple form row is the hardest dark one.

## Constraints to design against

- **Semantics versus accent.** The accent is user-selectable on the web and
  Android (where wallpaper-derived Material You colour is on by default) and
  fixed to Forest on Apple. Keep `danger` clear of Oxblood, `warning` and
  `flagged` clear of Amber, `info` clear of Azure, and `success` clear of
  Forest as far as the floors allow. Where they cannot be fully separated,
  that is acceptable: every semantic site also carries a glyph or a word.
- **Warning versus flagged.** Both are orange today on Apple. Make the flag
  gold and the warning orange so a flagged message never looks like a warning.
- **Two current accents fail as text.** Amber light measures 4.37:1 on a
  hovered web row and 4.34:1 on the Android surface; Oxblood dark measures
  4.33:1 on the dark sidebar. Adjust these two in the same pass. The other
  four are fine and may stay.
- **Dark values are light, light values are dark.** The checker enforces
  contrast, not direction, but a dark-scheme value that only just clears the
  floor on the dark form row will look dull on black watch faces. Aim for
  headroom in dark.
- **Increase Contrast.** Apple ships high-contrast variants of its system
  colours and the app will lose them when it stops using those colours. If it
  is cheap, supply a high-contrast light and dark value for each `.fg` token
  as `light-hc` and `dark-hc`; engineering will wire them to the asset
  catalog's High Contrast slot. Otherwise the normal values are used for both.
- **Flag colours are user data.** The ten names are stored on the server and
  chosen by the user; only the rendered values change. A "yellow" that is
  really gold is fine, but it must still be the yellow of the set.
- **Swatches.** Ten pastels, one warm ink. Apple's current set is in the file
  as the starting point. They should look like one family in both schemes and
  hold the ink at 4.5:1; they do not need to be distinct from the accents.

## What not to do

- Do not add tokens for unread, selected, or link. They are roles of the
  accent.
- Do not change the neutral greys or surfaces; they are the backgrounds the
  tokens are measured against.
- Do not tune per platform. One value per token per scheme.

## Files

- `color-tokens.json` — the token set, surfaces, floors, and candidate values.
  Replace values; keep names, roles, `on` lists, and floors.
- `colors/*.html` — one preview card per family, generated from the JSON;
  light and dark side by side with the worst ratio for each token.
- `../color-audit.md` — the audit that produced this brief, with the
  per-client census and baseline measurements.
- `../../scripts/check-color-tokens.py` — the checker.

## Return path

Return the edited JSON. The audit session runs the checker, compares the
result against the current baseline, re-renders the cards under `colors/`
with `scripts/render-color-tokens.py`, and folds the values into the
implementation plan at `../color-tokens-plan.md`. This folder is synced to
the "Design System" project in Claude Design; the cards there show the same
ratios the checker applies.
