# Cross-Media UX Plan: One Vocabulary for Mail and Feeds

## Progress

This table and the `**Status:**` line under each phase are updated in
the same PR as the work, so the next session reads where things stand
instead of reconstructing it from the git log.

| Phase | Status |
| --- | --- |
| 1 -- Shared vocabulary and small parities | Shipped in 1.22.0 (2026-09-25) |
| 2 -- Custom flags on feed items | Not started (2026-10-20); follows the unified flags plan |
| 3 -- Acting on feed items in bulk, and out of the reader | Not started (2026-10-20) |
| 4 -- Feed rules | Not started (2026-10-20) |
| 5 -- Cross-media views: flagged and search | Not started (2026-10-20) |
| 6 -- Ambient surfaces: Spotlight | Not started (2026-10-20) |

This document is the design: what each phase builds and why. The
sequencing, the gates against other plans, the verification lanes, and
the maintainer's open decisions live in the execution plans written
after the 2026-10 Apple-client rearchitecture:

- [`post-wave-3/flags-and-cross-media.md`](./post-wave-3/flags-and-cross-media.md)
  runs Phases 2, 4, 5 and 6, preceded by
  [`unified-flags-plan.md`](./unified-flags-plan.md) as its Stage A.
- [`post-wave-3/feed-bulk-actions.md`](./post-wave-3/feed-bulk-actions.md)
  runs Phase 3.
- [`post-wave-3/android-parity.md`](./post-wave-3/android-parity.md)
  runs the Android legs if each one follows its Apple leg (see
  "Context").

Where this document assumes the default answer to an open decision, it
says so; "Open decisions" at the end lists them. The code facts below
were re-checked against `stage` at d6d36148 (2026-10-20).

## Context

The feed reader shipped in 1.15.0
([`rss-implementation-plan.md`](./rss-implementation-plan.md)) as a
second section of the native clients, and 1.20.1 folded its settings
into the mail categories: Reading and Actions each carry an "Email
messages" section and a "Feed items" section instead of a separate
Feeds category. That was the first deliberate step toward the position
this plan takes throughout: **the feed reader is part of the app, not a
bolt-on**, and a user who learns an affordance on one medium should
find it on the other unless there is a reason grounded in the medium
itself.

A parity survey on 2026-09-23 found the two media diverged in ways the
medium does not explain. The mail side had custom flags, server-side
rules, bulk selection, global search, forward, and a full set of macOS
menu chords. The feed side had none of those, but had mark-all-read,
which mail lacked, and the two sides disagreed on a word: mail called
the standard flag "Flag" and showed a flag glyph, while feeds called the
same idea "Favorite" and showed a star. Some of the gaps are recorded
decisions in [`rss-requirements.md`](./rss-requirements.md) (Decision
14 deferred tagging and ruled out keyword muting; Decision 15 deferred
save-for-later). Others were simply unbuilt.

Phase 1 (1.22.0) closed the vocabulary gap and the small parities: the
feed's Favorite became Flag, feed badges follow the Folder counts
setting, mail gained Mark All as Read, the macOS Feeds menu gained the
mail menus' chords, and the feed list's title became a scope
switcher. What remains is the larger work: custom flags and rules on
feed items, bulk selection and forward, the cross-media views, and
Spotlight.

The motivating example is flags. A user who has defined a "Receipts"
flag and a "Read later" flag in Settings > Flags, then opens a feed
item, has no way to apply either. Nothing about an article makes a flag
inapplicable; the palette is already medium-neutral (a slot, a label, a
colour, an enabled bit, synced as a preference), and only the storage
binding, an IMAP keyword per slot, is mail-specific. Extending flags to
feed items is the cheapest of the unifications and the one that unlocks
two deferred feed decisions (tagging, save-for-later) at once. It is
Phase 2. It comes after the unified flags plan, which folds the system
`\Flagged` toggle into the palette as one more entry and gives both
media one flag mark: building the feed flag menu and row dots before
that would mean building them twice.

