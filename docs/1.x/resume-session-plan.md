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
| A     | Apple: session record, feed-aware launch, position cache | Shipped 1.17.0 (2026-09-11); follow-ups for #1555, #1535, and the restored-item spinner in review (2026-09-13) |
| B     | Android: position cache + local session record           | Ready to start (2026-09-13): the Android feed reader shipped in 1.19.0 (RSS plan 6a–6d) and landed the feed half of the position cache and the route identities with it; the session record, launch restore, watermark, and mail positions remain |
| C     | Cross-device RSS toast (server additive fields)          | Not started; follows Phase B. Prerequisite: a dual-form anchor (element + fraction) on Apple; best after Phase D so the hand-off is element-level both ways |
| D     | Element anchors on Android (CSP hash-source boundary)    | Not started; briefed for a separate session (2026-09-13); covers the mail reader too |

The background-termination investigation that surfaced this work is
tracked separately in #1537 and is independent of every phase here.

## Phase A — Apple

**Status:** Shipped 1.17.0 via PR #1538 (2026-09-11); sticky per-feed reader defaults followed in PR #1542 (same release). Device UAT (2026-09-13) confirmed the launch restore, the sticky defaults, and scroll positions surviving a relaunch, and surfaced three defects, all fixed in the follow-up PR: a root view rebuilt by a compact/regular size-class flip re-landed on the launch-time snapshot instead of the live position (#1555; #1557 separately stopped iPhone rotation from causing the flip at all); a navigate request selected a `Folder(path:)` stand-in the sidebar highlight never matched (#1535); and the item pushed by the launch restore could sit on its spinner until reopened, because the reader built its model from `.task`, which an iPhone push cancels (the mail reader's existing `.onAppear` workaround now applies). Scroll positions restored "after a lag", which pointed at the scroll bridge not firing. A web-view test (`ReaderScrollBridgeTests`, a real `WKWebView` with page JavaScript disabled) showed the bridge fires within 0.2 s; the actual defect was the anchor probe: `elementFromPoint(4, 4)` lands in the reader stylesheet's body padding and resolves to `body`, so every capture fell back to the `f<fraction>` form, and a fraction of `scrollHeight` shifts as images load below the fold. The probe now samples the horizontal centre and a few rows down, so captures name an element and restore to it regardless of reflow.

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

**Status:** Ready to start (2026-09-13). The Android feed reader shipped
in 1.19.0 (RSS plan 6a–6d), and that work landed part of this phase
ahead of it. Re-read of what is in place, and what is left, before the
phase begins; the user chose to let the reader bake first.

**Already in place from the Android reader (RSS plan 6a–6d):**

- **Feed reading positions.** `FeedReadingPositions` (app layer, a JSON
  file under `filesDir`, capacity 200, top clears, keyed by
  `RssItem.id`) with capture on scroll settle and restore on open —
  the feed half of this plan's position cache, done. It stores the
  `f<fraction>` form only: the Android body `WebView` runs with
  JavaScript off, and `evaluateJavascript` does not run under that
  setting, so the element anchor Apple captures is not available there.
  The two clients' fraction codecs agree (a leading `f`, a decimal
  fraction; Apple writes four decimals, Android three, both parse
  either).
- **Route identities.** `FeedRoutes` names the item list by
  `RssItemScope.token` and the item by `feed_id` + `sort_key`, the same
  identities `ResumeSession` stores, so the session record can name a
  feed position with no mapping layer.
- **Per-feed defaults and sticky toggles.** `FeedPolicies` mirrors the
  Apple `FeedDetailPolicy`: open mode, styling, remote content, and the
  filter pill are read at model creation and written back per toggle.
- **The mail reader's `HtmlBody` already exposes `restoreFraction` /
  `onScrollFraction`** (the feed reader shares it), so mail reading
  positions need only a store and the view-model wiring, not a reader
  change.

**Left for Phase B:**

- **The local session record and launch restore.** Android still lands
  every launch on INBOX (`launchDestinationDone`) and restores only its
  own *server* cursor (`NavCursor.restoreOnce`), so a relaunch depends
  on a network round trip and never returns to the Feeds tab. Add a
  per-install record matching `ResumeSession` (section; mail folder and
  message; feed scope and item), recorded from the nav host's route
  changes, and a launch restore that navigates to
  `FeedRoutes.items(scope, item)` or the mail cursor route silently.
  Process-scoped like the existing one-shots, so an activity recreation
  does not re-land; the Apple lesson from #1555 (a rebuilt root must
  restore the *live* record, not the launch snapshot) applies if the
  nav host is ever recreated mid-process.
- **Mail reading positions**, by generalising `FeedReadingPositions` to
  the `mail:<Message-ID>` / `feed:<id>` key scheme Apple uses
  (`ReadingPositionKey`) and wiring `MessageDetailViewModel` to it
  through the hooks `HtmlBody` already has.
- **The foreign-toast "already offered" watermark**, persisted next to
  the client id in `NavCursor`'s DataStore, and the same-place check,
  so an ignored cross-device prompt is not repeated on the next launch
  and a foreign cursor at the device's own position raises no prompt.
