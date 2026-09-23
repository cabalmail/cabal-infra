# Unified Flags Plan

## Progress

| Phase | Status |
| --- | --- |
| 1 -- Palette accepts the `\Flagged` slot | Not started |
| 2 -- Kit model: synthesis, default resolution | Not started |
| 3 -- Apple client | Not started |
| 4 -- Android client | Not started |
| 5 -- Documentation | Not started |

## Context

[rules-composition-and-custom-flags-plan.md](rules-composition-and-custom-flags-plan.md)
(shipped in 1.8.0) gave users a palette of up to 20 custom flags --
IMAP keywords `cabal-flag-01..20`, labelled and coloured in synced
preferences -- beside the pre-existing system `\Flagged` toggle. The
clients now ship two flag vocabularies with two sets of affordances:

- **`\Flagged`**: a star, toggled by swipe, keyboard shortcut (Apple
  ⌘⇧8 in the list and ⌘⇧L in the reader; Android Shift+L), the row
  and bulk menus, and the reader toolbar; filterable via the
  All/Unread/Flagged pill and `?flagged=1` search; settable by a rule's
  `flag: true`.
- **Palette slots**: coloured dots on the row, chips in the reader,
  applied through a picker menu; managed in Settings > Flags; settable
  by a rule's `flags: [slot]`.

The split is an artefact of implementation order, not a user-facing
concept. `\Flagged` is, from the user's chair, simply a flag whose
label and colour they cannot change and whose affordances are richer
than the ones they defined. This plan folds it into the palette as one
more slot so there is a single flags interface: one list in Settings,
one rendering on messages, one picker, and one toggle gesture that
latches onto whichever flag the user puts first.

### Why `\Flagged` is a free slot

Keywords are not a later addition to IMAP -- RFC 2060 (1996) defined
system flags and keyword atoms together. The 26-letter limit the
shipped design works around is Dovecot's *Maildir* storage: keywords
map per folder to `a`-`z` in `dovecot-keywords`, which is why decision
4 of the shipped plan fixed the vocabulary at 26 slots (20 user, 6
reserved). `\Flagged` lives elsewhere: it is the Maildir info letter
`F`, one of the six standard flag letters, not a keyword letter. Two
consequences shape this plan:

- Adding `\Flagged` to the palette consumes none of the 20 user slots
  and none of the 6 reserved ones. The cap becomes 21 entries.
