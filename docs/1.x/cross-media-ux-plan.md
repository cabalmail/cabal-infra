# Cross-Media UX Plan: One Vocabulary for Mail and Feeds

## Progress

This table and the `**Status:**` line under each phase are updated in
the same PR as the work, so the next session reads where things stand
instead of reconstructing it from the git log.

| Phase | Status |
| --- | --- |
| 1 -- Shared vocabulary and small parities | Not started |
| 2 -- Custom flags on feed items | Not started |
| 3 -- Acting on feed items in bulk, and out of the reader | Not started |
| 4 -- Feed rules | Not started |
| 5 -- Cross-media views: flagged and search | Not started |
| 6 -- Ambient surfaces: notifications and Spotlight | Not started |

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
medium does not explain. The mail side has custom flags, server-side
rules, bulk selection, global search, forward, and a full set of macOS
menu chords. The feed side has none of those, but does have
mark-all-read, which mail lacks. Some of the gaps are recorded
decisions in [`rss-requirements.md`](./rss-requirements.md) (Decision
14 deferred tagging and ruled out keyword muting; Decision 15 deferred
save-for-later). Others are simply unbuilt. And the two sides even
disagree on a word: mail calls the standard flag "Flag" and shows a
flag glyph, while feeds call the same idea "Favorite" and show a star.

The motivating example is flags. A user who has defined a "Receipts"
flag and a "Read later" flag in Settings > Flags, then opens a feed
item, has no way to apply either. Nothing about an article makes a flag
inapplicable; the palette is already medium-neutral (a slot, a label, a
colour, an enabled bit, synced as a preference), and only the storage
binding, an IMAP keyword per slot, is mail-specific. Extending flags to
feed items is the cheapest of the unifications and the one that unlocks
two deferred feed decisions (tagging, save-for-later) at once. It is
Phase 2, after a vocabulary phase that makes the rest coherent.

As with every native-client plan, Apple and Android are the reference
clients and ship together per phase. The React admin app is
second-class and receives none of this unless separately prioritised.
The Linux client is out of scope.

### Where the survey found the two media already aligned

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
- **The reader** shares `HTMLBodyView`, the reader stylesheet, and the
  link menu between a mail body and a feed summary.

## Goals

- A user-defined flag applies to a mail message and to a feed item, by
  the same name, colour, and gesture, from the same menu.
- Every list-level action that makes sense for both media exists for
  both: mark all read, bulk selection, per-flag filtering, the macOS
  menu chords, and the title-as-switcher above the list.
- Rules exist for both media, edited in one place, with the conditions
  and actions each medium supports.
- A feed item can leave the reader as an email.
- "Flagged" and "Search" can show both media at once.
- Feed notifications and Spotlight entries appear where the mail ones
  already do.

## Non-goals

- **Move, archive, and trash for feed items.** Feed items are not
  user-owned objects; retention is by policy (Decision 4). A per-item
  trash would fight it. The swipe picker's missing Dispose stays
  missing.
- **Snooze and threading.** Neither medium has them; snooze was ruled
  out (Decision 15) and threading was never planned.
- **Converging the reader defaults.** The Android-strips-author-CSS
  versus Apple-overrides reader-mode experiment (since 2026-08-20) is
  the maintainer's to call and is not settled by this plan.
- **Server-side cross-feed full-text search.** Decision 14 (revised)
  deferred it indefinitely on cost. Phase 5's cross-media search is
  client-side over the local cache.
- **Newsletter ingest and feed-to-email digests** (Decisions 7 and 8)
  stay on the roadmap. Phase 3's forward-as-email is a manual, one-off
  action and does not reopen either.
- **The React admin app and the Linux client.**

## Design decisions

### 1. The flag palette is the one source of truth

The palette (`FlagPalette.swift`, `FlagPalette.kt`; the `flag_palette`
synced preference) stays exactly as it is: twenty fixed slots
`cabal-flag-01` .. `cabal-flag-20`, each with a label, colour, and
enabled bit. Feed items reference the same slot identifiers. Renaming
or recolouring a flag in Settings therefore changes it on both media at
once, and a slot disabled in the palette disappears from both menus
while its marks persist, exactly as mail keywords do today. There is no
second palette, no feed-specific flag, and no per-medium enable bit.

### 2. Feed item flags are a string set on the state row

