# Flag palette: `enabled` stops being accepted

## Progress

| Work item | Status |
| --- | --- |
| 1 -- `set_preferences` refuses `enabled` | Not started. Waits for 2.0 |
| 2 -- Stored palettes are swept | Not started |
| 3 -- The readers' tolerance goes | Not started |
| 4 -- Docs, changelog and release notes | Not started |

This is work for the 2.0 release and no earlier. It removes what the
1.x series has to keep after the Enabled switch left custom flags.

## Context

An entry of the flag palette (the `flag_palette` string in the synced
preferences' `app` map) is `{slot, label, color}` and, optionally,
`enabled`. Until 2026-11-11 a custom flag had an Enabled switch in
Settings > Flags, and `enabled: false` meant three things on the
server: `/set_flag` and `/rss_set_item_state` refused to add the slot,
and the rules compiler skipped a rule that set it.

The maintainer decided on 2026-11-11 that the switch does not earn its
complexity ([flags-and-cross-media.md](../1.x/post-wave-3/flags-and-cross-media.md),
decision 10). The removal runs in the 1.x series as three PRs:

- **E1, server.** `set_flag`, `rss_set_item_state` and
  `compile-user-rules.py` stop reading `enabled`: a slot is in the
  palette or it is not. `set_preferences` still accepts the field and
  stores it as sent. The field is announced as deprecated.
- **E2, Apple** and **E3, Android.** The switch goes, the client model
  loses the field, and a palette is written without it.

What 1.x cannot do is stop *accepting* the field. Every Apple and
Android build from 1.8.0 until E2 and E3 writes `enabled` on every
entry, and sends the whole `app` map, palette included, with every
settings push. `_validate_flag_palette` refuses an entry that has a key
it does not know, and one refused entry refuses the whole map. So a
server that dropped `enabled` from the validator would answer 400 to
every settings change those builds make, not only to palette edits.
Under [docs/compatibility.md](../compatibility.md) that is a breaking
change to the HTTP API, and its deprecation policy puts the removal no
earlier than the next major release.

## What is left when 2.0 is planned

**Server.**

- `lambda/api/set_preferences/function.py`, `_validate_flag_palette`:
  `enabled` in the set of keys an entry may have, the check that it is
  a boolean, and the docstring paragraph that says why it is there.
- The comments in `set_flag` (`_palette_slots`), `rss_set_item_state`
  (`palette_slots`) and `docker/shared/compile-user-rules.py`
  (`slots_in_palette`) that say `enabled` is not read.
- Tests that hold the 1.x behaviour:
  `test_enabled_is_deprecated_but_still_accepted_and_stored` and the
  two fixtures that send `enabled` in
  `test_set_preferences_app_map.py`;
  `test_an_entry_stored_as_disabled_still_sets` in
  `test_set_flag_palette.py`;
  `test_an_entry_stored_as_disabled_can_be_added` in
  `test_rss_item_flags.py`; and the two `enabled` tests in
  `docker/shared/test/compile-user-rules/test_compile_user_rules.py`.

**Stored data.** A row of `cabal-user-preferences` written by a build
from before E2 or E3 holds a palette whose entries carry `enabled`.
Nothing reads the key, so such a row is harmless, and it stays until a
newer build next pushes that user's settings.

**Clients.** Nothing, if E2 and E3 took the field out of the models as
planned. Both decoders skip a key they have no field for (Swift's
synthesized `Decodable`; `ignoreUnknownKeys` in `FlagPalette.kt`),
which is what lets a build without the field read a stored palette
that still has it.

**Docs.** The row in `docs/compatibility.md`, "Current deprecations",
and the sentence in `docs/rss.md` that calls `enabled` deprecated.

## Decisions for the maintainer

Asked when 2.0 is planned, each with a default.

1. **Refused, not dropped in silence.** The announcement says the
   field stops being accepted, so an entry that carries it is refused
   with the 400 any unknown key gets. The alternative, storing the
   entry without the key, would keep old builds working and is not
   what was announced. Default: refused.
2. **Stored rows: swept or left.** **Swept (recommended)**: a one-time
   script rewrites each stored palette without the key, after the
   deploy, so work item 3 can go. Left: the readers keep ignoring it
   for good, and work item 3 is dropped. Default: swept.
3. **The oldest client 2.0 supports.** A build from before E2 or E3
   cannot save any setting against a 2.0 server. Whether 2.0 does more
   than say so in its release notes (for example a check that tells
   the user to update) is a wider 2.0 question than this plan.

## Work items

### 1 -- `set_preferences` refuses `enabled`

**Status:** Not started.

Take `enabled` out of the allowed keys in `_validate_flag_palette`,
with its boolean check and the docstring paragraph. An entry that
carries it then fails like any entry with an unknown key, and the push
answers 400 with nothing written. The test that pins acceptance flips
to pin the refusal.

### 2 -- Stored palettes are swept

**Status:** Not started.

A script under `scripts/` that reads every row's `app.flag_palette`,
drops `enabled` from each entry, and writes the palette back only when
it changed, with a condition on the value it read so a concurrent push
wins. Run per environment by the operator after work item 1 is
deployed there, since until then an old build can write the key again.
It reports counts and no palette contents.

### 3 -- The readers' tolerance goes

**Status:** Not started. Only if decision 2 is "swept".

Once no stored row carries the key: the three "not read" comments and
the stored-as-disabled tests listed above.

### 4 -- Docs, changelog and release notes

**Status:** Not started.

- A `removed` changelog fragment. The `deprecated` one shipped with E1.
- `docs/compatibility.md`: the row leaves "Current deprecations".
- `docs/rss.md`: the sentence about `enabled`.
- 2.0's release notes name the first Apple and Android releases that
  write no `enabled`, as the oldest builds that can save settings.

## Before starting

- 2.0 is being cut. The deprecation policy does not allow this in a
  1.x release.
- E2 and E3 have shipped. Record their release numbers here; they are
  the minimum client versions work item 4 names.
- Count the stored rows that still carry the key in each environment,
  so the sweep's result can be checked against a number.

## Acceptance

On stage, as a stage test account:

- A settings push whose palette entry carries `enabled` answers 400 and
  writes nothing. The same push without the key is stored.
- A row that still carries the key, planted before the deploy, still
  lets `/set_flag` and `/rss_set_item_state` add that slot, and a rule
  that sets it still compiles.
- After the sweep, no row carries the key, and each palette is
  otherwise as it was.
- A build from before E2 or E3 fails its settings push. That is the
  intended break; record what the user sees.