- A rule that sets `\Flagged` keeps the cheap raw-write delivery path
  (`cabal-maildir-deliver.sh`'s `F` suffix); only keyword slots need
  the APPEND drain. Nothing on the delivery side changes.

## Goals

1. One flags interface across the native clients: the palette is *the*
   list of flags, and `\Flagged` is an entry in it.
2. Users can rename, recolour, reorder, and disable the `\Flagged`
   entry exactly like any other.
3. Users who have never touched the palette see no change beyond
   rendering: a flag labelled "Flagged" in the same gold, first in the
   list, toggled by the same gestures.
4. The single-gesture toggle (swipe, shortcut, reader button) survives,
   retargeted to a user-designated default flag.
5. Ships as a **minor** release under
   [docs/compatibility.md](../compatibility.md).

## Non-goals

- **Per-slot filtering.** The Flagged pill and `?flagged=1` search stay
  `\Flagged`-only in this plan; per-slot filtering is a clean additive
  follow-up (`?keyword=<slot>` mapped to an IMAP `KEYWORD` search) and
  is recorded below as such, not built here.
- **Removing the system-flag semantics of `\Flagged`.** Rules'
  `flag: true`, `folder_status`'s flagged count, and the React admin
  app's Flag/Unflag button all keep meaning `\Flagged`. The palette
  entry decorates the system flag; it does not replace it.
- **Reserved slots 21-26.** Unchanged and still unexposed.
- **React admin.** Second-class client; it keeps its existing star
  toggle against `\Flagged` and receives none of this.
- **Linux client.** No flag UI yet; `flag_palette` stays on its
  deliberately-unsupported list. No preference *key* changes here, so
  the contract test is untouched.

## Decisions

### 1. The palette slot id for `\Flagged` is the literal atom

The new palette entry is `{slot: "\\Flagged", label, color[, enabled]}`.
The slot id is the IMAP atom itself, not a synthetic `cabal-flag-00`,
for two reasons:

- Every client already passes `entry.slot` straight to `set_flag` for
  palette entries, and `set_flag` already accepts `\Flagged` through
  the same endpoint (`_check_keyword` short-circuits on the backslash).
  The unified picker needs no special case.
- **Graceful degradation for builds in the field.** Both shipped
  native decoders take `slot` as an arbitrary string
  (`FlagPalette.swift`, `FlagPalette.kt`) and their `slots(in:)` /
  `slotsIn` helpers filter against the fixed `cabal-flag` list, so an
  old build that receives the new entry lists it in Settings, never
  renders a stray chip for it, and -- if the user picks it from the old
  build's flag menu -- sends `\Flagged` to `set_flag`, which simply sets
  the system flag. A synthetic id would 400 on those builds.

The server-side change is confined to `set_preferences`:
`FLAG_PALETTE_SLOTS` gains `\Flagged`, and the entry-count cap becomes
21 (20 user slots plus this one). `set_flag`, `list_envelopes`,
`search_envelopes`, `set_rules`, and the compiler are untouched.

### 2. An absent entry is synthesized; delete means reset

Existing palettes carry no `\Flagged` entry and must not need a
migration. The kits resolve the *effective* palette from the wire
palette:

- If no entry has `slot == "\\Flagged"`, the kit inserts
  `{slot: "\\Flagged", label: "Flagged", color: "yellow",
  enabled: true}` at index 0. `yellow` is chosen because `flag.yellow`
  shares its hue with the `flagged.fg` token (hue 88 in
  `design/color-tokens.json`), so an un-customized user sees no colour
  shift. The synthesized entry is not pushed to the server until the
  user edits it -- the wire palette stays byte-identical for users who
  never touch it.
- Any edit (rename, recolour, reorder, disable) materializes the entry
  in the pushed palette at its position.
- **The entry cannot be deleted, only reset.** Unlike a keyword slot,
  `\Flagged` cannot be un-minted: rules with `flag: true`, the
  `?flagged=1` search, `folder_status`, older builds, and the React app
  all still set or read it. Where other entries offer Delete, this one
  offers "Reset to default", which removes the wire entry so the
  synthesized default takes over again. Disable remains available for
  users who want it hidden from pickers and rendering.

### 3. The default flag is positional: first enabled entry

The single-gesture toggle needs one flag to latch onto. That flag is
the **first enabled entry in palette order**. No new field rides the
wire: array order is already display order and already synced, and it
round-trips through every shipped build. An explicit `default: true`
field was considered and rejected -- the shipped Apple encoder writes
only its four coding keys and the Android data class likewise, so any
palette edit from an old build would silently drop the designation,
and the fallback would have to be exactly this positional rule anyway.

Settings > Flags makes the rule visible: the first enabled row wears a
"Default" badge with a caption such as "Swipe actions and the flag
shortcut toggle this flag", and every other row's menu gains "Make
default", which moves it to the top. For an un-customized user the
default is Flagged, with no extra state.

Degenerate case: if every entry is disabled there is no default. The
toggle affordances then behave as a `none` swipe binding does today --
the swipe action is hidden and the shortcut and reader button are
disabled -- rather than silently falling back to `\Flagged`. The
palette itself can never be empty under decision 2.

### 4. One rendering for every slot

"Unified" has to mean one rendering, or the user still sees two
systems. The star goes: `\Flagged` renders as a coloured dot on the
row and a labelled chip in the reader, exactly like a keyword slot, in
its palette colour. Dot order on the row is palette order, so the
Flagged dot leads by default; the Android row's four-dot cap counts it
first. The reader flag button's icon reflects whether the default flag
is set, using the palette colour rather than the fixed gold.

The gold star survives where it means something else: address
favourites and feed favourites reuse the `flagged.fg` token for a
different concept and are out of scope.

### 5. Toggle affordances retarget to the default flag

Every `\Flagged` toggle becomes a *default flag* toggle:

| Surface | Today | After |
| --- | --- | --- |
| Swipe binding `toggle_flag` (Apple `Preferences+Swipe`, Android `SwipeBindings`) | toggles `\Flagged` | toggles the default flag; picker label "Toggle default flag" |
| Apple ⌘⇧8 (list) / ⌘⇧L (reader); Android Shift+L | `\Flagged` | default flag |
| Row and bulk context menus "Flag"/"Unflag" | `\Flagged` | one section listing every enabled slot (already present as the Flags submenu); the default flag leads |
| Reader toolbar flag button | toggles `\Flagged`, menu lists slots | toggles the default flag; menu unchanged |
| Bulk action bar `bulk.toggleFlag` | `\Flagged` | default flag |

The `toggle_flag` wire value in `APP_ALLOWED` is kept; its meaning is
unchanged for every user who has not reordered the palette, and for
one who has, the change is the feature. Labels that hard-code
"Flag"/"Unflag" become "<label>"/"Remove <label>" where the label is
the default entry's; accessibility identifiers (`message.swipe.toggleFlag`,
`reader.toggleFlag`, `bulk.toggleFlag`) are retained so tester probes
keep working.

