# Post-Wave 3 plans

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Each plan's repo line numbers are as of the commit named under its "Written" line; re-check them before starting.

This folder holds one plan per workstream left after the 2026-10 rearchitecture of the Apple clients (Waves 0.1 to 3.3, all merged and soaked by release 1.31.0). Every plan assumes [`00-working-agreements.md`](00-working-agreements.md). The FU-1 to FU-19 catalogue of platform `#if` blocks is [`../platform-conditionals-followups.md`](../platform-conditionals-followups.md).

Written 2026-10-13 at the close of the Cabalmail Client Architecture project. There are 21 plans, one per workstream, plus `00-working-agreements.md`, which every plan assumes. They were written against `stage` at `50e6022` (release 1.31.0, promoted when #2043 merged on 2026-10-12). Since then, `stage` has gained only #2049, the fix for listing a very large folder, which changes no plan.

> **Erratum (2026-10-15):** By 2026-10-15 `stage` had also gained #2051, hardening PRs 1, 6, 2 and 3 (#2053, #2054, #2056, #2057) and dependabot bumps #2044 to #2048, and `main` had released 1.31.1 and 1.31.2. The hardening PRs change the hardening plan's status and the `HTMLBodyView.swift` call below; see "Where things stand".

## Where things stand (2026-10-16)

- **Released since the plans were written.** 1.31.1 (PR #2052, 2026-10-13) shipped #2049 (the Lambda API accepts IMAP lines up to 10 MB, so a folder of about 140,000 messages lists again) and #2051 (certificate renewal runs daily). 1.31.2 (PR #2055, dated 2026-10-14) shipped hardening PR 1 (#2053, `5eb7284`, "Apple: composer keeps only formatting from content it did not write") and hardening PR 6 (#2054, `c467789`, "API: /new folds case and answers clearly for an existing address").
- **Hardening Session A is under way.** Merged to `stage` and not yet released: PR 2 (#2056, `5046716`, "Apple: feed reader mode runs no script from the article", the fix for #1911) and PR 3 (#2057, `f078467`, "Apple: reader bridges run in the app's own script world"), plus dependabot bumps #2044 to #2048; `stage` is at `5a56ce2`. #1911 is still open; it closes after a reader check on the Mini and your check of the stage TestFlight build on iPhone. PR 6's stage proof waits on you running a proof script on the Mini as test accounts 2 and 3, the two that the rig's credential helper serves. If Session A does not finish these, the plan's "Session A remainder" brief picks them up. Session A recorded decision 1 as private (2026-10-13) and took decisions 2, 3, 6 and 7 on their recommended answers. PR 3 extracted nothing from `HTMLBodyView.swift` (see the erratum under "Calls made here"). Session B (PRs 4 and 5) has not started, and neither has android-parity.md PR 1, the Android twin of #1911 that the hardening plan wanted in PR 2's release.
- **docs-and-bookkeeping.md.** Its decision 4 was answered on 2026-10-15: all the plans go into the repo, scrubbed, here in `docs/1.x/post-wave-3/` (its option (c), with this README as the index, so PR 2's separate index page is no longer needed). Under decision 3 the FU catalogue lands at `docs/1.x/platform-conditionals-followups.md` in the same change (its default (a)); the links to it from `docs/apple.md` "Platform conditionals", `CLAUDE.md` and the header of `apple/platform-conditionals-allowlist.txt` are still PR 2's. Decisions 1 and 2 are unanswered. Issues #1912, #1915, #1970, #1995 and #1996 are still open, and the 1.31.0 iPad keys paragraph in `CHANGELOG.md` (now at `CHANGELOG.md:85-86`) is still uncorrected. The project is retiring after hardening, so this plan runs as a fresh session from its repo copy, not as the project's last thread.
- **Nothing else has started.** No merged or open PR on `stage` since `50e6022` belongs to any other plan (checked against the `stage` log and the open PR list on 2026-10-15).
- **New since the plans: #2050.** Opened 2026-10-13 and labelled `needs-verification`: one prod `/list_envelopes` call returned 502 because `helper.envelope_dict` calls `.decode()` on a `None` header-fields value when Dovecot returns the key with a NIL value; the issue suggests `(data.get(...) or b'')`. No plan covers it. It sits beside mail-correctness.md's #1990, another `list_envelopes` 502.

## What you decided, and what I need from you now

On 2026-10-13 you endorsed the three calls this section asked for:

1. **Hardening comes next, handled privately.** hardening-web-and-writes.md Session A starts now. The composer and `/new` mechanisms stay out of issues, PRs, commit messages, changelogs and public forums until the fixes are on prod (its decision 1, answered). android-parity.md PR 1 is the Android twin of #1911.
2. **The release order for the days before the Duo ships (about 2026-10-23):**
   - **1.32: security and regressions.** Hardening Session A (PRs 1, 2 and 6, plus android-parity PR 1), ipad-layout-and-keyboard.md Session 1 (the three Wave 3 iPad regressions now on prod), mail-correctness.md release A, and any small Now fixes that are ready (feed-bulk-actions.md PR A, platform-conditionals.md's two Rules PRs). If it fills slowly, promote the hardening PRs on their own first.

     > **Erratum (2026-10-15):** Hardening PRs 1 and 6 did not wait for 1.32: they shipped on their own in release 1.31.2 (PR #2055, dated 2026-10-14), as #2053 and #2054. PR 2 (#2056) and PR 3 (#2057) are merged to `stage` and not yet released, and android-parity.md PR 1 has not started.

   - **1.33: duo-support.md R1**, your Oct 7 Duo spec built on the Wave 3 shells, cut to what has merged (see below), with whatever bug fixes are ready.
   - **After the Duo ships:** duo R2, sqlite-mail-store.md Phase 0, apple-ci-and-build-config.md PR C and mail-correctness.md release B, one structural change per release.
3. **docs-and-bookkeeping.md is the rearchitecture project's last thread,** unless better counsel turns up first. It moves the API change rule and the FU-1 to FU-19 catalogue into the repo before the project's folder closes, corrects the 1.31.0 notes (they misdescribe the iPad Home, End and Page keys) and closes five issues whose fixes have shipped. It is small and asks four questions.

> **Erratum (2026-10-15):** The project is retiring after hardening, so docs-and-bookkeeping.md runs as a fresh session from its repo copy, not as the project's last thread. The FU catalogue is already in the repo at `../platform-conditionals-followups.md` (its decision 3, default (a)), brought in with these plans (its decision 4, answered 2026-10-15: option (c)). The API change rule, the 1.31.0 notes and the five issues are still its work.

**The Duo plan now follows your Oct 7 spec.** duo-support.md was first written without the Claude Doc "Cabalmail on iPhone Duo: Poses and Transitions" (`https://claude.ai/code/artifact/0c0feb74-4160-4721-9f21-a173161becdc`, private to your account; a session you run can read it), and it re-landed `duo` branch fixes that the spec replaces. It was revised on 2026-10-13: the list pinned to the fold only in book pose, with your drag handle and a per-window width when flat; toasts on the fold rule, with button toasts below a laptop fold; the reader's actions in system bars; compose as a sheet with a window only on request; the overlay in open portrait; and the laptop layout as a build, not an optional prototype. Its "Spec map" places every item of the spec. Thirteen other plans carry a short dated note where they disagreed with the spec. Two things to know:
- **R1 grew and changes iPad too.** Compose becomes a sheet on iPad (its Decision 8), the list width becomes per window, and later the overlay reaches iPad portrait, because the spec chooses by window shape, not device. R1 has a priority order and is cut at what has merged.
- **One question is bigger than the rest:** the spec asks for one view tree (four tabs on both displays, the iPad tab bar you accepted, Settings as a sheet), but Wave 3 shipped two shells swapped on a close or open. duo-support.md Decision 9 recommends a timeboxed spike in Session 2 and a yes or no after it.

Every other question lives in its plan and is asked in one batch by that plan's scope doc. Each question has a recommended answer and a default that is used if you don't answer.

## Session or project

Only **sqlite-mail-store.md** recommends a project. It needs six or seven releases with a soak and a downgrade drill between them, a server change that must reach prod a release ahead of its client, migrations that must survive a tester installing an older build, decisions that fall due phase by phase, and gates on six other plans and the Duo. Phase 0 runs first as an ordinary session.

The other 20 recommend sessions, some as two or more sequential sessions. That differs from the roadmap posted in the rearchitecture project, which listed five items as "Later, as separate projects":

| Roadmap item | Plan | Recommendation | Why |
|---|---|---|---|
| SQLite mail store with an offline queue | sqlite-mail-store.md | Project | See above. |
| Kit split into Core, Networking, Persistence, Mail and Feeds | kit-split.md | Session | Six strictly sequential PRs in the same files. An umbrella module leaves 218 app files and 207 app test files untouched, so it is smaller than the 1.0 module move, which ran as one session. |
| Duo extras: a detached reader window | detached-reader-window.md | Session, Later | An open Duo shows the list and reader side by side when wide, and the spec keeps one split view in every open pose, so the Duo does not need a spanned shell. If it lands, "Open in New Window" appears only at regular width and falls back to opening in place. |
| Duo extras: a foldable simulator in CI | duo-support.md PR 1 | Part of the Duo sessions | A few lines of YAML once apple-ci-and-build-config.md's `create-sim.sh` takes a device type. |
| Shared load and error state | shared-load-error-state.md | Two sessions | Four open error bugs first, then one load state for every screen once its files are free. |
| Cross-media Phase 3 and feed bulk actions | feed-bulk-actions.md | One PR, then two sessions | Each half is one app area with one batch of decisions. The first half's release has to soak before the second can start. |

The reasoning is the same everywhere. A project earns its keep with a coordinator and parallel threads. In this codebase, shared hotspot files and the roughly five concurrent macOS CI jobs force one Apple PR at a time. Every one of these plans is an ordered chain of PRs with one batch of decisions, which is how every rearchitecture workstream actually ran. duo-support.md (sequential sessions, split at the device's arrival) and flags-and-cross-media.md (a chain of five sessions, one per phase) are also large but serial.

This is a judgement call. If you would rather give the Duo work its own project as a home for its conversations, nothing in the plan breaks. It just won't use parallel threads.

## The plans

| Plan | What it does | Vehicle | Size | When |
|---|---|---|---|---|
| [hardening-web-and-writes.md](hardening-web-and-writes.md) | Makes the composer keep only the formatting of content it did not write, stops feed reader mode running article script (#1911), and makes `/new` answer clearly for an address that is already in use (Session A). Stops write retries that can replay and errors that are swallowed (Session B). **Private until fixed.** | Two sessions | M | A Now, B Next |
| [duo-support.md](duo-support.md) | Builds your Oct 7 Duo spec on the Wave 3 shells behind one fold adapter, adds a Duo CI leg, then does a device pass, the overlay and laptop layout once you have a Duo, and the one-tree merge if you choose it. | Sequential sessions: two, plus a third for the merge | XL | Now |
| [ipad-layout-and-keyboard.md](ipad-layout-and-keyboard.md) | Fixes the three Wave 3 iPad regressions (#2032, #2033, #2034) and the iPad menu commands, then the older layout bugs and #1988. | Two sessions | M | Session 1 Now, Session 2 Next |
| [mail-correctness.md](mail-correctness.md) | Fixes five mail-path bugs, among them the #1990 server 502 that hits every client and #2037, plus the Page Up and Page Down gap. | Session | M | Now |
| [apple-ci-and-build-config.md](apple-ci-and-build-config.md) | Makes `apple-gate` binding, records and controls which Xcode builds CI and the uploads (an unrecorded 27.1 beta today), adds one setup action and a device-aware `create-sim.sh`, and closes a release-dashboard gap. | Session | M | Now |
| [docs-and-bookkeeping.md](docs-and-bookkeeping.md) | Moves the API rule and the FU catalogue into the repo, corrects stale docs and comments, closes shipped issues, and gives you a cleanup checklist for the Studio and the Mini. | Session, ideally the rearchitecture project's last thread | S | Now |
| [android-parity.md](android-parity.md) | The Android backlog. PR 1 is the twin of #1911 and should ship with hardening PR 2. The rest is minor bugs and one feature. Kept outside the rearchitecture project, per your earlier call. | Session, plus short later legs | M | PR 1 Now, rest Next |
| [sqlite-mail-store.md](sqlite-mail-store.md) | Moves mail envelopes into SQLite under one account-scoped root with a shared offline queue. Phase 0 first fixes the feed store's open bugs (#1871, #1956, #1957). | Project, with Phase 0 as a session first | XL | Phase 0 Now, Phases 1 to 5 Next |
| [live-verification.md](live-verification.md) | Runs the live checks that Waves 0 to 3 left to tests or to "by hand later", plus a three-hour outbox soak, on the Mini. Seeds a test folder of about 800 messages that the fold checks need. | Session | M | Step 1 (the folder) Now, rest Next |
| [feed-bulk-actions.md](feed-bulk-actions.md) | Fixes #1914, then builds feed multi-select and a bulk bar shared with mail (cross-media Phase 3). | One PR, then two sessions | M | PR A Now, sessions Next |
| [platform-conditionals.md](platform-conditionals.md) | Fixes the two Rules bugs (#2031, #2040), then retires the remaining `#if` blocks, FU-1 to FU-19. | Two sessions | L | Rules PRs Now, rest Next |
| [account-isolation.md](account-isolation.md) | Sets the one-account-per-install policy and fixes what leaks between accounts: a sign-in under a different server or account inheriting the last one's unsent mail, offline mail and settings. Must run before SQLite Phase 1. | Session | S, or M with the push stamp | Next |
| [multi-window-and-restore.md](multi-window-and-restore.md) | Restore, link-routing and window bugs from the Wave 3 soak and TestFlight pass. | Two sessions | L | Next |
| [shared-load-error-state.md](shared-load-error-state.md) | Fixes four error bugs (#1900, #1902, #1903, #1918) and puts failure wording in one place (Session A), then moves every screen onto one load state (Session B). | Two sessions | L | A Next, B Later |
| [mail-navigation-refactors.md](mail-navigation-refactors.md) | Behaviour-preserving extractions in the navigator, compose and reader hotspots that other plans need room in. | Session, in two passes | M | PRs 6 and 3a Now if CI is idle, PR 1 Next, rest Later |
| [swift6-and-strict-checking.md](swift6-and-strict-checking.md) | Turns the app's warnings into errors, then moves each target to Swift 6 language mode over two releases. | Two sessions | M | Next (A1 Now if CI is idle) |
| [test-debt.md](test-debt.md) | Fixes brittle tests (sleeps, short waits, duplicate fakes, 34 source-scan files) and covers untested paths and harness gaps. | Two sessions | L | Next |
| [flags-and-cross-media.md](flags-and-cross-media.md) | Unified flags across mail and feeds (Stage A), then cross-media Phases 2, 4, 5 and 6. | A chain of five sessions | XL | Stage A Next, rest Later |
| [kit-split.md](kit-split.md) | Splits CabalmailKit into targets behind an umbrella module. | Session | M | Later, after the SQLite project |
| [refresh-scheduling.md](refresh-scheduling.md) | Fixes the #1983 wording, then removes redundant refreshes and fills trigger gaps. | Session | M | Later (PR 1 Now) |
| [detached-reader-window.md](detached-reader-window.md) | Lets you open a message in its own window. | Session | L | Later |

> **Withheld (2026-10-15):** The hardening row describes Session A's composer and `/new` fixes only in the words of the public 1.31.2 changelog and commit subjects. The detail of those two findings stays out of this public copy under hardening decision 1 (private until the fixes are on prod for every client). The fixes shipped in release 1.31.2.

> **Erratum (2026-10-15):** docs-and-bookkeeping.md runs as a fresh session from its repo copy, not as the rearchitecture project's last thread; the project is retiring after hardening.

Each plan starts with its recommendation, size, priority, dependencies and Duo groundwork. It ends with the brief to paste into the session or project that runs it.

## Suggested order

Each plan's Depends and Unblocks lines are the detailed record.

**Now**
1. Work that needs no macOS runner: docs-and-bookkeeping.md, live-verification.md Step 1 (the test folder) and apple-ci-and-build-config.md PR D (the dashboard).
2. apple-ci-and-build-config.md PRs A and B (an honest gate and `create-sim.sh`). Then make `apple-gate` a required check if you agree (its decision 1).
3. duo-support.md Session 1 has CI priority until the Duo ships. ipad-layout-and-keyboard.md Session 1 interleaves with it, one `SplitShell` PR at a time. The spec changes iPad too, so iPad changes from duo R1 and R2 are expected, not regressions.
4. Bug fixes fill the gaps between Duo runs. Lambda and Android PRs can run any time, since they use Ubuntu runners: mail-correctness.md PR 1, hardening PR 6 and android-parity PR 1. Then the app PRs: hardening Session A, the rest of mail-correctness.md release A, sqlite-mail-store.md Phase 0, platform-conditionals.md's Rules PRs and feed-bulk-actions.md PR A.
5. Only when the Apple CI queue is idle: swift6 A1, mail-nav PRs 6 and 3a, refresh PR 1 and test-debt A1.

**Next**
1. duo-support.md Session 2, once you have the device.
2. The rest of live-verification.md, then account-isolation.md. Both come before SQLite Phase 1.
3. The navigation and window bug chain: mail-nav PR 1, multi-window Sessions 1 and 2, ipad Session 2 and shared-load Session A. Its #1903 fix comes early, because flags and SQLite wait on it.
4. Structure that clears gates: platform-conditionals Session 1, both feed-bulk sessions, the rest of apple-ci, swift6 Session A, both test-debt sessions, and the remaining android-parity PRs.
5. flags-and-cross-media.md Stage A.

**Later**
1. The sqlite-mail-store.md project, Phases 1 to 5, then kit-split.md. The two must not overlap. SQLite goes first, per its decision 7 (unanswered; both plans recommend that order).
2. refresh-scheduling.md, shared-load Session B, platform-conditionals Session 2, mail-nav's second pass, detached-reader-window.md, the cross-media sessions, the later Android legs and duo Session 3 (the one-tree merge if you choose it, else the optional reader-bar refactor).

## Calls made here, and what is still open

- **`HTMLBodyView.swift` is at SwiftLint's 500-line cap,** and two plans edit it. Hardening PR 3 lands first, so it does the extraction. Platform-conditionals Session 1 PR 6 then rebases onto that.

  > **Erratum (2026-10-15):** Hardening PR 3 merged to `stage` as #2057 (`f078467`) without the extraction. It keeps `HTMLBodyView.swift` code-line-neutral (one-for-one line changes; `apple/.swiftlint.yml` sets `ignore_comment_only_lines: true`) and extracts no type, so the file stays at its 500-line `file_length` cap. The extraction falls to the next PR that adds a code line there: platform-conditionals.md Session 1 PR 6.

- **The Android twin of #1911 has no coordinator,** because Android work ran outside the rearchitecture project. Whoever runs hardening Session A also opens android-parity.md PR 1, which is one small Android-only PR, so one thread owns the pairing. If it isn't ready, the Apple fix ships without it.
- **Shared rigs and CI.** The Studio has one screen and the only Duo simulator, and nine plans want it. The Mini is shared with your tester agent and the Android emulator. Each plan says to post before taking a screen. Until the Duo ships, the Duo work has first claim on the Studio and on the macOS runners. Nothing enforces either rule. They are agreements.

  > **Erratum (2026-10-16):** Posting before taking a screen worked because the rearchitecture's sessions shared threads. A session started from this repo cannot see other sessions, so it tells you instead, as `00-working-agreements.md` "Working from the repo" says.

- **Still open, with recommendations:** duo-support.md Decision 9 (one view tree or two shells; a spike first, recommended), SQLite decision 7 (do SQLite before the Kit split; recommended), and apple-ci decision 6 (retire `lint.yml`'s macOS swift job; recommended, but the default keeps it). Where test-debt's ratchet step and a platform-conditionals docs fix land depends on decision 6. Both plans are worded either way.

## Not planned, recorded so they aren't lost

None of these has an owner. Each would need its own decision to pick up.

- A reader, migration and user notice for outbox and draft items that the SQLite move quarantines. sqlite-mail-store.md keeps them out of scope, and hardening Session B only files an issue.
- Feed rows that store a snippet, so the list stops loading full article HTML (audit 02 F16).
- Replacing `ComposeWindowCloseInterceptor`. The FU-5 work keeps it.
- Narrowing the Mini's stage AWS access to the credentials it reads.
- A deep link that races a wide window's first layout. Not planned unless it reproduces.
- Moving logic out of views: about 14 direct client calls and many `Task` blocks (audit 06 F14). Only an "as views are touched" rule exists.
- An isolated `deinit` for the compose autosave loops; main-actor default isolation if you say "not now" in swift6 Session B; Android twins of #1903, #1935, #2028, #2037, #1974 and #1977 (none is filed, and none is planned without a reproduction); and `NavStateCoordinator` adopting the shared `Debouncer`.

## Deliberately left out

These are excluded because you decided against them or because they already shipped: #2029 (closed as won't do), a Command-M Move chord, the per-domain API protocol split (dropped 2026-10-07), per-window toasts (one app-wide slot, which now records the column that raised a toast so the Duo can place it), keeping the list model alive across a close or open ("Anchor only"; a rebuilt list still must not drop a just-opened message from an Unread filter), the drag-move registry, folding the Inbox badge poller into the per-folder pollers, lighter PR runs beyond #1784, and the Safari private-link History check. Auth parity (#1950, #1951, #1952) belongs to `docs/1.x/auth-parity-plan.md`, not to the rearchitecture project.

## Starting one

- **A session:** start a Claude Code session on `cabal-infra`. It reads the plan and `00-working-agreements.md` from `docs/1.x/post-wave-3/`; then paste the brief from the end of the plan. Every brief begins by re-checking the file and line numbers and the issue states it cites against current `stage`.
- **A project:** create the project on the same repo, have it read the same two files from this folder, and start from the plan's kick-off section.
- Nothing else is needed. The rearchitecture project's records (the proposal, the audits, the scope docs, the soak notes and its threads) are not in the repo, and project memory was off, so each plan states what it took from them where it uses it.

## How these were made, and the limits

- I swept the proposal, the audits, every scope doc, the soak and TestFlight notes, the rearchitecture project's threads, the open issues and the code at `50e6022`. That produced 435 items, which I grouped into 21 workstreams. Each plan was drafted, then fact-checked against the code and GitHub, critiqued for vehicle, order and scope, and revised. Finally all 21 were cross-checked against each other: 30 consistency fixes (decision and PR numbers, one owner for each shared item, gates updated after #2043 merged), 11 duplicates resolved, and the order above.
- Nothing was built or run except the platform-conditionals checker. Device behaviour comes from issues and soak notes. Line numbers will drift, which is why every brief re-checks them first.
- The rearchitecture project's shared folder was unreadable during the last revision pass on 2026-10-13. Project-file line citations in apple-ci-and-build-config.md, test-debt.md, docs-and-bookkeeping.md and live-verification.md were carried over from their earlier drafts, which had read those files, and were not re-read in that pass. Code citations were re-read at `50e6022`.
