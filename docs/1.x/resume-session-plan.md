# Resume Where You Left Off — Session Restore Plan

## Context

The native clients double as feed readers since the RSS reader shipped
(1.15.0, [`rss-implementation-plan.md`](./rss-implementation-plan.md)),
and the launch flow they inherited from the mail-only era no longer
fits: every cold launch lands on INBOX and offers a "pick up where you
left off" toast, whether the user was last reading mail on this device,
reading mail on another device, or reading a feed item here. A user who
is mid-article, switches apps, and comes back to a relaunched app is
dropped into INBOX with a prompt about a mail folder.

This plan replaces that with two layers that already exist in embryo:

- **A local session record** (per install, never leaves the device).
  What was on screen when the app last went away: the section (mail or
  feeds), the list scope, the open item, and its reading position. A
  cold launch restores it silently. This is the layer the relaunch
  scenario needs, and it needs no server.
- **The server cursor, unchanged in role** but narrowed in use. The
  `/get_nav_state` / `/set_nav_state` pair stays the cross-device
  signal: "you were reading X on another device, pick up here?" The
  resume toast fires only for a cursor written by a *different*
  install and newer than anything this install has already been shown.
  It no longer offers a device its own position back, because the
  local layer has already restored it.

On top of both sits a **per-item reading-position cache**: leaving an
item half-read and coming back to it later in the same session (or
after a relaunch) reopens it at the same place, for mail and feed items
alike.

### Why not make the server cursor per-device

`set_nav_state` replaces a single `nav_state` attribute on the
`cabal-user-preferences` row, keyed by user only (no range key), and
`get_nav_state` returns that bare object as the response body. A
per-device server cursor means a schema change, a read-modify-write
race on a map attribute or a new range key, and a breaking read for the
shipped Apple and Android builds that decode `folder` at the top level.
The local layer sidesteps all of it, and the server stays RSS-unaware
until the cross-device RSS toast (Phase C) needs it, where it lands as
additive optional fields.

### Decisions

- **Same-install restore is silent and symmetric.** Mail and feeds both
  resume in place. This reverses the 0.10.x decision (PR #568) that a
  cold launch always lands on INBOX; that decision existed because a
  silent restore of the *server* cursor was swallowing the cross-device
  toast, and the two-layer split removes the reason. Android already
  restores its own cursor silently and prompts only for a foreign one
  (`android-client-plan.md` §5); Apple adopts the same rule.
- **Fallback ladder, one per section.** Item, then its list scope, then
  the section home (INBOX for mail, the feed list for feeds). A pruned
  feed item degrades to its scope; a deleted subscription degrades to
  the feed list; a deleted mail folder degrades to INBOX; a message no
  longer in the folder's initial window leaves the user at the list.
- **Reachability for feeds is a local lookup.** The item and scope are
  checked against the on-device `RssStore` (SQLite), so a feed restore
  costs no network at launch. Mail keeps its existing top-50 window
  probe through the list's normal initial load.
- **Storage is an explicit per-install record, not `@SceneStorage`.**
  SceneStorage is per window and idiomatic, but macOS honours "Close
  windows when quitting an app", iOS discards it on force-quit, and
  Android has no equivalent. A `UserDefaults`-backed record behaves the
  same on every platform and matches the house precedent for
  device-scoped state (`PushSettings`, `InstallIdentity`). The most
  recently active window wins on macOS; per-window fidelity is not a
  goal.
- **Reading positions are keyed by item identity**, not by session:
  Message-ID (falling back to folder + UID) for mail, `RssItem.id` for
  feeds. The cache is bounded (200 entries, least-recently-used
  eviction) and persisted alongside the session record. A position at
  the top of the body is not stored; an existing entry is cleared
  instead.
- **Scroll capture gains a scroll-driven bridge.** The reader web view
  already runs an app-installed link bridge (`WKUserScript` + message
  handler) with page JavaScript disabled; a sibling scroll bridge posts
  the DOM anchor after each scroll settles, so the last stretch of
  reading before leaving an item is not lost to the interval of the
  2-second poll, which stays as a fallback. Captures carry the raw
  scroll offset so the receiver can tell "at the top" from a real
  position. The anchor format (`i<path>|<delta>` / `f<fraction>`) and
  the server's `msg_anchor` field are unchanged.
- **No user-facing toggle.** There is none today; the toast is opt-in
  by action. If one is ever wanted it is a local per-install setting
  (the `PushSettings` pattern), not a synced preference.
- **`list_scroll` stays dead on Apple.** It is accepted, stored, and
  transmitted but never applied by the Apple list. If list position is
  ever wanted it should anchor on the top visible row's identity, not a
  pixel offset. Out of scope here.
- **Explicitly deferred.** A staleness TTL on the restored *item*
  (landing on its list instead after a day or two) and a "finished
  reading" heuristic (restoring to the top when the reader was within a
  screen of the end) were both considered and left out of v1. The
  requirement is to resume exactly where the user left off; either
  refinement is a one-constant change if it proves wanted.

## Progress