- **The server cursor stays mail-only until Phase C**; nothing in this
  phase writes a feed position to `set_nav_state`.

## Phase C — Cross-device RSS toast

**Status:** Not started. Deliberately sequenced after the Android feed
reader (RSS plan Phase 6, shipped 1.19.0) and this plan's Phase B, in
that order: the toast's whole value is the cross-platform hand-off, so
built earlier it would serve only Mac-to-iPhone and be tested with one
client. The RSS plan records the same ordering from its side; the two
documents should keep agreeing.

**Design constraint found on re-read (2026-09-13): the anchor must be
dual-form.** Apple captures the element anchor (`i<path>|<delta>`) and
since 1.18.2 rarely falls back to a fraction; Android can capture and
apply only `f<fraction>` (JavaScript is off in its body `WebView`).
So a position handed Android-to-Apple restores today (Apple applies
the fraction form), but Apple-to-Android would carry an anchor Android
cannot apply. Before or as part of Phase C, Apple's `ScrollCapture`
should carry the fraction alongside the element anchor — it already
reads the scroll offset, and the scrollable height is one more property
in the same script — and the cursor should carry both (`msg_anchor`
plus a sibling `msg_fraction`, additive and optional, with the
element anchor preferred by a reader that can apply it). The same
dual capture belongs in Apple's local position cache so its own
fraction is available for the hand-off. The dual form ships regardless
of Phase D below: it costs almost nothing and covers Android builds
that predate it.

### Phase D — Element anchors on Android (separate session)

**Status:** Not started (2026-09-13). Decided worth doing: element
anchors are superior wherever a document reflows after load, and the
cross-device hand-off is the case where the two clients most need to
agree. Scoped for its own session, since it is an Android web-view
posture change that also covers the mail reader (the feed reader shares
`HtmlBody`), with its own CI gate and device pass.

The constraint: Android's `javaScriptEnabled` is one switch for the
whole web view. Apple's `allowsContentJavaScript = false` disables the
page's scripts while app-injected scripts still run, enforced by WebKit;
Android has no such split, so the app's anchor script cannot run unless
the page's could too. The boundary therefore has to be built and
proven by us. Subresource integrity is not the primitive: it verifies
fetched scripts against a hash but gates nothing about inline scripts,
event-handler attributes, or `javascript:` links, and `require-sri-for`
is gone from browsers. The SRI-shaped primitive that *does* gate
execution is a Content-Security-Policy hash-source.

Design to build and prove, in this order:

1. **Policy.** `javaScriptEnabled = true` on the body view with a
   `Content-Security-Policy` meta first in the generated head:
   `script-src 'sha256-<hash of the anchor script>'`, no
   `'unsafe-inline'`, so inline scripts, `on*` attributes,
   `javascript:` URLs, and every external script are refused; a
   sender's own CSP meta can only intersect with ours. A hash rather
   than a nonce, since the script is static and nothing needs minting
   per document.
2. **Exemption for the app's own calls, verified.** Chromium's
   `evaluateJavascript` and androidx's `addDocumentStartJavaScript` are
   believed not to be subject to page CSP; a real-WebView test must
   show it (as `ReaderScrollBridgeTests` did for the Apple bridge). If
   they are subject to it, the anchor script goes in the head as the
   hashed inline script and reports through `WebMessageListener`, the
   Android analogue of the script message handler, origin-restricted.
3. **Belt and braces.** Strip script elements and `on*` attributes at
   render time regardless, so the policy is the second wall.
   `blockNetworkLoads` stays as it is: with remote content off, a
   script that somehow ran has nowhere to send anything; the residual
   exposure is DOM tricks and CPU, and grows only when the user taps
   "load remote content".
4. **The CI gate.** A fixture with an inline script, an event-handler
   attribute, a `javascript:` link, and an external script; a test that
   loads it in the reader's configuration and asserts none executed
   while the anchor script did and reported. This test is the boundary;
   without it the policy is a comment. It should run on the mail
   reader's configuration too, since that is the larger surface.
5. **Anchor parity.** Port the Apple anchor function (plain DOM
   JavaScript; probes the horizontal centre and a few rows down; emits
   `i<path>|<delta>` with `f<fraction>` as the fallback) and the
   settle-debounced scroll bridge. `FeedReadingPositions` then stores
   whichever form was captured, and restore applies `i` when present
   and `f` otherwise, matching Apple's `restoreScript`.

Out of scope for that session: the session record and launch restore
(Phase B) and the cursor fields (Phase C). It should land before Phase
C so the hand-off is element-level in both directions; it does not
block Phase B.

Let the server cursor carry a feed position so a device can offer
"pick up this article on your Mac". Additive, optional fields on
`set_nav_state` (`kind`, `rss_scope`, `rss_item`), with `folder`
required only when `kind` is absent or `mail`. Safe for shipped
builds: the Apple decoder treats a folder-less cursor as "nothing to
restore", Android's `folder` is already nullable. Per-item positions
across devices are a separate question; if wanted, the per-item read
state rows the feed reader already syncs are the natural home for an
anchor.
