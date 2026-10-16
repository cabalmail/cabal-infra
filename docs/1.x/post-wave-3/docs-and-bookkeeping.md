# Docs, stale comments and issue bookkeeping

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session. One batch of decisions, three small PRs, a few issue comments and a checklist for the maintainer; there is no audit, no server change, no parallel work and no soak. Run it as the rearchitecture project's last thread if you can, because that thread can still read the project's folder.
**Size:** S
**Priority:** Now. It moves the API change rule and the FU-1 to FU-19 catalogue out of the rearchitecture project's folder, which was closing. The published 1.31.0 notes misdescribe the iPad keys, and five fixed issues are still open.
**Depends on:** nothing. Release PR #2043 merged on 2026-10-12 at 11:33Z, so nothing here waits on a promotion.
**Unblocks:** flags-and-cross-media.md (it lists the API rule and the Phase 1 status fix as coming before its A0). It is a soft help to platform-conditionals.md (the catalogue in the repo before its FU-1 PR) and to the five other plans that change Lambdas and cite the rule: sqlite-mail-store.md, account-isolation.md, hardening-web-and-writes.md, mail-correctness.md and shared-load-error-state.md.
**Duo groundwork:** Small. The catalogue's Progress table is where FU-1 gets tracked, and duo-support.md's FU-12 builds on FU-1. The checklist keeps the Studio's Duo branches and rescue refs until duo-support.md hands over its delete list, and it frees about 6.4 GB on the Studio, the rig with the Duo simulator.
**Written:** 2026-10-12 against stage 50e6022, revised 2026-10-13 after #2043 merged. Re-check line numbers before starting.

> **Erratum (2026-10-15):** The rearchitecture project is retiring after hardening, so this plan runs as a fresh session from this repo copy, not as the project's last thread; what it needed from the project's records is stated in the plan. The FU catalogue has already moved into the repo with these plans (decision 3, answered), so for the catalogue PR 2 only adds the links.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| Decisions | 3 and 4 answered 2026-10-15 (see "Decisions for the maintainer"); 1 and 2 open. |
| PR 1. Released notes and the API rule | Not started (2026-10-15). |
| PR 2. Apple docs and the catalogue | Partly done (2026-10-15): the catalogue and the folder index came in with the change that added `docs/1.x/post-wave-3/`. The rest is not started. |
| PR 3. Stale comments | Not started (2026-10-15). |
| Issue bookkeeping | Not started (2026-10-15). |
| The maintainer's checklist | Not started (2026-10-15). |

> **Duo spec (2026-10-13):** This plan was written before the maintainer's Oct 7 Duo spec (the Claude Doc "Cabalmail on iPhone Duo: Poses and Transitions", linked in duo-support.md) was read in the rearchitecture project. duo-support.md now follows it; where this plan's text disagrees with the points below, the points win. In the spec, "fold" means book or laptop pose, which changes no size class and swaps no shell; what this plan calls folding or unfolding the Duo is closing or opening it.
>
> - Record #2006 and the Settings sheet-to-tab hand-off in `docs/apple.md` as rules of the current two shells, which duo-support.md Decision 9 may replace. The search model is already per window on stage. Write the new Settings sentences as describing today's shells; duo-support.md PR 11 owns the next revision of that section.

"The FU catalogue" is [`docs/1.x/platform-conditionals-followups.md`](../platform-conditionals-followups.md), which came into the repo with these plans: one entry per platform `#if` left in shared Apple code, grouped as FU-1 to FU-19. It was written for 3.2 G's ratchet, after you answered "Ratchet, but let's document the rest for follow-up work" (the maintainer, 2026-10-09).

## Decisions for the maintainer

1. **May the session make the GitHub writes itself?** These are: close #1912, #1915, #1970, #1995 and #1996, with an evidence comment on each; and replace the iPad paragraph in the published 1.31.0 release text. **Yes (recommended)** / Closes only / No. Yes means the open-issue list and the release page are correct the same day. No means the session posts the evidence and the corrected paragraph, and you close the issues and paste the paragraph. Default: No.
2. **When must a Lambda change reach prod, compared with the client change that needs it?** **(a) Prod first (recommended).** A client change that relies on a server change merges to `stage` only after that server change has been promoted, unless the client works unchanged without it. (b) Stage first: the server change reaches `stage` before the client change, or with it. This is how `00-working-agreements.md` records the rule. Why it matters: stage TestFlight builds are used against prod. The sticky-feed-order rollout you accepted used (a): "PR 2 merged and promoted to prod before PR 3 merges to stage (a TestFlight build from stage talks to prod)". sqlite-mail-store.md's rule 6 assumes (a) as well. The cost of (a) is that a feature needing a new endpoint takes two releases. Default: (a).
3. **Where should the FU catalogue live?** **(a) In `docs/1.x/platform-conditionals-followups.md`, added now with a Progress table and linked from `docs/apple.md`, `CLAUDE.md:91` and the allowlist header (recommended).** (b) A GitHub issue with the 19-row summary. (c) platform-conditionals.md's first session adds it as its own plan doc. With (a), the notes for every block outlive the rearchitecture project's folder, which a new project cannot read. The 3.2 brief asked for this pointer, and PR #2012 left it out. With (c), the catalogue stays out of the repo until that session starts. Default: (a).
   - **Answered 2026-10-15: (a).** The catalogue is at `docs/1.x/platform-conditionals-followups.md`, added with its header and Progress table by the change that added `docs/1.x/post-wave-3/`. The links to it from `docs/apple.md` "Platform conditionals", `CLAUDE.md` and the header of `apple/platform-conditionals-allowlist.txt` are still PR 2's.