| Phase | Work item                                                | Status      |
| ----- | -------------------------------------------------------- | ----------- |
| A     | Apple: session record, feed-aware launch, position cache | In review: PR #1538 (2026-09-11) |
| B     | Android: position cache + local session record           | Not started |
| C     | Cross-device RSS toast (server additive fields)          | Not started |

The background-termination investigation that surfaced this work is
tracked separately in #1537 and is independent of every phase here.

## Phase A — Apple

**Status:** In review, PR #1538 (2026-09-11). Not yet device-tested.

### Kit (`CabalmailKit`)

- `RssItemScope` gains a string round-trip (`token` / `init?(token:)`)
  and `Codable` conformance through it: `all`, `sub:<id>`,
  `folder:<id>`. Needed before a scope can be persisted anywhere.
- `ResumeSession` (`Models/ResumeSession.swift`): the local session
  record. `section` (`mail` | `feeds`), the mail position (`folder`,
  `uid`, `messageID`), the feed position (`feedScope`, `feedItemFeedID`,
  `feedItemSortKey` — the pair `RssStore.item(feedId:sortKey:)` looks
  up), and `savedAt`. Mail and feed fields are kept independently so
  switching sections and back within one relaunch restores both.
- `ReadingPosition` + `ReadingPositionCache`: `anchor` (HTML) or
  `offset` (plain text) per item key, bounded LRU, `Codable`.
- `ResumeSessionStore`: `UserDefaults`-backed persistence for the
  session record, the position cache, and the newest foreign
  `updated_at` already offered (so a dismissed cross-device toast is
  not re-offered on the next launch). `clear()` on sign-out. A
  synchronous `storedSection(defaults:)` read lets SwiftUI property
  initialisers seed the compact tab bar without a frame on Mail first.

### App (`Cabalmail`)

- `NavStateCoordinator` owns the store. Every existing recording call
  (`recordFolder`, `recordMessage`, `recordNoMessage`,
  `recordMessageScroll`) also updates the session record and, for
  scroll, the position cache. New: `recordFeedScope`,
  `recordFeedItem`, `noteSection` (compact / visionOS tab changes),
  `position(for:)`, `savePosition`. Session writes are debounced
  briefly and flushed when the scene leaves the foreground.
- Launch. `MailRootView`'s launch task reads the session instead of
  always landing on INBOX: a mail session lands on its folder
  (provisionally, as INBOX was) and schedules the message restore the
  list already knows how to consume; a feeds session (wide layouts)
  selects the scope and hands the resolved item to the feed navigation
  modifier. `finishInboxLanding` becomes `finishLaunchLanding`: swap the
  fetched folder in by path, or fall back to INBOX when the folder is
  gone. The server-cursor probe now offers the toast only for a foreign
  cursor. `VisionSectionView` mirrors the same changes.
- Compact iPhone: `SignedInRootView`'s tab bar gains a selection seeded
  from the stored section, and records section changes. `FeedRootView`
  restores its scope and item from the session once per process and
  records its own selection changes.
- Readers. `FeedItemDetailView` passes `restoreAnchor` and
  `onScrollCaptured` to the shared `HTMLBodyView`, reading and writing
  the position cache. `MessageDetailView` consults a pending
  cross-device scroll restore first, then the cache.
- `HTMLBodyView`: scroll bridge alongside the fallback poll
  (`HTMLBodyView+ScrollBridge.swift`). Captures report whether the page
  is at the top so the cache can clear rather than store a trivial
  position.
- `AppState.signOut` clears the store.

### Verification

- `swift test` (Kit): scope token round-trip, session record and
  position cache codability, LRU eviction, top-of-body clearing, store
  persistence and `clear()`.
- App-layer XCTest: launch-destination policy (session → provisional
  landing / fallback), section bookkeeping.
- Manual on iPhone: read a feed item mid-way, force-quit, relaunch →
  same item, same scroll. Back out to the item list, relaunch → same
  list. Same for a mail message in a non-INBOX folder. Delete the
  subscription on the Mac, relaunch the phone → feed list. Read a
  message on the Mac while the phone is backgrounded, foreground the
  phone → cross-device toast, and it does not reappear on the next
  launch after being ignored.

## Phase B — Android

**Status:** Not started.

Android already restores its own server cursor silently and prompts
for a foreign one, so its launch behaviour is right for mail. It needs:

- The per-item reading-position cache (its reader records no scroll at
  all today; `NavCursor.record` carries neither `msg_anchor` nor
  `msg_scroll`).
- The local session record, so a relaunch does not depend on the
  server round-trip, and so the feeds section can be restored once the
  Android RSS reader (rss plan Phase 6) exists. Design the record shape
  to match `ResumeSession` so the two clients agree on semantics.
- The foreign-toast "already offered" persistence.

## Phase C — Cross-device RSS toast

**Status:** Not started.

Let the server cursor carry a feed position so a device can offer
"pick up this article on your Mac". Additive, optional fields on
`set_nav_state` (`kind`, `rss_scope`, `rss_item`), with `folder`
required only when `kind` is absent or `mail`. Safe for shipped
builds: the Apple decoder treats a folder-less cursor as "nothing to
restore", Android's `folder` is already nullable. Per-item positions
across devices are a separate question; if wanted, the per-item read
state rows the feed reader already syncs are the natural home for an
anchor.