### 6. Filtering stays `\Flagged`-only; labels follow the palette

The All/Unread/Flagged pill and the search sheet's Flagged toggle keep
filtering on `\Flagged`, because that is the only flag the server can
filter on today. Their label follows the palette entry's label (a user
who renamed it "Urgent" sees an "Urgent" pill), and they are hidden
when the entry is disabled. Per-slot filtering is the natural next
step once this ships and is not part of this plan.

### 7. Rules are unchanged on the wire

`flag: bool` keeps meaning `\Flagged` (the shipped plan's Phase 5
decision 1 stands) and `flags: [slot]` keeps carrying keyword slots.
The rule editors already present the system Flagged toggle beside the
per-slot toggles; the only change is cosmetic -- the Flagged row takes
its label and colour from the palette entry and sits first, so the
editor's list matches Settings > Flags. The compiler, `set_rules`, and
`flag_not_in_palette` are untouched; a disabled `\Flagged` entry does
*not* make `flag: true` rules skip, since the system flag is always
settable.

### 8. Compatibility: minor release

Under `docs/compatibility.md` the HTTP-API change is "accepting a new
value" (one more slot id, a higher cap) -- explicitly non-breaking, and
"clients must ignore unknown fields and tolerate new values" is the
contract the shipped decoders honour (decision 1). No endpoint,
request, or response shape changes; no preference key is added; no
migration runs. The client-side changes are behaviour and rendering,
recorded as `changed` fragments with the `Apple:` / `Android:`
prefixes.

Old-build interactions, enumerated:

- Old build, new server, palette with a `\Flagged` entry: entry shows
  in Settings as a custom flag; no chip; picking it sets the system
  flag (the star lights). Editing the palette from the old build
  round-trips the entry intact (the four keys are the same).
- New build, old server (stage/prod before Phase 1): a push carrying a
  `\Flagged` entry is rejected with a 400 on the whole `app` map, the
  same failure mode `flagPaletteSyncable` already guards. Phase 2 must
  therefore materialize the entry only on an explicit user edit, and
  the client PRs merge after Phase 1 is live. Until the user edits it,
  the synthesized entry never reaches the wire and the old server is
  never asked to accept it.

## Phase 1 -- Palette accepts the `\Flagged` slot

**Status:** Not started.

`lambda/api/set_preferences/function.py`: add `\Flagged` to
`FLAG_PALETTE_SLOTS`; raise the entry cap from 20 to 21 with a comment
tying the count to "20 keyword slots plus the system flag";
`_validate_flag_palette` otherwise unchanged (the slot is unique per
palette like any other). `set_flag` needs no change. Unit tests cover
the new slot round-tripping, a 22-entry palette rejected, and
`cabal-flag-00` still rejected.

Acceptance: stage `set_preferences` accepts a palette whose first
entry is `{"slot":"\\Flagged","label":"Urgent","color":"red"}` and
returns it canonically; a 22-entry palette 400s; `set_flag` with
`\Flagged` behaves as before.

## Phase 2 -- Kit model: synthesis, default resolution

