# Unified Flags Plan

## Progress

| Phase | Status |
| --- | --- |
| 1 -- Palette accepts the `\Flagged` slot | Done: #2370, in prod with 1.46.0 (2026-11-10) |
| 2 -- Kit model: synthesis, default resolution | Apple Kit merged (2026-11-09), #2371; `android/kit` merged (2026-11-10), #2389, the first PR of android-parity.md leg L1 |
| 3 -- Apple client | Merged (2026-11-10): rendering and Settings > Flags, #2375; affordances, #2376. Acceptance run on stage (2026-11-10): iPhone, iPad and visionOS pass, macOS failed ⌘⇧8 with a named default flag, fixed in #2378 (merged 2026-11-10). Duo simulator pass run (2026-11-10): pass in five poses; the flag button's hold menu passes closed and is not settled in the open poses. Soak run (2026-11-10) on the Mini, four platforms: no regression found, five older defects filed (#2381 to #2385). Promoted to prod as 1.47.0 (2026-11-11), with the iOS, macOS and visionOS builds uploaded from `main`. The physical-Duo check waits for the device (duo-support.md, Decision 7) |
| 4 -- Android client | Started (2026-11-10) as android-parity.md leg L1: rendering and Settings > Flags merged, #2390; the controls in review. The acceptance run follows the merge |
| 5 -- Documentation | Merged (2026-11-10), with Phase 3's second PR, #2376 |

This plan is run by Session 1 of
[post-wave-3/flags-and-cross-media.md](post-wave-3/flags-and-cross-media.md),
which splits the Apple work into PRs A0 to A4 and records the
maintainer's answers. Two of them shape this plan (2026-11-09): the
feed's Flag button follows the palette's Flagged entry (decisions 4 and
6 below), and the Android work -- Phase 4 and Phase 2's `android/kit`
half -- runs separately, as android-parity.md leg L1, about a release
after Apple.

## Context

[rules-composition-and-custom-flags-plan.md](rules-composition-and-custom-flags-plan.md)
(shipped in 1.8.0) gave users a palette of up to 20 custom flags --
IMAP keywords `cabal-flag-01..20`, labelled and coloured in synced
preferences -- beside the pre-existing system `\Flagged` toggle. The
clients now ship two flag vocabularies with two sets of affordances:

