# Refresh scheduling

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session. Five small sequential PRs and a one-hour measuring step, three decisions that fit in one batch, no server change, no migration and nothing that needs parallel threads. The session may pause after its mail PRs and resume for PR 4 once the feed list files are free (see Hotspots).
**Size:** M. Five small PRs; the feed and reconnect tests need two new test seams.
**Priority:** Later, except decision 1 and PR 1, which can go now. Only #1983 is a filed issue, and it is a wording mismatch. The rest saves requests and fills trigger gaps nobody has reported, so the maintainer's bugs-first rule puts it after the bug plans.
**Depends on:** nothing hard. Order only, through shared files (see Hotspots).
**Unblocks:** nothing hard. Soft: multi-window-and-restore.md (R4 can reuse the foreground poll if this lands first; it does not need it) and mail-navigation-refactors.md (`ComposeAutosave` can adopt PR 2's loop helper later); test-debt.md (its A4 reuses PR 2's test clock if PR 2 lands first).
**Duo groundwork:** Little. A fold rebuilds the view tree, which re-syncs the open feed list each time (inferred from `Navigation/TreeGate.swift:4-10` and the list's `.task(id: scope)`; not run on the Duo simulator); PR 4 stops that, and PRs 3 and 4 each add a check on the Studio's Duo simulator.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
| --- | --- |
| Decisions 1 to 3 | Unanswered (2026-10-15); each defaults to (a). |
| Step 0. Measure | Not started (2026-10-15). |
| PR 1. #1983 (decision 1) | Not started (2026-10-15). |
| PR 2. One loop helper with a steppable clock | Not started (2026-10-15). |
| PR 3. Reconnect and foreground triggers | Not started (2026-10-15). |
| PR 5. Subscribed folder counts (decision 3) | Not started (2026-10-15). |
| PR 4. The feed freshness rule (decision 2) | Not started (2026-10-15). |

> **Duo spec (2026-10-13):** This plan was written before the maintainer's Oct 7 Duo spec (the Claude Doc linked in duo-support.md) was read here. duo-support.md now follows it; where this plan's text disagrees with the points below, the points win. In the spec, "fold" means book or laptop pose, which changes no size class and swaps no shell; what this plan calls folding or unfolding the Duo is closing or opening it.
>
> - PR 4: a list re-mounted by a shell swap is not a sync trigger at all, whatever the floor; the spec treats a size change as never a reason to re-query. PR 3: with INBOX scrolled down, a foreground poll that inserts rows keeps the first visible row 〔.22115〕. Run the Duo checks as close and open, plus one book and one laptop pass that should sync nothing.

## Decisions for the maintainer

1. **#1983: an open unsubscribed folder is still checked for new mail, though its banner says it is not kept up to date. Which one changes?** Ask now; PR 1 does not wait for the rest.
   - (a) **The banner (recommended).** Reword it to say the folder updates only while it is open. Consequence: Drafts, Sent and Trash, which the mail server does not subscribe by default (only INBOX and Archive, `docker/imap/configs/dovecot/15-mailboxes.conf:11, :36`), keep showing new messages while you look at them. It relaxes the written rule "we only spend resources proactively on folders the user has explicitly subscribed to" (`FolderListViewModel.swift:59-60`) for the one folder on screen.
   - (b) The code. An open unsubscribed folder stops checking by itself and updates only when opened, pulled or refreshed from the banner's button. Consequence: "subscribed means proactive fetching" holds exactly, as #1983 notes, but an open Sent or Drafts list no longer shows new arrivals by itself (inferred).
   - Default if unanswered: (a).
2. **How recent must a feed sync be for the app to skip an automatic one?** Automatic means returning to the app, a connection coming back, the 15-minute timer, and opening or coming back to a feed list. Pull, the Refresh buttons and the Feeds menu always sync.
   - (a) **5 minutes (recommended).** Consequence: coming back from an article, or folding the Duo, no longer re-syncs every feed in view (about two requests per feed each time), but new items and read or favorite marks made on another device can show up to 5 minutes late after you return; pull fixes that at once. New items rarely arrive faster, since the server fetches feeds on a 5-minute schedule (`terraform/infra/modules/app/rss_fetcher.tf:405`); marks change at once, so the lag on marks is the real cost.
   - (b) 5 minutes for new items, but always pull marks. Marks stay current; each trigger still costs one request per feed, and it needs a Kit change (a marks-only pass in `RssSyncEngine`) that waits for sqlite-mail-store.md to release `RSS/`.
   - (c) 1 minute. A smaller lag; it still saves a quick back-and-forth and a fold.
   - (d) Never skip, as today. PR 4 shrinks to docs.
   - Default if unanswered: (a).
3. **Sidebar counts of subscribed folders that are not open refresh only on the sidebar's first load, Reload and New Folder. Refresh them on more triggers?**
   - (a) **On return to the app, on reconnect, and every 5 minutes (recommended).** Consequence: one status request per such folder per trigger (10 subscribed folders cost about two a minute), and the manual's "Subscribed folders are refreshed proactively" (`docs/user_manual.md:36`) becomes true.
   - (b) On return and reconnect only. A Mac left in front for hours can still show stale counts.
   - (c) No. PR 5 becomes a manual fix saying counts refresh on Reload.
   - Default if unanswered: (a).

## What you'll see change

- **PR 1 (#1983):** with (a), the unsubscribed-folder banner says the folder updates only while it is open. With (b), an open unsubscribed folder stops checking for new mail by itself.
- **PR 2:** nothing visible. The two session timers get a clock that tests can step, and they stop when their owner goes. PR 5's timer is built on it.
- **PR 3:** when the connection comes back, open mail lists and the Inbox count check at once instead of after up to 60 seconds of retry backoff, and feed marks made offline go out at once. Coming back to the app also checks open mail lists at once, unless Step 0 shows they already do. Each open list shows its loading indicator briefly when that happens, as it does on today's 60-second check.
- **PR 4 (decision 2):** feeds stop re-syncing each time you return to the app or come back from an article within 5 minutes of the last sync. Fewer spinners and requests; pull still syncs at once.
- **PR 5 (decision 3):** sidebar counts of subscribed folders keep up without pressing Reload.

## Why

The rearchitecture proposal's verdict on refresh was "Share: single-flight per key, one scheduler per medium". Single-flight means a second caller waits for work already running instead of starting it again. The waves did that half: mail got one poller per open folder (workstream 2.2, PR D), and the feed engine joins overlapping passes (`CabalmailKit/.../RSS/SharedRun.swift`). The scheduling half is missing in five places.

1. **Feeds: nothing asks whether a sync just ran.** Six places start feed work (listed below). The engine joins passes that overlap but never skips a fresh one. Each pass is the catalog plus two requests per subscription, one for new items and one for read and favorite marks (`RssSyncEngine.swift:141-161`). On iPhone the item list builds a fresh model that syncs every time you come back from an article (`FeedItemListView.swift:117-127`); for All Feeds that is every subscription. The feeds audit's finding F5 (uncoordinated feed refresh triggers) asked, longer term, for "a small `RefreshCoordinator` shared by mail and feeds (interval, foreground, manual, on-open; coalescing; one `isRefreshing` per medium)", adding "do not force mail into it in the first pass" (more under "Background from the rearchitecture").
2. **Reconnect does nothing.** Open mail lists wait out the watcher's retry backoff, which doubles from 2 s to 60 s (`MailboxWatcher.swift:27-32`), and the 60-second tick. The feed queue is not drained either: the Kit audit's table of offline queues (its F13, under "Background from the rearchitecture") says feed marks go out on "each local write + app triggers; **not** reachability", although the engine's own doc lists "reconnect" among the app's triggers (`RssSyncEngine.swift:35-36`).
3. **Returning to the app leaves open mail lists alone** (`AppState+Foreground.swift:16-28`). #2028 cites this as a reason a list can stay without a new message for a while; its likely cause is the pop-once restore, which multi-window-and-restore.md's R4 fixes. The cost is unmeasured: the tick sleeps on a clock that keeps running while the app is suspended, so an overdue tick may already fire on return (inferred). Step 0 measures it.
4. **Subscribed folders' counts have no trigger** after the sidebar's first load (`FolderListView.swift:248-268`; `FolderListViewModel.swift:61-65, :229`; grep finds no other path). INBOX has the badge loop and open folders have their pollers; the rest wait for Reload, though server-side rules file mail into them.
5. **#1983, and loops that cannot be stepped or stopped.** The badge and feed loops are `Task { [weak self] in while !Task.isCancelled { await self?... } }` with real sleeps (`SessionPollers.swift:39-43, :84-88`). The tests audit says such a loop "keeps waking forever doing nothing" if its owner goes without `stop()`, and asked for a `Poller` with an injectable clock (see "Background from the rearchitecture"). In production `SessionManager` owns them for the app's life (`SessionManager.swift:95`), so this is a test seam more than a leak.

## Where things stand

- **Mail, per open folder** (`Mail/Store/FolderPoller.swift`, `FolderPollers.swift`): a watcher polls `/folder_status` every 30 s (`ApiBackedImapClient.swift:43`); a 60-second tick catches read and flag changes the watcher cannot see; a 1-second coalesce turns several change events into one poll; one poll runs at a time with at most one queued. The clock is injectable and tests step it (`ManualPollClock`, `CabalmailTests/FolderPollTestSupport.swift`). Each poller is keyed by its client and stops in `cancel()` (`FolderPoller.swift:102-113`). `requestPoll` is private (`:170`); mail-correctness.md's PR 4 adds a public one-folder poll entry that joins the coalesce, if the maintainer takes its decision 3 default.
- **Inbox badge:** its own 60-second loop in `SessionPollers` (`:35-71`). Workstream 2.2 kept it there by its default decision 9, which the maintainer did not overrule: "It is session-lifecycle code with recent sign-out fixes (#1886, #1892), it runs whether or not Inbox is on screen, and folding it in saves one STATUS a minute only while Inbox is open". This plan does not fold it.
- **Feeds, the six starters:** (1) session start, then every 15 minutes (`SessionPollers.swift:81-106`, started at `SessionManager.swift:388`); (2) every return to the app (`AppState+Foreground.swift:27`, `AppState+Feeds.swift:27-29`); (3) the feed sidebar's first appearance, Refresh, pull and the Feeds menu (`FeedSidebarViewModel.swift:98-140`; `FeedSidebarSection.swift:111, :122, :137, :180`; `FolderListView+Helpers.swift:133, :154`); (4) the item list on every appearance, Refresh and pull (`FeedItemListView.swift:123, :157, :207`); (5) subscribe and OPML import (`FeedManagementViewModel.swift:49, :121`); (6) each local mark drains the queue once (`RssSyncEngine.swift:314-316`). Each feed's last successful sync time is already stored (`RssSyncEngine.swift:164-165`; `RssStore+State.swift:175-206`).
- **Reachability:** a client from `CabalmailClient.make` builds its own `Reachability`, and the Outbox drains through it (`CabalmailClient.swift:214-228`). `changes()` yields the current state first (`Reachability.swift:47-57`). The app's only reaction is the sidebar reloading when it shows a saved copy (`FolderListView+Helpers.swift:23-34`). Test clients from the memberwise init have no reachability and no feed engine (`CabalmailClient.swift:85-96`), so in `SessionHarness` `refreshFeeds()` returns at once (`SessionPollers.swift:102`); no app test drives it.
- **The debug log does not record API requests** (grep of `CabalmailLog` calls). A `CabalmailLog` line does reach Settings > Debug Log.
- **No background refresh:** no `BGTaskScheduler` or `UIBackgroundModes` under `apple/`. It waits for the RSS plan's Phase 8, "Not started" (`docs/1.x/rss-implementation-plan.md:32, :1950-1952`).
- **Issues (GitHub, 2026-10-12):** #1983 open, `needs-verification`, no linked PR; its body offers decision 1's two options. #2028 open; multi-window-and-restore.md owns the fix (R4). #1962 open (Duo: a feed item open folded is lost on unfold); duo-support.md owns it. No issue tracks the stale sidebar counts.

## The plan

One session, one Apple PR in CI at a time, in the order 1, 2, 3, 5, 4. PR 4 goes last because it needs the feed list files that other plans hold; PR 5 does not. The shape: each medium keeps its own scheduler and hears the same triggers. Mail lists use `FolderPollers`. The badge, the feeds and the subscribed counts use `SessionPollers`. `AppState+Foreground.swift` hands the foreground trigger to both. Feeds gain a freshness rule. No `RefreshCoordinator` type is built (see Not in this plan).

**Step 0. Measure (no PR; Mini; about an hour).** With a temporary, uncommitted `CabalmailLog.info` line in `appScenePhaseChanged`, record: on macOS, whether Command-Tab away and back, Command-H, and minimizing each change the scene phase; on the iOS simulator, with INBOX open, how long a message sent from the other stage account takes to appear after a 20-second and a 2-minute absence. Put the numbers in the scope doc. If the message already appears within about 5 seconds both times, PR 3 drops its foreground mail poll and keeps reconnect. If the Mac changes phase on Command-Tab, the foreground mail poll skips any folder its poller polled in the last 60 seconds: one rule on every platform, no `#if os`.

**Status:** Not started (2026-10-15).

**PR 1. #1983 (decision 1).** Runs as soon as the maintainer answers, in any free Apple CI slot, and rides whatever release is next.
- (a) Change the sentence at `MessageListView+UnsubscribedBanner.swift:81` and the doc comment at `:4-9`. Stay at or under today's 62 characters, for example "This unsubscribed folder updates only while it is open." (55); otherwise `UnsubscribedBannerLineLimitTests.testLineLimitDoesNotTruncateAtTheNarrowestColumnTheBannerCanDrawIn` may fail at the 220 pt column. Fix the comment at `MessageListViewModel+Optimistic.swift:55-57` ("Unsubscribed folders (Drafts) get no proactive poll", already untrue; comment-only, and only while no other `MessageListViewModel*` PR is open), and re-read `FolderListViewModel.swift:56-60` and `FolderListFilter.swift:35-40`. Add "and updates while it is open" to `docs/user_manual.md:36` and say the same in `docs/apple.md`, "Change watching is tied to the message list lifetime" (`:1516-1545`).
- (b) Guard `startWatching()` (`MessageListViewModel.swift:231-235`) with the banner's own rule, `UnsubscribedBannerPolicy` against `mailStore.counts.subscribedFolderPaths`, never `folder.isSubscribed` (`UnsubscribedBannerPolicy.swift:7-17`). Subscribing or unsubscribing the open folder starts or stops its watching; observe that in the model or the store, not in `MessageListView.swift`, whose re-appear branch (`:500-508`) a source-scan test pins. Tests in `MessageListFolderPollTests`: no poller for an unsubscribed folder; one starts on subscribe and stops on unsubscribe; the re-appear refresh still runs.
- `Apple:` fragment under `changed`; PR body "Addresses #1983", so the soak verifies and closes it. Verify: CI; on the Mini (macOS), open Sent and read the banner (a), or send from that account with Sent open and see the copy appear only on pull (b). Risk: low.

**Status:** Not started (2026-10-15).

**PR 2. One loop helper with a steppable clock.** `no-changelog`.
- A small `@MainActor` helper in `Shared/Primitives/` (the session names it) that runs a body every interval, with `now` and `sleep` injected the way `FolderPollTiming` injects them (`FolderPollers.swift:41-50`), and ends when cancelled or when its owner is gone (`guard let self else { return }`, as `FolderPoller.swift:142-147` does). Move both `SessionPollers` loops onto it. Keep `feedRefreshTask` an internal settable `Task<Void, Never>?` that the stop call cancels (three suites assign it), and keep `inboxBadgeTask` `private(set)` and readable, as today.
- One test clock, not three: if test-debt.md's A4 has landed its manual test clock, use it; otherwise generalize `ManualPollClock` and tell test-debt.md. Leave `FolderPoller`'s own tick alone. Do not touch compose (mail-navigation-refactors.md PR 3 owns those loops).
- Tests: fires once per stepped interval, stops on cancel, stops when its owner is released; existing suites unchanged. Verify: CI. Risk: low.

**Status:** Not started (2026-10-15).

**PR 3. Reconnect and foreground triggers.**
- Mail on reconnect: each `FolderPoller` gets a fourth task that watches its own client's reachability and polls once on a change from unreachable to reachable, ignoring the first value (the current state). It follows its client by construction and stops in `cancel()`, so sign-out and the last list leaving end it. The poll goes through the change path, so it joins any poll within the coalesce. It does not reset the watcher's backoff: the one-shot poll covers the moment and the tick the rest, and 2.2's decision 10 keeps the watcher unchanged.
- Mail on foreground (unless Step 0 drops it): `appScenePhaseChanged(to: .active)` asks every running folder poller to poll once through `mailStore.folderPollers`, using mail-correctness.md's PR 4 entry if it has merged; if not, add one and tell that plan.
- Badge: one extra tick on foreground and on reconnect. Feeds: on reconnect, `drainPending()` at once, then a pass; on foreground, today's pass until PR 4. If sqlite-mail-store.md's PR 4.5 (feeds join its shared queue, which drains on reachability) has merged, drop the feed reconnect drain.
- The badge and feed reconnect observer is a task `SessionPollers` starts with the feed loop, over the client at hand, and cancels in `stopFeedRefreshPolling()`, which `tearDownSession` already calls (`SessionManager.swift:316-317`), so `SessionManager.swift` is not edited. Since the start calls are idempotent, a sign-in over a wired session would leave this observer on the old client while the loops follow the new one (`SignInCharacterizationTests.swift:326-333`). No screen reaches that; say so in a comment. account-isolation.md's decision 3 (Refuse or End first) removes the case.
- One `CabalmailLog.info` line per foreground or reconnect trigger, counts only, so the checks below can read Settings > Debug Log.
- Seams: the reachability stream comes through a closure (beside `FolderPollTiming`, and on `SessionPollers`) defaulting to `client.reachability?.changes()`, so tests feed their own stream; with kit-split.md's PR E merged, use its fake `Reachability` instead. Feed tests set a feed-engine closure on `SessionPollers` (default `client()?.rssSync`) to an `RssSyncEngine` over `FakeRssClient` and a temporary `RssStore`, as `FeedSidebarRefreshCancellationTests.swift:35-44` builds one. No Kit change; `SessionHarness` unchanged. Copy the `#if canImport(Network)` guard only if kit-split.md's PR 0 has not removed it.
- Tests: reconnect (false, then true) polls each open folder once and drains the feed queue once; an initial true does nothing; a reconnect after sign-out asks nothing. With two folders open, `.active` asks one flagged STATUS of each (`flagged: true` in `FakeImapClient.statusCalls`) beside the badge's unflagged INBOX STATUS; with none open, no flagged STATUS. Two `.active` calls within a second poll each folder once. "Leaving asks nothing" stays green. Wait on counts or the stepped clock, never a fixed sleep that asserts absence.
- `Apple:` fragment under `changed`. PR body "Refs #2028", with no fix word (address, fix, close, resolve, any form) within 30 characters before "#2028" anywhere in it: the release dashboard (`scripts/release-dashboard.py:182-185`) would count it as claimed and hold Promote.
- Verify: CI. Mini, iOS and visionOS simulators: repeat Step 0's timing and read the Debug Log line. Reconnect only if the rig can cut a simulator's network without disturbing the maintainer's machine; otherwise a TestFlight check. Studio, Duo simulator: with INBOX open, fold and unfold, then send a message; it arrives. Risk: low to medium; a flapping connection is bounded by one poll in flight and one queued per folder.

**Status:** Not started (2026-10-15).

**PR 5. Subscribed folder counts (decision 3).** Runs before PR 4.
- A third `SessionPollers` loop on PR 2's helper, every 5 minutes, plus the foreground and reconnect triggers, which skip if a walk finished in the last minute. It asks a STATUS of each path in `mailStore.counts.subscribedFolderPaths`, minus INBOX and folders open in a list, at most a few at once as the sidebar does, and hands each answer to `mailStore.takeStatus(_:folderPath:askedAt:fetchedThrough:)` (`MailSessionStore.swift:134-151`), which already bounds a reply by writes in flight and drops one from an ending session (inferred to be enough; the session confirms it). Leave `FolderListView.swift` alone (multi-window-and-restore.md's session 2 holds it). If the loop needs a hook from `AppState`, install it in `AppState.init` beside `boundInboxUnread` (`AppState.swift:138-140`); `ComposeWindowSlotSourceScanTests` reads that file but pins only `composeSlots.endSession()`.
- Docs: `docs/user_manual.md:36`, `docs/apple.md`. `Apple:` fragment under `changed`.
- Tests: the stepped clock gives one walk per interval; the walk skips INBOX and open folders; a walk after sign-out asks nothing. Verify: CI; on the Mini (macOS), move a message into a subscribed folder from the webmail and see its sidebar count change within 5 minutes without Reload. Risk: low.

**Status:** Not started (2026-10-15).

**PR 4. The feed freshness rule (decision 2).**
- A small value type (the session names it) answers "sync now?" from each covered feed's stored last sync time, the floor and the time. A feed never synced, or stamped in the future (a clock change), counts as stale. A trigger skips only when every feed it covers is fresh. Automatic triggers follow it: the 15-minute tick, foreground, reconnect, and the item list's `.task(id: scope)` sync through a new list-model entry, so `sync()` keeps its behaviour and its tests. Manual triggers never consult it, and the queue drain never skips. The sidebar's first-appearance `refreshIfNeeded` may follow it; decide with the #1908 cancellation suites in view.
- #1908's retry keeps working. Today a re-appear sync is what retries a sync that was cut short (`FeedItemListViewModel.swift:299-307`). A cut-short or failed feed never writes its last sync time (`RssSyncEngine.swift:162-165`), so it stays stale and the next appearance still syncs it.
- A skipped pass also skips the catalog, so a subscription added on another device appears at the next pass that runs (inferred: within about 20 minutes, or at once on pull).
- No Kit change: the rule reads the store, and the engine still "never decides *when* to run" (`RssSyncEngine.swift:35`). The feed list files get one call each.
- Tests: the rule with fixed dates (fresh, stale, never synced, future, a mixed scope); two foregrounds inside the floor make one pass (`FakeRssClient.catalogCalls`, through PR 3's engine seam); a list re-appearing with fresh feeds makes no items call, while pull makes one; a cancelled sync, then a re-appear inside the floor, still syncs the feeds that did not finish; `FeedItemListSyncTests`, `FeedItemListSyncCancellationTests` and `FeedSidebarRefreshCancellationTests` pass unchanged.
- Docs: a short "Feed refresh" part in `docs/apple.md` listing the triggers and the rule. `Apple:` fragment under `changed`.
- Verify: CI. Mini, iOS and visionOS simulators: open All Feeds, open an item, go back; the Debug Log shows a skip, and pull syncs. Studio, Duo simulator: fold and unfold with a feed list open, no sync inside the floor; then #1962's steps (open an item folded, unfold) still keep the item, since this PR changes what the rebuilt list does. Risk: low to medium; pull is the escape.

**Status:** Not started (2026-10-15).

**Releases.** PR 1 rides the next release. PRs 2, 3 and 5 ride one release, with PR 2 as its one structural change. PR 4 rides a later one, so a feed complaint is easy to tell from the mail triggers. Device checks (a real return to the app on iPhone and Mac, a real reconnect) go on the maintainer's TestFlight checklist for the release that carries them, and hold Promote, not merge.

**Hotspots.** One open PR per file at a time; check for open PRs before each.
- `Mail/Store/FolderPoller.swift`, `FolderPollers.swift` (PR 3): mail-correctness.md's PR 4 (adds the poll entry first) and sqlite-mail-store.md (its PR 3.4 and app thread; it is Next, so it likely runs first).
- `Session/SessionPollers.swift`, `App/AppState+Foreground.swift` (PRs 2, 3, 5): no other plan names them.
- `App/AppState.swift` (PR 5, only if needed): multi-window-and-restore.md R2 and account-isolation.md C1.
- `MessageListViewModel*.swift` (PR 1): mail-correctness.md, mail-navigation-refactors.md, detached-reader-window.md, shared-load-error-state.md B4, sqlite-mail-store.md.
- `Feeds/ItemList/*` (PR 4): feed-bulk-actions.md while it runs, then flags-and-cross-media.md Stage A; shared-load-error-state.md B2 edits the feed view models and `FeedSidebarViewModel.swift`; ipad-layout-and-keyboard.md's PR C moves one line in `FeedItemListView.swift` (#2027). PR 4 slots into a gap between those PRs; if none opens for weeks, the session pauses after PR 5's release and resumes later.
- `Shared/Primitives/` and test clocks (PR 2): test-debt.md A4.
- Kept out: `MessageListView.swift`, `FolderListView.swift`, `SessionManager.swift`, `SessionHarness.swift` and the Kit.

## Background from the rearchitecture

The passages of the rearchitecture's records that this plan's brief used to send the session to. Those records are not in the repo. The code they describe has moved on since, so their own line numbers are left out; check the code before relying on any of it.

- **Workstream 2.2's decisions 9 to 11** (defaults in its scope doc of 2026-10-08; the maintainer's answers that day settled its order, the shared load state and the remembered pill, and overruled none of these):
  - Decision 9, the Inbox badge poller stays in `SessionPollers`: quoted in full under "Where things stand".
  - Decision 10, "**No Kit change.** The registry reuses `MailboxWatcher` and `idle` as they are, which keeps the watcher's offline backoff (#1797) and the watcher characterization tests meaningful. Renaming them would change `AsyncStreamTerminationCaptureScanTests`, which inventories both files and whose floor test looks for `public actor MailboxWatcher`."
  - Decision 11, "**Poller details:** one entry per folder path, made by the first subscriber and stopped with the last; one STATUS (with the flagged count) per watcher event or 60-second tick, handed to every subscriber as `refresh(prefetched:)`; the tick's clock is injectable so tests don't wait. The registry hangs off `MailSessionStore`, which 2.1 keeps one per `AppState` (the maintainer's yes to its Q2), and `forgetAccount()` stops every entry. `startWatching` subscribes the list and `stopWatching` unsubscribes it; `stopWatching` still cancels the list's page loads, scroll-settle load, debounced persist and bottom prefetch, as `MessageListWatcherTeardownCharacterizationTests` pins. A list that re-appears subscribes and refreshes, as now."
- **The feeds audit's F5, uncoordinated feed refresh triggers (overlapping full syncs)** (2026-10-02). Sign-in, the feed sidebar's mount (wide and compact) and each return to the app all started a full sync, and opening any scope synced it (for All Feeds, every subscription in turn); the sidebar's refresh refreshed the catalog twice; and the engine had no single-flight, so syncs of one feed could interleave and two queue drains could push the same rows twice. It recommended single-flight inside `RssSyncEngine` (later callers await the task in flight), a sidebar refresh that just awaits `syncAll()`, and an All Feeds sync that calls `syncAll` rather than loop. Then: "Longer term, a small `RefreshCoordinator` shared by mail and feeds (interval, foreground, manual, on-open; coalescing; one `isRefreshing` per medium) would replace the four trigger sites. Mail's 60 s view-owned loop lives in a different layer for IDLE reasons, so do not force mail into it in the first pass."
- **The Kit audit's F13, offline write queues and retry policy that differ per feature** (2026-10-02). Its table, by path:
  - HTTP transport: no queue; one retry after 250 ms on error -1005, -1001 or a spurious cancel, which also replays non-idempotent POSTs such as `/send` and `/move_messages`.
  - Mail send: `Outbox` JSON files; sent on reachability up or after enqueue; no backoff; dropped silently after 10 attempts.
  - Mail flag, move and purge: no queue; the error goes to the view model.
  - RSS marks: a SQLite `pending` table; triggered on "each local write + app triggers; **not** reachability"; no backoff; never gives up.
  - IDLE polling: a 30 s timer; `MailboxWatcher` backs off from 2 to 60 s.
  - Save draft: no queue, by design; an error banner.

  It recommended one `PendingOperationQueue` (a persisted op log, an idempotency key, exponential backoff, a reachability trigger and a dead-letter state), backed by SQLite, for RSS marks, mail send and later mail flag and move.
- **The tests audit (06, 2026-10-02).** Among its most consequential robustness instances: "Autosave/poll loops with `[weak self]` + `self?.` never exit if the owner is gone without `stop()`." Its examples were compose's 5 s and 60 s autosave loops and a loop in `AppState`. "The loop keeps waking forever doing nothing", and "The fix is `guard let self else { return }` inside the loop." Its finding F15 (hand-rolled debouncers, seven, and pollers, eight) recommended: "Extract a `Debouncer` and a `Poller`, each with an injectable clock. That makes F8's tests deterministic and fixes the never-exiting `[weak self]` loops" (F8 is its finding on fixed sleeps that assert absence).

## How to start it

Kick-off brief to paste:

> Run the refresh scheduling plan (refresh-scheduling.md) on current `stage`. Read 00-working-agreements.md first, and the plan's "Background from the rearchitecture". Re-check every file:line it cites and the state of #1983, #2028 and #1962. Check which sibling PRs have merged: mail-correctness.md's PR 4 (a one-folder poll entry), sqlite-mail-store.md's PRs 3.4 and 4.5, test-debt.md's A4 (a test clock), kit-split.md's PR 0 and PR E; and whether a feed-bulk-actions.md, flags-and-cross-media.md or shared-load-error-state.md PR is open in `Feeds/ItemList/`. File an issue for the stale sidebar counts (none exists). Write a short scope doc with the maintainer's three decisions at the top, quoted in full, and one line per PR saying what the maintainer will see change; if decision 1 is already answered, open PR 1 at once. Run Step 0 on the Mini before PR 3. Then open PRs 2, 3, 5 and 4 one at a time, each green before the next. Do not fold the Inbox badge loop into the folder pollers. Do not edit any source-scan test; ask first if one blocks you. Write "Refs #2028" and keep fix words away from that number.

Read: this plan and `00-working-agreements.md`, both in `docs/1.x/post-wave-3/`. What the session needs from workstream 2.2's decisions 9 to 11, the feeds audit's F5, the Kit audit's offline-queue table and the tests audit's loop findings is under "Background from the rearchitecture" above. Rigs: the Mini for Step 0 and the iOS, visionOS and macOS simulator checks; the Studio's Duo simulator for PRs 3 and 4 (one Studio GUI session at a time; post before taking the screen). Coordinate use of the two stage test accounts.

## Risks and checks

- **Pinned shapes.** Keep `feedRefreshTask` settable and `inboxBadgeTask` readable, the re-appear branch in `MessageListView.swift:500-508` (`MessageListRefreshRoutingTests`), and the `applyLaunchRestoreWhenReady()` calls in `FeedItemListView.swift` (`LaunchRestoreSequencingSourceScanTests`; `CompactBrandMarkSourceScanTests` also reads the file). No scan edit is needed.
- **#2028 is not closed here.** A warm notification tap consumes its restore before any poll lands; R4's retry is the fix.
- **A loading flash on every return to the app.** A poll holds each list's loading state; Step 0 decides whether the Mac needs the 60-second skip.
- **Clock changes.** A future last-sync time counts as stale, so a clock set back never freezes feed syncing.
- **A feed that always fails** never counts as fresh, so triggers covering it keep running a pass, as today. No worse; say so in the docs.
- **Fixed sleeps in tests.** `AppForegroundTests` already sleeps 200 ms (`:60`, `:71`). Add no more; test-debt.md owns those.
- **A stale engine comment.** `RssSyncEngine.swift:35-36` lists "background refresh" among the app's triggers; none exists. docs-and-bookkeeping.md fixes it.

## Not in this plan

- **A `RefreshCoordinator` type and one shared "refreshing" indicator per medium** (F5's longer-term idea): not built. The engine's single-flight already joins overlapping feed passes, and `FolderPollers` already coalesces mail; what is missing is triggers and a freshness rule, which fit in the existing owners. A shared indicator is a load-state question for shared-load-error-state.md (B2 moves the feed sidebar and list onto one load state).
- **Folding the Inbox badge loop into the folder pollers:** kept separate by 2.2's default decision 9, which the maintainer did not overrule; nothing has changed.
- **One STATUS per folder per interval** (the verify line of the mail audit's W7, polling consolidation: "network logs show one `/folder_status` per interval per folder regardless of window count"): not proposed. It needs a Kit change to `idle(folder:)` and saves about one STATUS a minute per open folder, and the tick still has to ask the folder to see read and flag changes.
- **#2028's restore retry:** multi-window-and-restore.md (R4).
- **A shared `Debouncer` with an injectable clock:** test-debt.md (A4). This plan takes the loop helper only; mail-navigation-refactors.md ("Not in this plan") already says so.
- **The compose autosave loops:** mail-navigation-refactors.md PR 3; it may adopt PR 2's helper later.
- **The shared offline queue and its reachability trigger:** sqlite-mail-store.md; its PR 4.5 replaces this plan's feed reconnect drain.
- **One STATUS fanned out to each list's own fetch:** sqlite-mail-store.md (PR 3.4).
- **Poll-vocabulary renames** (`idle`, `MailboxWatcher`) and the `canImport(Network)` guards: kit-split.md.
- **iOS background refresh and push-driven feed refresh:** the RSS plan's Phase 8 (`docs/1.x/rss-implementation-plan.md:1950`), not started; no code exists for it.
- **Holding the list model across a fold:** the maintainer chose "Anchor only" for workstream 3.3's decision G (2026-10-09: each list keeps building its own model, and after a fold the rebuilt list shows its top until its first refresh lands, then moves back to the row you were on); the instantly rebuilt list is sqlite-mail-store.md's.
- **Pausing polling while the Mac app is in the background:** not proposed; the Dock badge and the menu-bar count read the badge loop.
- **A freshness rule for the mail list's re-appear refresh:** not proposed; it is one STATUS and one page, and a scan pins it.
- **Real-device return-to-app and reconnect checks:** the maintainer's TestFlight checklist for the release that carries PR 3 (and PR 4). **Real iPhone Duo checks:** duo-support.md.

## Sources

- Repo at 50e6022: the files and lines cited above, all under `apple/` unless they start `docker/`, `terraform/`, `lambda/`, `docs/` or `scripts/`. The main ones: `CabalmailUI/Session/SessionPollers.swift`, `CabalmailUI/Mail/Store/FolderPoller.swift` and `FolderPollers.swift`, `CabalmailUI/App/AppState+Foreground.swift`, `CabalmailKit/Sources/CabalmailKit/CabalmailClient.swift:66-98, :114-233`, `RSS/RssSyncEngine.swift:10-36, :141-166`, `CabalmailTests/SessionHarness.swift:166-188`, `CabalmailTests/FakeRssClient.swift`, `scripts/release-dashboard.py:179-185`.
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Sibling plans in this folder, read 2026-10-12: mail-correctness.md, sqlite-mail-store.md, kit-split.md, multi-window-and-restore.md, account-isolation.md, feed-bulk-actions.md, flags-and-cross-media.md, shared-load-error-state.md, ipad-layout-and-keyboard.md, mail-navigation-refactors.md, duo-support.md, test-debt.md (A4), live-verification.md (rig contention; the real foreground and reconnect checks), docs-and-bookkeeping.md (the `RssSyncEngine` trigger comment).
- GitHub, read 2026-10-12: #1983, #2028, #1962 open; #1355, #1880 (not planned), #1886, #1908 closed. Open PRs: #1968 (Linux) touches none of these files; #2043 is the 1.31.0 promotion of stage itself, so it carries them but cannot conflict with stage work.