4. **Answer before the rearchitecture project closes: should there be a public pointer to the 21 post-Wave 3 plans?** (a) None. Each plan becomes a `docs/1.x` plan doc when its work starts, the way `cross-media-ux-plan.md` did. **(b) One short index, `docs/1.x/apple-post-wave-3.md`, with one line per workstream (name, goal, priority, vehicle). The plans themselves stay in the rearchitecture project's folder (recommended).** (c) All 21 plans go into `docs/1.x`, scrubbed. GitHub Pages publishes `docs/` at www.cabalmail.com. Option (b) leaves a public record of the deferred work without adding 21 documents that would start to go stale. Option (c) publishes rig and account details that would first need scrubbing. Default: (a), because publishing needs your yes.
   - **Answered 2026-10-15: (c).** The maintainer chose to commit all the plans, scrubbed and self-contained, under `docs/1.x`. They are in `docs/1.x/post-wave-3/`, and that folder's `README.md` is the index, so PR 2's separate index page is no longer needed.

These are not asked again. The session records them as decided in `docs/apple.md`. Each one merged after its PR stated it and asked for objections, and you approved each PR without comment:
- #2011 kept the cross-device check on each main window's own foreground transition, because only a main window can show the offer. Windows that come forward together still ask only once.
- #2006 ends a leftover search when you widen from a tab other than Search. The PR said: "Say if you'd rather the leftover search survive."
- #2012 reports a stale allowlist row as a warning rather than a failure. That was the brief's own rule.

If you disagree with any of them, say so, and the session files an issue for the plan that owns that area. The #2006 Settings-sheet question is multi-window-and-restore.md's decision 1, not this plan's.

## What you'll see change

- **PR 1 (docs only).** The 1.31.0 entry in `CHANGELOG.md` will say that the arrow keys move the selection, while Home, End, Page Up and Page Down scroll the iPad list and leave the selection alone. If decision 1 is Yes, the GitHub release page will match. `docs/compatibility.md` gains the rule for changing an endpoint. Nothing changes in the apps.
- **PR 2 (docs only).** `docs/apple.md` stops describing the IMAP-era cache, the old `TabView` shell, a six-category Settings and outbox entries that get dropped. The FU catalogue appears in `docs/1.x`. The cross-media plan shows Phase 1 as shipped. If decision 4 is (b), the index page appears. Nothing changes in the apps.

  > **Erratum (2026-10-15):** The FU catalogue is already in `docs/1.x` (decision 3, answered), and decision 4 was answered (c), so no index page comes with PR 2. PR 2 still makes the `docs/apple.md` changes, links the catalogue and updates the cross-media plan.