The per-user, per-item state row already carries `is_read`,
`is_read_explicit`, and `is_favorite`. It gains `flags`, a DynamoDB
string set of slot identifiers. `/rss_set_item_state` accepts
`add_flags` and `remove_flags` lists per item and applies them with
`ADD` and `DELETE`, which are atomic and commutative. That matches
IMAP's `+FLAGS` / `-FLAGS` semantics and means two devices flagging the
same item offline cannot clobber each other, which a whole-set replace
would. Items and state-sync rows serialise `flags` as a list (empty
when absent). No new index: clients already hold the item cache and
count unread locally, so a per-flag filter is a local query.

### 3. "Favorite" becomes "Flag"

The feed's standard mark is the same idea as mail's `\Flagged`, and
once custom flags exist on feed items, a "Favorite" star beside a flag
menu is a contradiction. The feed UI adopts the mail word and glyph
everywhere: the row indicator, the reader button, the swipe action, the
filter pill ("Flagged"), and the Actions settings picker. Wire fields
(`is_favorite`, `favorite_key`, the `favorite_by_feed` index, the
`filter=favorite` query value, the `rss_swipe_*` option value) are
unchanged; this is a presentation rename and a client-only change.
The alternative, renaming mail's flag to "Favorite", was rejected: mail
users know the term, the IMAP flag is named for it, and the custom
flags are already called flags.

### 4. Feed rules live in the rules document and run at ingest

Mail rules are a versioned document behind `/get_rules` and
`/set_rules`, compiled to procmail and applied at delivery. Feed rules
join the same document rather than a second one, so there is one
editor, one versioning scheme, one conflict story, and one place to
list them. A rule gains a `source` field, `mail` (the default, so
existing documents parse unchanged) or `feed`. A feed rule's conditions
are drawn from `feed` (subscription), `title`, `author`, and `summary`;
its actions are `flags` (slots, validated as for mail) and `markRead`.
`set_rules` rejects a mail action on a feed rule and vice versa, so a
saved rule always means something, which is the lesson of the
rules-composition plan's "decorate-then-file" finding.

Feed rules are evaluated server-side when the fetcher inserts a new
item (`rss_fetch`, `insert_item`), once per subscriber of the feed, and
the outcome is written straight to that subscriber's state row. This is
the delivery-time analogue of procmail. Client-side evaluation on sync
was rejected: with several devices, whichever synced first would apply
the rule, the others would see the outcome only after state sync, and
a device that never syncs a feed would never apply it. A feed is shared
across subscribers, so the fetcher loads each subscriber's rules once
per invocation; at hobby scale the subscriber count per feed is small
and the item count per fetch smaller.

### 5. Keyword mute stays out; this plan does not reopen it

Decision 14 ruled out per-feed keyword muting. A feed rule's `markRead`
action is the closest thing this plan offers: the item still appears,
already read, in the list. A `hide` action would be muting by another
name, so it is not proposed. If the maintainer wants to revisit the
decision, the rule model in Decision 4 has an obvious slot for it.

### 6. Mark-all-read for mail is a server endpoint

The Apple and Android clients talk to the Lambda API, not IMAP, so a
client cannot issue `STORE 1:* +FLAGS \Seen` itself, and paging every
UID through `/set_flag` is wrong for a large folder. A new
`/mark_folder_read` endpoint takes a folder and sets `\Seen` on its
unseen messages in one IMAP round trip through the shared helper. It is
the mail twin of `/rss_mark_all_read` and takes the same shape:
`{folder}` in, `{flipped}` out.

### 7. Bulk selection on feed items reuses the mail machinery

The feed item list adopts the mail list's selection modes as they are:
`bulkMode` and the selection bar on iOS, modifier-click on macOS, the
`SelectionTopBar` on Android. The bulk actions are the subset that
applies to feed items: mark read or unread, flag or unflag, and set
custom flags. Move and Dispose are absent for the reason in Non-goals.

### 8. Cross-media views are client-side over the local caches

The "Flagged" smart view and the cross-media search results are
assembled on the device from the mail envelope cache and the
`RssStore` item cache, interleaved by date with a medium indicator on
each row. Neither needs a server change. Search on the feed side is the
existing local FTS index widened from one subscription to all cached
items; the mail side is the existing server search. Results are
sectioned by medium rather than merged, because the two searches have
different scopes (the whole mailbox versus the cached window of each
feed) and a merged list would imply a completeness the feed side
cannot promise.

