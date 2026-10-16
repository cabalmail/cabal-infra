# Live verification backlog

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session. One soak session on the Mac mini carries it end to end: no code, no PRs, one batch of answers. Its output is evidence comments, new issues for failures, a seeded test folder and a short device list for the maintainer. Its fixture step (Step 1) may run first on its own.
**Size:** M (about two rig days: roughly ten hours of checks, a three-hour unattended outbox run that overlaps simulator work, and under option B an overnight token wait).
**Priority:** Next, except Step 1, the big-folder fixture, which is Now: duo-support.md (Now) and multi-window-and-restore.md want it for their row 300 and 700 checks before the Duo arrives about 2026-10-23. Run the rest before account-isolation.md's PR B and sqlite-mail-store.md's Phase 1 change the sign-out and cache paths it checks, so they get a live baseline.
**Depends on:** nothing.
**Unblocks:** duo-support.md and multi-window-and-restore.md (the `SoakBig` folder for rows 300 and 700); test-debt.md (its B4 commits this plan's shim and fixture script after it runs). Soft: account-isolation.md (baseline before PR B) and sqlite-mail-store.md (baseline before Phase 1, and a folder over 250 messages for its Phase 2 soak).
**Duo groundwork:** No Duo checks (they all live in duo-support.md). It seeds the folder of about 800 messages that the fold checks use at rows 300 and 700, and writes down the shim and two-account recipes the Duo passes can reuse.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| Decisions 1 to 5 | Unanswered (2026-10-15). |
| Step 0. Rig prep | Not started (2026-10-15). |
| Step 1. Fixture | Not started (2026-10-15). |
| Step 2. Wave 0 paths | Not started (2026-10-15). |
| Step 3. Account switch | Not started (2026-10-15). |
| Step 4. Outbox backoff run | Not started (2026-10-15). |
| Step 5. Simulator checks while Step 4 runs | Not started (2026-10-15). |
| Step 6. Write-up and cleanup | Not started (2026-10-15). |
| Part B. The maintainer's devices | Not started (2026-10-15). |

## Decisions for the maintainer

1. **Which fixes closed on tests alone get a live re-check: A, B or C?** **A (recommended): the account-switch fixes.** These are the closures where a failure would show one account's mail, counts or notification actions to the next account, or change the next account's mail on the server (#1852, the worst). A re-checks #1825, #1848, #1851, #1852, #1872, #1883 and #1937's second-account leg, plus #1886 if the Mac's Dock badge can be seen, with pre-fix controls for four of them; about half a rig day. It relies on the shim (a test-only add-on, kept outside the repo, that makes the app's network calls wait, fail or go offline on command). On the iPhone simulator the shim is proven only for timed holds and faked replies, so A may shrink, and the record will say what ran. A leaves out #1829, also an account-switch fix, because staging it needs two fakes at once; its tests stand. **B:** A plus #1818, #1823 item 2, #1828 and the offline feed watermark, about three more hours and an overnight wait. **C:** none. Default: A.
2. **Where does the big-folder fixture go: test account 3 (recommended), test account 1, or nowhere?** About 800 synthetic messages, filed by a mail rule into a `SoakBig` folder and kept afterwards. Stage has no public IMAP listener, so they are sent by SMTP submission, which needs the account's password. Test account 3 (a third stage test account; see "The rig" below): the session already gets that password from the stage credential helper, and test account 1's mail and your tester agent's runs stay untouched. Test account 1: it is the account the Mini's simulators already use, but you must first make its password available to sessions. Nowhere: #1818, #1823 and the deep-place checks here, in duo-support.md and in multi-window-and-restore.md fall back to your own account or skip. Default: test account 3, kept.
3. **Run the three-hour outbox backoff soak on the Mini's Mac app: Yes or No?** **Yes (recommended).** It is the one Wave 0 path never run live, and App Nap's effect on the retry timer is invisible to unit tests. For those three hours nothing may sign out, quit or rebuild the Mac app, including your tester agent. Default: yes.
4. **Install the stage TestFlight Mac build on the Mini: Yes or No?** **Yes (recommended).** You sign in to TestFlight on the Mini once. Mac notification checks then get real push, and the session learns whether a release-signed app in Applications appears in Spotlight, so later Mac soaks (multi-window-and-restore.md, mail-correctness.md) stop needing your hands for those. It adds one more Mac copy that shares the keychain. Default: no; Mac push and Spotlight checks stay on your device list.
5. **Your device list (Part B): B1 to B3 (recommended), All, or None?** B1 is about ten minutes of real push after an account switch, B2 two minutes of Siri, B3 a week of normal use with crash reports on. Default: the list is posted and nothing waits on it.

## What you'll see change

- **Step 1, fixture:** a `SoakBig` folder of about 800 synthetic messages and one mail rule appear in the stage account decision 2 picks. Nothing else changes in the apps.
- **Steps 2 to 5:** nothing in the apps. Each checked item gets one evidence comment or a new issue (about fifteen comments on closed items, so expect that much email). Why it matters: a pass turns "closed on tests" into "seen working", and a failure finds an account leak before account-isolation.md and sqlite-mail-store.md rewrite the same code.
- **Decision 4 Yes:** a TestFlight copy of Cabalmail on the Mini.
- **Step 6:** one soak record in the thread, the cleanup, and Part B for you.

## Why

Waves 0 to 3 closed many fixes on their tests because the soak rig could not set up the conditions: a second account, a held or failed request, more than 600 messages, a failed keychain write, real push. The maintainer agreed each time to unblock Promote (for #1823 item 2, after the Wave 2 soak: "2. Yes", the maintainer, 2026-10-09). Most closing comments record the maintainer's explicit OK; #1851 and #1852 were closed under the 1.24.0 soak's blanket agreement (their closing comments, 2026-10-05). Several of those limits are gone. The stage credential helper gives sessions test accounts 3 and 2. Since 2026-10-08 the shim has been injected into iPhone simulators for timed holds and faked replies (#1937, #1823). The iPad simulator opens a second window from the menu bar. The account-switch fixes matter most: a failure shows one person's mail or counts to another, or marks another account's message read on the server, and 1.3's `SessionManager` (PR #1887) rewrote that code after most of them were verified. Separately, Wave 0 left paths never exercised (the 2026-10-02 stage soak did not check the scrub of a password an older build had stored, PR #1778; the real outbox backoff schedule, about three hours of failures, PR #1780; or the offline mark-all-read watermark and the website-data cleanup in feeds, PR #1781), and 1.3 left an iOS offline cold launch and a cold-start App Intent unchecked (PR #1887, "Not checked live").

## Where things stand

**Release.** 1.31.0 is out. PR #2043 merged on 2026-10-12, and `main` is its merge of 50e6022, so stage and prod hold the same app code at writing. A failure found now is already in prod: file it, and nothing holds. If stage has moved when this runs and a failure sits in code not yet in prod, tell the maintainer, who can hold the next promotion. The release dashboard will not do it: it holds Promote only while an open tester or fixer issue has a fix merged on stage (`scripts/release-dashboard.py:17-24`).

> **Erratum (2026-10-15):** Stage and prod no longer hold the same app code. Since writing, 1.31.1 (PR #2052, 2026-10-13) and 1.31.2 (PR #2055, dated 2026-10-14) have been released, and `stage` (now at `5a56ce2`) holds two Apple changes not yet released: hardening-web-and-writes.md's PR 2 (#2056, feed reader mode runs no script from the article) and its PR 3 (#2057, the reader bridges run in the app's own script world). A failure in code those two touched is not yet in prod, so this paragraph's rule for a moved stage applies to it.

**Wave 3's by-hand checklist.** The checklist (a file in the rearchitecture project's records listing the by-hand checks Wave 3's PRs asked for, on the stage TestFlight build of 59d8ff8; the items this plan uses are under "Background from the rearchitecture") shows every box unchecked because nobody edits it. The maintainer ran Mac checks on the TestFlight build of stage 59d8ff8 (#2016, #2018) and the iPad Menus and notification checks on 1.30.0 (1791732986) of stage e87fd419 (#2025 to #2028). #2018 passed the maintainer's recheck on 2026-10-12 and is closed. The maintainer closed the checklist's discussion with "Anything I haven't reported is good." (the maintainer). Readers disagreed on whether that covered the checklist's "At the Studio" section and the checks needing setup the maintainer may not have had: a second account (Mac and iPad "Another account starts windows fresh"), a deep list place (iPad "A deep list place across a resize", iPhone "The list reopens deep after a swipe-away"), the CloudWatch count (iPad "One preferences pull for two windows") and two iPad windows after an Xcode stop ("Two iPad windows come back after an Xcode stop", in "At the Studio"). This plan does not re-ask. The rig runs the ones it can stage (Steps 3 and 5). Device-only checks with no recorded result are taken as passed under those words.

**#1783's iPad two-window menu case** ("needs a real iPad", the 2026-10-05 pre-release soak's note for leaving it untested: a second main window on the iPad simulator needed a system multitasking gesture, and the simulator could not deliver keyboard shortcuts) is probably not covered (low to medium confidence). #2026 came from the iPad Menus pass, but its 2026-10-11 comment says only the main window was open, and #2025 (closed, not planned) says holding Command showed no menu, so the checklist's two-window check (iPad "Message menu with two windows") could not run as written. Step 5 tries it on the iPad simulator with menu clicks.

**Fixes closed on tests alone** (all closed as completed; GitHub checked 2026-10-13):

| Issue | Live check needs | Rig can stage it? | Option |
|---|---|---|---|
| #1806 corrupt stored session | a stored session that will not decode | Not in a simulator keychain (#1806 comment); on the Mac only by overwriting the item, which risks the shared keychain | Skip |
| #1808 keychain write fails in a refresh | a failing keychain write | No, not without a code seam | Skip |
| #1818 new mail while scrolled past row 600 | a folder over 600 messages | Yes, with `SoakBig` | B |
| #1823 item 2, scrolling up from a far jump | a folder over 500 messages | Yes, with `SoakBig` | B |
| #1825 sign-out leaves counts, shields, a parked Spotlight link | a second account | Yes | A, with control |
| #1828 Cognito throttles the launch refresh | an expired ID token (12 h lifetime) and a faked throttle | iPhone clone, if the shim can fake Cognito's reply (inferred) | B |
| #1829 sign-out during an expiry teardown | a forced expiry while `/push_deregister` is held | Two fakes at once; not attempted | Skip |
| #1848 a STATUS reply during sign-out | a second account and a held folder-count request | Yes | A, with control |
| #1851 late unread change after the next sign-in | a second account and a held `/set_flag` | Yes | A, with control |
| #1852 late request sent with the next account's token | a second account and a held body load | Yes | A, with control; the most serious |
| #1872 old account's notification actions | a second account and a delivered notification | Yes, `xcrun simctl push` on an iPhone clone | A |
| #1873 stale UIDVALIDITY | a restore carrying one | Precondition never arose (#1873 comment, 10-06) | Skip |
| #1883 push after a failed deregistration | a failed `/push_deregister` and a read of `cabal-push-tokens` | iPhone clone, if the shim can fail one endpoint (inferred; on 10-06 the simulator could not be taken offline) | A |
| #1886 badge poll in flight at sign-out | a held INBOX count and a visible badge | Only through the Mac Dock badge, if the debug build may badge; the menu-bar line reads "Not signed in" whenever signed out (`apple/CabalmailMac/MenuBarExtraMenu.swift:52`), so it cannot show the leak | A if the badge shows, else Skip |
| #1892 Check Inbox intent at sign-out | Shortcuts and a timed sign-out | No | Skip |
| #1937 second-account leg | a second account and a held feed catalog | Yes (mechanism already shown live, #1937 comment 10-08) | A |

**Code under check** at 50e6022 (Kit paths under `apple/CabalmailKit/Sources/CabalmailKit/`, app paths under `apple/CabalmailUI/`):

| Check | Where |
|---|---|
| Password scrub, shipped in 1.23.0 (`CHANGELOG.md:874`) | `Auth/AuthService.swift:142-146`; tag 1.22.6 stored it at `AuthService.swift:168` |
| Outbox backoff | `Outbox/SendQueue.swift:38-62` (30 s doubling to a 3,600 s cap, `:49`); ten attempts, `Outbox/Outbox.swift:68`; about 3 h 4 min to the failed state |
| Per-feed website data | `Feeds/FeedWebStorage.swift:19-36`, called at sign-out from `Session/SessionManager.swift:539` |
| Next account clears cached mail | `Session/SessionManager.swift:690` |
| #1886, #1872, #1852 fixes | `Session/SessionPollers.swift:61-64`; `Platform/Services/PushRegistrar.swift:303, 360`; `Auth/AuthService.swift:128, 246` |
| Push payload | `lambda/api/push_dispatch/function.py:230-240`: `msgRef` is {folder, uid, msg_id}, with no account |
| Log text | `Logging/CabalmailLog.swift:47` marks every unified-log line private, so `log stream` shows `<private>`; Settings, Diagnostics, Debug Log keeps the plain text, in memory, last 1,000 lines (`Logging/DebugLogStore.swift:4-11, 50`) |
| Token lifetime | ID and access tokens 12 h, refresh token 7 days (`terraform/infra/modules/user_pool/main.tf:146-158`) |

**The rig** (the Mini, the checkout):
- iOS 27 is the only iOS runtime on the Mini (#1912 comment, 2026-10-07); the other platforms' runtimes are unchecked. There is a signed macOS debug build.
- Accounts: three stage test accounts, test account 1 (what the simulators and the Mac app are signed in as), test account 3 and test account 2. The stage credential helper on the rig serves test accounts 3 and 2 only (it reads their credentials at run time from AWS Parameter Store; never print them); how a session signs test account 1 back in after a sign-out is not recorded. Two-account switches ran on the iPhone simulator on 10-06 (#1883 comment).
- Mail: stage has no public IMAP listener (`terraform/infra/modules/elb/variables.tf:12-17`). SMTP submission works with an account's password (`scripts/test-mail-loop.py`).
- The shim is an `NSURLProtocol` injected with DYLD and driven by flag files, outside the repo. On macOS it has done offline, slow and a forced 401 (the 2026-10-05 pre-release soak, which injected it with `DYLD_INSERT_LIBRARIES`, controlled it by flag files in the app's tmp directory, and kept the network-client entitlement so the compose editor stayed alive). On iPhone simulators it has done a 20 s hold (#1937) and a faked `/folder_status` reply (#1823). Not yet shown: an offline iPhone simulator, failing one endpoint, logging request bodies, holding until released. Its location is not recorded (perhaps in the scratch folder on the Mini where the 2026-10-02 soak left its builds, helper scripts and screenshots; inferred).
- SimDrive drives the simulators by accessibility id (`docs/apple.md:172`).
- Limits: the Mini's Spotlight never lists Cabalmail, and a macOS debug build gets no APNs push (#2018 comment, 2026-10-12). The iPhone simulator does register and deregister push tokens (#1883 comment). Synthetic key chords are unreliable on the iPad simulator (Command-A never reached the list, #1929; a synthetic Command-comma did open Settings once, #2026). Simulators show no app badge. Every macOS build on the Mini shares one keychain, so one Mac sign-out signs out every copy. Windowed mode crashed the iPad simulator's render server (#2035). There is no Duo simulator on the Mini.
- Known open bugs a check may hit: #2030 (on iPhone, a folder picked after launch does not restore its place, and a foreground terminate reopens a stale route), #2042 (Mac place after Command-Q), #2028 (a warm notification tap selects the folder, not the message), #2035. Add evidence to these; do not refile them.

**Other users of the rig.** The maintainer's daily tester agent runs on the Mini (digest #705, last entry 2026-10-07); whether it is paused is unknown. 25 open issues carry `needs-verification` on 2026-10-13.

## The plan

No PRs. Each check ends in one GitHub comment on the item it checked (stage SHA, platform, what was forced, result) or a new issue. Re-reproduce a failure with a second, independent agent run before filing it; file it with `needs-verification` and a link to the closed item, and don't reopen. Do every sign-out on a throwaway clone of a simulator unless the step says Mac, and delete clones afterwards. Timed holds of 60 to 120 seconds are enough for every race below; releasing on a flag file is a bonus.

**Step 0. Rig prep (about two hours).**
- Ask the maintainer (or read #705 and the tester's charter) whether the tester agent is idle, and announce the Mac blocks: Step 3's Mac legs and Step 4's three hours.
- Ask the maintainer how a session signs test account 1 back in on the Mac. Without an answer, skip every Mac sign-out (Step 3's Mac legs, #1886) and say so.
- Run `xcrun simctl list runtimes`. Build stage for the iPhone and iPad simulators and the signed Mac app, holding `/tmp/cabal-build.lock`.
- Build tag 1.22.6 in a throwaway worktree, capped at 45 minutes. It is the scrub's starting point and the pre-fix control for #1825, #1848, #1851 and #1852 (fixed in 1.24.0 and 1.25.0). If today's Xcode cannot build it, record the scrub as test-only and drop the controls.
- Shim probe, capped at 90 minutes, on the Mac and on an iPhone clone: hold a named endpoint for a set time, fail one endpoint with a 500, go fully offline, log request paths (and bodies if possible). Record what works; each check below names what it needs. If the shim is gone, rebuild it outside the repo within the cap.
- Spotlight, 30 minutes: find out why the Mini's Spotlight never lists Cabalmail (System Settings, Spotlight; `mdutil -s /`; whether the debug build's location is indexed). Record the answer. With decision 4 Yes, install the TestFlight Mac build and repeat the probe against it.
- Check whether the Mac debug build may badge its Dock icon (System Settings, Notifications). That decides #1886.

**Status:** Not started (2026-10-15).

**Step 1. Fixture (about an hour; may run first, on its own, now).**
- In the account decision 2 picks, create `SoakBig` and a rule "Subject contains [soakbig]: Move to SoakBig" in the app's Rules settings. A rule-filed message pushes only to devices opted in to that folder, and the inbox is the default (`docs/push-notifications.md:35-37, 322-325`), so nothing buzzes.
- Send about 800 messages by SMTP submission from one of the account's own addresses to another, one every two seconds, subjects tagged `[soakbig]` and numbered, bodies from `scripts/test-mail-loop.py`'s word corpus. Keep the sender script in the session's scratch space, not the repo. Send one first, and stop and ask the maintainer if SMTP AUTH refuses the account (it has a second factor; that SMTP accepts the password alone is inferred).
- Confirm the app lists `SoakBig` with the right count and INBOX untouched. Post the account and size in the thread for duo-support.md and multi-window-and-restore.md.

> **Erratum (2026-10-16):** A later session cannot read this session's conversation. End Step 1 with a docs-only PR that records in this plan's Step 1 Status line the fixture account (by its "test account N" name), the message count and the stage SHA; duo-support.md, multi-window-and-restore.md and sqlite-mail-store.md read it there. The sender script stays out of the repo until test-debt.md B4 commits it; until then put its source in the soak-record issue that Step 6 opens (00-working-agreements.md, "Working from the repo").

**Status:** Not started (2026-10-15).

**Step 2. Wave 0 paths (about 90 minutes).**
- **Password scrub (PR #1778).** Install the 1.22.6 build on a fresh iPhone clone and sign in as test account 3. Confirm `imap.password` is in the clone's keychain, keyed as the 10-02 soak did (it matched the item by account hash). Install the stage build over it and launch once. Expect `imap.password` and `imap.username` gone and the session restored. A failure means upgraded testers still hold a password on the device.
- **Website data at sign-out (PR #1781, defect 9).** iPhone clone: open articles in two feeds so their per-feed stores fill, note their contents, sign out. Expect the contents emptied; the directories may linger (`FeedWebStorage.swift:19`).
- **Offline feed watermark (PR #1781, defect 7; option B only).** Mac, where offline is proven. Shim offline: Mark All as Read on a throwaway feed folder, wait two minutes, go online. Expect the drained request to carry the tap-time watermark. Skip if the shim cannot log bodies; the Lambda half has unit tests. Never mark All Feeds read on a shared account.

> **Erratum (2026-10-16):** How the 10-02 soak matched the keychain item by "account hash" was not recorded. Build the query from the code instead: the app keeps it as a generic password with service `com.cabalmail.CabalmailKit` and account `imap.password` (`apple/CabalmailKit/Sources/CabalmailKit/Auth/SecureStore.swift:57-70, 137-139`).

**Status:** Not started (2026-10-15).

**Step 3. Account switch (about four hours; option A or B).** Each check on its own iPhone clone signed in as test account 1; sign in to test account 3 (or test account 2) through the stage credential helper, and never print a credential. First run #1852 and #1825 on a fresh 1.22.6 clone (signed in as test account 3, switching to test account 2) with the same recipe. If the old build does not show the bug, the recipe does not discriminate (a held request may simply be cancelled at sign-out), and the stage result is recorded as inconclusive. Add #1848 and #1851 controls if time allows.
- **#1825.** Hold test account 3's folder-count (STATUS) replies at the switch. Expect empty sidebar counts, not test account 1's. Then: move a test account 1 INBOX message, sign out within 60 s, sign in as test account 3. Expect test account 3's message with that UID to stay visible.
- **#1848.** Hold one folder's count request, sign out while it is held, let it land, sign in as test account 3. Expect that folder's badge empty until test account 3's own reply.
- **#1852 and #1851.** Turn on mark-as-read-on-open (a synced preference; Step 6 turns it off). Hold `/fetch_message` for an unread test account 1 INBOX message, sign out, sign in as test account 3 before it lands. Expect no `/set_flag` in the shim log and test account 3's message with that UID still unread on the server. Then hold `/set_flag` for a multi-message mark-read, switch, let it land. Expect test account 3's INBOX count unchanged, also after an offline relaunch.
- **#1872.** `xcrun simctl push` an alert shaped like `push_dispatch`'s (category `MAIL_MESSAGE`, a `msgRef` for a test account 1 INBOX message). Sign out and in as test account 3. Expect the notification gone; if it is still there, its Archive must not move test account 3's message. Repeat with a tap while signed out: nothing opens after test account 3 signs in.
- **#1883** (needs "fail one endpoint"). Fail `/push_deregister` at sign-out, sign in as test account 3. Expect `cabal-push-tokens` to hold only test account 3's row for that device token once it registers (#1897). Never post a token.
- **#1937.** Hold `/rss_list_subscriptions` during a feed refresh, sign out, sign in as test account 3 before it lands. Expect only test account 3's feeds.
- **iPad two-window switch (the checklist's iPad "Another account starts windows fresh").** iPad clone, two full-screen windows on different folders with messages open: sign out, sign in as test account 3. Expect both windows fresh on test account 3's INBOX.
- **Optional, two minutes.** If a paired watch simulator exists, check that it drops test account 1's addresses after the switch (`sessionDidEnd`, `SessionManager.swift:545`). Nobody has checked it.
- **Mac legs,** only if Step 0 found how to sign test account 1 back in, in one announced block. Two windows on different folders with messages open: sign out, sign in as test account 3; expect both fresh on test account 3's INBOX (the checklist's Mac "Another account starts windows fresh"). #1886, only if the Dock badge shows: hold the badge poller's INBOX count, sign out, let it land; expect no badge. Sign test account 1 back in.

**Status:** Not started (2026-10-15).

**Step 4. Outbox backoff run (decision 3; about 3 h 4 min, unattended).** Mac, signed in as test account 1. Plant one outbox entry as the 10-02 soak did (it injected a failed entry into the iPhone app's outbox and relaunched), and have the shim fail `/send` with a 500. Not the in-flight reply: that rolls the attempt count back (`SendQueue.swift:247`). Leave the window behind others so App Nap can act. Read attempts from Settings, Diagnostics, Debug Log, or count `/send` hits in the shim log; not from `log stream`. Expect gaps of about 30 s, 1, 2, 4, 8, 16 and 32 min, then 1 h and 1 h, then the failed banner with Retry. Then Discard the entry. Until it ends, nothing signs out, quits or rebuilds the Mac app: a sign-out wipes the outbox (`SessionManager.swift:539-545`).

> **Erratum (2026-10-16):** How the 10-02 soak planted its entry was not recorded, and it did so on iPhone, not the Mac. The outbox is one JSON file per entry, named by UUID, in an `outbox` directory under the app's cache directory (`CabalmailClient.swift:142`, `Outbox/Outbox.swift:13-21, 216`), each file a `PersistedRecord` envelope, `{"schemaVersion": N, "payload": {...}}` (`Persistence/PersistedRecord.swift`). The simpler route is also allowed: queue a real send while the shim fails `/send`.

**Status:** Not started (2026-10-15).

**Step 5. Simulator checks while Step 4 runs (about three hours).**
- **#1818 (B).** In `SoakBig`, jump past row 600, send one `[soakbig]` message, let the list refresh, scroll back up. Expect no skipped or doubled row.
- **#1823 item 2 (B).** Jump to rows 300 to 500 and scroll up one row. Expect row 299 to load without lingering as a placeholder.
- **#1828 (B).** iPhone clone. Make the stored token expire, either by having the shim shorten `ExpiresIn` in the sign-in reply (inferred possible) or by leaving the app closed overnight. Launch with the shim answering the refresh with `TooManyRequestsException`. Expect the offline launch with cached mail, not "Server error: Rate exceeded" on the sign-in form.
- **iPhone deep place (the checklist's "The list reopens deep after a swipe-away").** A clone signed in to the fixture account: make `SoakBig` the launch folder (pick it, go Home, terminate, launch), scroll to about row 300, wait five seconds, go Home, terminate, launch. Expect that row at the top. In any other folder this is #2030.
- **CloudWatch count (the checklist's "One preferences pull for two windows").** iPad clone, two windows, signed in to the fixture account so that no other client of it runs (the log lines do not say which device called). Go Home and back, then count START lines in `/cabal/lambda/get_preferences`. Expect one. Post the count, not the lines.
- **Cold-start notification.** 3.3's `DeepLinkRouter` (PR #2007) rewrote the path 1.3 checked. With the app not running, `simctl push` and tap; separately, Mark as Read. Expect the message open, or marked read on the server. A warm tap is #2028.
- **iPad two-window menu (#1783).** Two full-screen windows; choose Message, Reply by clicking the menu bar (click the app name by the date, #2025). Expect one reply, in the front window only. If SimDrive cannot reach the menu, record that.
- **iOS offline cold launch (PR #1887 gap; needs the shim offline on iPhone).** Terminate, go offline, launch. Expect the app signed in, cached INBOX shown and the "Couldn't reach the server" banner. If the shim cannot take the simulator offline, this becomes Part B's B4.

**Status:** Not started (2026-10-15).

**Step 6. Write-up and cleanup (about 45 minutes).** Post one soak record in the thread: the SHA per step, what was forced and when it landed, the controls, the results, a list of every comment and issue posted, the AWS reads used, the Spotlight finding, and the shim and fixture recipes. Clean up: turn mark-as-read-on-open back off; mark unread again what the checks marked read; delete the clones, planted outbox entries, the 1.22.6 worktree and its DerivedData, and the shim's flag files; leave the Mac app signed in as test account 1 for the tester agent. Keep `SoakBig` and its rule unless decision 2 said otherwise; deleting the folder in the app removes them later. Post Part B.

> **Erratum (2026-10-16):** "In the thread" now means a GitHub issue with no PII, opened as the soak record, plus a docs-only PR that fills in this plan's Progress table and Status lines and links that issue. Put the shim's source and its flag-file interface, and the Step 1 sender script, in the issue as code blocks, for test-debt.md B4. Tell the maintainer the AWS reads used rather than posting them.

**Status:** Not started (2026-10-15).

**Part B. The maintainer's devices** (stage TestFlight build; nothing holds a release):
- **B1, real push after an account switch (about 10 minutes).** iPhone with notifications on, signed in to stage account X. Turn on Airplane Mode, sign out (so deregistration fails, as in #1883), turn it off, sign in as stage account Y. Send mail to X. Expect no notification for it, earlier X notifications gone from Notification Center, and the app badge at 0 after the sign-out. Stage only: the prod-and-stage case is a known gap owned by account-isolation.md.
- **B2, Siri cold (about 2 minutes).** With Cabalmail not running, ask Siri to check your Cabalmail inbox. Expect a spoken count. Sign out and ask again. Expect a plain "not signed in" sentence, not a raw error. shared-load-error-state.md's A5 keeps those spoken sentences, so this stays valid.
- **B3, background survival (#1843 closed; #1537 closed, not planned; passive).** Turn on the app's Settings, Diagnostics, Crash reports and use the app for a week. Then look in iOS Settings, Privacy & Security, Analytics & Improvements, Analytics Data for crash or `JetsamEvent` files naming Cabalmail. The app's Debug Log keeps only the last 1,000 lines in memory, so it shows a crash payload only soon after the launch that delivered it (inferred). 3.3's restore hides a relaunch, so landing on INBOX no longer signals one.
- **B4, only if Step 5 could not:** iOS offline cold launch with Airplane Mode (1 minute).
- **B5, only with a Vision Pro:** look at the app icon and move your head; the layers should separate (`docs/apple.md:944-947`).
- **B6, optional, whenever you are at the Mini:** allow the Safari extension consent so a session can run #1765's History check. You declined it on 2026-10-06; it is offered for a time you are there, not re-proposed.

**Status:** Not started (2026-10-15).

## Background from the rearchitecture

**The Wave 3 by-hand checklist.** The rearchitecture kept one checklist of the checks a Wave 3 PR or thread asked a person to do, for the stage TestFlight build from the #2015 merge (stage 59d8ff8, uploaded for iOS, macOS and visionOS on 2026-10-10); checks the sessions had already run on simulators or the Studio were left out. It warned that a few checks need an INBOX of 300 messages or more, which the stage test account's folders lack. To open a second window: on the Mac there is no File > New Window (File > New is New Message; View > Show Tab Bar, + in the tab bar, then dragging the new tab out should work but was never tried); on iPad, File > New Window from the menu bar, or touch and hold the app icon and choose New Window. The items this plan runs or cites, by their checklist titles:

- **Mac, "Another account starts windows fresh"** (#2005). Setup: a second account you can sign in to; two main windows on different folders, each with a message open. Do: Settings > Account > Sign Out; sign in as the other account and look at both windows; then sign out and back in as yourself. Expect: both windows start fresh for the other account (normally its INBOX, nothing open), not on your folders or messages. Wrong if: a window reopens on your account's folder or message, or on a folder the other account does not have.
- **iPad, "Message menu with two windows"** (#1997). Setup: hardware keyboard; two windows side by side, each with a different message open; hold Command (or open the menu bar) to see the Message menu. Do and see: (1) quit and reopen; before tapping anything, the Message menu matches the window in front (Reply enabled if it reopened on a message); (2) tap the first window: Command-T twice toggles Mark as Read/Unread on its message only, and Command-R opens one reply, to that message; (3) with the reply in front, the Message menu is dimmed and Command-R does nothing; (4) close the reply without sending; without tapping, Command-R opens a reply for the front window's message straight away; close that too. Wrong if: the menu stays dimmed until you tap, the other window's message toggles, two replies open, or Command-R is dead after a reply closes.
- **iPad, "A deep list place across a resize"** (#2013). Setup: a folder of well over 300 messages; one window, All pill, default sort, no search. Do: scroll until about the 300th message is at the top and note it; narrow until the tab bar shows and let it settle; widen back and let it settle. Expect: the same message at the top each time (past the first 250 the list may show first and move to it a moment later). Wrong if: the list stays at the top or lands on a clearly different message.
- **iPad, "Another account starts windows fresh"** (#2005). As the Mac item, with two windows, opening Settings from the gear in the folder panel or with Command-comma. Expect: both windows start fresh for the other account (normally its INBOX, nothing open). Wrong if: a window shows your account's folder or message, or a folder the other account lacks.
- **iPad, "One preferences pull for two windows"** (#2011), the CloudWatch count. Setup: AWS console access for the environment the iPad is signed in to; keep the app closed on other devices and the web app for a few minutes, because the log does not say which device called. Do: open two windows side by side; note the time; go to the Home Screen, wait about ten seconds, and tap the app icon; in CloudWatch Logs, open `/cabal/lambda/get_preferences` and count the START lines around that moment. Expect: one invocation for that return, not two. Wrong if: two invocations a moment apart each time you come back with two windows open.
- **iPhone, "The list reopens deep after a swipe-away"** (#2015). Setup: more than about 300 messages in INBOX. Do: Mail tab, INBOX, All pill, default sort, no search; scroll until about the 300th message is at the top and note it; wait at least five seconds; swipe the app away and open it again. Expect: INBOX reopens with that message at the top (past the first 250 the list may show first and move to it a moment later). Wrong if: INBOX reopens at the top.
- **"At the Studio (not TestFlight)"**, three items that need Xcode or the Duo simulator: "Duo fold keeps the list's place" (#2013, #2015; INBOX at about rows 30, 300 and 700), "Two iPad windows come back after an Xcode stop" (#2005, #2015) and the optional "Duo fold in the middle of a search" (#2006). The Xcode-stop item, which multi-window-and-restore.md runs: two windows wide enough to show the list beside the reader, one on INBOX and one on another folder, each scrolled to a different top message with a message open; tap into each, wait five seconds, go to the Home Screen, stop the app from Xcode and launch it from the Home Screen; expect both windows back on their own folder, open message and top message (a swipe-away throws saved windows away, so only an Xcode stop tests this).

## How to start it

Start a thread in a Claude project with a Remote Control session on the Mac mini, working in the checkout. The session reads this plan and `00-working-agreements.md` from `docs/1.x/post-wave-3/`; the Wave 3 checklist items it runs are under "Background from the rearchitecture" above, and what it needs from the 2026-10-02 and 2026-10-05 soak notes is stated where it is used. Paste the maintainer's answers under the brief. To run only the fixture now, use: "Run Step 0's first three bullets and Step 1 of docs/1.x/post-wave-3/live-verification.md, then stop."

> Run the live verification backlog in the plan docs/1.x/post-wave-3/live-verification.md on the Mac mini as a soak: no code, no PRs. Read docs/1.x/post-wave-3/00-working-agreements.md first. The maintainer's answers to the plan's decisions are below. Work in your own worktree of origin/stage and hold /tmp/cabal-build.lock around every build. Use only the stage test accounts 1, 2 and 3 the plan names; read test account 2 or 3 credentials through the stage credential helper on the rig and never print one; ask the maintainer how to sign test account 1 back in before any Mac sign-out. Do sign-outs on throwaway simulator clones unless a step says Mac. Before any Mac sign-out, and before Step 4, confirm the maintainer's tester agent is idle and tell the maintainer, because every macOS build on the Mini shares one keychain. Reuse the test-only network shim from the 2026-10-05 soak, and in Step 0 establish what it can do on the iPhone simulator. Run the steps in order: Step 4 (the outbox run) starts after Step 3, and nothing may sign out, quit or rebuild the Mac app until it ends; do Step 5 on simulators meanwhile. Run the pre-fix controls the plan names. Post one evidence comment per checked item (stage SHA, platform, what was forced), with no PII, no device tokens, no raw log lines and no hard-wrapped paragraphs. Re-reproduce any failure with a second agent before filing it as a new needs-verification issue that links the closed one; add to #2030, #2042, #2028 or #2035 rather than refiling. Finish with the soak record in this thread, the cleanup, and Part B for the maintainer.

> **Erratum (2026-10-16):** Where the brief says to reuse the 2026-10-05 soak's network shim, ask the maintainer where it is first ("The rig" says its location was not recorded); if it cannot be found, rebuild it outside the repo within Step 0's 90-minute shim-probe cap and record its flag-file interface in the soak record. "The soak record in this thread" means the issue and docs-only PR in Step 6's erratum.

## Risks and checks

- **The shared Mac keychain.** One Mac sign-out signs out the tester agent's and every other session's Mac app, and the session may have no way to sign test account 1 back in. Hence sign-outs on simulator clones, and Mac legs only after Step 0 settles it.
- **Rig contention.** The Mac app is this plan's hotspot. Other plans verify on the Mini in the same weeks (shared-load-error-state.md, refresh-scheduling.md, ipad-layout-and-keyboard.md, multi-window-and-restore.md). Book Step 3's Mac block and Step 4's three hours; simulator clones do not collide.
- **The shim is not in the repo** and its iPhone-simulator abilities are partly unproven. Each check names what it needs; whatever Step 0 cannot show is skipped and named in the record, with Part B's B4 as the one device fallback.
- **Race checks prove only the interleaving forced.** Record which request was held, for how long, and when it landed; the 1.22.6 controls show whether a recipe can fail at all.
- **Fixture sending.** About 800 messages through stage's SMTP: throttle, stop on errors, keep every INBOX untouched. Stage monitoring may notice the burst (inferred); tell the maintainer before sending.
- **Old-tag build.** 1.22.6 is six weeks older than the toolchain; it is capped at 45 minutes, with a named fallback.
- **Credentials.** The classifier refused stage credentials before the helper existed; use only the helper. Don't plant failing SQLite writes (refused in the feed-fix soak; that seam belongs to sqlite-mail-store.md).
- **AWS reads.** If the Mini's stage AWS access cannot read `cabal-push-tokens` or the `get_preferences` log, skip #1883's table read and the CloudWatch count, and record the denial. It read the table on 10-06.
- **Stage moves mid-session.** Record the SHA per step; re-run any check whose path a merge touched.
- **Email volume.** About fifteen comments on closed items reach the maintainer's inbox; the soak record lists them in one place.

## Not in this plan

- **Every Duo check,** including list place across folds at rows 30, 300 and 700, a fold mid-search and #1962's device confirmation: duo-support.md. This plan only seeds the folder.
- **Two iPad windows after an Xcode stop (the checklist's "Two iPad windows come back after an Xcode stop") and #2030 itself:** multi-window-and-restore.md, whose R1b verification runs that exact check after its fix. Run now, it would hit #2030's stale-route bug.
- **The iPad deep list across a window resize (the checklist's "A deep list place across a resize"):** windowed mode crashes the Mini's iPad simulator (#2035), so it is device-only and taken as passed under "Anything I haven't reported is good".
- **#1912 on a pre-27 runtime, and the deployment floors:** apple-ci-and-build-config.md (its decision 3 records that no rig tests pre-27).
- **The visionOS `.inspector` availability claim (audit c-7: code comments say visionOS lacks `.inspector`, which the 2026-10-02 platform-split audit believed SwiftUI offers there; unverified):** platform-conditionals.md. It is an SDK question.
- **The 25 open `needs-verification` issues:** the tester's verify mode and the plans that own them.
- **Closing issues whose fixes shipped** (#1912 and #1915 were fixed in 1.29.0 and are still open), the Studio chores ("Cabal33Probe", git cleanup) and the stale Safari extensions on the Mini: docs-and-bookkeeping.md.
- **The iPad Settings-sheet card:** multi-window-and-restore.md, decision 1.
- **Real-keyboard chords on iPad** (#1929, #2026, #2027): ipad-layout-and-keyboard.md.
- **The cross-deployment push leak and an account stamp in `msgRef`:** account-isolation.md. Its PR D device check, and refresh-scheduling.md's real foreground and reconnect checks, go on the maintainer's TestFlight checklist for the release that carries them, as the working agreements say; Part B is the template.
- **Committing the shim and fixture script:** test-debt.md's B4, after this runs.
- **Narrowing the soak rig's stage AWS access** to the credentials it reads: no plan owns it, and doing it first would block this session's AWS reads. The soak record lists every AWS read so the maintainer can narrow it when they choose.
- **#1880's count race** (closed, cannot reproduce): if a count glitch shows up, add the evidence to #1974 or #1977 (mail-correctness.md).
- **Closures skipped on purpose:** #1806, #1808, #1829, #1873 and #1892, for the reasons in the table.

## Sources

- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo. The 2026-10-13 revision cited them as this plan's draft and its two reviewers had, because they could not be re-read during that revision; the checklist and soak-note content above was re-read from them for this copy on 2026-10-15.
- Repo at 50e6022: `apple/CabalmailKit/Sources/CabalmailKit/` `Auth/AuthService.swift:128-146, 246, 389-396`, `Outbox/SendQueue.swift:38-62, 247, 271`, `Outbox/Outbox.swift:68`, `Logging/CabalmailLog.swift:47`, `Logging/DebugLogStore.swift:4-11, 50`, `Logging/MetricKitCollector.swift:42`; `apple/CabalmailUI/` `Feeds/FeedWebStorage.swift:7-36`, `Session/SessionManager.swift:539-545, 690`, `Session/SessionPollers.swift:61-64`, `Platform/Services/PushRegistrar.swift:303, 360`, `Mail/Store/MailCounts.swift:216-221`, `Settings/SettingsView.swift:292-309`; `apple/CabalmailMac/MenuBarExtraMenu.swift:51-52`; tag 1.22.6 `AuthService.swift:168`; `lambda/api/push_dispatch/function.py:230-240`; `terraform/infra/modules/user_pool/main.tf:146-158`; `terraform/infra/modules/elb/variables.tf:12-17`; `scripts/release-dashboard.py:17-24`; `scripts/test-mail-loop.py:1-45`; `docs/push-notifications.md:35-37, 322-325`; `docs/apple.md:172, 944-947`; `CHANGELOG.md:874`. Fix PRs mapped to tags with `git merge-base`: #1840 and #1849 in 1.24.0, #1861 and #1863 in 1.25.0, #1884 in 1.26.0.
- GitHub, checked 2026-10-13. Closed as completed: #1806, #1808, #1818, #1823, #1825, #1828, #1829, #1843, #1848, #1851, #1852, #1872, #1873, #1883, #1886, #1892, #1937, #2018. Closed, not planned: #1537, #2025. Merged PRs: #1778, #1780, #1781, #1783, #1887, #2007, #2043 (Release 1.31.0, merged 2026-10-12). Open: #1912, #1915, #1929, #1962, #2016, #2026, #2027, #2028, #2030, #2035, #2042, digest #705. Comments read: #1823 (10-09), #1828, #1851, #1852, #1873, #1883 (10-06), #1886 (10-06), #1912 (10-07), #1937 (10-08), #2018 (10-12), #2026 (10-11), #1765 (closing).
- `00-working-agreements.md` and sibling plans in this folder, read for hand-offs: duo-support.md, multi-window-and-restore.md, account-isolation.md, refresh-scheduling.md, shared-load-error-state.md, sqlite-mail-store.md, test-debt.md, apple-ci-and-build-config.md, ipad-layout-and-keyboard.md, feed-bulk-actions.md.
