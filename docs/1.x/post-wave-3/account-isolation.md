# Account isolation and session lifecycle

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session. Under the defaults it is three small sequential Apple PRs after one batch of answers; if the maintainer picks the push stamp, it adds one small server PR and one client PR that waits for it, still in sequence, with no audit phase, parallel threads or migration (the client PR may slip to a second release).
**Size:** S under the defaults (decision 4 No). M if decision 4 is Stamp.
**Priority:** Next. Nothing in it is an open user-visible bug, so the Duo round and mail-correctness.md go first. Run it before sqlite-mail-store.md's Phase 1, which needs decision 1 before its scope doc and this plan's PR B before its PR 1.2.
**Depends on:** nothing hard. Order only: mail-correctness.md PR 4 before PR D; sqlite-mail-store.md PR 0.2 before PR C2 if Phase 0 is running (same file); never open beside shared-load-error-state.md A5 or multi-window-and-restore.md R2 or W3 (shared files, see Hotspots). Soft: live-verification.md's baseline run before PR B (it asks to go first); docs-and-bookkeeping.md's API rule in the repo before PR A (Stamp only).
**Unblocks:** sqlite-mail-store.md (decision 1 before its Phase 1; PR B before its PR 1.2, which rewrites the same pin and files legacy caches under the remembered server and username, a premise PR B makes true); android-parity.md L6 (only under Stamp, once PR A is live). multi-window-and-restore.md W3 relies on PR C1 resetting the device-wide collapsed keys, in either order.
**Duo groundwork:** None in layout or scenes; the one link is that a Duo set up from a backup or Quick Start brings this app's cache and stored session with it (tokens are stored AfterFirstUnlock, not ThisDeviceOnly, `SecureStore.swift:99`, and nothing excludes the cache from backup) *(inferred)*, so PR B's server-aware rule also covers a Duo that later signs in elsewhere.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
| --- | --- |
| Decisions 1, 3 and 4 | Unanswered (2026-10-15); decision 2 is recorded, not asked |
| Scope doc and the three issues | Not started (2026-10-15) |
| PR B. Sign-in rules | Not started (2026-10-15) |
| PR C1. Account leftovers | Not started (2026-10-15) |
| PR C2. A failed wipe is reported | Not started (2026-10-15) |
| PR A. Server stamp (decision 4 Stamp only) | Not started (2026-10-15) |
| PR D. Apple stamp check (Stamp only) | Not started (2026-10-15) |

## Decisions for the maintainer

Four items; only 1 and 3 need thought. Answer 1 before PR B and before sqlite-mail-store.md's Phase 1 scope doc, 3 before PR B, and 4 before any server work. Two terms: a session is *wired* when its client is installed and running; a *pin* is a characterization test that asserts today's behaviour.