## Phase 1 -- Shared vocabulary and small parities

The cheap changes that make the rest coherent. Client-only except for
the one Lambda in item 1c. Ship as one release.

**Status:** Not started.

1. **Favorite becomes Flag** (Decision 3). Apple: `FeedItemListView`
   (row indicator, swipe label, filter pill title), `FeedItemDetailView`
   (reader button and accessibility identifier text; the identifier
   string itself stays for the probes), `Preferences+Swipe.swift`
   (`FeedSwipeAction` display name), the Actions settings picker.
   Android: `FeedItemListScreen`, `FeedItemDetailScreen`, the swipe
   bindings, and the strings. Glyph follows mail's flag glyph on both.
   Issue #1612 (both star states drew solid) is the reminder that the
   star was already a weak signal.
1. **Folder counts govern feed badges.** The Reading preference
   `folderCountDisplay` (unread, total, or both) currently applies to
   mail folders only; `FeedSidebarRows` and `FeedTree` always show
   unread. They read the same preference. The all-feeds and per-folder
   roll-ups follow.
1. **Mark all read for mail** (Decision 6). New Lambda
   `lambda/api/mark_folder_read` with a `requirements.txt`, an API
   Gateway route in `terraform/infra/modules/app`, and a pylint pass.
   Apple: a Mailbox menu item with a chord, a folder context-menu item
   in the sidebar, and a toolbar overflow entry on the message list.
   Android: the folder overflow menu. Always confirm first, naming the
   folder, as the feed side's `FeedManagementActions` confirmation
   already does for a feed or folder scope.
1. **macOS Feeds menu chords.** `FeedsMenuCommands` gains Mark as
   Read/Unread (⌘T), Flag/Unflag (⌘⇧8), and Mark All Read, dispatched
   through `AppState.requestFeedCommand` like the existing Subscribe
   item and answered by the mounted feed list. The chords are the same
   as the Message menu's; the menu that is enabled follows the active
   section, so a chord never fires on both. Shortcuts stay
   window-scoped and focus-independent, as the mail ones are.
