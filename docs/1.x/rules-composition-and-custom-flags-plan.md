# Rules Composition and Custom Flags Plan

## Context

The first days of mail rules running in prod (2026-08-26) surfaced three
related findings:

1. **Move + Continue reads as "the rule didn't fire."** Per
   [user-mail-rules-plan.md](user-mail-rules-plan.md) settled decision 8,
   a spill-through rule compiles its destination to a procmail copy
   (`:0c:`). When a spilled message runs off the end of the rule list,
   default delivery puts the original in the inbox. The behavior is
   exactly as designed -- but the *label* is wrong: a Move rule with
   Continue enabled is a Copy rule, and the user watching the inbox
   concludes the rule is broken. Move + Continue and Copy + Continue
   compile to byte-identical procmail, so the Move label buys nothing.
2. **Decorate-then-file does not compose.** The plan doc's motivating
   example -- "file receipts into Receipts AND flag anything from
   billing" -- is not actually expressible. Flags are Maildir delivery
   metadata (the `:2,F` filename suffix), so they can only be applied
   where a delivery happens: a Flag rule with destination None and
   Continue enabled compiles to an empty body and is dropped
   (`compile_skip_rule reason=no_effect`). The editor happily saves that
   rule today; it silently evaporates at compile time. The only working
   form is the manual cross-product (one terminal rule per
   condition-combination, most-specific first).
3. **Users want custom flags** (IMAP keywords) as a first-class feature,
   and the rules engine should be able to set them.

This plan covers the rules-engine and editor improvements that fix (1)
and (2), and the custom-flags feature that answers (3), because the
mechanism that fixes (2) is the same one that lets rules set custom
flags later.