- **`\Flagged`**: a flag glyph on Apple and a star on Android, toggled
  by swipe, keyboard shortcut (Apple
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
2. Users can rename, recolour and reorder the `\Flagged` entry exactly
   like any other. It cannot be deleted or disabled (decision 2).
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
- Any edit (rename, recolour, reorder) materializes the entry in the
  pushed palette at its position.
- **The entry cannot be deleted, only reset.** Unlike a keyword slot,
  `\Flagged` cannot be un-minted: rules with `flag: true`, the
  `?flagged=1` search, `folder_status`, older builds, and the React app
  all still set or read it. Where other entries offer Delete, this one
  offers "Reset to default", which removes the wire entry so the
  synthesized default takes over again.
- **The entry cannot be disabled** (decided 2026-11-10, with Phase 3's
  first PR). This plan first kept an Enabled toggle on it "for users
  who want it hidden from pickers and rendering"; the maintainer saw
  nothing a disabled built-in flag could mean, so its editor has no
  toggle. The wire format is unchanged and still carries `enabled`, so
  an entry that arrives disabled (written through the API, or by a
  client that offers the toggle) is honoured as data: it is passed over
  as the default flag, and "Reset to default" clears it.

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
palette itself can never be empty under decision 2. Since the system
entry cannot be disabled in the app, this case needs a palette that
carries it disabled already; the handling stays, for that data.

### 4. One rendering for every slot

"Unified" has to mean one rendering, or the user still sees two
systems. The separate glyph goes (`flag.fill` on Apple, a star on
Android): `\Flagged` renders as a coloured dot on the
row and a labelled chip in the reader, exactly like a keyword slot, in
its palette colour. Dot order on the row is palette order, so the
Flagged dot leads by default; the Android row's four-dot cap counts it
first. The reader flag button's icon reflects whether the default flag
is set, using the palette colour rather than the fixed gold.

The gold star survives where it means something else: address
favourites reuse the `flagged.fg` token for a different concept and are
out of scope.

Feed items are in scope. Their favourite became the feed's flag in
1.22.0 and draws mail's glyph and colour, so it follows the palette's
Flagged entry (decided 2026-11-09): the feed row draws the same dot in
the entry's colour, from `is_favorite`, and the feed's Flag button and
swipe take the entry's label and hide when the entry is disabled.
Nothing changes on the server for this.

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
when the entry is disabled. The feed list's Flagged pill follows the
same entry. Per-slot filtering is the natural next
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
  the first client PR that lets a user make that edit (Phase 3's
  Settings > Flags) merges only after Phase 1 is in **prod**, not just
  on stage: a TestFlight build cut from stage talks to the prod API.
  Until the user edits it, the synthesized entry never reaches the wire
  and the old server is never asked to accept it.

## Phase 1 -- Palette accepts the `\Flagged` slot

**Status:** Merged (2026-11-09), #2370, and deployed to stage the same
day. The acceptance below was run against the stage API then and
passed: the palette was stored and returned canonically, a 22-entry
palette and `cabal-flag-00` each got a 400 and left the stored palette
alone, and `set_flag` set and cleared `\Flagged` on a message as before.
It reached prod with 1.46.0 (2026-11-10): prod's `set_preferences` runs
the same build that passed on stage. Phase 3's wait for it (decision 8)
is over.

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

**Status:** The `CabalmailKit` half merged (2026-11-09), #2371, once
Phase 1 was live on stage; it adds the model and no way to edit the
system entry, so it did not need Phase 1 in prod. The `android/kit`
half merged (2026-11-10), #2389, as the first PR of android-parity.md
leg L1: the same model under Kotlin names (`SYSTEM_SLOT`,
`DEFAULT_SYSTEM_ENTRY`, `effective`, `defaultEntry`, `keywordEntries`,
`storedAfterEditing`, `resettingSystemEntry` and a two-argument
`slotsIn`), with `MAX_ENTRIES` 21 and the one-argument `slotsIn` left
keyword-only until the app moves its rows and reader over. As built on Apple, the encode rule is `FlagPalette.stored(afterEditing:from:)`
with `resettingSystemEntry(in:)` for reset, and palette-ordered slots
are a second form, `slots(in:palette:)`: the existing `slots(in:)`
keeps its keyword-only result until Phase 3 moves the row and the
reader over, so that no flag is drawn twice in between.

`CabalmailKit` here; `android/kit` mirrors it in android-parity.md leg
L1:

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

Acceptance: Kit tests green; a wire palette without
the entry encodes back byte-identical after a no-op edit.

## Phase 3 -- Apple client

**Status:** In two PRs, as flags-and-cross-media.md splits it. The
first, rendering and Settings > Flags, merged (2026-11-10), #2375; the
second, the affordances with the "Default" badge and "Make default",
merged (2026-11-10), #2376. Both are on stage. The acceptance at the
end of this phase was run on 2026-11-10 and found one defect, fixed in
#2378 (merged 2026-11-10); its results are under the acceptance text. What the
first one settled:

- The reader's flag button is not recoloured. It was never gold: since
  `ReaderToggleFace` it draws the action ("Flag" / "Unflag"), not the
  state, so there is no state colour to take from the palette. Its
  title follows the default flag's label (second PR).
- The system entry's editor has no Enabled toggle (decision 2). A
  custom flag whose entry is disabled is still drawn on the messages
  that carry it, as it always was: "disabled" means offered nowhere,
  not hidden.
- Feed rows draw the system entry's dot beside the date, from
  `is_favorite`.

What the second one settled, all in one value the controls read
(`FlagToggle`):

- **Words.** The built-in flag under its original name keeps "Flag" /
  "Unflag", so goal 3 holds for the labels too; decision 5's
  "<label>" / "Remove <label>" applies to every other default flag,
  including the built-in one once renamed. A recolour alone keeps the
  old words. The menu bar item reads both ways ("Urgent/Remove
  Urgent"), as "Flag/Unflag" did.
- **Colour.** The swipe's fill is the flag's palette colour, so the
  `flagged.fill` token has no user left on Apple mail or feed surfaces.
- **Flag menus** (the reader button's, and the row menu's Flags
  submenu, now one rule: `FlagMenuPolicy.rows`) list every enabled
  entry in palette order, the built-in one included, then any flag the
  message carries whose entry is disabled or gone. When the default
  flag would be the only row there is no menu, so an untouched palette
  keeps the plain button. The selection menu keeps its one item, the
  default flag's toggle; it never had a Flags submenu.
- **Settings > Flags.** The "Default" badge appears once the list has
  a second flag, and the footer carries the caption. "Make Default" is
  in each row's context menu, above Move Up / Move Down, and is a move
  to the top; a disabled flag cannot be made the default.
- **No default flag** (reachable only from a stored palette whose
  built-in entry is disabled, decision 3): the swipe, the row and
  selection menu items and the bulk bar's button are absent, and the
  reader button, both shortcuts and the menu bar item are dimmed.
- **Filters** (decision 6). The Flagged pills and the search sheet's
  toggle take the built-in entry's label. With that entry disabled they
  are hidden unless lit, so a filter that is on can be turned off.
- **Rule editor** (decision 7). One list in palette order; the built-in
  entry's toggle is the rule's `flag`, and it is offered even when the
  entry is disabled, since a rule can always set the server's flag.
- **Feeds** (decision 4). The swipe, the row menu item, the reader
  button, the pill and the Feeds menu item take the built-in entry's
  name and colour whatever its position, because a feed item has that
  flag and no other. With the entry disabled the swipe and the menu
  item go and the reader button is dimmed, not removed, so its bar
  keeps its shape.

- Settings > Flags: the effective palette; "Default" badge and caption
  on the first enabled row; "Make default" in row menus; "Reset to
  default" replacing Delete on the system entry; the entry
  participates in drag reorder.

  > **Erratum (2026-10-11):** Settings > Flags never drag-reordered on
  > macOS: its grouped `Form` ignores `onMove` there (#2019). The Mac
  > reorders through Move Up / Move Down in each row's context menu, so
  > the system entry joins reordering through that menu (beside "Make
  > default"), and drag reorder via Edit is iOS / iPadOS / visionOS only.
- Rendering (decision 4): row dots and reader chips include the system
  entry; the reader flag button reflects the default flag in its
  palette colour; the flag glyph and `flaggedFg` usage on mail surfaces go.
- Affordances (decision 5): swipe, ⌘⇧8 / ⌘⇧L, row/bulk menus, bulk
  bar, `WindowCommand.toggleFlagged` -> default-flag toggle;
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

**Acceptance run (2026-11-10)**, against stage at 6538066c5 as the first
stage test account, on the Mini's simulators and its Mac. The palette
was put in four states (untouched; the entry renamed "Urgent" and red;
another flag, "Todo", first; every entry disabled, which only data can
do now), and each press was checked against the flags the server then
held. The rename was done in the Settings editor on the iPhone and
through the API elsewhere.

| Platform | Result |
| --- | --- |
| iPhone simulator | Pass: swipe, pill, bulk bar, rule editor, the editor itself |
| iPad simulator | Pass: swipe, pill, reader flag button |
| visionOS simulator | Pass: reader flag button and pill in all four states, swipe with "Todo" first |
| macOS | Pill, toolbar button, Message menu item, ⌘⇧L and the no-default case pass. **⌘⇧8 failed** once the default flag had a name |
| iPhone Duo simulator (stage at cbe028f1c, with #2378) | Pass. Closed: swipe and pill in all four states. Open landscape, book pose, open portrait and laptop pose, with "Todo" first: the reader's chips in list order, and its flag button sets and clears "Todo", from the side strip in the first two and from the bottom bar in the last two (below the fold in laptop pose). The flag button's touch-and-hold menu (checked during the soak): closed, it lists the flags in list order and sets and clears one that is not the default; not settled in the open poses |
| Old build (2026-11-06, before Phase 2) | Pass: the entry lists as an ordinary flag, survives an edit made from the old build, and picking it sets `\Flagged` |

The macOS failure: the Message and Feeds menus both declared ⌘⇧8, and
#2376 made their two items take the flag's name. SwiftUI does not give
a menu item it is updating a key equivalent another item already holds,
so the Message item lost its key on its first retitle; the item, ⌘⇧L
and the toolbar button still worked. #2378 declares the chord on one
menu at a time, the one for the section in front
(`SharedChordPolicy.flagChord`), and `FlagChordTests` counts the items
on the chord in the menu bar the app built. Checked in the running Mac
app with the fix: ⌘⇧8 sets and clears "Todo" on a message, the key
moves to the Feeds item when a feed is in front and back again, a
rename arriving while the app runs keeps it, and with a feed in front
it sets and clears the feed item's flag.

The Duo pass ran on the Mini's simulator, not the Studio's. The flag
button's touch-and-hold menu is, on a wide window, the reader's one way
to a flag other than the default (the Message menu of the bottom bar
has no Flags row). The pass itself could not open it. The soak found
the press that does (a held press of 1.5 s through the driver's `drag`
verb), and with it the menu passes on the Duo closed and on the iPad's
wide layout, which is the layout the open Duo uses: it lists the flags
in list order, sets one that is not the default, marks it, and clears
it, each checked against the server. In the Duo's open poses the
driver's coordinate presses do not land at all (a held press on a list
row opens no menu either), so there the reading says nothing about the
app; a person holding the button in Device Hub, or on the device,
settles it. Not run: the physical-Duo check, a trackpad swipe on
macOS. "New build, old server" can no longer be run: Phase 1 is in
prod.

**Soak (2026-11-10)**, stage at cbe028f1c (the same code as a3f5ed023),
on the Mini with the first stage test account. The acceptance run
above checked what Stage A set out to change; the soak looked for
anything nearby that it broke. Everything stage holds that prod does
not is this change (#2375, #2376, #2378), so the lanes worked through
what it touched: list rows, swipes, filter pills, row menus, bulk
actions, the reader's header and bar, reply, move, search and its
filter sheet, the feed list and reader, Settings > Flags, the rule
editor's flag list, the menu commands, relaunch and background. Each
lane had eight seeded messages of its own; every action was checked
against the server's flags. The flag list was the built-in flag first
under its original name, then two custom flags; a short second pass
made a custom flag the default (the iPhone's row menu and the Duo's
hold menu).

| Lane | Result |
| --- | --- |
| iPhone 17 simulator | No regression. Every check passes but the search for the lane's tag, which is the server defect below. Among them: the settings writes (add, rename, recolor, move and delete a flag; the swipe set to the default flag; add and delete a rule), largest text and landscape. Dark mode (list dots and reader chips) was run after the lanes, because the account's theme is a synced setting, and passes |
| iPad Pro 11-inch simulator | No regression. Every check passes but the same search. Among them: the hardware-keyboard chords (⌘⇧8, ⌘⇧L, ⌘⇧U, ⌘T), the menu bar's Message menu, a 375 pt window, portrait, largest text and the flag button's hold menu. Dark mode not run there |
| Apple Vision Pro simulator | No regression. Every check the driver could deliver passes. Not run: the row's hold menu, trailing swipes in the narrow lists and hover, none of which it can deliver there |
| macOS (the app on the Mini) | No regression. Rows, the reader's bar and flag menu, ⌘⇧8 in mail and in feeds, the Message and Feeds menus with a compose window in front and without, reply, move there and back, a three-message selection (bulk flag, bulk read, ⌘⇧8), the pills, Settings > Flags (add, recolor, delete; the built-in flag's editor) and the rule editor |

Each defect a lane reported was run again on a build of `main` at
af998ca22 (1.46.0), or asked of the server directly. All five are older
than Stage A and are filed:

- #2381, macOS: after a visit to Feeds, the reader's Flag, reader view
  and Move buttons stay in the toolbar's overflow in a narrow window.
- #2382, server: a search for a hyphenated word finds only some of the
  messages that contain it.
- #2383, iOS: the reader's sender avatar falls back to initials after
  the first message opened in a launch.
- #2384, visionOS: the reader pane is blank, or says "1 Message
  Selected", after a folder switch with a message open.
- #2385, Apple: under the Flagged pill, an unflagged row can come back
  for about a minute when a list refresh lands after the unflag. The
  iPad lane saw it twice in six tries; forced with a held reply, stage
  and `main` behave alike.

Seen and left as they are: on iPhone and visionOS, rows in Select mode
run to both edges of the list (the same on `main`); the flag dots take
room from the sender's name, about 16 pt each; on the iPad the flag
button's hold menu, opening upward from the bar, lists the flags
bottom-up. The test account is back as it was: no soak mail, an empty
flag list, the swipes, filters and theme as before. One disabled rule
named "New rule", left by the acceptance run's rule-editor check, was
removed.

## Phase 4 -- Android client

**Status:** Started (2026-11-10), as android-parity.md leg L1, after
the Apple release was promoted as 1.47.0, on Phase 2's `android/kit`
half (#2389). The app takes two PRs, as Apple's did. The first,
rendering and Settings > Flags, merged (2026-11-10), #2390; the second, which moves the
controls to the default flag, is in review (2026-11-10). The acceptance
below runs after both merge. What the first one settled:

- The star leaves every row. A flagged message shows a dot in the
  built-in entry's color on its row, with the custom-flag dots, in the
  order of Settings > Flags and counted in the four-dot cap, and a named
  chip in the reader. Search results draw the dots too; before, they
  showed the star and no custom flag. A flagged feed item shows the same
  dot beside its date in place of the star at the row's edge, and the
  row's spoken description names the flag.
- Settings > Flags lists the effective palette. The built-in entry's
  dialog has Reset to default where the others have Delete flag, and no
  Enabled switch (decision 2).
- The star stays on the controls that set a flag (the maintainer's
  answer of 2026-11-10, recorded in android-parity.md), so the reader's
  button, the selection bar and the swipe keep it.
- Until the second PR, the reader's menu, the row's long-press menu and
  the rule editor offer keyword entries only: the control beside each of
  them already sets the built-in flag, and `set_rules` refuses its atom
  in a rule's `flags`.

What the second one settled, all from one value the controls read
(`FlagToggle`, as on Apple):

- **Words and color.** "Flag" / "Remove flag" stay while the default
  flag is the built-in one still called "Flagged"; any other default
  flag reads "<label>" / "Remove <label>". The swipe's wash and the
  reader's filled star take the flag's palette color.
- **Which controls.** The flag swipe, the reader's star button,
  Ctrl+Shift+L in the list and the reader, the selection bar's two items
  (set in the bar, remove in its overflow menu) and a search result's
  long-press act on the default flag.
- **Flag menus** (the reader's overflow menu and the row's long-press
  menu, one rule: `FlagMenu.rows`) list every enabled entry in palette
  order, the built-in one included, then any flag the message carries
  whose entry is disabled or gone. Android's row menu is flat, so there
  the list replaces the "Flag" item instead of sitting in a submenu
  beside it. When the default flag would be the only row, the reader
  shows no flag rows and the row menu keeps its one plain item.
- **Settings > Flags.** The first enabled row says "Default" under its
  name once the list has a second flag, and the footer says what that
  means. "Make default" is a button in each flag's dialog, since these
  rows have no context menu; it is a move to the top, and is dimmed on
  the default flag and on a disabled one. The swipe picker's option
  reads "Toggle default flag".
- **No default flag** (reachable only from a stored palette whose
  built-in entry is disabled): the swipe edge does not drag, the
  selection bar's star and the reader's star are dimmed, the overflow
  item is absent, and the shortcut and the search long-press do nothing.
  A flag the message already carries is still listed in the menus, for
  removal.
- **Filters.** The Flagged pills (mail and feeds) and the search sheet's
  checkbox take the built-in entry's label. With that entry disabled
  they are hidden unless lit.
- **Rule editor.** One list in palette order; the built-in entry's
  toggle is the rule's `flag`, offered even when the entry is disabled,
  and its atom is never written to the rule's `flags`.
- **Feeds.** The swipe, the reader's star button and the pill take the
  built-in entry's name and color whatever its position. With the entry
  disabled the swipe edge does not drag and the reader's button is
  dimmed, not removed.

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

**Status:** Merged (2026-11-10), #2376, with Phase 3's second PR.
The manual had no flags section, so it gains a Flags entry under Mail;
the rules doc's Flag extra says the editor lists the flags as Settings
> Flags does.

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
- **Address favourites** keep the gold star and the `flagged.fg`
  token; if the glyph's disappearance from mail makes that read as
  inconsistent, the token note in `design/color-tokens.json` should be
  revisited then.