1. **The scope title is a switcher.** The folder name above the mail
   list is a menu: on iOS, iPadOS, and visionOS the system title menu
   (`toolbarTitleMenu`), on macOS a bold `Menu` in the `.navigation`
   toolbar slot standing in for the removed title, on Android a
   `FolderTitle` with a dropdown in the `TopAppBar`. The rows are
   grouped by `FolderSwitchMenuPolicy` (Apple) and `FolderSwitchMenu`
   (Android): subscribed folders at the top level, the rest under
   "Other folders", the current one checked. The feed item list's
   title is plain text on both platforms (`FeedItemListView`,
   `FeedItemListScreen`). It adopts the same affordance over the feed
   scopes: "All Feeds" first, then the folder tree flattened with
   indentation for depth, each folder's subscriptions beneath it, the
   current scope checked. The grouping is a sibling policy
   (`FeedScopeSwitchMenuPolicy`) built on the same `ReaderMenuRow`
   rows so the two menus share their assistive-technology behaviour
   (#1367) and the macOS materialize-once handling (#1329, #1337).
   A search scope keeps its plain title, as the mail one does.
1. **Android settings section fix.** Issue #1706: "Default sort" and
   "Sort descending" sit under "Feed items" but drive the mail list.
   Move them back under "Email messages". Independent of the rest but
   trivially in scope.

Acceptance: a tester who reads a feed item, flags it, filters the feed
to Flagged, and then does the same in INBOX sees the same word, glyph,
and chord on both; marking INBOX all read from the sidebar flips every
unseen message in one call; tapping the feed list's title opens a
menu that switches to another feed or folder without leaving the
list, exactly as tapping the folder name does in mail.

## Phase 2 -- Custom flags on feed items

The motivating feature. Server first, then the two clients together.

**Status:** Not started.

### 2a. Server

1. `rss_set_item_state`: accept `add_flags` and `remove_flags` per
   item, validated against the twenty slot identifiers (reuse the
   validator in `set_rules`, moved to `rss_api` or `helper` as fits);
   apply with `ADD flags :add` and `DELETE flags :remove`; reject an
   entry that adds and removes the same slot. `updated_at` and
   `updated_key` advance as for any state change, so state sync carries
   the flags.
1. `rss_api.serialize_item` and `serialize_state`: emit `flags` as a
   sorted list, empty when the attribute is absent.
1. `docs/rss.md`: the item and state objects and the endpoint row.
1. Tests in `lambda/api/_shared/tests` for the expression builder and
   serialisers.

### 2b. Kit and clients

1. **Models.** `RssItem` and `RssItemStateChange` gain `flags`
   (Apple: `Set<String>`; Android: `Set<String>`); the change carries
   `addFlags` and `removeFlags`. `RssStore` schema version 5 adds a
   `flags` text column (JSON list) to `items` and the `pending`
   mutation shape; Room database version 2 does the same with a
   migration.
1. **Sync.** `RssSyncEngine` on both platforms applies `flags` from
   item pages and state pages, and queues flag mutations through the
   existing pending queue with the same retry and coalescing rules as
   read and favorite. Coalescing must keep add and remove distinct
   (an add followed by a remove of the same slot collapses to a
   remove, not to nothing).
1. **Menus.** The mail flag menu (`FlagMenuPolicy`,
   `MessageDetailView+FlagOptions`, the Android reader's flag sheet)
   is generalised over a "flaggable" abstraction (current flag set,
   apply add/remove) and mounted on the feed reader toolbar and the
   feed row context menu. The palette's enabled bit and ordering are
   honoured identically.
1. **Rows.** Feed rows show the keyword dots the mail rows show
   (`MessageListView+Rows`, `EnvelopeRow`), same size, same order.
1. **Filter.** The feed filter pills gain the per-flag filter the mail
   list offers, sourced from the local cache.
1. **Swipe.** `FeedSwipeAction` gains no new case; custom flags are a
   menu action on both media today and stay so.

Acceptance: flag an article "Read later" on the phone; it shows the
dot on the Mac after sync; disable the slot in Settings and the dot
vanishes on both media; re-enable and it returns. Two devices offline,
one adds slot 3 and the other adds slot 5 to the same item; after both
sync the item carries both.

**Changelog:** one `Apple:` and one `Android:` fragment each. The
Android headline shares the 500-character release budget.

## Phase 3 -- Acting on feed items in bulk, and out of the reader

**Status:** Not started.

1. **Bulk selection** (Decision 7). Apple: `FeedItemListView` adopts
   the `bulkMode` selection binding, the `BulkActionBarLayout` bar, and
   modifier-click from `MessageListView+Bulk` and `+ModifierClick`,
   with a `FeedItemListViewModel+Bulk` that batches through
   `/rss_set_item_state` (at most 100 per call, as the endpoint
   allows). Android: `SelectionTopBar` on `FeedItemListScreen`. Actions:
   mark read, mark unread, flag, unflag, set custom flags.
1. **Forward as email.** A "Forward as Email…" item on the feed reader
   toolbar and row context menu opens the composer with the subject
   `Fwd: <title>`, the item's link on the first line, and the summary
   HTML below a rule, in the same reply/forward quoting style the mail
   forward uses. Nothing is sent server-side; the composer is the
   existing one. Android mirrors through the same compose route. The
   share sheet keeps sharing the link.
1. **Print and Open in Browser parity.** Mail has no Open in Browser
   equivalent, and neither medium prints; this item records that
   neither is a gap to close.

Acceptance: select eight articles, mark them read, undo one; forward
an article and the received mail carries the link and the summary.

## Phase 4 -- Feed rules

**Status:** Not started.

### 4a. Server

1. `set_rules`: accept `source` (`mail` default, `feed`); validate the
   condition field set and action set per source (Decision 4);
   document version bump with the backward-compatible default so the
   shipped clients keep parsing.
1. The procmail compiler in the imap container
   (`compile-user-rules.py`, run on every reconfigure) skips `feed`
   rules with a logged `compile_skip_rule reason=feed_source`, so the
   per-user `.rc` never sees them.
1. `rss_fetch`: on `insert_item`, evaluate each subscriber's feed rules
   against the parsed item and write the resulting `flags` and
   `is_read` (explicit) to the subscriber's state row in the same
   batch as the insert. Conditions match case-insensitively on the
   plain text of the field, as mail rules do on headers. Metrics: rules
   evaluated, items matched, per feed.
1. `docs/mail-rules.md` grows a "Feed rules" section; `docs/rss.md`
   notes the ingest-time evaluation.

### 4b. Clients

1. `Rule` (`Rule.swift`, the Android model) gains `source` and the
   feed condition and action cases; `RulesValidator` mirrors the
   server's per-source rules.
1. `RulesView` and the Android rules editor gain a source picker at
   the top of the editor; the condition field menu and the action
   controls swap sets with it. The rules list groups by source with the
   existing section header style ("Email messages", "Feed items").
1. A "Flag matching items" rule template for feeds beside the existing
   `muteNewsletter` mail template.

Acceptance: a rule "title contains 'release' in feed X, flag
Releases" flags the next matching item on ingest, on every device,
before any device opens the feed.

## Phase 5 -- Cross-media views: flagged and search

**Status:** Not started.

1. **Flagged smart view** (Decision 8). A "Flagged" entry in the
   sidebar above the mail folders (Apple `SignedInRootView` /
   `MailRootView`; Android nav host) lists flagged mail and flagged
   feed items interleaved by date, each row carrying its medium's
   glyph and opening in its medium's reader. Filter pills within the
   view select a custom flag. Counts follow the Reading preference.
1. **Search scope.** The global search field drops the "Search all
   mail" placeholder for "Search", gains a scope segment (All, Mail,
   Feeds), and shows results sectioned by medium. The feed section
   widens `RssStore`'s FTS query from one subscription to all cached
   items (Apple), with Android's Room store gaining the equivalent
   query; the mail section is the existing server search. The feed
   section's footer states that it searches downloaded items only.
1. **Spotlight and resume.** A result row opened from either section
   writes the same resume record its medium's reader writes today.

Acceptance: search a word that appears in an email and in an article
and both appear, sectioned; open the Flagged view on the Mac and see
the article flagged on the phone in Phase 2 beside a flagged message.

## Phase 6 -- Ambient surfaces: notifications and Spotlight

**Status:** Not started.

1. **Notifications settings placement.** The feed subscription's
   `notifications_enabled` flag exists end to end on the server
   (`/rss_update_subscription`, the SQLite and Room columns) but has no
   client toggle and no dispatch path. Dispatch is
   [`rss-implementation-plan.md`](./rss-implementation-plan.md) Phase
   8 and is not duplicated here. This plan owns only the settings
   surface: Settings > Notifications lists feeds beside folders under
   the same "Email messages" / "Feed items" split, so the opt-in model
   reads as one feature when Phase 8 lands. Until then the feed
   section is present but explains that feed notifications are not yet
   delivered, rather than hiding the toggle.
1. **Spotlight for feed items.** `SpotlightIndexer` gains an
   `indexItems` path fed by the sync engine, with a `feed` domain
   identifier and the item's title and summary text; `SpotlightRouting`
   opens the item through the resume record's feed path. Retention
   follows the local cache's pruning.
1. **App Intents and Watch.** Recorded as not planned. An "Open feed"
   intent and a Watch feed view have no demand yet.

Acceptance: a Spotlight search for an article title opens it in the
app; Settings > Notifications shows a feeds section with the same
shape as the folders section.

## Rollout

- Each phase is its own PR or small PR set to `stage`, verified on
  stage with the shared tester account, then promoted with the next
  release. Phases 1 and 2 are independent of each other except for the
  vocabulary; ship Phase 1 first so the flag menu lands under the
  right word.
- Server changes (Phases 2a, 4a, and the Phase 1 Lambda) are additive
  and backward-compatible: a client that does not send `add_flags`
  gets today's behaviour, and a rules document without `source` is a
  mail-only document. Shipped app versions keep working across each
  server deploy.
- Local schema migrations (`RssStore` v5, Room v2) are forward-only.
  The Apple store's `userVersion` ladder and Room's migration list are
  the established pattern.
- The tester pipeline's sweep prompts cover feeds already; each phase's
  acceptance line above is written to be a sweep item.

## Open questions for the maintainer

1. **Decision 3's direction.** "Favorite" becomes "Flag" is the
   recommendation. If the star is preferred as the feed's standard
   mark, the rename reverses and mail's `\Flagged` presentation changes
   instead, which is a larger and more surprising change for mail
   users.
1. **Keyword mute** (Decision 5). Left out to honour the recorded
   decision. Phase 4's rule model would take a `hide` action with no
   structural change if the decision is revisited.