Apple and Android are the reference clients. The React admin app is
second-class and receives none of this unless separately prioritised.
The Linux client is out of scope. Phase 1 shipped on both clients at
once. Whether later phases do, or Android follows a release behind each
Apple phase through `android-parity.md`, is open (see "Open
decisions"); both execution plans recommend the split. Server changes
stay additive either way, so a client that has not caught up keeps
working.

### What the rearchitecture changed underneath

The 2026-10 rearchitecture of the Apple clients (Waves 0.1 to 3.3)
moved most of the code this plan names. The facts a phase depends on:

- The Apple app layer is one `CabalmailUI` module in feature folders.
  `MailRootView` is gone: `SignedInRootView` picks one of four shells
  and holds the window's `SceneNavigator` above the switch.
- Selection is a generic, per-window `SelectionModel<ID>` held above the
  layout switch. Only mail uses it (`SelectionModel<MessageRef>`); the
  feed list still selects one `RssItem?`.
- `MessageRef` is mail's item identity. There is no medium-neutral item
  identity, and `AppRoute` keeps separate mail and feed halves.
- The wide sidebar is mail's folder `List` (`FolderListView`, hosted by
  `MailSidebarColumn`). Feeds are drawn inside it as row buttons
  (`FeedSidebarContent`'s `.rowButtons` mode), because one `List`
  carries one selection type.
- Menu commands are window-scoped (`WindowCommand` through
  `FocusedValue`), and the Message, Mailbox and Feeds menus act on the
  window in front.
- The chrome kit (`Shared/Chrome/`) is shared by both media, but has no
  unread dot or flag mark yet; the unified flags plan adds them.
- `RssStore` is at schema 6, and `openRecovering` deletes a file written
  by a newer schema. Android's `RoomRssStore` is at version 1 with a
  destructive fallback.

### Where the two media already align

These are the model to copy, not work items:

- **Resume where you left off**
  ([`resume-session-plan.md`](./resume-session-plan.md)) carries a
  section, a scope, and an item for either medium, and the
  reading-position cache keys entries `mail:` and `feed:`. Same
  behaviour, one record.
- **Swipe actions** use one settings pane, the same option shape, and
  the same wire-key pattern (`swipe_*` and `rss_swipe_*`). The feed
  picker correctly omits Dispose: there is nowhere to dispose a feed
  item to.
- **The reader.** `FeedItemDetailView` renders a feed item's in-feed
  body through the same sandboxed `HTMLBodyView` the mail reader uses,
  with the same reader stylesheet and link menu; only the publisher's
  live page uses its own `ArticleWebView`.
- **List and sidebar chrome.** One `FilterPill`, `CountBadge`,
  `SidebarTreeRowLabel` and `TitleSwitchMenu` serve both media, and one
  `ReaderToolbarPolicy` lays out both readers' toolbars.
- **Phase 1's vocabulary**: the Flag word and glyph, the Folder counts
  setting, the Mark All as Read chord, and the title switcher.

## Goals

- A user-defined flag applies to a mail message and to a feed item, by
  the same name, colour, and gesture, from the same menu.
- Both lists can be filtered by a custom flag. Neither can today: mail's
  filter is All, Unread, or Flagged (`MessageFilter`).
- Bulk selection works on feed items as it does on mail, with the
  actions that apply to a feed item.
- Rules exist for both media, edited in one place, with the conditions
  and actions each medium supports.
- A feed item can leave the reader as an email.
- "Flagged" and "Search" can show both media at once.
- Feed items appear in Spotlight beside mail.

## Non-goals

- **Move, archive, and trash for feed items.** Feed items are not
  user-owned objects; retention is by policy (Decision 4 of the RSS
  requirements). A per-item trash would fight it. The swipe picker's
  missing Dispose stays missing.
- **Snooze and threading.** Neither medium has them; snooze was ruled
  out (Decision 15) and a threaded view was never planned.
- **Converging the reader defaults.** The Android-strips-author-CSS
  versus Apple-overrides reader-mode experiment (since 2026-08-20) is
  the maintainer's to call and is not settled by this plan.
- **Server-side cross-feed full-text search.** Decision 14 (revised)
  deferred it indefinitely on cost. Phase 5's cross-media search is
  client-side over the local cache.
- **Newsletter ingest and feed-to-email digests** (Decisions 7 and 8)
  stay on the roadmap. Phase 3's forward-as-email is a manual, one-off
  action and does not reopen either.
- **Feed notification settings before feeds can notify.** Delivery is
  RSS plan Phase 8, which has not started, and the settings surface
  lands with it (Phase 6 explains why, and "Open decisions" has the
  alternative).
- **Print and Open in Browser parity.** Mail has no Open in Browser
  equivalent and neither medium prints; neither is a gap to close.
- **App Intents and the Watch for feeds.** An "Open feed" intent and a
  Watch feed view have no demand.
- **The React admin app and the Linux client.**

## Design decisions

### 1. The flag palette is the one source of truth

The palette (`FlagPalette.swift`, `FlagPalette.kt`; the `flag_palette`
synced preference) holds twenty keyword slots `cabal-flag-01` ..
`cabal-flag-20`, each with a label, colour, and enabled bit, and, once
the unified flags plan ships, one more entry for the system `\Flagged`
flag (21 entries at most). Feed items reference the same entries.
Renaming or recolouring a flag in Settings therefore changes it on both
media at once, and an entry disabled in the palette disappears from
both menus while its marks persist, exactly as mail keywords do today.
There is no second palette, no feed-specific flag, and no per-medium
enable bit.

On a feed item, the `\Flagged` entry binds to the existing
`is_favorite` bit and the keyword slots bind to a new `flags` set
(Decision 2). So the feed's Flag control takes the Flagged entry's name
and colour and hides when that entry is disabled; and once Phase 2
gives feed items keyword flags, the feed swipe and ⌘⇧8 toggle the
user's default flag (the first enabled entry), as mail's do after
unified flags. This is the "Follows the palette" default; the
alternative keeps a fixed Flagged toggle on feeds whatever the palette
says.

### 2. Feed item flags are a string set on the state row

The per-user, per-item state row already carries `is_read`,
`is_read_explicit`, and `is_favorite`. It gains `flags`, a DynamoDB
string set of keyword slot identifiers (`\Flagged` stays
`is_favorite`). `/rss_set_item_state` accepts `add_flags` and
`remove_flags` lists per item and applies them with `ADD` and
`DELETE`, which are atomic and commutative. That matches IMAP's
`+FLAGS` / `-FLAGS` semantics and means two devices flagging the same
item offline cannot clobber each other, which a whole-set replace
would.

Validation follows `set_flag`'s `_check_keyword`: adding needs a slot
that is enabled in the user's palette; removing is always allowed, so a
retired slot can still be cleared; and an entry that adds and removes
the same slot is rejected. Items and state-sync rows serialise `flags`
as a sorted list, empty when the attribute is absent. No new index:
clients already hold the item cache and count unread locally, so a
per-flag filter on feeds is a local query.

### 3. "Favorite" became "Flag"

Shipped in Phase 1. The feed's standard mark is the same idea as mail's
`\Flagged`, and with custom flags coming to feed items, a "Favorite"
star beside a flag menu would have been a contradiction. The feed UI
adopted the mail word and glyph everywhere: the row indicator, the
reader button, the swipe action, the filter pill ("Flagged"), and the
Actions settings picker. Wire fields (`is_favorite`, `favorite_key`,
the `favorite_by_feed` index, the `filter=favorite` query value, the
`rss_swipe_*` option value) are unchanged; it was a presentation rename.
Renaming mail's flag to "Favorite" instead was rejected: mail users
know the term, the IMAP flag is named for it, and the custom flags were
already called flags. The unified flags plan later replaces the glyph
on both media with the palette-coloured dot, through one shared mark.

### 4. Feed rules sit beside mail rules in the rules document and run at ingest

Mail rules are a versioned document behind `/get_rules` and
`/set_rules`, compiled to procmail by the IMAP tier and applied at
delivery. Feed rules join the same document, so there is one editor,
one versioning scheme, one conflict story, and one place to list them.
They sit in a list of their own, `feedRules`, beside `rules` and under
the same `version`, rather than as entries of `rules` marked by a
`source` field.

The shipped decoders rule out putting them inside `rules`:

- Android's decoder fails the whole set on a condition field or action
  it does not know, and Apple builds before 1.39.1 did the same (#1901).
  One feed rule would leave every rule unreadable on those builds.
- Apple from 1.39.1 keeps such a rule opaque and read-only, but its
  encoder writes only the keys it knows, so a save from it would drop
  `source` and send the feed rule back as a mail rule.
- A feed rule with no conditions and only decoration actions is a
  well-formed mail rule. Every shipped build would show it as one that
  matches all mail, and a save would make it one.

Beside `rules`, a feed rule is invisible to shipped builds: their
decoders read only `rules`, `version`, and `updatedAt`. A save from a
shipped build carries no `feedRules` key, and `set_rules` keeps the
stored list when the key is absent. Since every save still bumps
`version`, a feed-rule edit racing a mail-rule edit on another device
gets the same conflict as two mail-rule edits. The procmail compiler
reads only `rules` and does not change.

A feed rule's conditions are drawn from `feed` (subscription), `title`,
`author`, and `summary`. Its actions are the three decorations a mail
rule has: `flag` (the item's Flagged mark, `is_favorite`), `flags`
(keyword slots, validated as for mail), and `markRead`. A feed rule has
no destination. `set_rules` validates each list against its own
condition and action sets, so a saved rule always means something,
which is the lesson of the rules-composition plan's
"decorate-then-file" finding.

Feed rules are evaluated server-side when the fetcher inserts a new
item (`rss_fetch`, `insert_item`), once per subscriber of the feed, and
the outcome is written straight to that subscriber's state row. This is
the delivery-time analogue of procmail. Client-side evaluation on sync
was rejected: with several devices, whichever synced first would apply
the rule, the others would see the outcome only after state sync, and a
device that never syncs a feed would never apply it.

The fetcher cannot do this today. It has no way to find a feed's
subscribers (the subscription table's only feed-keyed index is the
sparse `by_feed_notify`), and its IAM role reaches neither the rules
table, nor the subscription table, nor the item-state table. Phase 4
adds a feed-keyed subscription index and those grants. A feed is shared
across subscribers, so the fetcher loads each subscriber's rules once
per invocation; at hobby scale the subscriber count per feed is small
and the item count per fetch smaller. Evaluation is best effort: a
rules lookup that fails is logged and never fails ingestion or
dead-letters the feed.

### 5. Keyword mute stays out

Decision 14 ruled out per-feed keyword muting, and this plan does not
reopen it. A feed rule's `markRead` action is the closest thing it
offers: the item still appears, already read, in the list. A `hide`
action would be muting by another name, so it is not proposed; if the
decision is ever revisited, the feed rule model has an obvious slot for
it.

### 6. Mark-all-read for mail is a server endpoint

Shipped in Phase 1. The Apple and Android clients talk to the Lambda
API, not IMAP, so a client cannot issue `STORE 1:* +FLAGS \Seen`
itself, and paging every UID through `/set_flag` is wrong for a large
folder. `/mark_folder_read` takes `{host, folder}`, finds the folder's
unseen messages with one SEARCH, and sets `\Seen` on them in batched
STOREs through the shared helper, answering `{status, flipped,
failed}`. It is the mail twin of `/rss_mark_all_read`.

### 7. Bulk selection on feed items reuses the mail machinery

The feed list adopts the mail list's selection as it is: a
`SelectionModel` for the window, held above the layout switch so a
selection survives a shell change, keyed by the feed item's id. The
bulk action bar now drawn in `MessageListView+Bulk` becomes one shared
view both lists mount, and modifier-click on macOS follows
`MessageListView+ModifierClick`. On iPad the feed list's Select button
and modifier-clicks go through a `Platform/` adapter (FU-9 in
[`platform-conditionals-followups.md`](./platform-conditionals-followups.md)),
not a new `#if`. Android: the `SelectionTopBar` that `MessageListScreen`
uses, on `FeedItemListScreen`. The bulk actions are the subset that
applies to feed items: mark read or unread, toggle the flag, and (after
Phase 2) set custom flags. Move and Dispose are absent for the reason
in Non-goals.

### 8. Cross-media views: the feed half is local, the mail half is not

The "Flagged" view and the cross-media search results are assembled on
the device and interleave or section rows from both media, but only the
feed half can come from a local cache. The `RssStore` item cache holds
every downloaded item and its FTS index, so flagged and matching feed
items are local queries. The mail envelope cache holds only the folders
a device has opened (one file per folder, the first pages of each), so
it cannot answer "every flagged message". The mail half therefore comes
from the server's cross-folder search (`search_envelopes` with no
`folder`, which searches every subscribed folder but Trash, and
`flagged=1`), online only, until the SQLite mail store's cross-folder
flagged query ([`post-wave-3/sqlite-mail-store.md`](./post-wave-3/sqlite-mail-store.md)
PR 5.1) keeps it for offline use. By default the Flagged view waits for
that query rather than being built twice.

Filtering either half by a custom flag needs one server change:
`search_envelopes` has no keyword criterion, so it gains an optional
`keyword`, checked against the slot pattern and mapped to IMAP
`KEYWORD`. The same parameter serves the per-flag filter on the mail
list (Phase 2).

Rows in a mixed list need one identity for either medium: a two-case
`ItemRef` in the Kit (`.mail(MessageRef)` and a feed case keyed by feed
and sort key). The sidebar needs one selection (a mail folder, a feed
scope, or a smart view) in place of the row-button workaround, so one
`List` selects both media and can host the Flagged entry. The Flagged
view interleaves rows by date, each with its medium's glyph. Search
results are sectioned by medium rather than merged, because the two
searches have different scopes (the whole mailbox versus the cached
window of each feed) and a merged list would imply a completeness the
feed side cannot promise.

## Phase 1 -- Shared vocabulary and small parities

**Status:** Shipped in 1.22.0 (2026-09-25) on both clients, with the
`mark_folder_read` Lambda. No stage or device verification was recorded
before release. Every item has been in use since, and later releases
fixed defects found in them (Mark All as Read acting only on the window
in front, one title menu for mailboxes and feeds, offline mark-all-read
on feeds), so the acceptance line below is a regression check, not an
owed step.

What shipped:

1. **Favorite became Flag** (Decision 3) on the feed rows, reader
   button, swipe action, filter pill, and Actions settings picker. On
   Android the flag glyph was already the star mail uses, so only the
   words changed there.
1. **Folder counts govern feed badges.** The Reading preference
   `folderCountDisplay` (unread, total, or both) applies to the feed
   rows and the All Feeds and per-folder roll-ups as it does to mail
   folders. The preference moved above the "Email messages" section on
   both platforms, since it governs both media.
1. **Mark all read for mail** (Decision 6), from the Mailbox menu, the
   sidebar folder context menu and the message list's toolbar overflow
   on Apple, and the folder overflow menu on Android, always confirming
   first and naming the folder.
1. **macOS Feeds menu chords.** Mark as Read/Unread (⌘T), Flag/Unflag
   (⌘⇧8), and Mark All as Read (⌥⌘T, the Option variant of the
   per-message ⌘T, on the Mailbox menu as well). The menu that is
   enabled follows the active section, so a chord never fires on both.
1. **The feed list's title is a scope switcher**, as the folder name
   above the mail list is: "All Feeds" first, then the folder tree
   flattened with indentation for depth (sub-folders before feeds, root
   feeds last), the current scope checked. A search scope keeps its
   plain title.
1. **Android settings section fix** (#1706): "Default sort" and "Sort
   descending" moved back under "Email messages".

Acceptance: a tester who reads a feed item, flags it, filters the feed
to Flagged, and then does the same in INBOX sees the same word, glyph,
and chord on both; marking INBOX all read from the sidebar flips every
unseen message in one call; tapping the feed list's title opens a menu
that switches to another feed or folder without leaving the list,
exactly as tapping the folder name does in mail.

## Phase 2 -- Custom flags on feed items

The motivating feature. It follows the unified flags plan, which puts
`\Flagged` in the palette, adds the shared flag mark to the chrome kit,
and retargets the toggle gestures to the default flag. Server first,
then the Kit, then the clients.

**Status:** Not started (2026-10-20). The unified flags plan has not
started either.

### 2a. Server

1. `rss_set_item_state`: accept `add_flags` and `remove_flags` per item
   and apply them with `ADD flags :add` and `DELETE flags :remove`,
   validated as Decision 2 says. A `\Flagged` in either list is
   rejected; that mark is `favorite`. `updated_at` and `updated_key`
   advance as for any state change, so state sync carries the flags.
1. `rss_api.serialize_item` and `serialize_state`: emit `flags` as a
   sorted list, empty when the attribute is absent.
1. `search_envelopes`: an optional `keyword` (Decision 8), for the
   per-flag filter on the mail list.
1. `docs/rss.md`: the item and state objects and the endpoint row.
1. Tests in `lambda/api/_shared/tests` for the expression builder, the
   validation, the serialisers, and the keyword criterion.

### 2b. Kit and clients

1. **Models.** `RssItem` gains `flags` (Apple and Android:
   `Set<String>`), and the state change carries `addFlags` and
   `removeFlags`. Apple: `RssStore` schema 7, on the migration runner
   from the SQLite mail store plan's PR 0.1, adds an `items.flags`
   column (a JSON list) and a slot column on `pending`, with a flag
   kind whose value means add or remove. Android: the feed store is at
   Room version 1 with a destructive fallback, so its first bump needs
   a real migration or an upgrade drops queued marks. `android-parity.md`
   PR 9 plans that bump (version 2, for folder and All Feeds order); if
   it lands first, as planned, Phase 2 is version 3.
1. **Sync.** `RssSyncEngine` on both platforms applies `flags` from item
   pages and state pages, and queues flag changes through the existing
   pending queue. Coalescing is per item and slot, so the latest intent
   wins (an add followed by a remove of the same slot leaves a remove,
   not nothing), and a state page never overwrites a slot that has a
   queued change. The drain sends at most 100 items a call, and every
   write shares a transaction with its queue row, as #1956 made the
   read and flag writes do.
1. **Menus.** The mail flag menu's builder (`FlagMenuPolicy`, now in
   `Mail/Reader/` beside `MessageDetailView+FlagOptions`) moves to
   `Shared/` over a small "flaggable" value (the current slots, add,
   remove) and is mounted on the feed reader's Flag button
   (`FeedReaderToolbar`, which becomes a menu with a primary action, as
   mail's is) and on the feed row's context menu. Android generalises
   the flag menu in `MessageDetailScreen` the same way and mounts it on
   `FeedItemDetailScreen` and the feed row. The palette's enabled bit
   and order are honoured identically.
1. **Rows.** Feed rows draw the keyword dots through the shared flag
   mark, the same size and order as mail rows (`MessageListView+Rows`,
   `EnvelopeRow`).
1. **Filter.** Both lists gain a per-flag filter. By default it is one
   flag picker inside the Flagged pill rather than a pill per flag (the
   pill row already wraps at narrow widths, #2014), and the pick resets
   when the list is left. Mail filters through `keyword`; feeds query
   the local cache.
1. **Swipe.** `FeedSwipeAction` gains no new case. The flag toggle
   follows the default flag (Decision 1), and custom flags stay a menu
   action on both media.
1. **Bulk.** If Phase 3 has landed, Set Flags joins the feed bulk bar.

Acceptance: flag an article "Read later" on the phone; it shows the
dot on the Mac after sync; disable the slot in Settings and the dot
vanishes on both media; re-enable and it returns. Two devices offline,
one adds slot 3 and the other adds slot 5 to the same item; after both
sync the item carries both. Filter INBOX and a feed to "Read later" and
each shows only the items carrying it.

**Changelog:** one `Apple:` and one `Android:` fragment, and a plain
fragment for the server PRs. The Android headline shares the
500-character release budget.

## Phase 3 -- Acting on feed items in bulk, and out of the reader

**Status:** Not started (2026-10-20). `feed-bulk-actions.md` runs it in
two sessions: first the feed Kit writes and list tidy-ups, including a
one-request Mark All as Read for a feed folder or All Feeds, then
multi-selection and Forward. The bug fix it opened with, #1914 (a
back-out button on the six feed and flag confirmation dialogs), shipped
in 1.39.1.

1. **Bulk selection** (Decision 7). Selected items are written through
   `/rss_set_item_state`, at most 100 per call, as the endpoint allows.
   Actions: mark read, mark unread, toggle the flag, and set custom
   flags once Phase 2 has shipped.
1. **Forward as email.** "Forward as Email…" on the feed reader (by
   default in its View menu on iPhone and iPad and its More menu on the
   Mac and visionOS, not as a toolbar button) and on the row's context
   menu opens the existing composer with the subject `Fwd: <title>`,
   the item's link on the first line, mail's forward banner, and then
   the summary as plain text with its paragraph breaks (a capped start
   of the article when the feed sends no summary). Plain text matches
   mail's forward, which is plain text (`ReplyBuilder`), and keeps
   untrusted feed markup out of the rich-text composer. Nothing is
   sent server-side. Android mirrors through the same compose route.
   The share sheet keeps sharing the link.

Acceptance: select eight articles, mark them read, undo one; forward
an article and the received mail carries the link and the summary.

## Phase 4 -- Feed rules

**Status:** Not started (2026-10-20).

### 4a. Server and infrastructure

1. **Terraform.** A feed-keyed index on the subscription table, and
   grants for `rss_fetch`: read on the rules table, query on the new
   index, update on the item-state table. Applied through `infra.yml`
   with Checkov, tflint, and tfsec. `app.yml` deploys Lambda code
   independently of `infra.yml`, so this rides a promotion before the
   code that needs it.
1. **`get_rules` and `set_rules`.** `get_rules` returns `feedRules`
   (empty when absent). `set_rules` accepts it as an optional key under
   the same version check, validates it as Decision 4 says, and keeps
   the stored list when a save omits the key. The procmail compiler is
   unchanged.
1. **`rss_fetch`.** On `insert_item`, evaluate each subscriber's feed
   rules against the parsed item and write the resulting `flags`,
   `is_favorite`, and explicit `is_read` to the subscriber's state row.
   Conditions match case-insensitively on the plain text of the field,
   as mail rules do on headers. Best effort, per Decision 4. Metrics:
   rules evaluated and items matched, per feed.
1. **Docs.** `docs/mail-rules.md` gains a "Feed rules" section;
   `docs/rss.md` notes the ingest-time evaluation.

### 4b. Clients

1. **Model.** A feed rule type and validator beside `Rule` and
   `RulesValidator` (Apple: `Rule.swift`, `RulesValidator.swift`;
   Android: `Rules.kt`, `RulesValidator.kt`), decoding `feedRules` and
   mirroring the server's validation. A value the build does not know
   keeps the rule opaque, as #1901 made Apple's mail rules do, rather
   than failing the set.
1. **Editor.** Settings > Rules (`RulesView`, Android `RulesScreen`)
   gains a "Feed items" section after "Email messages" in the same
   form. Adding a rule there opens the editor (`RuleEditorView`,
   `RuleEditorScreen`) with the feed condition fields and the three
   decoration actions. The source scans that read the Rules files
   (`RulesPaneContainerSourceScanTests`, `RuleRowHitTargetTests`,
   `SectionFooterWrapTests`) are asked about before they change, never
   edited to pass.
1. **Template.** A "Flag matching items" feed template beside the
   existing `muteNewsletter` mail template.

Acceptance: a rule "title contains 'release' in feed X, flag
Releases" flags the next matching item on ingest, on every device,
before any device opens the feed. A save of the mail rules from a build
that predates Phase 4 leaves the feed rule in place.

## Phase 5 -- Cross-media views: flagged and search

**Status:** Not started (2026-10-20).

1. **Structure first** (Decision 8). `ItemRef` in the Kit and one
   sidebar selection, shipped alone in its release because it changes
   root navigation: `AppRoute` gains the smart view and still decodes
   routes stored by older builds, and the restore suites guard it. On
   iPhone and iPad, where the Flagged entry lives depends on
   `post-wave-3/duo-support.md` Decision 9 (one view tree or two
   shells), so the single sidebar list lands on the Mac and visionOS
   first.
1. **Flagged smart view.** A "Flagged" entry in the sidebar above the
   mail folders (Apple: the folder `List` in `FolderListView`, which
   the wide shells host through `MailSidebarColumn` and which the feeds
   join from `FolderListView+Helpers.swift`; Android: the top of
   `FolderListScreen`) lists flagged mail and
   flagged feed items interleaved by date, each row carrying its
   medium's glyph and opening in its medium's reader. A flag picker
   within the view selects a custom flag. Counts follow the Reading
   preference.
1. **Search scope.** The global search field (`SearchView`) drops the
   "Search all mail" prompt for "Search", gains a scope segment (All,
   Mail, Feeds), and shows results sectioned by medium. The feed
   section widens `RssStore`'s FTS query (`search(feedId:query:)`)
   from one subscription to all cached items, with Android's Room store
   gaining the equivalent query; the mail section is the existing
   server search. The feed section's footer states that it searches
   downloaded items only.
1. **Resume from results.** A row opened from either section writes the
   same resume record its medium's reader writes today.

Acceptance: search a word that appears in an email and in an article
and both appear, sectioned; open the Flagged view on the Mac and see
the article flagged on the phone in Phase 2 beside a flagged message.

## Phase 6 -- Ambient surfaces: Spotlight

**Status:** Not started (2026-10-20).

1. **Spotlight for feed items** (Apple). `SpotlightIndexer` indexes
   envelopes and message bodies today. It gains a feed-item path fed by
   `RssSyncEngine`, under its own domain identifier, with the item's
   title and summary text, pruned with the local cache and removed at
   sign-out. `DeepLinkRouter` has message, Spotlight, and folder links;
   it gains a feed item link, and the Spotlight handling in
   `SpotlightRouting.swift` (an `AppState` extension) routes a feed
   result through it to the item's reader.
1. **Feed notification settings wait for delivery.** The feed
   subscription's `notifications_enabled` flag exists end to end on the
   server (`/rss_update_subscription`, the SQLite and Room columns) but
   has no client toggle and no dispatch path, and dispatch is RSS plan
   Phase 8, not started. A toggle shown before then would do nothing,
   and the two settings are different kinds of switch: mail's
   notification choices are per device, kept on that device's push-token
   row, while a feed's switch is per subscription and synced to every
   device. The visionOS build has no Notifications section at all. So
   the feed half of Settings > Notifications is designed and built with
   delivery in RSS Phase 8, which will have to say how the two kinds of
   switch sit together.

Acceptance: a Spotlight search for an article title opens it in the
app; signing out removes the feed entries from Spotlight.

## Rollout

- Each phase is its own PR or small PR set to `stage`, verified on
  stage with the shared tester account, then promoted with the next
  release. Only one Apple PR from these plans is open at a time, to
  pace the macOS CI runners.
- **Server first, to prod.** A server PR is promoted to prod before a
  client PR that relies on it merges to `stage`, because a TestFlight
  build from `stage` talks to prod, and each failure against an older
  prod is silent: an older `rss_set_item_state` answers 200 to an
  `add_flags`-only entry and skips it, so the client's drain deletes
  the queued mark; an older `search_envelopes` ignores `keyword`, so a
  per-flag filter shows unfiltered mail; an older `set_rules` reads only
  `rules` and answers 200, so a saved feed rule is dropped.
- Server changes (Phases 2a and 4a) are additive and backward-compatible
  the other way: a client that does not send `add_flags` gets today's
  behaviour, and a build that knows nothing of `feedRules` never sees
  or loses a feed rule. Shipped app versions keep working across each
  server deploy.
- Local schema migrations (`RssStore` schema 7, the next Room version)
  are forward-only, but a downgrade is not yet safe: `RssStore` deletes a
  file written by a newer schema, and with it any unsent feed marks.
  The SQLite mail store plan's PR 0.2 sets such a file aside and
  imports its pending rows when a newer build returns; by default
  schema 7 ships after that. Room must not move past version 1 without
  a real migration.
- The tester pipeline's sweep prompts cover feeds already; each phase's
  acceptance line above is written to be a sweep item.

## Open decisions

These are the maintainer's, asked in the execution plans with a
recommended default. This document is written to the defaults;
answering otherwise changes the phase named.

| Decision | Phase | Default | Asked in |
| --- | --- | --- | --- |
| Do later phases ship on Android with Apple, or a release behind? | All | A release behind, through `android-parity.md` | flags-and-cross-media 3; feed-bulk-actions 2 |
| Does the feed's Flag control follow the palette's Flagged entry? | 2 | Follows the palette | flags-and-cross-media 2 |
| Per-flag filtering: both lists, sticky or per visit, or neither yet? | 2 | Both lists, per visit | flags-and-cross-media 4 |
| Does feed schema 7 ship before the shared offline queue? | 2 | Before, after the set-aside fix | flags-and-cross-media 5 |
| How does Mark All as Read on a feed folder reach the server? | 3 | One queue row per feed, sent as one request | feed-bulk-actions 3 |
| Where does Forward as Email go? | 3 | The reader's menus and the row menu | feed-bulk-actions 4 |
| What does the forwarded mail contain? | 3 | The summary as plain text | feed-bulk-actions 5 |
| Where are feed rules stored? | 4 | `feedRules` beside `rules` | flags-and-cross-media 6 |
| Is the Flagged view built now or on the SQLite store's query? | 5 | On the SQLite store's query | flags-and-cross-media 7 |
| Keep or drop the All / Mail / Feeds search scope? | 5 | Keep | flags-and-cross-media 8 |
| Feed notification settings before feeds can notify? | 6 | Wait for RSS Phase 8 | flags-and-cross-media 9 |

Keyword mute (Decision 5) and the Favorite-to-Flag rename (Decision 3)
are settled and not asked again.