1. **One signed-in account per install, as policy?** **Yes (recommended)** or No.
   - Yes: it is written into `docs/apple.md` and `docs/push-notifications.md`, and switching stays Sign Out then Sign In. sqlite-mail-store.md's PR 1.2 deletes other accounts' directories on this basis, and kit-split.md keeps one `Reachability` per client.
   - No: several accounts at once becomes its own project (an account picker, per-account storage, push routing, and a `push_register` change, since #1897 deletes every other account's row for a device token). Decision 2 reopens, and decision 3 should be End first.
   - Evidence: 1.3 left it out of scope (its scope doc: "More than one signed-in account at once. There is no UI for it; the manager holds at most one current session."). #1897, which you merged, rests on an install being "signed in to one account at a time" (`lambda/api/push_register/function.py:10-11`). No title among the repo's 523 issues asks for more than one account.
   - Default: Yes.
2. **Recorded, not asked: no per-account `Session` container.** Your 2.1 answer stands: one `MailSessionStore`, reset in place. 2.1's scope doc asked whether to keep one store reset in place and drop the per-account store from the plan, since a store per session would add only that a late answer lands in a discarded object instead of being refused by the sign-out gate, and would reopen `AppState.swift` and `SessionManager.swift`; you answered "2. Yes, keep it." (the maintainer, 2026-10-08). Nothing new argues against it. sqlite-mail-store.md's per-account directory (its decision 3) is the disk half and needs no in-memory container. It is listed here so sqlite-mail-store.md, whose gate G0 names "decisions 1 and 2", has one place to cite. It reopens only if decision 1 is No.
3. **A sign-in that arrives while a session is wired should:** **Refuse (recommended)**, End first, or Stay pinned.
   - No screen reaches this today *(inferred, high confidence)*. Three pins record what would happen: the first session is replaced without being ended, a different user's sign-in wipes the cache under it, and a failed attempt leaves it wired under an error.
   - Refuse: `signIn` logs a line and returns before showing "Signing in". It is the smallest change in the riskiest file, and it matches decision 1.
   - End first: the sign-in runs the whole Sign Out, then signs in. 1.3's scope doc called that "what more than one account would need", so it pays only if decision 1 is No.
   - Refuse or End first changes the expected values of four tests in `SignInOverASessionCharacterizationTests` (`SignInCharacterizationTests.swift:309, :334, :366, :388`), which needs your yes.
   - Stay pinned: a new issue is filed and the three "Tracked in #1826" comments point to it.
   - What changed since 1.3 kept them: 1.3 kept them so a high-risk refactor changed no behaviour (its decision 7, recorded in the PR #1887 body), and #1826 closed on 2026-10-09 without ever listing them.
   - Default if unanswered: Stay pinned, because expected values cannot change without your yes.
4. **Stamp each push with its account?** **No (recommended)** or Stamp.
   - For #1883 you chose "#1883: Server cleanup" (#1897) over the stamp (the maintainer, 2026-10-06). In that discussion the reviewers noted: "Stage and prod both push through production APNs to the same device token... Cleanup can't reach the other deployment's table, and a stamp only catches this if it names the deployment". #1897's description listed what cleanup cannot reach and offered the stamp "if you ever want it".
   - One point is new *(inferred from code, not reproduced)*: on an iPhone, a push for another account can show a message from the signed-in account as its sender, subject and preview. `/push_envelope` searches the signed-in account's folder for the Message-ID and, on a miss, uses the push's UID hint (`lambda/api/push_envelope/function.py:110`). #1883 said this only of the Mac.
   - No: the residual stays accepted, and PR B adds the banner point to `docs/push-notifications.md:72-82`. The cases are tester-shaped (leaving prod offline and signing in to stage, a next account with notifications off, two Mac app instances on different accounts), and a wrong banner shows mail the device's own user can already read.
   - Stamp: PR A (server) and PR D (Apple), and android-parity.md L6 adds Android. Size becomes M.
   - Default: No.

**Smaller calls**, which the scope doc states with their defaults for a one-word veto: on a different-account sign-in, clear the debug log (Keep would keep the last sign-out's lines for diagnosis), and reset only the custom notification folder list (the Inbox, All or Chosen scope and the master toggle stay, since `PushSettings` is "per *device* by design", `PushRegistrar.swift:59-66`). The new issues close on their tests with your OK at the soak, as #1883 and #1886 did, because only the test harness reproduces them.

## What you'll see change

- **PR B (sign-in rules):** after a session expires at launch, signing in with the same username on another server no longer sends the last server's unsent mail through the new server, and no longer shows its offline mail *(inferred defect, not reproduced)*. Decision 3's rule changes nothing you can reach.
- **PR C1 (account leftovers):** when a different account signs in, folder and feed groups start expanded, Settings > Debug Log starts empty, and the notification "Choose folders" list is back to Inbox. A folder list that answers after Sign Out no longer leaves the old account's subscriptions behind for the next account's unsubscribed-folder banner *(inferred)*.
- **PR C2 (failed wipe):** nothing visible. A sign-out wipe step that fails now says so in the debug log instead of failing silently.
- **PR A (Stamp only, server):** nothing visible.
- **PR D (Stamp only):** a notification for another account or server shows "New mail" with no Mark as Read or Archive, and tapping it changes nothing in the signed-in account. The Mac does not show it.

## Why

- **Three latent defects with no open tracker.** The pins in `SignInOverASessionCharacterizationTests` each say "Tracked in #1826". #1826's body and its 2026-10-09 status table never listed them; it closed that day, and #1992 took only the restore items. A sign-in over a wired session skips `sessionWillEnd`, so that account's push registration is never withdrawn.
- **The different-user rule ignores the server.** The wipe runs only when `lastUsername != username` (`SessionManager.swift:689`). A launch whose refresh is refused removes the tokens but keeps the cache and the remembered server and username (`:288-293`). All accounts share one cache directory (`SessionEnvironment.swift:78-88`). So the same username on another server opens the last server's envelopes, folder list and outbox, and the send queue drains that outbox under the new session *(inferred from code)*.
- **A late folder list still writes.** PR #1849 named three paths it left: an unread revert (#1851), a late badge or Siri count (#1886, #1892), and "a late folder-list reply writing the subscribed folders back". The third was never filed.
- **Some account state outlives the account.** The debug log is never cleared at sign-out. Three per-install keys hold the last account's folder names. Every wipe step that can throw is `try?` with no log, so "A failed wipe leaves the previous user's mail on disk" (audit 06 F11, swallowed errors on the draft, outbox and sign-out-wipe paths).
- **The account policy was never written down.** 1.2 deferred a store per session to 1.3, 1.3 kept one per `AppState` (its D3), and 2.1 dropped it. The rearchitecture proposal's target is still "one `Session` shared by every window" per account. sqlite-mail-store.md needs the policy to design its directories.
- **Pushes still name no account.** `push_dispatch` builds `{'folder', 'uid', 'msg_id'}` (`push_dispatch/function.py:230`). #1897's cleanup cannot reach another deployment's table or a device whose next account never registers.

## Where things stand

- **Sign-in.** `signIn` (`SessionManager.swift:127-163`) never checks for a wired client. `wireSession` replaces it ("A sign-in over a wired session (#1826) replaces its client", :352) and lets the old one go at :389. Only `tearDownSession` (:315-345) and `endUnwiredSession` (:558-562) run `endSession`. 1.3 added only that the replaced client is shut down (PR #1887 body, decision 7).
- **Reachability.** `ContentView.swift:27-33` shows `SignInView` only outside `.signedIn` and `.restoring`. Its button and Return key are off during `.signingIn` (`SignInView.swift:106, :141, :156`). An expiry signs out before the form shows (`SessionManager.swift:522-528`).
- **Pins.** `SignInCharacterizationTests.swift:309` (`testTheFirstSessionStaysWiredWhileTheSecondSignInLoads`), :334, :366 and :388, with the "Tracked in #1826" comments at :333, :365 and :387. The leftovers header still says 1.3 "moves per-account state into a session that ends as a whole" (`SignOutLeftoversCharacterizationTests.swift:10-13`).
- **Identity rules.** The username comparison is exact: "Alice" and "alice" are two Cognito accounts (`SignInMfaCharacterizationTests.swift:318-323`). The server is remembered raw, scheme and spaces included (`SignInCharacterizationTests.swift:121-150`). `Preferences.scopeIdentifier` trims and lowercases both (`Preferences+AccountScope.swift:9-20`). The push code keys on raw `username@controlDomain` (`PushRegistrar.swift:273, :299-305`).
- **The store and late writes.** `AppState` keeps one `mailStore` for its life (`AppState.swift:96`, built at :136), reset by `forgetAccountState` (:207-212). The teardown gate refuses a late answer wherever a writer asks `acceptsCounts(from:)` (`MailSessionStore.swift:62-64`). The saved-count seed asks (`FolderListViewModel.swift:158`). The subscribed-folder writers do not: the live list at :117 (applied even after a cancel, :103), the offline copy at :143, and a failed toggle's revert at :190, which writes through :206.
- **Leftovers.** `DebugLogStore` is an in-memory ring of 1,000 lines, cleared only by the Debug Log screen's button (`DebugLogView.swift:34`). Keys holding the last account's names: `cabalmail.folder.collapsedPaths` (`FolderListView.swift:90`), `cabalmail.feeds.collapsedFolders` (`FolderListView.swift:45`, `FeedSidebarSection.swift:79`) and `cabalmail.push.chosenFolders` (`PushRegistrar.swift:75`). The different-account hook is `owner.accountChanged`, set at `AppState.swift:196`. The wipe's `try?` steps are at `CabalmailClient+Maintenance.swift:20-24` and :39.
- **Push.** `push_register` answers `{"status": "registered"}` (`function.py:243`) and already writes `if_not_exists` fields on the row (:201). `push_dispatch` reads the user's rows (:290-297) and has only `PUSH_TOKENS_TABLE_NAME` in its environment (`terraform/infra/modules/app/push_dispatch.tf:201-205`). Apple's parser ignores unknown keys (`CabalmailShared/PushMessageCoordinates.swift:43-55`) and `patching` keeps them (:88-99). Android's `PushSignal.from` reads only folder, uid and msg_id (`PushSignal.kt:19-31`). An added field breaks no shipped build.
- **Issues (checked 2026-10-12).** #1826 closed (completed, 10-09); #1992 closed (10-12); #1883 closed (completed, 10-06) by PR #1897 (merged 10-06); PR #1849 merged (10-05), with #1851, #1886 and #1892 closed; #1957 open (sqlite-mail-store.md PR 0.2); #1973 open (mail-correctness.md PR 4); #2039 open (multi-window-and-restore.md W3). #1158, "Android: sign-out leaves per-install mail caches ... in place", closed not planned on 2026-08-19; it is about caches, not about how many accounts. No open issue covers anything this plan does.

## The plan

One session. It writes a short scope doc with decisions 1, 3 and 4 and the smaller calls at the top, gets one batch of answers, then files one issue each for the sign-in over a wired session, the cross-server wipe and #1849's late folder list, so each PR says "Addresses #N". Each Apple PR carries tests that fail on its parent commit, and an `Apple:` fragment or the `no-changelog` label.

**Status:** Not started (2026-10-15).

**PR B. Sign-in rules** (decisions 1 and 3).
- Different-account rule: compare server and username, not username alone (`SessionManager.swift:689`). The server is trimmed, stripped of `https://` or `http://` and lowercased; the username stays exact, as the case pin requires. The same rule drives `owner.accountChanged`.
- Decision 3: under Refuse, a guard after `awaitTeardown()` at the top of `signIn` logs and returns while a client is wired. Under End first, it runs the sign-out teardown through the gate, then proceeds. Under Stay pinned, only the three comments change, to the new issue.
- Docs: decisions 1 and 2 in the `Session/` row of `docs/apple.md` (:1024) and the one-account premise in `docs/push-notifications.md`; under decision 4 No, the banner point joins the residual paragraph (:72-82). The leftovers header comment (`SignOutLeftoversCharacterizationTests.swift:10-13`) is corrected; it is a comment, not an expected value.
- Tests: an expired launch restore for `alice` on server A, then `alice` on server B, wipes the cache and outbox; the same server retyped with a scheme, spaces or capitals keeps them; `Alice` after `alice` still wipes. Under Refuse or End first, the four named tests become tests of the rule, each listed in the PR with before and after.
- Verify: CI. On the Mini, a regression run of ordinary sign-in and sign-out with test account 1 and test account 2 (MFA on) in both directions, on the signed macOS build and the iPhone simulator. That run cannot show the fixes: no screen reaches decision 3's path, and sessions never sign in to prod. A Mac sign-out signs out every Mac app instance on the Mini, since they share a keychain (live-verification.md, risks), so announce the run and avoid the tester's run times.
- Fragment: `Apple:` fixed. Risk: medium (sign-in code).

**Status:** Not started (2026-10-15).

**PR C1. Account leftovers** (the smaller calls).
- Gate the subscribed-folder writers on `mailStore.acceptsCounts(from: client)`: `FolderListViewModel.swift:117`, :143 and the revert at :190.
- On a different-account sign-in: clear `DebugLogStore.shared` before the different-user wipe, so that wipe's own failures (PR C2) stay readable; then `accountChanged` removes `cabalmail.folder.collapsedPaths`, `cabalmail.feeds.collapsedFolders` and `cabalmail.push.chosenFolders`. Removing a key refreshes the `@AppStorage` views, so no view file changes *(inferred)*. Key names come from one place: multi-window-and-restore.md W3's `DefaultsKey` enum if it has merged, otherwise C1 adds the enum and W3 extends it.
- W3 (#2039) tags each window's copy of the collapsed sets with the account, so C1 need not reach scene storage, and either order works.
- Tests: a folder list answering after Sign Out leaves `subscribedFolderPaths` nil (a held fake, as `SignOutLateCountTests` do); a revert landing after Sign Out writes nothing; the keys and log reset for another account and stay for the same one, the same server retyped included.
- Verify: CI; on the Mini, PR B's run with a group collapsed and Settings > Debug Log open. Fragment: `Apple:` fixed. Risk: low.

**Status:** Not started (2026-10-15).

**PR C2. A failed wipe is reported.**
- `clearLocalData` and `clearLocalDataEndingSession` (`CabalmailClient+Maintenance.swift:17-41`) log each failed step through `CabalmailLog` (06 F11: "Make the sign-out wipe report failure").
- No retry flag. A different user's next sign-in already wipes again before wiring (`SessionManager.swift:689-691`), the same user reading their own cache is harmless, and sqlite-mail-store.md's PR 1.2 adds a retry for the caches. The logging still matters after that, because the outbox and drafts stay in the shared directory under sqlite-mail-store.md's default.
- Tests: a Kit test where one step throws (the scope doc picks the seam). `no-changelog`. Risk: low.

**Status:** Not started (2026-10-15).

**PR A. Server stamp** (decision 4 Stamp only; no macOS runner, so it may run beside one Apple PR).
- `push_register` gives each token row a random stamp on its first write (`if_not_exists`, beside :201) and returns it as `account_stamp` in its 200 body (:243). `push_dispatch` adds the row's stamp as `acct` to `msgRef` (:230) and the FCM data map (:253-260), building the payload per row instead of per signal. A row written before PR A carries no stamp until its next register.
- Why random rather than a hash of user and server: no Terraform change and no `CONTROL_DOMAIN` on `push_dispatch`, it differs per deployment by construction, and nobody can test a guessed address against it. An unsalted hash of `user@domain` is a stable pseudonym anyone who knows the server can confirm. The scope doc may pick a keyed hash if per-row payloads prove awkward.
- Tests in `lambda/api/_shared/tests/` beside `test_push_register_other_accounts.py`: the stamp kept across registers, returned, carried in both payloads, and absent for an unstamped row. Docs: `docs/push-notifications.md:84-91`. Fragment: `added`, no prefix. Additive, as the API rule requires.
- Verify: the `CLAUDE.md` pylint command and the `_shared` suite; after the stage deploy, register from the Mini and read the stamp in the response *(inferred: the rig's helper can make that call)*; never print credentials. Risk: low.

**Status:** Not started (2026-10-15).

**PR D. Apple stamp check** (Stamp only; after PR A is on stage and mail-correctness.md PR 4 has merged).
- `PushMessageCoordinates` gains an optional `account`, read from `acct`. The app keeps the stamp from its last register, mirrors it to the app group through a new `PushHandoff` key for the notification service extension (NSE), and clears it at sign-out.
- A stamped push is foreign unless its stamp matches the signed-in account's; an unstamped push acts as today.
- The NSE source (`CabalmailNotificationService/NotificationService.swift`, compiled into both extensions, `project.yml:558-566`) skips `/push_envelope` for a foreign push and drops the `MAIL_MESSAGE` category, so no actions show. iOS cannot discard an alert push without the notification-filtering entitlement, which this plan does not request. The Mac extension gets no alert pushes.
- The app ignores a foreign tap or action (in mail-correctness.md PR 4's extracted action handler); the Mac drops a foreign silent push before enriching it (`AppDelegate.swift:92-108`). `PushRegistrar.swift` has 433 counted lines against SwiftLint's 500 (`.swiftlint.yml:47-50`), so the stamp store is its own type.
- Tests: `PushWireTests` (parsing), `PushHandoffContractTests` (the new key; the only test of the NSE boundary), `PushAccountSwitchTests` (foreign ignored, same account runs, unstamped runs), and the NSE's choice as a `CabalmailShared` function with tests.
- Verify: CI. On the Mini's iPhone simulator, `xcrun simctl push` a payload with a foreign `acct` and check Mark as Read does nothing, as live-verification.md does for #1872; whether `simctl push` runs the NSE is unconfirmed, so the NSE rule rests on its unit tests. The device check stays with this plan, on the maintainer's TestFlight checklist for the release carrying D: an iPhone on prod goes offline, signs out and signs in to stage, and mail to the prod account shows "New mail" with no actions.
- Fragment: `Apple:` fixed. Risk: medium (a wrong comparison hides actions on real mail).

**Status:** Not started (2026-10-15).

**Order and releases.** Scope doc, issues, then B, C1 and C2, one Apple PR in CI at a time. They can share one release; B is its one lifecycle change. Under Stamp, A opens once decision 4 is answered; D rides the same release only if A is on stage and mail-correctness.md PR 4 has merged by then, otherwise the next. The soak repeats the switches between test account 1 and test account 2 on the Mini. An issue left open under Stay pinned has no fix merged, so it does not hold Promote.

**Hotspots** (one open PR per file):

| File | PRs here | Also edited by |
| --- | --- | --- |
| `Session/SessionManager.swift` | B, C1 | shared-load-error-state.md A5; sqlite-mail-store.md PRs 1.1-1.2 |
| `SignInCharacterizationTests.swift`, `SignInMfaCharacterizationTests.swift` | B | shared-load-error-state.md A5 (prefix assertions); sqlite-mail-store.md PR 1.2 (rewrites :366 after B) |
| `App/AppState.swift` | C1 | multi-window-and-restore.md R2 |
| `Mail/Folders/FolderListViewModel.swift` | C1 | shared-load-error-state.md B2 |
| The collapsed keys and `DefaultsKey` | C1 | multi-window-and-restore.md W3 |
| `CabalmailClient+Maintenance.swift` | C2 | sqlite-mail-store.md PRs 0.2 and 1.2 |
| `Platform/Services/PushRegistrar.swift` | D | mail-correctness.md PR 4 (first); platform-conditionals.md S1 PR 8 |
| `Platform/Services/AppDelegate.swift` | D | multi-window-and-restore.md R2 |
| `CabalmailNotificationService/NotificationService.swift` | D | swift6-and-strict-checking.md B1 |

## Background from the rearchitecture

What the brief below used to send the session to the rearchitecture project's scope docs and audits for, stated here:

- **Workstream 1.3's scope (the session manager, PR #1887).** Out of scope there: "A store per session (D3)"; "A single process-wide `Reachability` and removing the Kit's test-driven optionals", since "One client per account already means one `Reachability` per account" *(inferred, in that doc)*; and "More than one signed-in account at once. There is no UI for it; the manager holds at most one current session." The latent defects it pinned for #1826, which this plan's issue for a sign-in over a wired session takes: a second sign-in over a wired session replaces it without ending the first; another account's sign-in over a session wipes the shared cache but never ends the first; a failed second sign-in shows an error while the first session stays wired (the pins under "Where things stand"). Its decision 6 kept 0.8's `SessionHooks` closure struct as the platform-service seam and added no protocols, since "Protocols would replace a working seam with no change in behaviour". Its decision 7 changed no characterization test's expected values and kept the #1826 quirks, because "1.3 is high risk. A refactor that also changes behaviour is hard to review and to bisect" and "The pins are latent: no UI offers a second sign-in over a session". The alternative it set aside, letting a new sign-in end the old session, "is what more than one account would need" and needed the maintainer's yes. PR #1887's body records decisions 3, 6 and 7 as implemented.
- **Workstream 2.1's answers (2026-10-08).** The maintainer said yes to all four of its questions, among them question 2: one store reset in place, with the per-account store dropped from the plan (quoted under decision 2).
- **The Kit audit of 2026-10-02 (audit 03 F12, persistence).** F12 found eight persistence mechanisms with inconsistent layout, scoping, eviction and corruption policy. On account scoping: `Preferences` keys are per-account hashes; every file cache (envelopes, bodies, drafts, outbox and the RSS database) sits in one shared, unscoped directory that sign-out wipes; `ResumeSessionStore` is per install; and the `RssStore` doc says one SQLite file per account while the file sits in the shared cache directory. Not all session data is cleared at sign-out: `clearLocalData` misses `BimiUrlCache` and the contacts store, which live per launch in `AppState`, and `DebugLogStore`; "The first two are low-sensitivity." Its recommendation, one local-store foundation with envelopes moved into SQLite, also gives one account-scoped root, `<AppSupport>/Cabalmail/accounts/<scopeHash>/{mail.sqlite, bodies/, rss.sqlite, drafts/, outbox/}`. Its persistence matrix marks `Preferences` per account and not cleared (it is scoped instead); `ResumeSessionStore` per install and cleared by the app; the keychain tokens and the push enrichment store (keychain plus app-group defaults, the only app-group storage) single-account and cleared; and `BimiUrlCache`, the contacts store and `DebugLogStore` (a bounded in-memory ring, per process) not cleared.
- **The tests-and-robustness audit of 2026-10-02 (audit 06 F11).** "Swallowed errors on draft, outbox and sign-out-wipe paths": the sign-out cache wipe in `CabalmailClient+Maintenance.swift` is all `try?`, and "A failed wipe leaves the previous user's mail on disk"; the wipe is the privacy property `AppState.swift` states. Its recommendation: "Log every swallowed failure through one logger. Surface a dropped outbox message to the user. Make the sign-out wipe report failure." This plan's PR C2 takes the wipe; the draft-save and outbox-remove `try?` are hardening-web-and-writes.md's (see "Not in this plan").

## How to start it

Start a Claude Code session on `cabal-infra`. It reads this plan and `00-working-agreements.md` from `docs/1.x/post-wave-3/`. Point it at this plan's "Background from the rearchitecture" (the 1.3 and 2.1 scope passages and audits 03 F12 and 06 F11), issues #1826 and #1883, the bodies of PRs #1849 and #1897, and the sibling plans sqlite-mail-store.md (decision 3, PR 1.2, gate G0), multi-window-and-restore.md (W3, R2), mail-correctness.md (PR 4) and shared-load-error-state.md (A5). Paste:

> Run the account isolation plan (account-isolation.md, read with 00-working-agreements.md from `docs/1.x/post-wave-3/`, then the plan's "Background from the rearchitecture") on current `stage`. The maintainer's answers to decisions 1, 3 and 4, if the maintainer has given them: [paste]. Decision 2 is already answered. Re-check every file:line it cites and the state of #1826, #1957, #1973 and #2039, and read sqlite-mail-store.md and multi-window-and-restore.md's W3 so the plans stay in step. Write a short scope doc: the open decisions at the top, quoted in full with their recommended answers, then the smaller calls with their defaults, then one line per PR saying what the maintainer will see change. Post it and wait for one batch of answers; for anything left open, use the plan's default and say so in the PR. File one issue each for the three untracked defects, with no PII and no hard-wrapped paragraphs. Open PR B, C1 and C2 in order, one Apple PR in CI at a time, each with tests that fail on the parent commit. Under decision 4 Stamp, PR A may run beside one, and PR D waits for A on stage and for mail-correctness.md's PR 4. Change no characterization test's expected values except the four decision 3 names, and only with the maintainer's yes; change no source-scan anchor or expected text. Before opening a PR, check the plan's hotspot table for another plan's open PR on the same file. Live checks run on the Mac mini with the two stage test accounts (test account 1, and test account 2 with MFA on): coordinate their use, never print credentials, never sign in to prod, and ask the maintainer before driving any Mac GUI.

## Risks and checks

- **Sign-in is high-risk code.** A regression locks a user out. Check: PR B is a guard and a comparison; every lifecycle suite stays green apart from the named tests; the Mini regression run happens before B leaves draft.
- **The server comparison.** Too loose keeps another server's cache; too strict wipes when the same server is retyped. Check: the scope doc fixes the rule and tests it both ways. `Preferences.scopeIdentifier` lowercases the username, so "Alice" and "alice" share preferences but not a cache. That predates this plan and stays, since changing it would orphan every stored preference scope.
- **Resets on the wrong trigger.** C1's resets run only on a different-account sign-in; tests cover the same account and the same server retyped.
- **Scans.** None is expected to change. `ComposeWindowSlotSourceScanTests` reads `AppState.swift` (C1 keeps `composeSlots.endSession()` where it is). `SignInReasonSourceScan` (`SessionExpiryTeardownTests.swift:155`) and `ConfirmationDialogRoleTests` (:142) read `SignInView.swift`, which no PR edits. `FolderSwitchPlacementTests` (:91, `FolderListView+Helpers.swift`) and `CompactBrandMarkSourceScanTests` (:19, `FeedSidebarSection.swift`) read view files C1 avoids. No scan reads `SessionManager.swift`, `PushRegistrar.swift`, `FolderListViewModel.swift`, `MailCounts.swift` or the Maintenance file.
- **Issues only the harness reproduces.** The cross-server wipe and the late folder list cannot be forced live; they close on tests with the maintainer's OK (the smaller call). Un-quiescing development to pair it with stage could show the cross-server case, which is not worth it.
- **Stamp only.** A wrong comparison hides actions on real mail. Unstamped pushes act as today, and reverting `push_dispatch`'s stamp (or PR A) returns every client to today's behaviour. A lost register response leaves the device without a stamp, so its own pushes show without actions until the next launch registers *(inferred, accepted)*. Mac app instances share one defaults domain and keychain, so the two-instance case may stay uncovered *(inferred)*. Older builds and Android ignore `acct`, so nothing breaks.

## Not in this plan

- **A directory per account, and sign-out deleting it:** sqlite-mail-store.md (its decision 3, PRs 1.1 and 1.2), relying on decision 1.
- **#1957:** sqlite-mail-store.md PR 0.2. **The app-layer test that sign-out retires the feed store:** test-debt.md A5, which sqlite-mail-store.md also names.
- **`BimiUrlCache` and contacts results at sign-out:** declined. Logos come from public per-domain lookups and contact names from the device's own address book, which every account on the device reads anyway; the Kit audit rated both "low-sensitivity" (audit 03 F12).
- **The session keys at `SessionManager.swift:709-721`:** nothing to move; each is used in one non-test file, and multi-window-and-restore.md W3 closes audit 06 F16 (`UserDefaults` keys duplicated as literals across files) without them.
- **The draft-save and outbox-remove `try?`:** hardening-web-and-writes.md. **#1973, notification actions through the mutation service:** mail-correctness.md PR 4.
- **Tests for `IntentBridge` and its hooks:** test-debt.md A6, which leaves the `@main` bodies untested and relies on live-verification.md's cold-start checks.
- **#1937's second-account leg and 1.3's cold-start notification and Siri checks:** live-verification.md. PR D's device check stays here, on its own release's TestFlight checklist.
- **A process-wide `Reachability`:** declined (kit-split.md: not planned; under decision 1 one per account is one per process). **The Kit's test-driven optionals:** kit-split.md decision 5 (Init, its default).
- **Android:** the stamp check is android-parity.md L6 (Stamp only); its feed store at sign-out is android-parity.md decision 3; #1158 stays closed.
- **A server-only banner fix** (no UID fallback when a Message-ID was given and missed): not proposed. It fixes the banner but not the actions, and could cost the banner on the account's own mail when the search misses for a reason nobody has sized.
- **`PushRegistrar`'s raw account key** (`:273, :299-305`): left as is; it errs toward dropping notifications.
- **Platform-service protocols:** not re-proposed (1.3 D6 kept `SessionHooks`). **Several accounts at once:** only if decision 1 is No, as its own project.

## Sources

- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Sibling files in this folder: `00-working-agreements.md`. Sibling plans in this folder: sqlite-mail-store.md (decision 3, PRs 0.2, 1.1, 1.2, G0, hotspots), multi-window-and-restore.md (W3, R2, hotspots), mail-correctness.md (PR 4), shared-load-error-state.md (A5, B2), android-parity.md (L6, decision 3), kit-split.md (decision 5, "Not in this plan"), live-verification.md, test-debt.md (A5, A6), docs-and-bookkeeping.md, platform-conditionals.md, swift6-and-strict-checking.md (B1), hardening-web-and-writes.md.
- Code at 50e6022, Apple: `apple/CabalmailUI/Session/SessionManager.swift:127-163, :268-303, :315-391, :515-562, :682-722`; `Session/SessionEnvironment.swift:78-88`; `App/AppState.swift:96, :136, :196, :207-212`; `Shell/ContentView.swift:27-33`; `Session/SignInView.swift:106, :141, :156`; `Mail/Store/MailSessionStore.swift:62-64, :215-219`; `Mail/Store/MailCounts.swift:68, :224-253`; `Mail/Folders/FolderListViewModel.swift:103-143, :158, :178-206`; `Mail/Folders/FolderListView.swift:45, :90`; `Feeds/Sidebar/FeedSidebarSection.swift:79`; `Platform/Services/PushRegistrar.swift:59-121, :226-305`; `Platform/Services/AppDelegate.swift:92-108`; `Settings/DebugLogView.swift:34`; `apple/CabalmailKit/Sources/CabalmailKit/CabalmailClient+Maintenance.swift:17-41`; `Auth/SecureStore.swift:99`; `Settings/Preferences+AccountScope.swift:9-20`; `API/BimiUrlCache.swift:1-25`; `Logging/DebugLogStore.swift:1-50, :92`; `Sources/CabalmailShared/PushMessageCoordinates.swift:43-99`; `apple/CabalmailNotificationService/NotificationService.swift`; `apple/project.yml:558-566`; `apple/.swiftlint.yml:47-50`.
- Code at 50e6022, tests: `apple/CabalmailTests/SignInCharacterizationTests.swift:121-150, :290-391`; `SignInMfaCharacterizationTests.swift:318-323`; `SignOutLeftoversCharacterizationTests.swift:5-13`; `ComposeWindowSlotSourceScanTests.swift:37`; `SessionExpiryTeardownTests.swift:155`; `ConfirmationDialogRoleTests.swift:142`; `FolderSwitchPlacementTests.swift:91`; `CompactBrandMarkSourceScanTests.swift:19`; `apple/CabalmailKit/Tests/CabalmailKitTests/PushHandoffContractTests.swift`.
- Code at 50e6022, server and Android: `lambda/api/push_dispatch/function.py:215-260, :290-297`; `lambda/api/push_register/function.py:5-20, :201, :234-243`; `lambda/api/push_envelope/function.py:1-12, :101-137, :140-168`; `docker/shared/push-enqueue.sh:59-68`; `terraform/infra/modules/app/push_dispatch.tf:201-205`; `android/app/src/main/kotlin/com/cabalmail/android/notifications/PushSignal.kt:19-31`; `docs/push-notifications.md:68-91`; `docs/apple.md:1024`.
- GitHub, checked 2026-10-12: #1826 closed (completed, 10-09); #1992 closed (10-12); #1883 closed (completed, 10-06; body names the Mac's envelope fetch and the actions); PR #1897 merged 10-06 (body: "The planned account stamp in `msgRef` would cover the first two cases if you ever want it"); PR #1849 merged 10-05 (body: "a late folder-list reply writing the subscribed folders back"); #1851, #1886, #1892, #1872, #1937 closed; #1957, #1973, #2028, #2039 open; #1158 closed not planned 2026-08-19; PR #1887 (1.3) body, decision 7; no issue title mentions more than one account (523 issues).
