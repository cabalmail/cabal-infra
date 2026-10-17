# Shared load and error state

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Two sequential sessions. Session A fixes four open error bugs and moves the app's failure wording into one place; Session B moves every screen onto one load state once its files are free. Nothing runs in parallel and there is no audit, migration or outside event, so a project would add coordination with nothing to coordinate.
**Size:** L overall (Session A: M, seven PRs plus one optional server PR. Session B: M, four PRs).
**Priority:** Next for Session A: four verified bugs (#1900, #1902, #1903, #1918, all open), two of them visible today, and two other plans wait on its #1903 fix. Later for Session B: nothing visible changes, and Now and Next plans hold its files first.
**Depends on:** Session A, order only: account-isolation.md, mail-correctness.md, mail-navigation-refactors.md, hardening-web-and-writes.md, platform-conditionals.md, feed-bulk-actions.md, swift6-and-strict-checking.md, test-debt.md; soft: docs-and-bookkeeping.md (the API rule in the repo, for A7). Session B: Session A, then order only: feed-bulk-actions.md, platform-conditionals.md, refresh-scheduling.md, flags-and-cross-media.md, duo-support.md, detached-reader-window.md, mail-correctness.md, mail-navigation-refactors.md, sqlite-mail-store.md, multi-window-and-restore.md. Files are in the "Hotspots" table.
**Unblocks:** sqlite-mail-store.md (A3 before its Phase 4), flags-and-cross-media.md (A3 before its B4.3), android-parity.md (decisions 2 and 3 settle two of its legs). Soft: detached-reader-window.md can adopt the load state after B3.
**Duo groundwork:** The rule this plan centralizes, that a load cut short by its own task's cancellation paints nothing and reloads on the next appearance, is the rule a fold exercises, because a layout swap tears down each screen's `.task` (inferred, high confidence); B2 and B3 check it on the Studio's Duo simulator. It does not keep screen models alive across a fold (3.3 "Anchor only", Wave 3.3's answer on 2026-10-09; see "Background from the rearchitecture").
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| A1, #1900 alone | Not started (2026-10-15) |
| A2, Kit error contract (#1902, #1918 client half, decision 1) | Not started (2026-10-15) |
| A3, #1903 in the Kit | Not started (2026-10-15) |
| A4, the mapper, logging and compose | Not started (2026-10-15) |
| A5, sign-in and Siri | Not started (2026-10-15) |
| A6, sheets, Rules, Settings, Addresses and feed management | Not started (2026-10-15) |
| A7, optional: the Lambda 500s (decision 2) | Not started (2026-10-15) |
| A8, only if decision 3 is Tolerate | Not started (2026-10-15) |
| B1, the type and the simple screens | Not started (2026-10-15) |
| B2, sidebars and feeds | Not started (2026-10-15) |
| B3, the reader and the action failures | Not started (2026-10-15) |
| B4, the message list | Not started (2026-10-15) |

> **Duo spec (2026-10-13):** This plan was written before the maintainer's Oct 7 Duo spec (the Claude Doc linked in duo-support.md) was read in the rearchitecture project. duo-support.md now follows it; where this plan's text disagrees with the points below, the points win. In the spec, "fold" means book or laptop pose, which changes no size class and swaps no shell; what this plan calls folding or unfolding the Duo is closing or opening it.
>
> - The cut-short rule covers today's shell swap on a close or open, not book or laptop folds. B3's Studio check adds: open a message, Mark Unread, close and open; the message stays unread and is not re-fetched (duo-support.md PR 8 fixes the re-mark).

## Decisions for the maintainer

Four questions. A1 and A3 need none of them and may open while they are out. If you do not answer, the stated default applies. If you already answered question 1 on a decision card during the rearchitecture project, that answer stands; these plans record no such answer as of 2026-10-15.

1. **What a garbled server reply says.** Today an unreadable 200 shows "Couldn't read the server's reply. list returned an unexpected reply." and Siri reads "folder_status" aloud. In Wave 1.6 (the error model and API split) the session offered readable labels and you did not answer, so endpoint paths stood (the 1.6 session: "switching to readable labels is a one-line change if you'd prefer them"; PR #1905's body makes the same offer). **(a) Drop the endpoint name from what people see and hear; keep it in the debug log (recommended).** Every surface, the watch included, says "Couldn't read the server's reply." This is a third option, not the labels 1.6 offered. (b) Readable labels ("the address list returned an unexpected reply"), a table to keep current for 17 decode sites. (c) Keep the paths. Default: (a).
2. **#1918: fix it on the client only, or on the client and the server?** Either way the Apple client reads a refusal's `Error` text for 4xx replies only (the #1918 tester's first option), so creating an address on `mail-admin` reads 'Subdomain "mail-admin" is reserved on every mail domain.' instead of "The server couldn't complete that request (400)." A 500 keeps the generic sentence. **Client and server (recommended).** A7 makes 27 Lambda sites return a fixed sentence in their 500 replies and log the exception, so React and Android stop showing Python exception text. Status codes and keys stay the same. It changes reply text rather than adding a field, which is why it needs your yes under the additive API rule. Default: client only, and the PR that fixes #1918 records the server gap.
3. **#1901: Close or Tolerate?** **Close (recommended).** The strict rule decode is deliberate (`Rule.swift:11-15`: "silently coercing them would rewrite the rule on the next save"), Android matches it (`Rules.kt:9-12`), `/set_rules` accepts only the five fields and five actions the clients know, and flags-and-cross-media.md decision 6a keeps feed rules in a list of their own. Consequence: a future condition field or action must arrive under a new key, or after a release that tolerates it. Tolerate adds A8 (the editor shows unknown rules read-only with "Update Cabalmail to edit these rules" and refuses to save) and an Android twin in android-parity.md. Default: no code change; #1901 stays open for you to close.
4. **One wording pattern for failures: Yes or No.** **Yes (recommended).** Every failure the app words itself reads "Couldn't \<do the thing>." and then the reason as its own sentence. When an action leads, the mapper drops the Kit's own lead so nothing stutters. The sign-in prefixes ("Network error:", "Transport error:", "Protocol error:", "Server error:", "Response error:") and compose's "Send failed:" go. Sentences that already read well stay: "Incorrect username or password.", the maintenance notice, a Cognito trigger's own copy, and Siri's canned sentences. Examples, today then Yes:
   - Draft save, server 500: "Couldn't save draft: Send failed: The server couldn't complete that request (500)." becomes "Couldn't save the draft. The server couldn't complete that request (500)."
   - Sign-in offline: "Network error: The Internet connection appears to be offline." becomes "Couldn't sign in. The Internet connection appears to be offline."
   - Rules load offline: "Couldn't load rules: Couldn't reach the server. The Internet connection appears to be offline." becomes "Couldn't load rules. The Internet connection appears to be offline."
   No: each screen keeps its wording; only #1900's "Send failed:" goes (A1) and the mapper reproduces today's sentences. Default: Yes. Yes also approves editing about 19 lines in four sign-in characterization suites (tests that pin today's exact wording).

Settled by default, not asked. #1902: a garbled Cognito reply at launch opens offline with the saved session, the trade-off you accepted for throttled refreshes in #1828. Not asked again: whether to do this work (Wave 2.2's answer 2, "No, make it a new workstream.", the maintainer, 2026-10-08; this plan is that workstream); keeping list models alive across a fold (3.3, "Anchor only"); the 13 lenient `try?` decode sites stay lenient (1.6 default 3).

## What you'll see change

- **A1, draft save:** a failed draft save no longer says "Send failed" (#1900).
- **A2, Kit error contract:** creating an address on a reserved or unentitled domain says why, in the New Address sheet, Siri and the watch (#1918). A garbled reply reads "Couldn't read the server's reply." with no endpoint name (decision 1). A garbled Cognito reply at launch opens offline instead of on the sign-in form (#1902).
- **A3, write paths:** after a rules save whose reply was garbled, the next edit no longer claims "Rules updated on another device"; Mark All as Read clears the badge and rows even when its reply was garbled (#1903). Both are rare.
- **A4 to A6, one mapper:** under decision 4, compose, sign-in, sheets, Rules, Settings, Addresses and feed management take one wording pattern. Each failure the app shows is also written to Settings > Debug Log.
- **A7, optional server (decision 2):** React and Android stop showing Python exception text when a Lambda fails.
- **A8, only if decision 3 is Tolerate:** rules the app does not understand show read-only with an update prompt instead of failing the whole list.
- **B1, B2, B4:** nothing visible. The spinner, error and Retry rules live in one type instead of six hand-written copies, so the next screen cannot get them wrong.
- **B3, reader:** the reader's and the list's action failures (flag, move, delete) take decision 4's wording. Otherwise nothing visible.

## Why

- **The same load bug keeps coming back, one screen at a time.** #1328 (rules), #403 and #1664 (reader spinner), #1815 (reader cancel) and #1908 (sidebars, feeds, sheets), all closed, were each fixed in the screen that showed it. #1328's report said: "it likely also affects any other screen using the same ... shape. I did not check the other screens." The cancelled-load check now has six hand-written copies (listed below).
- **Failure copy is worded in five places with different rules** (the Kit's copy and four app mappers, below). #1900 is the direct result: the send wording applied to a draft save.
- **Four error-contract bugs sit on that path,** each reproduced by the tester with probes against stage: #1900, #1902, #1903 and #1918.
- **It was asked for and deferred twice.** The rearchitecture proposal and audit 01 of 2026-10-02 (F8: one user-facing error mapper and a typed `ViewError`; F15: a shared `LoadState`; W5: shared list primitives for mail and feeds) asked for `LoadState`, `ViewError` and one mapper. 1.6 left them for whoever next held the message list; 2.2 made them a workstream of their own (both under "Background from the rearchitecture").
- **Failures leave no trace.** `CabalmailUI` has about 81 `catch` sites and 13 `CabalmailLog` calls, all in `AppDelegate.swift`, `PushRegistrar.swift` and `NotificationSettingsSection.swift` (audit 06 F12: logging is fragmented and sparse).

## Where things stand

Bare file names are under `apple/CabalmailUI/`; `Auth/`, `API/`, `IMAP/` and `Models/` are under `apple/CabalmailKit/Sources/CabalmailKit/`. Counts are mine at 50e6022.

**Load state.**
- `AsyncContentLoader` (`Shared/Primitives/AsyncContentLoader.swift:16-47`) holds a value, `isLoading` and `errorMessage`. Three screens use it: `NotificationSettingsSection.swift:241`, `MoveToFolderSheet.swift:21`, `MessageSourceSheet.swift:41`. `RulesView.swift:65` feeds `AsyncContentView` from `RulesViewModel`'s own state.
- Twelve model types keep their own flags (the B1 to B4 file lists name them). Four sheets hold their own error text (three feed sheets and `NewAddressSheet`), as does the watch's `NewAddressView`.
- The six copies of the cancelled-load check: `AsyncContentLoader.swift:36`; `FolderListViewModel.swift:93, 130` (attempt flag `:32`); `FeedSidebarViewModel.swift:108-112` (flag `:34`); `FeedItemListViewModel.swift:309`; `RulesViewModel.swift:108`; `MessageDetailViewModel.swift:156, 180` (flag `:52`).
- `FolderWindowLoader.swift:91-98` keeps four loading flags that also decide whether another load may start (concurrency gates): `isLoading` keeps page loads out until a refresh, reset or search lets go, and #1981 (open) notes five generation checks no test fails without. `MailSearchSession.swift:81, 85` adds two. `MessageListViewModel.isLoading` is derived (`:217`). Its `errorMessage` (`:34`) is written by the window through `FolderWindowHost` (`FolderWindowLoader.swift:13`), by the search through `MailSearchHost` (`MailSearchSession.swift:12`), and by the list model itself.
- Logic reads the error string: `ListPlaceTracking.swift:301, 309` and `SearchResultsPlaceholder.swift:87`.
- Pinned today: `LaunchRestoreSequencingSourceScanTests` pins the `initialLoadComplete` guards in `FeedItemListView.swift` and `MessageListView.swift`. The cancel rule is pinned by `FolderListCancellationTests`, `FeedSidebarRefreshCancellationTests`, `FeedItemListSyncCancellationTests` and `AsyncContentLoaderTests`. App-layer tests mention `errorMessage` or `loadError` on 161 lines in 50 files.

**Failure copy.**
- The Kit's copy is `CabalmailError: LocalizedError` (`Models/Errors.swift:66-105`, since #940). `.decoding` appends its detail (`:83-84`), so `decodeReply`'s "\<endpoint> returned an unexpected reply" (`API/URLSessionApiClient.swift:331`) reaches people. `serverExplanation` reads only `status` and `message` (`:112-121`).
- `localizedDescription` appears 50 times in 27 app files: 46 in 25 `CabalmailUI` files, 2 in Siri's `IntentSupport.swift`, 2 in the watch. Ten sites wrap it as "Couldn't X: ..." (each named in A4, A6 or B3); `ComposeViewModel+Internals.swift:265` wraps `describe(error)` instead. No raw `"\(error)"` reaches a user any more (#1814, closed).
- Flag, move and delete failures are worded in `Mail/Store/MailMutationService.swift:150, 315` (`error.localizedDescription`) and `:145-146, 310-311` (partial-failure sentences). They reach the screen as `outcome.message` at `MessageDetailViewModel+Flags.swift:76`, `MessageDetailViewModel.swift:298`, `MessageListViewModel+Move.swift:45, 141`, `+Optimistic.swift:36, 201`, `+Purge.swift:79` and `+Bulk.swift:147`. `MessageListViewModel.swift:428` and `+MarkAllRead.swift:18` write `localizedDescription` directly.
- The four app mappers: `FeedErrorText` (`Feeds/Sidebar/FeedSidebarViewModel.swift:193-218`), `SignInErrorText` (`Session/SignInErrorText.swift:8-41`), `ComposeViewModel.describe` (`Compose/ComposeViewModel+Internals.swift:411-419`) and `IntentError.friendly` (`Cabalmail/Intents/IntentSupport.swift:21-43`). `SessionManager.swift:158, 161, 284, 301, 649, 653` set the sign-in form's text.
- The watch does not link `CabalmailUI`; it compiles two named files from it (`apple/project.yml:372-379`). A mapper in `CabalmailUI` does not reach it without a `project.yml` line.
- `docs/apple.md:1196-1270` ("API errors") describes the split. Two of its sentences go false when A2 lands: `:1198-1199` (a non-JSON Cognito 2xx "still escapes as a Foundation error, #1902") and `:1213-1214` (a handler's `{"Error": ...}` body "isn't read (#1918)").

**The issues (GitHub, checked 2026-10-12).**
- **#1900 (open, bug, verified).** `pushDraftToServer` (`ComposeViewModel+Internals.swift:253-270`) prefixes `describe(error)`, whose default and `.invalidCredentials` arms start "Send failed:". At 50e6022, 12 of the 15 `CabalmailError` cases read with that prefix; only `.network`, `.authExpired` and `.maintenance` read clean. The tester's table predates `.http`: a `/save_draft` 500 now arrives as `.http(status:body:)` (`URLSessionApiClient.swift:281, 308`), not `.server(500)`.
- **#1902 (open, bug, verified).** `AuthService.swift:355` parses a Cognito 2xx with an unguarded `try JSONSerialization`. `OfflineLaunch.validateStoredSession` (`Auth/OfflineLaunch.swift:20-26`) catches only `CabalmailError`, so a cold launch lands on the sign-in form.
- **#1903 (open, bug, verified).** `/set_rules` and `/mark_folder_read` throw `.decoding` on an unreadable 2xx (`URLSessionApiClient+Rules.swift:12-30`, `+Messages.swift:305-311`). `RulesViewModel.performSave` (`:245-280`) then keeps the old version, so the next save's 409 becomes the "Rules updated on another device" alert (`RulesView.swift:80`). `MailMutationService.markFolderRead` (`:356-369`) throws at `:357`, before the cache, badge and refresh steps. A `.decoding` is not proof the server answered: the token refresh that runs before each request throws `.decoding` too (`AuthService.swift:380, 386`, reached from `attachAuth` at `URLSessionApiClient.swift:262-266` and the 401 retry at `:296`).
- **#1918 (open, bug, verified).** Refusals under `Error` read "(400)" or "(403)". On the server, 27 sites in 27 files (24 handlers and `_shared/admin_limits.py`, `helper.py`, `rss_api.py`) put `str(err)` in a 500 reply: 25 under `Error`, two under lowercase `error` (`new/function.py:51`, `new_address_admin/function.py:81`). The 4xx sites I found that return exception text wrap a validator's own message (`set_rules:366`, `push_register:192`, `push_envelope:150`, `search_envelopes:92`, `set_preferences:315`, `_shared/helper.py:904`, `check_dns_record:91`) (a scan, not a trace of every validator). React (`Addresses/index.jsx:93, 118`; `Users/index.jsx:153, 211`) and Android (`ApiClient.kt:184-188`) read `Error` at every status.
- **#1901 (open, enhancement, verified).** `Rule.Field` and `Rule.Action` (`Models/Rule.swift:20, 27`) have no unknown case, by design (`:11-15`). The tester called it "may be a close rather than a fix".
- **#1915 (open):** fixed on stage by `36d252a7`; its close-out is docs-and-bookkeeping.md's. **#2043:** the 1.31.0 release PR, merged on 2026-10-12.

## The plan

### Session A: the error contract and one mapper (Next)

One PR open at a time, in any order the files allow, except that A4 comes before A5 and A6. A7 uses no macOS runner and may be open beside the others. Start a PR only when no other plan has an open PR on its files (table below).

- **A1, #1900 alone.** Scope: the draft-save path stops using the send wording; `describe` gains the action or the draft path stops calling it. Files: `Compose/ComposeViewModel+Internals.swift`. Tests: every `CabalmailError` case, including `.http(500, ...)` and `.bulkPartialFailure`, through the draft-save path, none reading "Send failed". Verify: CI. Going offline on the Mini shows only wording, since `.network` already reads clean; a live check needs a `/save_draft` refusal. Fragment: `Apple:`, fixed. Risk: low.

  **Status:** Not started (2026-10-15).

- **A2, Kit error contract (#1902, #1918 client half, decision 1).** Files: `Auth/AuthService.swift` (guard the parse; throw an error `OfflineLaunch` treats as unreachable, for example `.transport`, since a captive portal is the likeliest cause (inferred); a JSON reply that lacks its tokens keeps `.decoding`), `Auth/OfflineLaunch.swift` if needed, `Models/Errors.swift` (`serverExplanation` also reads `Error` for an `.http` status of 400 to 499; under 1a `.decoding` drops its detail from the copy), `docs/apple.md:1198-1199, 1213-1214`. Tests: `AuthServiceTests` with a scripted transport (a fake network layer) answering an empty body, an HTML page and the tester's `{}` control; `OfflineLaunchTests`; `ErrorsLocalizedDescriptionTests` for `Error` at 400, 403 and 500 (500 stays generic); the copy assertion at `ApiClientDecodeFailureTests.swift:31`. Verify: CI; on the Mini, macOS signed in as test account 1, New Address with subdomain `mail-admin` shows the reason and creates nothing; the same on the watch simulator. Fragment: `Apple:`, fixed. Risk: low. It is Kit-only, so the watch and Siri get it too.

  **Status:** Not started (2026-10-15).

- **A3, #1903 in the Kit.** Rule: a 2xx from the Lambda whose body does not decode counts as done. The app never keys on `.decoding`, because a token refresh throws it before any request is sent. Files: `API/URLSessionApiClient+Rules.swift` (on an unreadable 2xx, `setRules` re-reads `/get_rules` and returns that set; `RulesViewModel`'s existing `rules == snapshot` guard keeps a newer local edit), `API/URLSessionApiClient+Messages.swift` and the `markFolderRead` protocol chain (an unreadable 2xx returns no count instead of throwing; no app caller uses the count), the shared `FakeImapClient`, and a few lines in `MailMutationService.swift` and `FolderMarkAllRead.swift`. If the re-read also fails, behaviour stays as today and a test pins it. Tests: a garbled 200 then an edit raises no conflict; a garbled 200 still zeroes the badge; a refresh that throws `.decoding` adopts nothing and zeroes nothing. Verify: CI; Mini smoke of a rule save and Mark All as Read. Fragment: `Apple:`, fixed. Risk: low. sqlite-mail-store.md PR 4.2 applies the same rule to its queued writes.

  **Status:** Not started (2026-10-15).

- **A4, the mapper, logging and compose.** Scope: one public mapper in `CabalmailUI/Shared/` (audit F8 called it `UserFacingError`): an error and an optional action in, one sentence out, with no side effects. Catch sites log through one explicit report call (the action, the error case and its detail, the status; never a reply body), so a redraw never writes a log line. The mapper depends only on `CabalmailKit`, so a later `project.yml` line could compile it into the watch. Files: the new type; `Compose/ComposeViewModel+Internals.swift`, `ComposeViewModel.swift:293, 459, 461`, `ComposeView+Subviews.swift:73`; delete `describe`. Tests: a table test of every `CabalmailError` case against a few actions. Verify: CI; Mini, compose offline and Close with Save Draft (wording only). Fragment: `Apple:`, changed. Risk: low.

  **Status:** Not started (2026-10-15).

- **A5, sign-in and Siri.** Files: `Session/SignInErrorText.swift` (deleted; its canned cases move into the mapper), `SessionManager.swift`'s six sites, `Cabalmail/Intents/IntentSupport.swift` (`IntentError.friendly` keeps its spoken canned cases, so live-verification.md's "not signed in" check still holds). Tests: about 19 prefix assertions in `SignInCharacterizationTests`, `SignInMfaCharacterizationTests`, `RestoreFailureCharacterizationTests` and `SessionLifecycleCharacterizationTests`, each listed in the PR; `IntentErrorTests`, which run only in the iOS-hosted suite (CI's `ios-app-test`, or the Mini with an iOS simulator destination). Verify: Mini, a wrong password still reads "Incorrect username or password."; signing in offline shows the new sentence. Fragment: `Apple:`, changed. Risk: medium (sign-in copy).

  **Status:** Not started (2026-10-15).

- **A6, sheets, Rules, Settings, Addresses and feed management.** Files: `RulesViewModel.swift:111, 274`, `NotificationSettingsSection.swift:301` (`:194` is log-only and needs no mapper), `MoveToFolderSheet.swift:89`, `MessageSourceSheet.swift:143`, `AddressesViewModel.swift`, `NewAddressSheet.swift:271, 273`, the feed management sheets (`FeedManagementActions.swift:171, 194, 207`, `FeedSubscriptionSettingsSheet.swift:177, 188`, `FeedFolderSheet.swift:98`, `SubscribeFeedSheet.swift:91`) and `FeedOpml.swift:33, 44, 126`. `FeedErrorText`'s token table moves into the mapper; `FeedErrorText.describe` stays as a one-line forwarder for `FeedSidebarViewModel` and `FeedItemListViewModel` until B2. Tests: the RSS tokens through the mapper. Verify: Mini, iPhone simulator, the reserved-subdomain refusal and a rules load offline. Fragment: `Apple:`, changed. Risk: medium (many one-line edits).

  **Status:** Not started (2026-10-15).

- **A7, optional: the Lambda 500s (decision 2).** The 27 sites log the exception and return a fixed sentence under the same key and status. Tests: `_shared/tests` (the only Lambda suite `lint.yml` runs), plus the per-function suites by hand (`delete_folder/tests`, `new_folder/tests`, `fetch_bimi/tests`); pylint with the repo's command; grep `react/admin` tests and `android/` for assertions on the `Error` text. No order against A2: the Apple client never reads a 500's text. Verify: CI; deploys to stage on merge through `app.yml`. Fragment: no prefix, security. Risk: low.

  **Status:** Not started (2026-10-15).

- **A8, only if decision 3 is Tolerate.** `Rule` keeps an unknown field or action as opaque data, the editor shows such rules read-only and refuses to save. Kit and `Rules/` files. Fragment: `Apple:`, changed.

  **Status:** Not started (2026-10-15).

**Releases and soak.** A1 to A3 ride the next release. Aim to land A4 to A6 in one release; a release with only some of them has mixed wording but nothing broken, so it does not hold Promote. Soak on the Mini: the reserved-subdomain refusal on macOS, the iPhone simulator and the watch simulator; Mark All as Read and a rule save; a wrong password; signing in offline. visionOS shares these view models and copy, so it gets no separate check (inferred). #1902 and #1903 can only be shown by tests; the tester could not trigger either live. Siri's copy on a device goes on live-verification.md's list.

### Session B: one load state (Later)

**Start when** A6 is on prod and feed-bulk-actions.md has finished with the feed files. Each PR then has its own gate.

**Rules the type must keep, each pinned by tests today.**
1. A load whose own task was cancelled records no outcome and keeps the spinner. Read the cancel off the task, never off the error (`AsyncContentLoader.swift:6-15`; #1908, #1328). This is also the fold rule.
2. Before any load has reached an outcome, the screen shows loading, never an error (#403).
3. An answer outranks an error that an overlapping load left (`AsyncContentLoader.swift:33`).
4. Content can show with an error beside it: a list over its cached rows, or the folder sidebar's saved copy offline (`FolderListViewModel.swift:22-25, 89-101`).
5. A refresh or page load in flight keeps content on screen. Where flags are also concurrency gates (the folder window, `MailSearchSession`, `FeedItemListViewModel`'s `isSyncing` and `isLoadingOlder`), the gates stay and the screen's state is derived from them.
6. A failure carries the mapper's sentence and whether Retry is offered.

A possible shape, for the session to confirm (inferred): `LoadState<Value>` holding the value, the activity (idle, loading, refreshing), an optional `ViewError` and whether an outcome was reached, with small methods for begin, finish, fail and cut short; `ViewError` holding the sentence and a retry flag. `AsyncContentLoader` becomes a thin holder of one `LoadState`. Where tests assert the sentence, keep `errorMessage` as a read-only property over the state, so behaviour tests keep asserting what the user sees.

- **B1, the type and the simple screens.** Gate: no platform-conditionals.md PR open on the Rules files or `NewAddressSheet` (its S2 PR 6). Files: `LoadState`, `ViewError`, `AsyncContentLoader`, `AsyncContentView`; `RulesViewModel`'s load and save state; `AddressesViewModel`, `NewAddressSheet`, `AddressListView`'s refresh, the settings address picker (`SettingsDetailViews.swift:18`). Tests: a `LoadStateTests` case per rule; `AsyncContentLoaderTests` keep their meaning. `no-changelog`. Risk: low.

  **Status:** Not started (2026-10-15).

- **B2, sidebars and feeds.** Gate: feed-bulk-actions.md done, platform-conditionals.md S2 PR 6 merged, and no refresh-scheduling.md or flags-and-cross-media.md Stage A PR open in `Feeds/ItemList/*` or `FeedSidebarViewModel.swift`. Files: `FolderListViewModel` (with its saved copy), `NewFolderForm`, `FeedSidebarViewModel`, `FeedItemListViewModel`, the feed sheets, `FeedOpml`; remove the `FeedErrorText` forwarder; log the five swallowed feed writes (`FeedItemListViewModel.swift:137, 144, 334, 342, 363`) through the report call. The three cancellation suites stay green with type-name edits only. Studio: on the Duo simulator, fold and unfold while the folder and feed sidebars load; no stuck spinner, no false error. `no-changelog`. Risk: medium.

  **Status:** Not started (2026-10-15).

- **B3, the reader and the action failures.** Gate: duo-support.md PR 6 and platform-conditionals.md FU-1 merged; mail-correctness.md PRs 4 and 5 merged; no detached-reader-window.md, mail-navigation-refactors.md or sqlite-mail-store.md Phase 3 PR open on the reader files; land before sqlite-mail-store.md Phase 4 opens (inferred, since Phase 4 rewrites the mutation path). Files: `MessageDetailViewModel` (`isLoading`, `hasAttemptedLoad`, `errorMessage`), the error pane in `MessageDetailView+Scroll.swift:30-44`, the reader actions in `+Toolbar` (`:238, 277`) and `+Move` (`:37`), and `MailMutationService.swift:145-150, 310-315`, whose sentences the list shows too. Verify: Mini, open a message offline, then Retry; Studio, fold while a message loads. Fragment: `Apple:`, changed. Risk: medium.

  **Status:** Not started (2026-10-15).

- **B4, the message list.** Gate: sqlite-mail-store.md Phase 3, which took mail-navigation-refactors.md's old PR 5 (`RowAnimationState`), either not yet open (its gate G2 requires B4 not open) or promoted; no mail-correctness.md PR open on `WindowRefresher.swift`. Files: `MessageListViewModel` exposes one state derived from `FolderWindowLoader` and `MailSearchSession`; `WindowRefresher.swift:170, 334`, `MailSearchSession.swift:153, 190`, `MessageListViewModel.swift:428` and `+MarkAllRead.swift:18` report through the mapper; `ListPlaceTracking` and `SearchResultsPlaceholder` read the state. The window's and the search's flags stay as gates. Leave `initialLoadComplete` alone. Docs: `docs/apple.md:1043` (the `Shared/Primitives` row) and the "API errors" section gain `LoadState`. Optional Studio check: fold with the list's error line showing. Fragment only if a list sentence changes. Risk: medium.

  **Status:** Not started (2026-10-15).

**Releases.** B1 to B3 share one release; B4 ships alone in the next, so a list regression is easy to trace.

### Hotspots (one open PR per file)

| Files | Here | Also edited by |
|---|---|---|
| `Auth/AuthService.swift`, `API/URLSessionApiClient*.swift` | A2, A3 | hardening-web-and-writes.md, kit-split.md |
| `Models/Errors.swift` | A2 | kit-split.md (decision 5) |
| `MailMutationService.swift` | A3 (a few lines), B3 | mail-correctness.md PRs 4-5, sqlite-mail-store.md Phase 4 |
| Compose files | A1, A4 | hardening-web-and-writes.md, mail-navigation-refactors.md PR 3, platform-conditionals.md FU-5, FU-16 |
| `SessionManager.swift`, sign-in characterization suites | A5 | account-isolation.md, sqlite-mail-store.md Phase 1 (PRs 1.1 and 1.2) |
| `Cabalmail/Intents/IntentSupport.swift` | A5 | swift6-and-strict-checking.md, test-debt.md |
| `RulesView.swift`, `RulesViewModel.swift` | A6, B1 | platform-conditionals.md S1 PRs 1-2, S2 PR 2; flags-and-cross-media.md B4.3 |
| `MoveToFolderSheet`, `MessageSourceSheet` | A6 | platform-conditionals.md FU-1, FU-2 |
| `FeedManagementActions`, `FeedSubscriptionSettingsSheet`, feed sheets, `NewAddressSheet` | A6, B1, B2 | feed-bulk-actions.md PRs A-B, platform-conditionals.md S2 PR 6 |
| `Feeds/ItemList/*`, `FeedSidebarViewModel.swift` | B2 | feed-bulk-actions.md, flags-and-cross-media.md Stage A, refresh-scheduling.md |
| `MessageDetailView*`, `MessageDetailViewModel*` | B3 | duo-support.md PR 6, platform-conditionals.md, detached-reader-window.md PR 3, mail-navigation-refactors.md, sqlite-mail-store.md Phase 3 |
| `MessageListViewModel*`, `FolderWindowLoader`, `MailSearchSession`, `WindowRefresher`, `ListPlaceTracking` | B4 | sqlite-mail-store.md Phase 3 (with mail-navigation-refactors.md's old PR 5), mail-correctness.md PRs 2-3, multi-window-and-restore.md |

No `project.yml` edit: `CabalmailUI` is included by folder. No source-scan edit is planned; if one turns out to be needed, ask the maintainer before opening the PR.

## Background from the rearchitecture

What this plan uses from the rearchitecture's records: the Wave 1.6 and Wave 2.2 scope docs, Wave 3.3's answer on folds, and audits 01 (mail) and 06 (tests and robustness) of 2026-10-02. They describe the code when they were written; "Where things stand" above is the picture at 50e6022.

- **Wave 1.6, the error model and API split (scope doc 2026-10-06, at `d322b1b`).** It set out to give the Kit one decode helper, typed error cases (`.storage` for keychain failures, `.cancelled` for a cooperative cancel, and `.http(status:body:)` for HTTP failures, so `.server(code:message:)` stopped meaning two things) and per-domain API protocols, fixing #1804, #1805, #1808 and #1815 part 2.
- **What 1.6 left, and why.** `LoadState`, `ViewError` and the user-facing mapper (the proposal's load-and-error row and audit 01 F8), because they change view models, including `MessageListViewModel*`, a hotspot Wave 2.2 held next; they were not in 1.6's file list. It also left binding `host`, `Encodable` bodies and a struct core (mechanical churn with no defect behind it), SQLite failures as `.storage`, the POST retry policy, folding `RuleSetConflictError`, the Kit target split and every server change.
- **1.6's defaults this plan builds on.**
  - Default 2: one decode helper for the 16 strict decode sites and `decodeRss`. A `DecodingError` becomes `.decoding("<endpoint> returned an unexpected reply")`, and the decode's coding path, never the body, goes to `CabalmailLog`. The reason: it restored the enum's documented contract (wire-level failures are normalized into `CabalmailError`) with the copy the case already had. That endpoint name is what decision 1 takes out of what people see and hear.
  - Default 3: the 13 lenient `try?` decode sites stay lenient: two shape probes ahead of a strict decode, four error-body probes (maintenance, `duplicate_in_flight`, the RSS envelope, the rules conflict version) and seven documented soft reads (BIMI, domains, the bulk split, preferences at two sites, the nav cursor, `discardDraft`). The reason: each is documented and deliberate, none is a reported defect, and the #1805 tester asked for one decision for all of them.
  - Default 12: no server change: every 1.6 fix was client-side, and changing an existing endpoint's failure replies is the maintainer's call under the additive API rule (`00-working-agreements.md`). Decision 2 asks that call for A7.
- **The mappers 1.6 found (at `d322b1b`).** `SignInErrorText`: canned copy first, then "Network error: …", "Transport error: …", "Protocol error: …", "Server error: …" and "Response error: …", else `localizedDescription`. `SessionManager.restoreFailed`: `.authExpired`, `.invalidCredentials` and `.notSignedIn` remove the stored session; `.network`, `.transport`, `.cancelled` and `.notConfigured` land signed out and keep the keychain; anything else lands on the sign-in error and keeps the tokens. `IntentError.friendly` (iOS only): `.network` and `.transport` read "Cabalmail could not reach the server." `FeedErrorText`: RSS tokens to copy. `ComposeViewModel.describe`: `.network` gets its own text, everything else becomes "Send failed: " plus `localizedDescription`. `OfflineLaunch.validateStoredSession` swallows only `isUnreachable` (`.network`, `.transport`) and `isTransientRefusal` (a `.server` carrying `TooManyRequestsException` or `InternalErrorException`, #1828), which is why A2 throws an error it treats as unreachable.
- **The Cognito escape.** 1.6 also found, unreported at the time, that `AuthService.call` decodes a Cognito 2xx with a bare `JSONSerialization.jsonObject`, so a non-JSON 2xx throws a Foundation error out of the Kit: the same class as #1805, outside `API/`. It asked whether to fold that into its decode PR or file it; it is #1902 now.
- **Wave 2.2, the message list split (scope doc 2026-10-08), answer 2.** "No, make it a new workstream." (the maintainer, 2026-10-08). `LoadState`, `ViewError` and the user-facing mapper, which 1.6 left for whoever next held the message list (its open question 6 had asked whether they get a home), became a workstream of their own, this plan, and 2.2 added none of them. The reasoning recorded with the answer: the defect they targeted is gone (#1814 put `localizedDescription` at every list error site), and the consistency that remains only pays off adopted across mail, the reader, folders and feeds together.
- **Wave 3.3, restore and routing, question 5: "Anchor only" (2026-10-09).** Asked whether to keep each folder's list model alive across a fold, the maintainer chose the recommended answer, anchor only: each list keeps building its own model; after a fold the top of the list shows until the rebuilt list's first refresh lands (the #1664 gate), then it moves to your row; rows past the top 250 reload; nothing in `MessageListViewModel*` changes. The reason: during a fold the old and new view trees are both alive for a moment and the old list stops watching late, so a model shared by both trees would end up off its poller with its page loads cancelled. (3.3's "fold" is what the Duo spec note above calls closing or opening.)
- **Audit 01 (mail): F8, F15 and W5.** F8: error handling was inconsistent and sometimes showed raw debug descriptions to users (15 `"\(error)"` sites, since removed by #1814), beside two unshared mappers; it recommended one `UserFacingError` mapper in the app layer, with view models exposing a typed `ViewError` (a message plus a retry affordance) instead of `String?`. F15: the folder, addresses and rules view models each invented their own loading and error vocabulary (`isLoading` and `errorMessage`; `hasAttemptedLoad`, `loadError` and `saveState` in Rules; `hasAttemptedLoad` in the reader); it recommended a shared `LoadState<Value>` (idle, loading, loaded, failed with a `ViewError`) across mail and feeds. W5, shared list primitives for mail and feeds, lists `LoadState` and `ViewError` first and says they can start immediately; its risk is low-medium, and its verify line asks that both lists compile against the shared types.
- **Audit 06 (tests and robustness): F11 and F12.** F11: swallowed errors on the draft, outbox and sign-out-wipe paths; it recommended logging every swallowed failure through one logger, telling the user about a dropped outbox message and making the sign-out wipe report failure (the draft and outbox halves are hardening-web-and-writes.md's; see "Not in this plan"). F12: logging was fragmented and sparse: four mechanisms (`CabalmailLog` into `DebugLogStore`, the Kit's direct `store.log`, `os.Logger` under three subsystems, and `NSLog`), and about 12 app-side log calls covered 99 `catch` blocks, so most errors became a string in `errorMessage` and left no trace. It recommended one `CabalmailLog` façade backed by `os.Logger` (one subsystem, a category per area), mirrored into `DebugLogStore`.

## How to start it

**Session A kick-off (paste):**
> Run Session A of `shared-load-error-state.md` (in `docs/1.x/post-wave-3/`; read it, including its "Background from the rearchitecture", with `00-working-agreements.md`). Stage was 50e6022 when it was written; re-check every file:line. Goal: fix #1900, #1902, #1903 and #1918 and replace the app's four failure-wording mappers with one. Do not merge to stage while a release PR is open, unless I say otherwise (#2043, for 1.31.0, merged on 2026-10-12). First write a short scope doc against current stage: the plan's four decisions at the top, quoted in full, with my answers where I have given them; then one line per PR saying what I will see change. A1 and A3 need no answer and may open while the questions are out. Open one PR at a time, and only when the plan's hotspot table shows no other plan's PR open on its files. Never treat a `.decoding` error as proof the server answered: the token refresh throws it too. Each tester comment on #1900, #1902, #1903 and #1918 holds a probe you can turn into a test. Before each push: `swiftlint --strict`, the Kit `swift test`, and `CabalmailMacTests` on the Mini, one build at a time; for A5 also the iOS-hosted suite. Test only as the two stage test accounts (test account 1 and test account 2), read their credentials at run time and never print them, and check that no other session is using the account, since a sign-in on one device can sign out another.

**Session B kick-off (paste), when A6 is on prod and feed-bulk-actions.md has finished:**
> Run Session B of `shared-load-error-state.md` (in `docs/1.x/post-wave-3/`; read it, including its "Background from the rearchitecture", with `00-working-agreements.md`). Session A's mapper is on prod. Goal: one `LoadState` and `ViewError` across the sheets, sidebars, feeds, reader and message list, keeping the six rules in the plan, with nothing visible changing except decision 4's wording for reader and list actions. Write the scope doc first: the proposed type, the PR order B1 to B4, and each PR's gate checked against current stage and open PRs. Keep the loader, search and feed flags as gates and derive the screen state from them. Leave `initialLoadComplete` alone. Run the Duo-simulator fold checks for B2 and B3 on the Studio. B4 ships in its own release.

**Read first:** this plan and `00-working-agreements.md`, both in `docs/1.x/post-wave-3/`. What the session needs from the Wave 1.6 and 2.2 scope docs and from audits 01 (F8, F15, W5) and 06 (F11, F12) is under "Background from the rearchitecture" above. **Rigs:** the Mini for macOS tests, simulators and the soak; the Studio for B2's and B3's Duo checks.

## Risks and checks

- **Copy can lose something useful.** Under decision 1a, a wrong control domain reads only "Couldn't read the server's reply." Today it reads "Response error: config.json: \<Foundation's decode message>" (`Config/ConfigLoader.swift:60-65`), which at least names config.json. The scope doc should give that case its own sentence. List every changed sentence in the PR body.
- **The stutter.** The pattern can produce "Couldn't X. Couldn't Y." if the mapper keeps the Kit's lead. The table test asserts that no sentence starts "Couldn't" twice.
- **#1902 under the default** could hide a lasting Cognito fault behind "offline". It matches #1828's accepted trade-off, and the debug log records each one.
- **Logging.** `CabalmailLog` writes to the unified log as private and to Settings > Debug Log (`CabalmailLog.swift:13-17`), so a reply body logged by mistake would show in plain text there. Log the case and its detail only.
- **Gates mistaken for display.** Folding the folder window's flags into one enum would change page-load gating that #1981 says is under-tested. Derive, don't replace.
- **Source scans over files this plan edits.** `MacSheetChromeSourceScanTests` and `NewAddressPreviewWrapSourceScanTests` read `NewAddressSheet.swift`; `RulesPaneContainerSourceScanTests`, `RuleRowHitTargetTests` and `SectionFooterWrapTests` read `RulesView.swift`; `SectionFooterWrapTests` also reads `NotificationSettingsSection.swift` and `SettingsDetailViews.swift`; `CompactBrandMarkSourceScanTests` reads `AddressListView.swift` and `MessageDetailView.swift`. Check their anchors before A6, B1 and B3 rather than in CI.
- **Server PR (A7).** React and Android only display the 500 text; no client branches on it (inferred from a grep of `react/admin/src` and `android/kit`, which also found `Dmarc/DnsCheckModal.jsx:38, 61`). Re-check before merging.
- **Lint caps.** If `file_length` or `type_body_length` trips, extract a type that owns behaviour, never a `+Foo.swift` extension.

## Not in this plan

- Swallowed errors on the draft crash-safety save and the outbox remove: hardening-web-and-writes.md.
- The other `try? await` sites in `CabalmailUI` (74 at 50e6022) stay best-effort on purpose; only the five feed writes B2 already edits gain a log line.
- The feed reader's WebKit failure text (`ArticleWebView.swift:204`): stays WebKit's sentence; the file is hardening-web-and-writes.md's while #1911 runs.

  > **Erratum (2026-10-15):** Hardening's fix for #1911, its PR 2 (#2056, `5046716`), merged to `stage` with its change to `ArticleWebView.swift`, so no open hardening PR holds the file now. #1911 itself stays open until the hardening session's stage check.

- Compose's send state (`isSending`) is a gate, not a load; `SendCoordinator` is mail-navigation-refactors.md PR 3.
- SQLite errors escaping as a raw `SQLiteDatabase.Error`: sqlite-mail-store.md (PR 0.1).
- `.server` renamed `.api`, folding `RuleSetConflictError`, `Encodable` bodies: kit-split.md (decision 5).
- #1915's close-out: docs-and-bookkeeping.md.
- The Android twin of #1901: android-parity.md, only if decision 3 is Tolerate.
- Siri on a device and a cold-start intent: live-verification.md. Tests for `IntentBridge`: test-debt.md.
- The watch's own sentences stay the Kit's (A2 improves them); compiling the mapper into the watch is a later one-line `project.yml` change, not planned.
- Keeping screen models alive across a fold: not re-proposed (3.3, "Anchor only"); sqlite-mail-store.md Phase 3 removes the refetch.

## Sources

- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Code at 50e6022: the `apple/` paths above; `apple/project.yml:372-379`; `lambda/api` (27 sites by a scan for `str(err)` under a 500; `_shared/helper.py:871-878` for the reserved-subdomain sentence); `react/admin/src/Addresses/index.jsx:93, 118`; `android/kit/src/main/kotlin/com/cabalmail/kit/api/ApiClient.kt:184-188`; `docs/apple.md:1043, 1196-1270`; `.github/workflows/lint.yml:279`.
- GitHub (read 2026-10-12): open #1900, #1902, #1903, #1918 (bug, verified), #1901 (enhancement, verified), #1915, #1981, PR #2043; PR #1905 (its body's readable-labels offer, read 2026-10-15); closed #403, #940, #1328, #1664, #1814, #1815, #1828, #1908.
- Sibling plans in this folder (2026-10-12): sqlite-mail-store.md (PR 4.2, G2, hotspots), flags-and-cross-media.md (decision 6, G3), feed-bulk-actions.md, duo-support.md (PR 6), detached-reader-window.md, android-parity.md (its conditional legs and its note on exception text in 500 replies), kit-split.md, platform-conditionals.md, mail-correctness.md, mail-navigation-refactors.md, hardening-web-and-writes.md, account-isolation.md, refresh-scheduling.md, live-verification.md (B2), docs-and-bookkeeping.md; and `00-working-agreements.md`.
