# Android parity backlog

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session. One Android session, run outside the Apple clients rearchitecture project (which has closed), carries the backlog end to end: about ten small Android-only PRs, one batch of decisions, no server change. The Android legs other plans hand here run later as one short session each, after their Apple leg ships, not as a standing project.
**Size:** M for the backlog session. The later legs add about XL in total (two L, three M, one S), spread over months *(inferred)*.
**Priority:** Now for PR 1, Next for the rest. PR 1 stops Android's feed reader mode running script from the article, the twin of #1911, and should ship in the same release as hardening-web-and-writes.md's Apple fix. The rest is low-impact bugs and one feature. It all runs on Ubuntu CI and touches no Apple file, so it can go at the maintainer's review pace beside the Duo work.
**Depends on:** hardening-web-and-writes.md (its decisions 2 and 3 set the design PR 1 mirrors). Decision only, not order: platform-conditionals.md decision 1 (the blank-rule default). Later legs: flags-and-cross-media.md, feed-bulk-actions.md, account-isolation.md (its decision 4 and PR A live), shared-load-error-state.md (its decisions 2 and 3), sqlite-mail-store.md (only if decision 5 here adds a leg).
**Unblocks:** nothing outside this plan. PR 9's first real Room migration is what the later feed legs build on.
**Duo groundwork:** None. This is the Android client; it lays nothing down for the iPhone Duo, and duo-support.md plans nothing foldable on Android.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
| --- | --- |
| Decisions 1 to 6 | Unanswered (2026-10-15) |
| PR 1. Reader mode runs no script (Android twin of #1911) | Not started (2026-10-15); its Apple twin, hardening PR 2 (#2056), is on `stage`, not yet released |
| PR 2. #1954: report feed, catalog and queue failures apart | Not started (2026-10-15) |
| PR 3 (only if decision 4 is Yes). A test harness for the feed database | Not started (2026-10-15) |
| PR 4. #1955: each sync-state write records only its own columns | Not started (2026-10-15) |
| PR 5. #2038: no suggestions on rule values | Not started (2026-10-15) |
| PR 6. #1931: the resume prompt names its destination | Not started (2026-10-15) |
| PR 7. #2031, Android half: a blank rule starts off | Not started (2026-10-15) |
| PR 8 (only if decision 3 is Yes). The feed store ends with the session | Not started (2026-10-15) |
| PR 9. Room version 2 | Not started (2026-10-15) |
| PR 10. Folder and All Feeds order stick | Not started (2026-10-15) |
| Later legs L1 to L6 | Not started (2026-10-15) |

## Decisions for the maintainer

1. **Vehicle.** Your words on Android feed order, answering the sticky feed order design's Android parity question (see "Background from the rearchitecture"): "Android: yes, with caveats... leave it for now and revisit in another project that isn't dedicated to the Apple clients" (the maintainer). **One Android session outside the Apple clients project (recommended)** or a new Android Claude project. A session run outside the Apple clients project meets "another project": about ten small PRs over two or three releases, with no coordinator. A project adds a coordinator and a scope phase this backlog does not need. Default: session.
2. **Android reader mode runs no script, mirroring your answers to hardening-web-and-writes.md decisions 2 and 3?** **Yes (recommended)** or No. Yes: reader mode looks the same (minus video embeds if you drop them there), and PR 1 fixes a new Android issue the session files; #1911 is already public, so filing it discloses nothing new. No: Android stays the one reader that runs article script, against the working-agreements rule. Default: Yes.
3. **Empty the Android feed store at sign-out?** **Yes, the feed store only (recommended)** or No. The harm today: marks one account queued offline are sent under the next account's session. For a feed both accounts follow, they change the second account's read and favorite state. A queued Mark All Read on such a feed is refused on every try and blocks the second account's own marks from ever sending *(inferred from code)*. Apple empties its feed store at sign-out and, since #1940, closes it. Yes adds PR 8. No: the answer is recorded and nothing is filed. Default: No, because it sits next to #1158 (mail caches), which you closed as not planned; this plan does not reopen #1158. Please answer here: the question the feed-fixes soak asked ("Tell me if you want it filed") was never answered, and the rearchitecture project's threads are not in the repo.
4. **Allow one test-only library in the Android kit, so the feed database's SQL runs in CI?** **Yes (recommended)** or No. Yes: the narrow writes (PR 4), the sign-out clear (PR 8), this first migration (PR 9) and every later one get CI tests; nothing extra ships in the app. No: those are checked by hand on the emulator, as the feed database is today. Default: Yes, if it runs inside the existing `kotlin` CI job; otherwise the session asks again.
5. **The Android mail queue and new server fields that sqlite-mail-store.md hands here.** **Not planned (recommended)** or add a later leg. Not planned: shipped Android keeps working because the fields are optional, and Android has no durable mail queue for them to protect. Revisit if Android ever queues mail writes offline. Default: not planned.
6. **Due before the first later leg, not in this batch: how the later legs run.** **One short session per leg, after its Apple leg is promoted (recommended)**, one Android session after the cross-media project ends, or an Android thread inside that project. Per leg: Android stays about one release behind Apple and each session works from merged Apple PRs. Default: per leg.

Not asked here: the blank-rule default (PR 7 follows platform-conditionals.md decision 1, whose default is that a blank rule starts off); #1158 (closed not planned); more than one signed-in account at once (out of scope since the rearchitecture's session-manager workstream, 1.3).

## What you'll see change

- **PR 1 (new Android issue, twin of #1911):** feed reader mode looks the same, but script inside an article no longer runs there.
- **PR 2 (#1954):** the red "Could not refresh feeds" line appears when every feed failed, and not because a queued mark failed to send.
- **PR 3 (only if decision 4 is Yes):** nothing visible. The feed database gets its first CI tests.
- **PR 4 (#1955):** "Load older items" no longer re-fetches a page it already loaded when a refresh overlapped it.
- **PR 5 (#2038):** Gboard stops rewriting words typed into a rule's Subject or Body value.
- **PR 6 (#1931):** the resume prompt names where it goes ("Pick up where you left off in Receipts?", or the feed's name), as Apple's does.
- **PR 7 (#2031, Android half):** Add rule opens the editor on a rule that stays off until you switch it on.
- **PR 8 (only if decision 3 is Yes):** signing out empties the feed list, its queued marks and the per-feed web profiles, so the next account starts clean.
- **PR 9:** nothing visible. The feed database gets its first real upgrade step, so unsent feed marks survive an app update instead of being wiped.
- **PR 10:** a feed folder and All Feeds open in the order last picked on any device, and the order menu appears on those lists too.

Later legs: the Android side of unified flags, feed custom flags, feed rules, the Flagged view and feed bulk actions, each about one release after Apple.

## Why

- **Reader mode runs article script.** Android's article view turns JavaScript on for the whole view (`ArticleWebView.kt:121`) and loads the reader document with `loadDataWithBaseURL(pageUrl, ...)` (`:240-247`). The reader document is Readability's output, inserted raw (`ReaderAssets.kt:63-72`), with only an `upgrade-insecure-requests` policy. On Apple the same gap was reproduced: an inline script and an `onerror` handler both ran, and Readability keeps `onerror` (#1911's comment of 2026-10-07). Android has not been tried *(inferred from code, high confidence)*. Practical risk is low, since the publisher's script already ran on the live page in the same profile, but it breaks the rule that readers render feed HTML with JavaScript off.
- **Feed order does not cross to Android.** The sticky-order plan recommended an Android follow-up once the server half was on prod, since without it "an order set on an Apple folder doesn't reach an Android folder list", and Android's local database needs a real migration so queued read and flag changes aren't dropped (see "Background from the rearchitecture"). The maintainer said yes with caveats (decision 1's quote). Apple shipped per feed (#1930) and folders and All Feeds (#1959) on an additive server change (#1919). The server half is on prod (`origin/main` 36191f8: `ordering_mode` in `rss_update_folder/function.py:34`, `order:feeds:all` in `set_preferences/function.py:85`). On Android, folder and All Feeds lists always open newest first.
- **Two Android twins of fixed Apple feed bugs** (found in the stage soak of the feed fixes): "#1954, #1955: Android has the same bugs as #1904 and #1938."
- **Rules save text the user did not type.** #2038 reproduced twice in the Wave 3 soak: Gboard rewrote "dont thier" as "don't their", and the editor auto-saves.
- **The resume prompt is a blind choice.** #1931: "Accepting it took me from the mail folder list straight into a feed article on a feed I had not been reading."
- **Add rule saves a live every-message rule.** #2031: Android's blank `Rule` defaults to enabled.
- **Any feed schema change on Android wipes unsent marks.** The Room store is at version 1 with a destructive fallback, so a version bump drops every table, the pending queue included.

## Where things stand

Issues (checked on GitHub 2026-10-12):

| Issue | State, labels | What |
| --- | --- | --- |
| #1911 | open; bug, apple, verified | Apple reader mode runs script; no Android issue exists |
| #1954 | open; needs-verification (no `android` label) | "every feed failed" counts a failed queue push |
| #1955 | open; needs-verification (no `android` label) | a sync overlapping Load older puts back the older cursor |
| #2038 | open; bug, needs-verification, android | Gboard autocorrects Subject and Body values |
| #1931 | open; tester-found, usability, android | resume prompt names nothing |
| #2031 | open; bug, apple, needs-verification, android | Add rule saves an enabled blank rule |
| #1158 | closed not planned 2026-08-19 | Android mail caches survive sign-out |

Apple references, all merged: #1935 (one sync pass; `RssSyncReport`, closed #1904), #1942 (each sync-state write records only its own columns; #1938), #1940 (a sync in flight at sign-out cannot refill the feed store; #1937), #1959 (folder and All Feeds order). #1957 (open, sqlite-mail-store.md) records an edge case of #1940's design. #2022 was fixed on stage by PR #2023 (commit f494bf3, Apple and Android) and closed when the 1.31.0 promotion (#2043) merged on 2026-10-12; its Gboard leftover is #2038 (PR 5).

Code at 50e6022 (paths under `android/`; `kit/...` is `kit/src/main/kotlin/com/cabalmail/kit`, `app/...` is `app/src/main/kotlin/com/cabalmail/android`):

- **Feed sync.** `kit/.../rss/RssSyncEngine.kt:147-183`: `syncAll` returns one map holding feed failures plus `"catalog"` and `"pending"` entries; `app/.../ui/feeds/FeedsViewModel.kt:133-137` compares its size to the subscription count. `FeedsViewModel.refresh` calls `refreshCatalog` (`:126`) and then `syncAll`, which fetches the catalog again (`RssSyncEngine.kt:150`). No app test builds a `FeedsViewModel`; `FeedViewModelsTest` builds only `FeedItemListViewModel` (`:187`).
- **Sync state.** `syncItems` (`RssSyncEngine.kt:70-116`) and `loadOlder` (`:122-139`) each read and rewrite the whole sync-state row. The first page of a feed's first sync sets the older cursor (`:84-91`), and that reaches the store only through the full-row write at `:114`. `RoomRssStore.setSyncState` (`:684-697`) replaces the row. Apple writes the older cursor at three points: the first page (`RssSyncEngine.swift:138`), progress (`:164`) and Load older (`:181`).
- **Room.** `kit/.../rss/RoomRssStore.kt:346-369`: `@Database(version = 1, exportSchema = false)` with `.fallbackToDestructiveMigration(dropAllTables = true)`. The Room Gradle plugin is in the catalog (`gradle/libs.versions.toml:115`) but unused. The kit has JUnit 6.1.3 unit tests only (`libs.versions.toml:24`), no Robolectric, no `androidTest`; the DAO is "exercised on-device" (`RoomRssStore.kt:39-41`).
- **Folder order.** `kit/.../models/Rss.kt:213-228`: `RssFolder` has no `ordering_mode` (`RssSubscription` has one, `:177`). `RssFolderUpdate` (`:344-353`) has no order field, and its `isEmpty` (`:351-352`) lists the four it has. `ApiClient.updateRssFolder` (`kit/.../api/ApiClient.kt:977-990`) sends none. `FeedItemListViewModel.kt:57` hides the order menu behind `canSearch` (single feed); `setOrdering` persists only to a subscription (`:284-294`). `PreferencesWire.kt:32` knows `filter:feeds:all`, sent only once set (`:72`), and no `order:` key.
- **Rules.** `RuleEditorScreen.kt:271-283` uses `KeyboardOptions(autoCorrectEnabled = false)`, which cannot add `TYPE_TEXT_FLAG_NO_SUGGESTIONS`; #2038 explains why Gboard needs it. `Rules.kt:85` defaults `enabled = true`; `RulesViewModel.kt:171` adds `Rule(name = "New rule")`; the templates already set `enabled = false`.
- **Resume prompt.** `strings.xml:112` takes no argument; one call site, `CabalmailNavHost.kt:333` (a 1,060-line file). Apple's wording: `apple/CabalmailUI/Navigation/NavStateCoordinator+ServerCursor.swift:88-98`.
- **Sign-out.** `SignInViewModel.kt:129-140` deregisters push, signs out, and clears the resume session and reading positions; it never touches `rssStore` (`AppContainer.kt:125`). The memoized feed engine is dropped only when the control domain changes (`AppContainer.kt:214-235`). The expired-session path (`SignInViewModel.kt:79-88`) signs out (tokens only) and clears neither the resume state nor any cache.
- **What a leaked queue does.** `drainPending` (`RssSyncEngine.kt:199-219`) pushes every queued mark under the current session, in order, and stops at the first failure; marks also trigger a drain at once (`pushSoon`, `:277-283`). Item marks: `rss_set_item_state` applies them when the caller follows the feed and answers 404 `not_subscribed` otherwise (`lambda/api/rss_set_item_state/function.py:29, 46-51`); rows for feeds the new account does not follow go at its first catalog refresh (`RoomRssStore.kt:401-419, 479-483`). Mark All Read: the queued row holds the old account's subscription id (`:597-616`), a per-user UUID (`_shared/rss_subscribe_core.py:216`). If the new account follows the same feed, the catalog refresh keeps the row, and `rss_mark_all_read` answers 404 `unknown_subscription` (`_shared/rss_api.py:172-179`) on every pass, so the new account's later marks never go *(inferred from code)*. A queued mail send cannot go out as the wrong account: `send` refuses a sender the caller does not own (`lambda/api/send/function.py:66-69`).

Checked and already handled on Android: #1939 and #1956 (`setRead`, `setFavorite` and `markAllRead` share a transaction with their queue row, `RoomRssStore.kt:579-616`); the client half of #1804 (`ApiClient.kt:501-503`); #1918's client half (Android reads `Error`, `ApiClient.kt:187`).

Not checked for this plan: any Android build or test run (this container has no Android SDK); a reproduction of #1954, #1955 or the reader-mode twin (all code readings); Android twins of #1903, #1935, #2028, #2037, #1974 and #1977; whether the Play internal-track upload is live; whether the maintainer has an Android device on that track; whether the Mini's emulator image is still installed.

## The plan

### The backlog session

Order: the reader-mode fix first, then bugs, then the Room work. PRs 2, 3 and 4 share `RssSyncEngine.kt` or `RoomRssStore.kt` and run in sequence. PRs 5, 6 and 7 touch separate files and may be open together. PR 10 follows PR 9 because it builds on PR 9's folder model. Android CI is `lint.yml`'s `kotlin` job on `ubuntu-latest` (ktlint, Android Lint with warnings as errors, kit and app unit tests); it does not compete with the Apple macOS runners. Each user-visible PR adds an `Android:` fragment whose bold headline is about 40 characters (a release's Android headlines share 500 characters; `scripts/tests/test_play_release_notes.py` fails a PR that overruns). PRs 3 and 9 take the `no-changelog` label; PR 9's note rides in PR 10's fragment.

**PR 1. Reader mode runs no script (Android twin of #1911).**
- Scope: two locks, mirroring hardening-web-and-writes.md PR 2 and the maintainer's answers to its decisions 2 and 3. First, JavaScript follows explicit reader state: `ReaderState.show` turns `settings.javaScriptEnabled` off before `loadDataWithBaseURL` (`ArticleWebView.kt:240-247`), and leaving reader mode (the toggle back at `:105-109`, the link-out branch in `shouldOverrideUrlLoading`) turns it on before the live page loads. A settings change applies from the next load *(inferred)*. Second, the reader document gains `script-src 'none'; object-src 'none'` and, if videos are dropped, `frame-src 'none'`. Extraction (`evaluateJavascript`, `:88`) still runs on the live page.
- Issue: file the Android issue first. The PR says "Fixes `#<new>`" and "Refs #1911", never a fix verb near #1911, which stays open for Apple. The release dashboard holds Promote while an open issue with a lifecycle label is claimed by a merged fix (`scripts/release-dashboard.py:133-139, 179-184, 461-478`).
- Tests: a kit test that the reader document carries the policy; a pure "JavaScript on for this load?" function tested over live, reader, link out and toggle back.
- Verify: on the Mini's emulator, an article whose body holds `<img src=x onerror="document.title='js-ran'">` (#1911's recipe) in reader mode; then images, links and toggling back.
- Risk: low. A flag left off would break the live page visibly; the toggle-back check catches it. Ship it in the same release as hardening's PR 2.

**Status:** Not started (2026-10-15). Its Apple twin, hardening-web-and-writes.md PR 2 (#2056, `5046716`, "Apple: feed reader mode runs no script from the article"), is merged to `stage` and not yet released; the hardening plan wanted both in one release. #1911 stays open until the hardening session's stage check. Hardening decisions 2 (same view) and 3 (drop video players) were taken on their recommended answers: Apple's reader rendering loads with page JavaScript off and leads with a content security policy refusing script, plugins and frames, Readability drops every video player, and a link tapped in the reader leaves it only once its page commits.

**PR 2. #1954: report feed, catalog and queue failures apart.**
- Scope: `syncAll` returns a report (catalog failure, pending failure, per-feed failures), modelled on `apple/CabalmailKit/Sources/CabalmailKit/RSS/RssSyncReport.swift`. `FeedsViewModel.refresh` shows the catalog failure, or the first failed feed's message only when every feed failed, as `apple/CabalmailUI/Feeds/Sidebar/FeedSidebarViewModel.swift:124-125` does. `FeedManagementViewModel.kt:246` keeps ignoring it. Optional: drop the second catalog fetch if the report carries the catalog diff.
- Tests: `RssSyncEngineTest` with `FakeRssClient`, as the issue describes. This PR adds the first `FeedsViewModel` test harness (engine provider, store, `onDroppedProfiles`), in `FeedViewModelsTest` or a new file.
- Verify: CI. Risk: low.

**Status:** Not started (2026-10-15).

**PR 3 (only if decision 4 is Yes). A test harness for the feed database.** One test-only dependency so `RoomRssStore` runs against real SQLite in the kit's unit tests; the scope doc names the library (Robolectric with the JUnit vintage engine is the likely route, *inferred*). First tests: `clear()` and `markAllRead`'s queue row. If it cannot run in the existing `kotlin` job, stop and ask. `no-changelog`.

**Status:** Not started (2026-10-15).

**PR 4. #1955: each sync-state write records only its own columns.**
- Scope: `RssStore` gains two narrow writes, as Apple's #1942 did: progress (since and state cursors, `lastSyncedAt`) and older (older cursor, `olderExhausted`), each an insert-if-missing then an update of its own columns in one transaction, mirrored in `InMemoryRssStore`. Three call sites: after the first page in `syncItems` (`:84-91`, the older write), at `:114` (progress) and in `loadOlder` (`:134-137`, older). No schema change.
- Tests: an engine test where `loadOlder` lands between `syncItems`' read and write (a suspending fake client) and the older cursor survives; a test that a feed's first sync leaves the older cursor set; DAO tests if PR 3 landed.
- Verify: the issue's steps on the Mini's emulator. Risk: low.

**Status:** Not started (2026-10-15).

**PR 5. #2038: no suggestions on rule values.**
- Scope: every `RuleField`'s value input gets `TYPE_TEXT_FLAG_NO_SUGGESTIONS` in `EditorInfo.inputType`, through Compose's `InterceptPlatformTextInput` *(inferred to exist in BOM 2026.09.00, marked experimental)*, with an `AndroidView` `EditText` as the fallback.
- Tests: a pure function giving the input flags per field.
- Verify: on the emulator with Gboard, `adb shell dumpsys input_method` shows `0x80001` for Subject and Body and `0x80021` for From; "dont thier acheive " typed with real key taps stays as typed (`adb shell input text` bypasses the keyboard and cannot show this).
- Risk: low to medium. The experimental opt-in must pass Lint, and a dependabot BOM bump could move the API.

**Status:** Not started (2026-10-15).

**PR 6. #1931: the resume prompt names its destination.** `resume_prompt` takes the name; a small resolver gives the mail folder's display name, or for a feed the subscription's title, then the item title, then "a feed", as Apple does. Change only the call site in `CabalmailNavHost.kt`. Tests: the resolver's fallbacks. Verify: #1931's recipe (seed `/set_nav_state` with a foreign `client_id`, cold-launch). Risk: low.

**Status:** Not started (2026-10-15).

**PR 7. #2031, Android half: a blank rule starts off.** `RulesViewModel.add`'s default gets `enabled = false`, per platform-conditionals.md decision 1. Tests: `RulesViewModelTest`. Verify: CI and one emulator pass. Issue wording: platform-conditionals.md writes "Fixes #2031" only if this PR merged first, so whichever half merges second claims the fix; the first says "Refs #2031". Risk: low.

**Status:** Not started (2026-10-15).

**PR 8 (only if decision 3 is Yes). The feed store ends with the session.**
- Scope: one container method, called from `signOut` after push deregistration: stop in-flight feed work, read the stored subscriptions' web-profile ids, empty the store (`RoomRssStore.clear()`, `:390-397`), drop the memoized engine, and drop those profiles (`FeedWebProfiles.drop`). Feed syncs run in screen-owned coroutine scopes, so the scope doc picks either a session-owned job for the engine or a session check before each store write (#1957 records the edge case of Apple's closing design). On sign-in, also empty it when the username differs from the last session's, as Apple does (`SessionManager.swift:689-694`, username only), or the control domain differs, which Android adds because one build serves any deployment (#1158's body). The expired-session path does not empty it, so the same user signing back in keeps unsent marks. Do not touch #1158's mail caches, body cache or drafts.
- Tests: a kit test that a pass started before the clear cannot write after it; a test that a queued Mark All Read cannot survive into the next account; an app test of the sign-in comparison.
- Verify on the emulator: as test account 1, queue a mark offline, sign out, sign in as test account 2 (MFA on), and check the Feeds list and that no mark is pushed. Coordinate account use: a sign-in on one device can sign out another.
- Risk: medium (session lifecycle). Not in the same release as PR 9.

**Status:** Not started (2026-10-15).

**PR 9. Room version 2 (nothing visible).**
- Scope: `RssFolderRow` gains `ordering_mode` (default `newest_first`); `MIGRATION_1_2` adds the column; `version = 2`, `exportSchema = true`, the Room Gradle plugin applied with a committed schema directory holding version 1 and version 2 (export version 1 first). Keep the destructive fallback for downgrades. The model half: `RssFolder.orderingMode` decoded and carried by `applying`, `RssFolderUpdate.orderingMode` counted in `isEmpty` (otherwise an order-only update is never sent), and `ordering_mode` in `updateRssFolder`'s body. In the same PR, add a dated erratum to `docs/1.x/cross-media-ux-plan.md:306-311, 467`: Phase 2 becomes Room version 3 (docs-and-bookkeeping.md hands it here).
- Tests: open a version 1 database holding a folder and a queued mark, migrate, check the folder reads newest first and the mark is still queued (in CI with PR 3, otherwise as an emulator check); decode tests with and without the field.
- Verify on the Mini: build a debug APK from stage and one from the branch, both signed with the Mini's debug key, install stage, mark an item read offline, install the branch build over it, go online, and see the mark arrive on another client. A Play-track build cannot be upgraded in place by a debug build, so do not test over one.
- Risk: medium. A mismatch between the entity and the migration fails when the store opens *(inferred)*; the test and the upgrade check exist for that.

**Status:** Not started (2026-10-15).

**PR 10. Folder and All Feeds order stick.**
- Scope: an `order:feeds:all` key in `AppPreferences`, `PreferencesWire` and `PreferencesRepository`, nullable and sent only once chosen, like `feedsAllFilter`. A non-null default would make every Android preference push re-send `newest_first` over an order picked on Apple. The list opens on the subscription's order, else the folder's, else (All Feeds) the preference, else newest first. `setOrdering` persists to the folder (`RssSyncEngine.updateFolder`) or to the preference. The order items show on folder and All Feeds lists; search stays single-feed (`FeedItemListScreen.kt:144`, `:193`). A folder's order applies to its merged list and each feed keeps its own (the sticky feed order design; see "Background from the rearchitecture"). An order change made offline is not queued (its known limit).
- Tests: wire round-trip of the key, an unknown value, and "unset is not sent"; `FeedViewModelsTest` for each scope's opening order and what each change persists.
- Verify on the Mini: set a folder's order and All Feeds' order on an Apple simulator with stage test account 1, refresh the Android emulator, check both lists, then the reverse. Risk: low.

**Status:** Not started (2026-10-15).

**Releases.** PR 1 rides with hardening-web-and-writes.md's PR 2. PRs 2 to 7 ride the next promotions. PR 8 and PR 9 never share a release, so a sign-out regression and a migration regression stay apart. PRs 9 and 10 go in one release with no other Android structural change, and its soak adds PR 9's upgrade check. Each issue needs its verification before promotion; ask the tester or a second agent to reproduce #1954, #1955 and the reader-mode twin first. Each Android merge to stage queues a `gate-stage` Play upload approval (`android.yml:129`), so batch merges where possible.

**Hotspots**, all Android, owned by this session while it runs: `RssSyncEngine.kt`, `RssStore.kt`, `RoomRssStore.kt`, `InMemoryRssStore.kt` (PRs 2, 3, 4, 8, 9); `ArticleWebView.kt` and `BodyFormatting.kt` (PR 1); `Rss.kt` and `ApiClient.kt` (PR 9); `FeedItemListViewModel.kt`, `FeedItemListScreen.kt`, the preferences files (PR 10); `CabalmailNavHost.kt` (PR 6); `AppContainer.kt`, `SignInViewModel.kt` (PR 8). The later legs edit the same files, so they start after this session's PRs merge. No Apple file, Lambda or Terraform.

**Rigs.** CI for every PR. The Mac mini's Android 15 emulator with Gboard, through Remote Control (#2038 used it in the Wave 3 soak; the tester's run in #1931 used `Pixel_8_API_35`); check first that the maintainer's tester is not using the Mini. An Apple simulator on the Mini for PR 10. Stage credentials are read at run time from AWS Parameter Store by a helper on the rig; never print them.

### Later legs (one short session each, decision 6)

**Status:** Not started (2026-10-15). None of the Apple legs they follow has started.

Each leg starts when its Apple leg is promoted, writes a short scope doc against the merged Apple PRs, and ships in one release with a soak.

| Leg | From | Starts when | Scope | Size |
| --- | --- | --- | --- | --- |
| L1 Unified flags | `docs/1.x/unified-flags-plan.md` Phase 4 and Phase 2's `android/kit` half | flags-and-cross-media.md's unified-flags release promoted | system flag slot and cap 21 in `FlagPalette.kt`; palette settings, row dots, reader chips, swipes, Shift+L, selection bar, rule editor (`unified-flags-plan.md:315-330`). No Room change | M |
| L2 Feed custom flags | cross-media Phase 2 | its server change live and Apple's client promoted | Room version 3 on PR 9's path (item flags, a pending slot column, coalesced per item and slot); `RssItem.flags`; the drain; reader Flag menu, row dots, picker | L |
| L3 Feed rules | cross-media Phase 4 | its server changes live and Apple's client promoted | feed rule model and validator; a "Feed items" section in the Rules editor | M |
| L4 Flagged view | cross-media Phase 5 | Apple's Flagged view promoted | a Flagged entry in the nav host; the mail half's source is decided in its scope doc | L |
| L5 Feed bulk actions | feed-bulk-actions.md (its decision 1) | its Apple PRs promoted | `SelectionTopBar` on `FeedItemListScreen`; Forward as Email; Mark All as Read on a folder or All Feeds in one request | M |
| L6 Push account check | account-isolation.md | its decision 4 is Hashed or Plain and its PR A is live | check the stamp before showing a push | S |

Conditional legs: feed notification toggles in Settings, only if flags-and-cross-media.md decision 10 is Now (its default, Wait, leaves Phase 6 as Apple-only Spotlight); an Android twin of #1901, only if shared-load-error-state.md decision 3 is Tolerate; Android adoption of sqlite-mail-store.md's optional server fields, only if decision 5 here adds it.

Room numbering: `docs/1.x/cross-media-ux-plan.md:306-311` and `:467` say Phase 2 is Room version 2. PR 9 takes version 2, so Phase 2 becomes version 3. PR 9 adds the dated erratum there, since the claim turns false only when PR 9 merges.

## Background from the rearchitecture

The sticky feed order design was a short plan written in the rearchitecture project when the maintainer asked that the feed list's order stick per feed (or folder) across devices. Apple's #1930 and #1959 and the server's #1919 shipped it; PR 9 and PR 10 are its Android follow-up. What this plan uses from it:

- **What already worked.** Per feed, the server and the Kit already stored and synced the order: every subscription carries an `ordering_mode` the server validates, and Android's list menu already saves it. Every list (a feed, a folder, All Feeds) can be sorted any of the four ways on the device; the server never sorts by the saved order, so no server listing changes.
- **The server half (now on prod, see "Why").** Additive only: a new `ordering_mode` on folder rows (missing rows read as newest first) and, for All Feeds, a synced preference key `order:feeds:all` beside the existing `filter:feeds:all`. It had to reach prod before any client sent the new field or key, because the server used to answer a folder update carrying only the order with "nothing to update" and rejects an unknown preference key outright.
- **Its recommendations.** All Feeds' order sticks too, through the synced `order:feeds:all` key, so the menu sticks everywhere the filter pill does. A folder's order does not change the feeds inside it: it applies to the folder's own merged list, and each feed keeps its own, as the pill's filter already behaves. Android parity as a follow-up after the server half is on prod, since without it an order set on an Apple folder does not reach an Android folder list; Android's local database needs a real migration so queued read and flag changes are not dropped (PR 9).
- **Known limit, unchanged.** Like the pill, an order change made while offline is not queued: if the write fails, the next refresh restores the server's value. Both would need the offline queue that today covers only read and flag marks.

## How to start it

Paste to open the session (a new Claude Code thread on the repo):

> Run the backlog session of `android-parity.md`, the Android parity backlog. Read `00-working-agreements.md` and `android-parity.md` (both in `docs/1.x/post-wave-3/`) first, then the plan's "Background from the rearchitecture" section and PR 2 of `hardening-web-and-writes.md`. The maintainer's answers to decisions 1 to 5, to hardening-web-and-writes.md decisions 2 and 3, and to platform-conditionals.md decision 1: `<paste>`. Work against current `stage` and re-check every file:line in the plan. First write a short scope doc: open questions at the top, each answerable in one word with a recommended answer, then one line per PR saying what the maintainer will see change. File the Android reader-mode issue (twin of #1911) and, if decision 3 is Yes, one for the feed store at sign-out; label #1954 and #1955 `android`. Then open the PRs in the plan's order against `stage`, each with an `Android:` fragment unless the plan says `no-changelog`. Never put a fix verb next to #1911, and follow the plan's wording rule for #2031. Touch no Apple file, Lambda or Terraform. CI is `lint.yml`'s `kotlin` job; this container has no Android SDK. For emulator checks, ask the maintainer for a Remote Control session on the Mac mini and confirm the maintainer's tester is not using it. Credentials for the two stage test accounts are read at run time from AWS Parameter Store by a helper on the rig; never print them.

Point the session at: this plan and `00-working-agreements.md` in `docs/1.x/post-wave-3/`; `hardening-web-and-writes.md` beside them. Reference PRs: #1935, #1940, #1942, #1959. Issues: #1911, #1954, #1955, #2038, #1931, #2031.

For a later leg: the same brief with the leg's row, the Apple PRs it mirrors, and the relevant phase of `docs/1.x/unified-flags-plan.md` or `docs/1.x/cross-media-ux-plan.md`.

## Risks and checks

- **The first migration.** A wrong migration fails when the store opens and takes the Feeds tab with it *(inferred)*. Checks: the migration test, the upgrade install in PR 9, and the same install in that release's soak.
- **Downgrades.** Installing an older build over version 2 loses the feed cache and unsent marks through the destructive fallback, as every bump did before *(inferred)*. Acceptable; say it in the PR.
- **Reader mode left without script.** If the JavaScript flag is not restored, live pages break. PR 1's toggle-back check, and the soak, open live pages after reader mode.
- **Experimental Compose API in PR 5.** Keep the flags in a tested pure function and re-run the `dumpsys` check in each soak until the API is stable.
- **Promote held by a claim.** A PR that writes "Fixes" or "Addresses" next to #1911 or #2031 before the Apple half lands holds every promotion. Use the wording in PRs 1 and 7.
- **Changelog budget.** Eight Android headlines at about 40 characters fit 500 characters with the lead line *(inferred)*. If other Android fragments are pending, let PRs ride the next release rather than trim headlines.
- **Shared rigs and accounts.** The Mini is shared with the maintainer's tester, and a sign-in can sign out the same account elsewhere. Coordinate before PR 8's two-account check.
- **No device in the loop.** If the maintainer has no Android device on the Play internal track (not checked), the emulator is the only check; the PRs should say so.

## Not in this plan

- #1158, Android mail caches at sign-out: closed not planned by the maintainer; not re-proposed. Decision 3 covers the feed store only.
- The Apple half of #2031: platform-conditionals.md.
- The stale status of cross-media Phase 1 (`docs/1.x/cross-media-ux-plan.md:11, 215`) and the pointer comment on #2022 (closed by the 1.31.0 promotion) naming #2038: docs-and-bookkeeping.md.
- Exception text in 500 replies: 27 Lambda sites in 27 files put `str(err)` in the reply (shared-load-error-state.md's count), including the `guarded` wrapper every feed endpoint Android calls goes through (`lambda/api/_shared/rss_api.py:110-121`). Android shows it because it reads `Error` at every status. The fix is server-side: shared-load-error-state.md decision 2 (its A7).
- The server half of #1804: hardening-web-and-writes.md (decision 5, default decline). If it ever ships, Android needs `message_raw` omitted, never null (`kit/.../models/Models.kt:136`).
- Checking that a shipped Android build's whole-set rule save leaves a stored `feedRules` list alone: flags-and-cross-media.md owns it, and it applies from its Phase 4 server change, not from L3.
- Native sign-up and native admin on Android (#1951, #1952, open): `docs/1.x/auth-parity-plan.md`.
- Queuing order changes made offline: unchanged on both platforms (the sticky feed order design's known limit, under "Background from the rearchitecture").
- The Android twins under "Not checked": none is filed, and none joins without a reproduction.

## Sources

- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Sibling files in this folder: `00-working-agreements.md`. Sibling plans (2026-10-12): hardening-web-and-writes.md (decisions 2, 3, 5; PR 2; its hand-off of the Android reader); flags-and-cross-media.md (decisions 4, 10; Stage B; its hand-off list); feed-bulk-actions.md (decision 1; its Android legs); account-isolation.md (decision 4; PR A; its hand-offs); platform-conditionals.md (decision 1; its #2031 close-out); shared-load-error-state.md (decisions 2, 3; its #1918 count); sqlite-mail-store.md (PR 4.0; its hand-off; `:69` on Android having no durable mail queue); duo-support.md (`:197`).
- Issues (GitHub, 2026-10-12): open #1911, #1931, #1951, #1952, #1954, #1955, #1957, #2022, #2031, #2038; closed not planned #1158. PRs #1919, #1930, #1935, #1940, #1942, #1959, #2023 merged. `origin/main` is 36191f8 (1.30.0); f494bf3 is not on it.

> **Erratum (2026-10-15):** `main` has since released 1.31.0 (#2043), 1.31.1 (#2052) and 1.31.2 (#2055), so f494bf3 is on `main` now.

- Android code at 50e6022: `kit/.../models/Rss.kt:177, 212-228, 344-353`; `kit/.../rss/RoomRssStore.kt:35-56, 346-369, 390-419, 479-483, 579-616, 684-697`; `kit/.../rss/RssSyncEngine.kt:70-139, 147-183, 199-219, 277-283`; `kit/.../api/ApiClient.kt:187, 501-503, 977-990`; `kit/.../settings/PreferencesWire.kt:32, 36-80`; `kit/.../models/BodyFormatting.kt:43-61, 79-110`; `kit/.../models/Rules.kt:85`; `kit/build.gradle.kts`; `gradle/libs.versions.toml:16, 21, 24, 115`; `app/.../AppContainer.kt:125, 192-235`; `app/.../ui/auth/SignInViewModel.kt:79-88, 129-140`; `app/.../ui/feeds/ArticleWebView.kt:42-56, 88-121, 225-247`; `ReaderAssets.kt:63-72`; `FeedsViewModel.kt:119-145`; `FeedItemListViewModel.kt:57, 130, 284-294`; `FeedItemListScreen.kt:144, 193`; `FeedManagementViewModel.kt:246`; `FeedWebProfiles.kt:17`; `app/.../ui/mail/MessageDetailScreen.kt:720`; `app/.../ui/rules/RuleEditorScreen.kt:271-283`; `RulesViewModel.kt:171`; `navigation/CabalmailNavHost.kt:333`; `app/src/main/res/values/strings.xml:112`; `app/src/test/.../ui/feeds/FeedViewModelsTest.kt:187`.
- Server: `lambda/api/set_preferences/function.py:79-87`; `rss_update_folder/function.py:34`; `rss_set_item_state/function.py:29-51`; `rss_mark_all_read/function.py:23-44`; `_shared/rss_api.py:110-121, 172-179`; `_shared/rss_subscribe_core.py:216`; `send/function.py:66-69`.
- Apple references: `apple/CabalmailKit/Sources/CabalmailKit/RSS/RssSyncReport.swift`; `RSS/RssSyncEngine.swift:138, 164, 181`; `RSS/RssStore+State.swift:201-212`; `apple/CabalmailUI/Session/SessionManager.swift:681-696`; `apple/CabalmailUI/Navigation/NavStateCoordinator+ServerCursor.swift:88-98`; `apple/CabalmailUI/Feeds/Sidebar/FeedSidebarViewModel.swift:124-125`.
- Repo tooling: `scripts/release-dashboard.py:133-139, 179-184, 461-478`; `.github/workflows/lint.yml` (`kotlin` job), `android.yml:129`, `android-changelog.yml`, `.github/scripts/play-release-notes.py`, `scripts/tests/test_play_release_notes.py`. Plans: `docs/1.x/unified-flags-plan.md:315-330`; `docs/1.x/cross-media-ux-plan.md:306-311, 428-452, 467`.