As with the original rules plan, the native clients (Apple, Android) are
the primary surfaces. The React admin app is second-class and receives
none of this unless separately prioritized. The Linux client is
separately owned; its only involvement is the preferences contract test
noted in [Phase 3](#phase-3--flag-palette).

## Goals

- Make the rule editor's labels truthful: a combination the engine
  cannot honor is either relabeled to what the engine actually does or
  is not offered at all. No rule that saves successfully may compile to
  nothing.
- Restore decorate-then-deliver composition for flags: "flag anything
  from billing" + "file receipts" as two independent rules, in that
  order, producing a flagged message in the destination folder.
- Add account-wide custom flags: a user-curated palette of up to 20
  named, colored flags, usable from every client on any message in any
  folder, settable by mail rules at delivery time.
- Keep every existing safety property of the compiler: skip-not-mangle,
  whitelisted-and-escaped user input, deterministic output, the
  golden-file self-test gate.

## Non-goals

- **An accumulate-then-deliver rules engine.** Destinations remain
  events, not carried state. "Move + let later rules decorate + end up
  only in the folder" (a `FILED`-suppression design) stays out of scope:
  the truthful-Continue change removes the combination that made it
  seem necessary, and pending *flags* (Phase 2) cover the composition
  people actually reach for.
- **Pending destinations.** The pending-state mechanism carries flags
  only. A `PENDING_FOLDER` would reopen every which-delivery-wins
  question the engine deliberately avoids.
- **Arbitrary user-named keywords on the wire.** Users name palette
  entries; the mailstore only ever sees fixed slot atoms (see decision
  4). Foreign-client keyword vocabularies (`$label1`,
  `$MailFlagBit0`, ...) are not imported or mapped.
- **Per-folder palettes.** Keyword identity in IMAP is by name and
  effectively account-global; a per-folder vocabulary would be a UI
  fiction the store cannot enforce.
- **Flag conditions.** Rules match on headers and body at delivery
  time; "if message is flagged X" conditions are a different feature
  (rules run before any client could have flagged the message).
- **Retroactive rule application** -- unchanged from the original plan.

## Design decisions

### 1. Continue gates the destination menu

The spill-through toggle moves to the top of the rule editor and
becomes the first choice ("does this rule end processing?"). Its state
constrains the destination picker below it:

- **Continue OFF** (default): Move, Copy, Archive, Delete, None -- as
  today.
- **Continue ON**: only **Copy** and **None** are selectable. Move and
  Archive are disabled because their spill-through compilation *is*
  Copy (Archive is Move-to-Archive); Delete is disabled because the
  engine already ignores Continue on Delete. Disabled options stay
  visible in place -- disabled, not hidden -- with a one-line
  explanation ("a rule that continues passes the message along; use
  Copy").

Turning Continue ON while Move or Archive is selected auto-converts the
destination to Copy, carrying the folder over, with an inline note.
This is safe, not a guess: the compiled output is identical. Turning
Continue OFF leaves Copy selected -- terminal Copy is valid and is the
honest statement of what the old Move + Continue was doing.

### 2. Stored rules are normalized in the editors; the server stays permissive

Rules stored as `move`/`archive` with `continueToNext: true` predate
this change and exist in prod. Editors render and save them as Copy
(silent one-way normalization -- again, identical compiled output).
`set_rules` validation and the compiler continue to accept the old
shape indefinitely, so a rule set that is never re-saved keeps working
and nothing needs a data migration.

### 3. Pending decorations ride procmail variables

Flags stop being compile-time constants baked into each delivery line
and become per-message runtime state:

- A rule with Flag and/or Mark-as-read, destination None, Continue ON
  compiles to variable assignments inside its condition block instead
  of nothing: `PENDING_F=F`, `PENDING_S=S`. Assignment blocks are
  non-terminal; no copy is created and no inbox-copy wart appears.
- Every delivery the compiler emits -- terminal moves, spill copies,
  and the file-level inbox fallback in the procmailrc -- folds pending
  flags in: the helper argument becomes `"${PENDING_F}${PENDING_S}"`
  (plus the rule's own flags, which are expressed by setting the same
  variables before the delivery line). Concatenation in F-then-S order
  can only yield `""`, `F`, `S`, or `FS` -- always valid, always
  sorted.
- Procmail runs once per message, so per-message isolation of the
  variables is free.
- Where no decorate-only rules exist in a user's set, the compiler
  emits today's output byte-for-byte; where they might be pending, a
  runtime condition on the variable (`* PENDING_F ?? F`) keeps the
  native no-helper delivery path for undecorated messages.

`cabal-maildir-deliver.sh` learns to accept an empty flags argument,
delivering into `new/` exactly like native procmail so unflagged mail
keeps normal unread semantics.

### 4. Custom flags are 26 fixed slots; users define 20

- The on-disk/IMAP keyword atoms are immutable slot identifiers:
  `cabal-flag-01` through `cabal-flag-20` for user flags, with slots
  21-26 **reserved** for future semantic keywords (`$Forwarded` and
  kin) so conventional keywords never compete with user flags for a
  folder's 26 Maildir keyword letters.
- The user-visible palette -- per-slot label, color, order, and
  enabled/disabled -- lives in synced preferences. Renaming a flag is a
  metadata edit touching zero messages; deleting and re-creating reuses
  the slot and never mints a new keyword. Per-folder keyword allocation
  is therefore bounded at 26 forever, and the keyword-dropped-on-copy
  edge case is structurally impossible.
- The palette cap (20) and the slot names are enforced at the API.
  This is sound because the Lambda API is the sole flag writer once the
  private mail-plane work removes public IMAP access; a directly
  attached MUA writing `$label1`-style keywords is not a supported
  configuration.

### 5. Keyworded delivery goes through IMAP APPEND

`cabal-maildir-deliver.sh`'s raw-Maildir write is safe for the
mapping-free system flags (`F`, `S`) but cannot safely set keywords:
the keyword-letter mapping is the per-folder `dovecot-keywords` file,
which Dovecot owns, rewrites, and caches in its indexes. Racing it from
procmail is not a supported pattern and is the one component of the
current engine that does not extend to keywords.

When a delivery carries keywords, the helper delivers via **IMAP APPEND
to localhost as the master user** (the same `{user}*admin` mechanism
the Lambda layer uses), passing system flags and keywords in one flag
list. Dovecot then owns letter allocation and index consistency. The
helper keeps its procmail contract (`w` flag; non-zero exit leaves the
message for later recipes / DEFAULT), so a failed APPEND degrades to an
undecorated inbox delivery, never a lost message. Deliveries carrying
only F/S keep the existing raw-write path; unflagged deliveries keep
native procmail delivery.

### 6. Rules reference slots and are validated like folders

A rule's flag set becomes a list of slot identifiers. `set_rules`
validates against the palette at write time; the compiler re-validates
at compile time (defense in depth, skip-not-mangle) and skips a rule
referencing a disabled or out-of-range slot with a logged
`flag_not_in_palette`, exactly parallel to `folder_not_found`. Pending
custom flags ride a `PENDING_KW` variable under the same rules as
decision 3; slot atoms are fixed safe strings, so the argv surface
stays trivial.

## Phase 1 -- Truthful Continue

Editor and documentation work only; no server or container changes.

- Apple and Android rule editors: toggle relocated to the top,
  destination gating per decision 1, auto-conversion with inline note,
  stored-rule normalization per decision 2.
- Rule summary lines updated so a continuing Copy rule reads as what it
  is ("Copy to Receipts, continue").
- Editors refuse to save a no-effect rule (destination None, Continue
  ON, no forward/reply -- flag/markRead alone do not count until Phase
  2) with an explanation, closing the silent-evaporation trap of
  Context (2).
- `docs/mail-rules.md`: the Destinations and Order-and-spill-through
  sections state plainly that a continuing rule passes the message
  along and that the inbox is the fallback destination; the
  file-receipts-and-flag-billing example is replaced with one the
  engine honors (the cross-product form), with a pointer to Phase 2's
  composition.
- Changelog fragments per client (`Apple:` / `Android:` prefixes).

Acceptance: editing a prod-shaped rule set (including stored
`move` + `continueToNext`) round-trips to the normalized form; the
disabled destinations render in place on both platforms; no rule
constructible in either editor compiles to `no_effect`.

## Phase 2 -- Pending decorations

Compiler and container work; re-enables the flag-then-file composition.

- `compile-user-rules.py`: emit variable assignments for decorate-only
  rules; fold `${PENDING_F}${PENDING_S}` into every delivery point;
  pending-aware inbox fallback in the procmailrc (runtime-conditioned
  so the undecorated path is unchanged); golden self-test fixtures for
  the new shapes (decorate-then-move, decorate-then-fallback,
  decorate-plus-own-flags, no-decoration byte-identity).
- `cabal-maildir-deliver.sh`: empty-flags argument delivers to `new/`.
- Editors: destination None + Flag/Mark-as-read + Continue becomes
  saveable again (Phase 1 blocked it); summary line for a decorate-only
  rule reads "Flag, continue".
- `docs/mail-rules.md`: the two-rule flag-billing + file-receipts
  composition documented as the worked example, including the ordering
  requirement (decorators above filers).

Acceptance: self-test gate passes; on stage, a decorate-only rule above
a move rule produces a flagged message in the destination folder and
nothing in the inbox; a decorate-only rule with no later match produces
a flagged inbox delivery; rule sets without decoration compile
byte-identically to the pre-phase output.

## Phase 3 -- Flag palette

Storage and palette management; no message-plane changes yet.

- `set_preferences`/`get_preferences`: a `flag_palette` value validated
  structurally (up to 20 entries; slot id in `cabal-flag-01..20`;
  label length-capped, control-characters rejected; color from a fixed
  set; stable order). Whole-palette last-writer-wins is accepted --
  palette edits are rare and single-device in practice.
- **Linux contract test**: `linux/xtask/tests/lambda_preferences_contract.rs`
  asserts exact key-set equality with the Lambda, so the server-side
  key addition must land together with the corresponding entry on the
  Linux side (deliberately-unsupported list or declared key --
  coordinate with the Linux client's owner; it is a one-line change).
- Apple and Android: palette manager in Settings (create, rename,
  recolor, reorder, delete-with-confirmation naming the slot's tagged
  messages caveat: deleting a palette entry hides the label; per-message
  tags on the retired slot remain until untagged and are shown by slot
  id if encountered).
- Reserved slots 21-26 are not exposed anywhere; the decision that
  semantic keywords (e.g. `$Forwarded`) draw from the reserved range is
  recorded here and budgeted, not implemented.

Acceptance: palette round-trips through preferences on both clients;
`cargo test -p xtask` green; a 21st entry is rejected server-side with
a clear client error.

## Phase 4 -- Keywords on the message plane

Make custom flags visible and settable on messages; rules still cannot
set them until Phase 5.

- `cabal-maildir-deliver.sh`: APPEND path per decision 5 (needed here
  for Phase 5, built and soak-tested in this phase behind the
  F/S-only usage).
- `set_flag`: accepts slot keywords in addition to system flags,
  validated against the palette.
- `list_envelopes` / `search_envelopes` / `fetch_message`: envelopes
  carry the message's slot keywords.
- Apple and Android: flag chips/menus on the message list and reader,
  driven by the palette; flag-picker actions wired to `set_flag`.
- S3 envelope/message caches: verify keyword changes invalidate or
  bypass caches the same way `\Flagged` does today.

Acceptance: tagging on one client appears on the other after refresh;
tags survive move/copy across folders (Dovecot name-preserving
translation); a keyword unknown to the palette is rejected by
`set_flag`.

## Phase 5 -- Rules integration

- Rule schema: `flag: boolean` grows to `flags: [slot-id]` (boolean
  accepted on read indefinitely, mapped to the legacy `F` system flag).
- `set_rules` and the compiler validate slots per decision 6;
  `flag_not_in_palette` joins the skip-reason vocabulary and feeds the
  existing `cabal-rules-skipped-anomaly` alarm baseline.
- Compiler: keyworded deliveries route through the APPEND path;
  `PENDING_KW` carries pending slot atoms under decision 3's rules;
  self-test fixtures extended.
- Editors: the rule editor's Flag extra becomes a palette picker
  (system Flagged plus the user's palette).
- `docs/mail-rules.md`: flags section updated; skip reason documented
  in the operator notes.

Acceptance: a rule tagging a slot delivers a tagged message into the
destination folder on stage; a rule referencing a deleted-from-palette
slot is skipped with the logged reason and the user's other rules still
apply; self-test gate passes.

## Observability and operations

- No new AWS services, tables, or IAM surface: the palette rides the
  existing preferences row; keywords are Dovecot-internal. No CI
  policy grants are expected for any phase.
- New compiler skip reasons flow into the existing `Cabal/UserRules`
  metrics and the `cabal-rules-skipped-anomaly` alarm; Phase 2 and 5
  should expect a one-time baseline shift and note it in the rollout
  PR.
- The APPEND path adds a localhost IMAP dependency to keyworded
  deliveries. Failure handling is the helper's existing contract
  (message falls through to later recipes / DEFAULT undecorated); a
  sustained failure is visible as messages arriving untagged plus
  helper stderr in the per-user procmail log on the mailstore EFS.

## Rollout

Each phase ships stage-first through the normal `stage` -> `main`
promotion, and each is independently valuable and independently
revertible: 1 (honest editors) has no server component; 2 (pending
flags) changes compiled output only for rule shapes that previously
compiled to nothing or did not exist; 3-5 are additive API surface
gated by the palette's existence. Phases 1 and 2 are worth shipping
even if custom flags are deferred; Phase 5 requires 2, 3, and 4.