**Status:** Not started. Merges after Phase 1 is live on stage.

`CabalmailKit` and `android/kit`, mirrored:

- `FlagPalette.systemSlot` (`"\\Flagged"`), `maxEntries` 21, and the
  `slots` list unchanged (`firstFreeSlot` must keep ignoring the
  system slot).
- `FlagPalette.effective(_:)`: the wire palette with the synthesized
  entry inserted at index 0 when absent (decision 2).
- `FlagPalette.defaultEntry(in:)`: first enabled entry of the effective
  palette, or nil (decision 3).
- `slots(in:)` / `slotsIn` include `\Flagged` when the message carries
  it, ordered by palette position rather than fixed slot order, so dot
  order matches the list.
- Encode/push: the entry is written only when it differs from the
  synthesized default or the wire palette already carried it (so a
  "Reset to default" removes it and a plain re-save of an untouched
  palette does not add it).
- Tests: synthesis, materialize-on-edit, reset, default resolution
  with disabled entries, ordering, and the `firstFreeSlot` invariant.

Acceptance: kit tests green on both platforms; a wire palette without
the entry encodes back byte-identical after a no-op edit.

## Phase 3 -- Apple client

**Status:** Not started.

- Settings > Flags: the effective palette; "Default" badge and caption
  on the first enabled row; "Make default" in row menus; "Reset to
  default" replacing Delete on the system entry; the entry
  participates in drag reorder.
- Rendering (decision 4): row dots and reader chips include the system
  entry; the reader flag button reflects the default flag in its
  palette colour; the star and `flaggedFg` usage on mail surfaces go.
- Affordances (decision 5): swipe, ⌘⇧8 / ⌘⇧L, row/bulk menus, bulk
  bar, `AppState.requestToggleFlagged` -> default-flag toggle;
  `FlagMenuPolicy` lists the system entry first; labels follow the
  palette; the degenerate no-default case disables them.
- Filter pill and search toggle labels follow the palette (decision 6).
- Rule editor: Flagged row styled from the palette entry, listed first.
- App-layer tests (`CabalmailMac` scheme) for the view-model paths;
  swiftlint clean.
- Fragment: `- Apple: **One flags list.** ...` under `changed`.

Acceptance on stage: an untouched account looks as before except the
star is a gold dot/chip; renaming the entry to "Urgent" and recolouring
it red updates the swipe label, the shortcut target, the pill, and the
rule editor; moving another flag to the top retargets the swipe;
disabling every flag hides the swipe and disables the shortcut.

## Phase 4 -- Android client

**Status:** Not started.

The same items as Phase 3 against the Android surfaces:
`FlagPaletteSettings` (up/down reorder gains "Make default"; Reset in
place of Delete on the system entry), `EnvelopeRow` dots,
`MessageDetailScreen` chips and top-bar button, `SwipeBindings`
`TOGGLE_FLAG`, Shift+L, selection bar, long-press menus, search
long-press, `RuleEditorScreen`. `isFlagged` in `Models.kt` stays (it
backs the pill) but no mail surface renders the star from it. Gradle
gate green (ktlint, Android Lint warnings-as-errors, unit tests).
Fragment: `- Android: **One flags list.** ...` under `changed`; the
headline is the only text that reaches Play release notes.

Acceptance: the Phase 3 script run on Android; a palette edited on one
platform reads identically on the other.

## Phase 5 -- Documentation

**Status:** Not started.

- `docs/user_manual.md`: the flags section describes one list, the
  default flag, and reset-vs-delete.
- `docs/mail-rules.md`: the flags sections note that the Flagged toggle
  in the rule editor is the palette's system entry.
- This plan's Progress table and per-phase Status lines, updated in
  the same PRs as the work.

## Follow-ups recorded, not planned

- **Per-slot filtering.** `search_envelopes` and the list pills could
  accept `?keyword=<slot>` (IMAP `KEYWORD`), making every palette entry
  filterable and retiring the `\Flagged` asymmetry left by decision 6.
- **Feed and address favourites** keep the gold star and the
  `flagged.fg` token; if the star's disappearance from mail makes that
  read as inconsistent, the token note in `design/color-tokens.json`
  should be revisited then.