- **PR 3 (Apple comments, `no-changelog`).** Nothing visible. This still matters: audit 01 F16 (in the rearchitecture's 2026-10-02 mail audit: cross-file doc comments drift from the code) found that wrong comments mislead you more than missing ones.
- **Issues.** Five fixed issues close. Two issues that already closed (#1896 and #2022) get a pointer to the open issues that carry their leftovers.
- **Your checklist (no code).** Stale branches, refs, build folders and leftovers go from the Studio and the Mini.

## Why

- **The published notes say something the code does not do.** `CHANGELOG.md:55-57` says a hardware keyboard "moves the selection with the arrow keys, Home and End, and Page Up and Page Down". The code scrolls. See `MessageListView+Selection.swift:138-139` ("leaving the selection where it is (a scroll, not a move)") and `:149-150` ("PgUp / PgDown scroll the list ... leaving the selection where it is"). The Wave 3 TestFlight checklist asked for this to be fixed before the release. It was not fixed: #2043 merged the text unchanged, release 1.31.0 was published with it (2026-10-12 11:33Z), and the prod TestFlight uploads on that merge succeeded. `release.yml` skips a version that already has a release (`release.yml:52-53`), so a repo fix alone does not change the release page.
- **The API rule exists only in the rearchitecture project's records and the working agreements.** The maintainer set the rule on 2026-10-02, during the rearchitecture's architecture audit. `00-working-agreements.md` records it as: "Lambda changes stay additive (new endpoints, optional request fields, new response fields). A removal or rename gets a sibling endpoint named `<name>_v2`, not a `/v2` tree. Shipped Apple and Android builds keep working. A server change ships to `stage` before or with the client that needs it." `docs/compatibility.md` defines breaking changes (:50-57) and deprecation (:123-130), but says nothing about `_v2` siblings or the order of deploys. A grep of `docs/` and `CLAUDE.md` finds neither. Six post-Wave 3 plans change Lambdas.

  > **Erratum (2026-10-15):** The working agreements are now in the repo at `docs/1.x/post-wave-3/00-working-agreements.md`, so a grep of `docs/` now finds the rule there and in these plans. `docs/compatibility.md` and `CLAUDE.md` still say nothing about it; PR 1 adds it there.

- **The FU catalogue exists only in the rearchitecture project's folder.** The 3.2 brief asked for "a pointer to the follow-up workstreams" in `docs/apple.md` and `CLAUDE.md`. PR #2012 said: "Nothing in the repository or on GitHub tracks FU-1 to FU-19 yet". The checker still finds 55 files and 141 blocks at 50e6022.

  > **Erratum (2026-10-15):** The catalogue is now in the repo at `docs/1.x/platform-conditionals-followups.md`, added with these plans. The pointers the 3.2 brief asked for in `docs/apple.md` and `CLAUDE.md` are still missing; PR 2 adds them.

- **Several sections of `docs/apple.md` describe code that no longer exists** (see below). **One plan's progress table is out of date:** `docs/1.x/cross-media-ux-plan.md:11` and `:215` still say "In review (2026-09-24)", but both clients shipped Phase 1 in 1.22.0 (`CHANGELOG.md:1083` onward).
- **Fixed issues are still open,** so anyone triaging, and the release dashboard, see them as live bugs.

## Where things stand

**Release.** `main` and `stage` are both at 1.31.0 (merge `b796cf50`; `stage` at `50e6022`, with no commits ahead of `main` on 2026-10-13). No release PR is open.

> **Erratum (2026-10-15):** Since then `main` has released 1.31.1 (PR #2052, 2026-10-13) and 1.31.2 (PR #2055, dated 2026-10-14), and `stage` is at `5a56ce2`, ahead of `main` with hardening PRs 2 and 3 (#2056, #2057) and dependabot bumps (#2044 to #2048). The 1.31.0 iPad keys paragraph in `CHANGELOG.md` is still uncorrected; with the 1.31.1 and 1.31.2 sections above it, it is now at `CHANGELOG.md:85-86`.

**Issues (GitHub, read 2026-10-13):**

| Issue | State | Fix | Action |
|---|---|---|---|
| #1912 back-out at launch re-lands in INBOX | open | `a587e8b6`, first in 1.29.0 | Close. The tester wrote "the close is yours" (2026-10-07) |
| #1915 New Folder sheet shows no error | open | `36d252a7`, first in 1.29.0 | Close, same note |
| #1970, #1995, #1996 tab-shell search; visionOS Message menu | open | `c1d88c23` (PR #2006, "Fixes #1970, #1989, #1995 and #1996"), first in 1.31.0 | Close by hand. A PR into `stage` closes nothing, and the commit has no keyword |
| #1896 list scroll on relaunch | closed by the merge | `1b5830c1` "Fixes #1896" | Comment: the leftovers are #2030 and #2042 (both open) |
| #2022 email keyboard for rule addresses | closed by the merge | `f494bf31` "Fixes #2022" | Comment: the Gboard leftover is #2038 (open) |
| #1966 window after a notification launch | closed by the merge | `5035e28b` | Nothing |

A scan of the commit messages in 1.29.0 to 1.31.0 finds no other open issue they name, apart from #1962 (see "Not in this plan").

**`docs/apple.md` drift this plan fixes.** apple-ci-and-build-config.md PR B rewrites the CI sections (:422, :702-716) and `:1074`.
- :89 says "Launch in the simulator and see 'Hello, Cabalmail'". The app now opens on sign-in.
- :1286-1288: envelopes are "keyed by UIDVALIDITY, the reconnect flow (`STATUS` + UID FETCH since UIDNEXT) drops straight onto this". That describes the IMAP era. Envelopes now refresh through the Lambda API's windowed pages (compare :1185-1194).
- :1333 names `Compose/Resources/`. The directory is `Compose/WebAssets/` (`apple/.gitignore:26-29`).
- :1449-1456, "Signed-in navigation: `TabView(.sidebarAdaptable)`", predates the four shells described in the folder guide (:1027). `TabShell.swift:5-8` says "No `.sidebarAdaptable`".
- :1471-1514 lists 6 Settings categories. `SettingsView.swift:78-79` has 10, adding Rules, Flags, Notifications and Diagnostics. visionOS has no Notifications category (:87-92).
- :1557-1559 says "`maxAttempts = 10` before an entry is dropped". The entry is not dropped: it stays in the outbox marked failed and is offered back (`SendQueue.swift:26-28`; `docs/apple.md:1268-1270` already says so).
- :1053-1101, "Platform conditionals", has no pointer to the catalogue.

**Stale comments this plan fixes.** Line numbers are at 50e6022.
- `MailRootView` was deleted in 3.2 E (PR #2008). It is still named at `Commands/FeedMenuAvailability.swift:71, 90, 103`, `Commands/MailboxMenuAvailability.swift:23` and `Navigation/NavStateCoordinator+Session.swift:12`. Where a comment means "a mail tree", the replacement is `WideMail` (through `DesktopShell` or `SplitShell`), `CompactMailStack` or `OrnamentShell` (PR #2008 body). The notes at `SceneNavigatorLandingTests.swift:7` and `SceneNavigatorRebuildTests.swift:8` say the rules "lived" on `MailRootView`, which is accurate history, so they stay.
- `MessageListView.swift:477` says of the search model "Every window shares it". Each window has its own (`SceneNavigator.swift:674-680`: "each window keeps its own query and results; shared by the window's layout trees").
- `MessageBodyCache.swift:45` says "Called from `MessageListViewModel.dispose` after a successful `UID MOVE`". That is no longer true. A confirmed removal goes through `CabalmailClient.forgetRemovedMessages` (`CabalmailClient+Bodies.swift:62-73`, called from `MailMutationService.swift:251`), and the refresh and reconcile prunes call it too (`WindowRefresher.swift:283`, `WindowReconciler.swift:216`). The new comment should describe the contract ("drops a body once its message is confirmed gone") without naming app types.
- `EnvelopeCache.swift:3-10`, the type's header, describes the "Phase 3 flow" (STATUS, then UID FETCH from the last-seen UIDNEXT). Like `docs/apple.md:1286-1288`, it predates the Lambda path.
- `RssSyncEngine.swift:35-36` lists "background refresh" and "reconnect" among the app's triggers. Neither exists today: there is no `BGTaskScheduler` in `apple/`, and refresh-scheduling.md says "Reconnect does nothing". refresh-scheduling.md PR 3 plans to add the reconnect trigger.

## The plan

**Setup.** Work on `stage`. No Swift toolchain is needed, and only PR 3 runs Apple CI. Before each PR, list the open PRs that touch its files, and keep one open PR per file. Shared files:
- `docs/apple.md` and `CLAUDE.md`: apple-ci-and-build-config.md PR B (which also edits `CLAUDE.md:91`), duo-support.md PR 7, multi-window-and-restore.md, swift6-and-strict-checking.md A4, hardening-web-and-writes.md and kit-split.md.

  > **Erratum (2026-10-16):** duo-support.md's `docs/apple.md` work is its PR 11 (Duo docs); its PR 7 is compose as a sheet. Read PR 11 where this hotspot list says PR 7 for `docs/apple.md`. At `5a56ce2` `CLAUDE.md:91` is the "Platform conditionals" bullet under "Build/Lint/Test Commands" > "Apple Clients". The change that added `docs/1.x/post-wave-3/` put two lines above it, so from then on it is at `:93`. Find it by that content, not by the number.

- `MessageListView.swift`: multi-window-and-restore.md R4 and R6, sqlite-mail-store.md Phase 3 (which took mail-navigation-refactors.md's old PR 5), ipad-layout-and-keyboard.md PR C.
- `Cache/*.swift`: sqlite-mail-store.md PR 0.3 (#1871).
- `Commands/*`: ipad-layout-and-keyboard.md and multi-window-and-restore.md.
- No Kit edit while kit-split.md's freeze (its PRs C and D) is on.

If a release PR is open, every merge to `stage` re-runs its whole suite. In that case, land the docs PRs back to back or wait for the release.

**PR 1. Released notes and the API rule (docs only).**
- `CHANGELOG.md:55-57`: say that the arrow keys move the selection, while Home, End, Page Up and Page Down scroll the list and leave the selection alone. Reflow to the house wrap and change nothing else. No fragment is needed, because this corrects a released section; the PR body says so.
- `docs/compatibility.md`: add a "Changing an endpoint" subsection under "1. HTTP API" (:40-57). Draft, using decision 2 (a): "Shipped Apple and Android builds call the API long after their release; the React app deploys with it. So the API changes additively: a new endpoint, a new optional request field or a new response field can ship in any release. A rename, a removal, or a change to a field's type or meaning ships as a sibling endpoint named `<name>_v2` (for example `rss_mark_all_read_v2`), never as a `/v2/` path tree. The original keeps serving shipped clients until the deprecation policy below retires it. A server change reaches production before a client change that relies on it merges to `stage`, because test builds from `stage` may sign in to a production deployment. A client change that works unchanged without the server change may ship with it." With (b), the last two sentences become "A server change reaches `stage` before, or together with, the client change that needs it."
- `CLAUDE.md`: add one sentence to "Lambda Functions (`lambda/api/`)" (:188-198) that points to the new subsection.
- After the merge, if decision 1 is Yes, run `gh release edit 1.31.0 --notes-file` with the output of `bash .github/scripts/changelog-section.sh 1.31.0` from `stage`. The 1.31.0 TestFlight "What to Test" text was set per build at upload; leave it.
- Check: run `changelog-section.sh 1.31.0` and read the rendered diff. Risk: none. The tooling reads only the top version header.

**Status:** Not started (2026-10-15). The 1.31.0 iPad keys paragraph is still uncorrected, now at `CHANGELOG.md:85-86`.

**PR 2. Apple docs and the catalogue (docs only).**
- `docs/apple.md`: fix the six drift sites above. Write the Settings list from the `Settings/` code. Replace :1449-1456 with two sentences that point to the shells in the folder guide. Record the three merged defaults where a section fits. Link the catalogue from "Platform conditionals".
- With decision 3 (a), add `docs/1.x/platform-conditionals-followups.md`. Copy the catalogue and make these changes:
  - Add a header saying it was written 2026-10-09 at `5a70043`, that its line numbers have drifted, and that blocks are matched by condition text after re-running `python3 scripts/check-platform-conditionals.py` (55 files and 141 blocks at 50e6022).
  - Add a `## Progress` table. Seed it with the block counts at 50e6022 from platform-conditionals.md's "What each FU holds". FU-17 is "parked until Rules is next touched". FU-19 "waits on dropping Xcode 26".
  - Replace the maintainer's first name with "the owner", and remove the links to project-only files.
  - Add the path to `CLAUDE.md:91` and to the header of `apple/platform-conditionals-allowlist.txt`. That header is a text file, not Apple source, so no Apple gate fires.

    > **Erratum (2026-10-16):** At `5a56ce2` `CLAUDE.md:91` is the "Platform conditionals" bullet under "Build/Lint/Test Commands" > "Apple Clients". The change that added `docs/1.x/post-wave-3/` put two lines above it, so from then on it is at `:93`. Find it by that content, not by the number. Decision 3 means the same bullet.

  - Merge it before platform-conditionals.md opens its FU-1 PR. Its Rules PRs (#2031, #2040) do not need it.

  > **Erratum (2026-10-15):** The copy is done, by the change that added `docs/1.x/post-wave-3/`: the catalogue is at `docs/1.x/platform-conditionals-followups.md` with the header and Progress table above, and it says "the maintainer" where this step said "the owner". Adding its path to `CLAUDE.md:91` and to the header of `apple/platform-conditionals-allowlist.txt`, and linking it from `docs/apple.md` "Platform conditionals", are still PR 2's.

- `docs/1.x/cross-media-ux-plan.md:11, 215`: Phase 1 becomes "Shipped in 1.22.0 (2026-09-25)". Say plainly that no stage or device verification was recorded (inferred from the plan text). flags-and-cross-media.md A0 checks this and does it only if this plan has not.
- With decision 4 (b), add the index page: one line per workstream, no names, no rigs. If you have retired the detached reader window by then (detached-reader-window.md decision 1 (b)), the page records that in one line.

  > **Erratum (2026-10-15):** Decision 4 was answered (c): every plan is in `docs/1.x/post-wave-3/`, and that folder's `README.md`, added by the same change, is the index. This page is not needed.

- Optional, last: update the "In review" rows in `color-tokens-plan.md` (:3, :19), `resume-session-plan.md` (:109, :188, :250) and `rss-implementation-plan.md` (:30, :1336, :1432, :1467, :1668), but only where a released `CHANGELOG.md` section names that work. List the rest in the PR body.
- Check: read each changed section rendered on GitHub. Grep the diff for the maintainer's first name, personal names, `/Users/`, production addresses, account names and hostnames. Risk: low.

**Status:** Partly done (2026-10-15). The catalogue and the folder index came in with the change that added `docs/1.x/post-wave-3/` (see the errata above). The `docs/apple.md` fixes, the catalogue links from `docs/apple.md`, `CLAUDE.md` and the allowlist header, the cross-media plan update and the optional "In review" updates are not started.

**PR 3. Stale comments (Apple sources, `no-changelog`).**
- Scope: the comment sites listed under "Where things stand". For `RssSyncEngine`, list only the triggers that exist when the PR is written. If refresh-scheduling.md PR 3 has merged, "reconnect" stays.
- Why a sweep now: 3.2 left the `MailRootView` comments "as agreed", to be updated "only if a later PR touches those lines". That rule kept comment churn out of structural PRs during the wave. The wave is over, the rearchitecture project has closed, and most of these files have no planned edit. Where a sibling plan already holds the file, the next-change rule still applies:
  - The "(hold Cmd)" comment goes to ipad-layout-and-keyboard.md PR C.
  - The `replace` comment at `EnvelopeCache.swift:207` goes with sqlite-mail-store.md PR 2.1.
  - The two navigator files go to mail-navigation-refactors.md.
  - If a sibling PR is open on any other file here when PR 3 opens, leave that file's comment to it, and say so on that PR.
- Read these before editing `MessageListView.swift`, and add or remove no anchor string: `LaunchRestoreSequencingSourceScanTests` (it counts `applyPendingRestoreWhenReady()`, comments included), `MessageListRefreshRoutingTests` (anchors on `} else if !isSearchScope {`), `CompactBrandMarkSourceScanTests`, `SwipeActionContainerSourceScanTests` and `ToolbarVisibilitySourceScanTests`.
- Label: `no-changelog`. A comment in Kit `Sources` trips `apple-changelog.yml` otherwise.
- Check: the PR's `apple-gate` run (SwiftLint and the Kit and app suites). The checker still prints 55 files and 141 blocks. `git grep -w MailRootView -- apple` finds only `SceneNavigator.swift`, `FeedNavigationState.swift` and the two test history notes. Risk: very low.

**Status:** Not started (2026-10-15).

**Issue bookkeeping (at the start).** Close #1912, #1915, #1970, #1995 and #1996 if decision 1 allows it; otherwise post the evidence and leave the close to the maintainer. Each comment names the fixing commit and the first release that has it. Add the leftover pointers on #1896 and #2022. Write each paragraph as one line, with no PII (CLAUDE.md).

**Status:** Not started (2026-10-15). #1912, #1915, #1970, #1995 and #1996 are still open.

**The maintainer's checklist (no code; the session touches no rig).** The counts come from the Studio cleanup report of 2026-10-11 (written in the rearchitecture project and not in the repo; the steps below state what they use from it), so re-list before deleting anything. A Remote Control session on the Studio can run the git and `simctl` steps if you ask; the System Settings steps are yours. Run it when no other session is using the Studio.
1. **Merged branches.** In the Studio's checkout, run `git fetch --prune`. The report counted 252 merged branches with no worktree (135 `claude/*`, 103 `worktree-bridge-*`, 2 `worktree-agent-*`, 8 `local/*` and 4 `ws23-*`) and called its list checked; the list itself is not in the report. Six of them merged only through PRs into `duo` or `swipe`, so an ancestor test must check `origin/duo` and `origin/swipe` as well as `origin/stage` and `origin/main`. Leave out `main`, `stage` and `development`, any branch checked out in a worktree (the report names `main` in the main checkout and `claude/project-thread-1893da` in the Layout shells worktree), and the Duo keep-list in step 3. Then run `git branch -D` on the reviewed list.
2. **Unmerged branches.** Delete the five that are patch-identical to merged work: `local/3.2-b`, `local/3.2-b-on-stage`, `local/3.2-c`, `local/pr-3.2-g` and `claude/unread-filter-large-folders`. The report calls them "Safe to delete on your word". The eleven 3.2 D to G draft stacks (`local/3.2-d`, `local/3.2-d-draft`, `local/3.2-d-handoff`, `local/3.2-e`, `local/3.2-e-draft`, `local/3.2-f`, `local/3.2-g`, `local/3.2-stack`, `local/3.2-stack2`, `local/pr-3.2-f` and `local/stack-3.2`) are your call: the report says they are "Not patch-identical to what merged". `git log --cherry-pick --right-only origin/stage...<branch>` shows what each holds. `claude/os27-swipe-proto` (an unpushed spike) and `claude/os27-adoption-notes` (PR #864 closed unmerged) are also your call.
3. **Duo items wait.** Keep `duo`, `tmp/duo-test-build`, `claude/duo-fold-diag`, the rescue refs `5d0ff1aa8`, `7c34d7497` and `a5cdc73ac`, and the stage copy of the iPhone Duo simulator (the one named for stage commit `e87fd419`) until duo-support.md's Session 1 hands you its delete list.
4. **Other rescue refs.** Do not use the report's drop command (it pipes every ref under `refs/rescue` to `git update-ref -d`): it deletes all 21 refs, the Duo ones included. For the 18 others, run `git cherry origin/stage <ref>`. A `+` line marks a commit that is on no branch. The report says 17 of the parked commits are on GitHub nowhere, and its list includes August fixes, so look at those before deleting. The trial-merge tips the report marks "not for pushing" (`279b7c6ab`, `359c56a36` and `dba0d3c2e`) need no check. Then run `git for-each-ref --format='%(refname)' refs/rescue | grep -v -e 5d0ff1aa8 -e 7c34d7497 -e a5cdc73ac | xargs -n1 git update-ref -d`.
5. **Stash.** Run `git stash show -p stash@{0}` (2026-07-25, +5 lines in `terraform/infra/modules/ecs/outputs.tf`), then apply it or drop it.
6. **Main checkout.** It is on `main`, 2,155 commits behind. Switch it to `stage` and fast-forward.
7. **Worktrees.** In the Layout shells worktree (the one on `claude/project-thread-1893da`), delete `apple/.dd-sim-27`, `.dd-sim-27-xr`, `.dd-sim-271` and `.derivedData-sim` (6.4 GB together), then `git worktree remove` it. Remove two more of the session worktrees the report left (the one detached at the stage tip, and the clean one whose tip is in `main`, idle since 2026-10-07) once no session uses them.
8. **Notification entry.** In System Settings > Notifications on the Studio, remove "Cabal33Probe" or turn it off (a throwaway test build left it; leave the Cabalmail entry alone).
9. **The Mini.** Remove the eight stale "Cabalmail" Safari extensions left by old builds. `pluginkit -m -v -p com.apple.Safari.web-extension` lists them with their paths, and deleting those old app copies should remove them (inferred). Look for leftover worktrees and build folders there too, since the Mini's state after 2026-10-11 is unknown.

**Status:** Not started (2026-10-15).

## How to start it

Best: run it as the rearchitecture project's last thread before it closes.

> **Erratum (2026-10-15):** The project is retiring after hardening, so this plan runs as a fresh Claude Code session from this repo copy, not as the project's last thread. What it needed from the project's records is stated in the plan.

Otherwise, open one Claude Code session on `cabal-infra`. It reads this plan and `00-working-agreements.md` from `docs/1.x/post-wave-3/`, plus repo files and GitHub items. The catalogue PR 2 needs is already in the repo at `docs/1.x/platform-conditionals-followups.md`, and the checklist states what it uses from the Studio cleanup report. Paste:

> Run the plan "Docs, stale comments and issue bookkeeping" (`docs/1.x/post-wave-3/docs-and-bookkeeping.md`) on current `stage`. Post the plan's four decisions in one message, quoted in full with the recommended answers, plus the "not asked again" list, and one line per PR saying what the maintainer will see. Where the maintainer leaves a decision open, use its default and say so in the PR body. Re-check every file:line before editing. Do the issue bookkeeping first, as decision 1 allows. Then open PR 1, PR 2 and PR 3 in order, one at a time, checking open PRs on the shared files first. Edit no source-scan anchor or expected text. Post nothing to GitHub with hard-wrapped paragraphs or PII. Do not touch the Studio or the Mini; end by giving the maintainer the checklist, updated with anything you learned.

> **Erratum (2026-10-15):** Decisions 3 and 4 were answered on 2026-10-15 (see "Decisions for the maintainer"), so the session posts them as answered and only 1 and 2 remain open.

## Risks and checks

- **Publishing project detail.** The catalogue and the index page go public. Check: before pushing, grep for the maintainer's first name, personal names, thread ids, `/Users/`, account names and hostnames.
- **The API rule could read as stricter than the major-version promise.** It is not: it describes how a rename ships inside a major version. Check: the subsection points to the deprecation policy rather than restating it.
- **Hotspot collisions.** Check the open PRs before each PR (see Setup).
- **A close can hide a leftover.** Check: every close or pointer comment names the open issue that carries the rest.
- **Wrong "In review" updates.** Check: update only rows that a released section names.
- **The checklist deletes something needed.** The two fixes above (keep the Duo refs; the eleven stacks are your call) close the two gaps found in review. Check: re-list everything before deleting.

## Not in this plan

- **#1985's close** goes to ipad-layout-and-keyboard.md (its decision 5, once its PR A for #2032 has merged and the iPad checks pass). live-verification.md no longer hands it here.
- **#1962's close and the triage of the Duo refs** go to duo-support.md (its Session 2 closes #1962 after a pass on the device).
- **The "(hold Cmd)" comment** (`CabalmailApp.swift:65-68`) goes to ipad-layout-and-keyboard.md PR C. That PR owns the file, and #2025's close asked for the fix "with the next change to that file". The facts it needs come from #2025's comments: holding Command shows shortcuts only on iPadOS 18 and earlier. On iPadOS 26 and later the commands sit in the menu bar, opened from the top edge or the app's name.
- **The comment at `EnvelopeCache.swift:207`:** `replace` has no production caller, and sqlite-mail-store.md PR 2.1 deletes it.
- **The `MailRootView` comments in `SceneNavigator.swift` (4) and `FeedNavigationState.swift` (1)** go to mail-navigation-refactors.md. So does the `SplitShell` width write (its PR 2, decision 2). Renaming `layoutIsWide` was declined there, because 3.2 kept the name.
- **The three "Tracked in #1826" pins** go to account-isolation.md. **The deleted `requestCompose()` comment and the Mac mailto comment** go to multi-window-and-restore.md W2.
- **The CI sections of `docs/apple.md`, `:1074`, the release dashboard and making `apple-gate` required** go to apple-ci-and-build-config.md.
- **The Room-version erratum in `cross-media-ux-plan.md:306-311, 467`** goes to android-parity.md PR 9. The claim becomes false only when that PR takes Room version 2, so the erratum belongs in the same PR.
- **The `SpotlightRouting.swift` comments** (`AppDelegate.swift:113`, `AppRootLifecycle.swift:65`), which flags-and-cross-media.md hands here, need no fix. The file exists at `apple/CabalmailUI/Navigation/SpotlightRouting.swift`, and both comments are accurate.
- **The FU burn-down and the stricter `canImport` check** go to platform-conditionals.md. **Live re-checks of fixes cleared on tests** go to live-verification.md.
- **Not pursued:**
  - Your full name as sample data (a Settings footer, a Kit test, a React test and two mocks). It is your own name, already in `apple/LICENSE` and on every commit, so replacing it hides nothing. If you want it gone, that is a five-file change with an `Apple:` fragment.
  - Listing every Lambda in `CLAUDE.md`'s table, which names 24 of the 77.
  - The Safari private-link History check, which you declined on 2026-10-06.
  - Errata for the rearchitecture project's shipped scope docs, which are historical and not in the repo.

## Sources

- Repo at 50e6022:
  - `CHANGELOG.md:8, 55-57, 1083`
  - `apple/CabalmailUI/Mail/MessageList/MessageListView+Selection.swift:138-150`
  - `docs/apple.md:89, 422, 702-716, 1027, 1053-1101, 1185-1194, 1268-1270, 1286-1288, 1333, 1449-1456, 1471-1514, 1557-1559`
  - `docs/compatibility.md:21-57, 123-142`
  - `CLAUDE.md:91, 188-219`
  - `docs/1.x/cross-media-ux-plan.md:9-17, 211-223, 304-311, 465-468`, and the "In review" lines named in PR 2
  - `apple/CabalmailUI/Settings/SettingsView.swift:77-92`
  - `apple/CabalmailKit/Sources/CabalmailKit/Outbox/SendQueue.swift:26-28` and `Outbox/Outbox.swift:68`
  - `apple/CabalmailUI/Shell/TabShell.swift:5-8` and `apple/.gitignore:26-29`
  - `apple/CabalmailUI/Navigation/SceneNavigator.swift:674-689`
  - The comment sites listed above, plus `CabalmailClient+Bodies.swift:62-73`, `MailMutationService.swift:251`, `WindowRefresher.swift:283` and `WindowReconciler.swift:216`
  - `apple/CabalmailUI/Navigation/SpotlightRouting.swift:1-15`
  - The five `MessageListView.swift` scans
  - `apple/platform-conditionals-allowlist.txt:1-11` and the checker output (55 files, 141 blocks)
  - `.github/workflows/release.yml:18-21, 52-53, 63` and `.github/scripts/set-testflight-notes.py:11-19`
  - `docs/CNAME`
- Git: `git tag --contains` for `a587e8b6` and `36d252a7` (1.29.0) and for `c1d88c23`, `1b5830c1`, `5035e28b` and `f494bf31` (1.31.0); the bodies of those commits.
- GitHub, read 2026-10-13:
  - #2043 merged 2026-10-12 11:33Z.
  - Release 1.31.0 published 11:33:31Z with the old paragraph. That merge ran the Apple TestFlight uploads and a Pages build.
  - #1896, #1966 and #2022 closed by the merge.
  - Open: #1912, #1915, #1962, #1970, #1985, #1995, #1996, #2030, #2032, #2038 and #2042.
  - #2025 closed not planned, with its comments. #1826 closed.
  - PR bodies: #2006, #2011 and #2012. PR #864 closed unmerged.
- In this folder and beside it: `00-working-agreements.md` (the API rule) and the FU catalogue, `../platform-conditionals-followups.md`.
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo. Those records could not be read on 2026-10-13 (I/O error), so the plan's use of them came from its 2026-10-12 draft and that draft's fact-check. For this repo copy (2026-10-15), the passages it states from the 3.2 scope doc, audit 01, the Wave 3 TestFlight checklist, the sticky-feed-order plan and the Studio cleanup report were read again; the thread quotes were not re-checked.
- Sibling plans read for hand-offs: sibling plans in this folder, live-verification.md included.
