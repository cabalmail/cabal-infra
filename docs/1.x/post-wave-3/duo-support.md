# iPhone Duo support

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Sequential sessions, not a project: Session 1 now, Session 2 once the maintainer has a Duo, and Session 3 for the one-tree merge if Decision 9 takes it (otherwise only the optional reader-bar refactor). The device is the only outside wait and splits the work cleanly, CI already builds with the 27.1 SDK, nothing needs a server change or migration, and the Studio's one screen and `SplitShell.swift` serialize the work, so a coordinator and parallel threads would buy nothing. If Decision 9 takes the merge, this becomes four sessions over several releases; that is the point where a project of its own starts to pay as a home for the decisions, though it still would not use parallel threads.
**Size:** XL (Session 1: up to ten small PRs and a Studio simulator pass; Session 2: a device pass and five to eight PRs; Session 3: the shell merge, L on its own).
**Priority:** Now. The Duo ships about 2026-10-23, and the TestFlight app is already a 27.1-SDK build, so today's Duo problems (Reply opening a full-screen window, Search broken on the closed display, nothing kept off the crease) reach the maintainer on day one (inferred, high confidence).
**Design source:** the maintainer's Oct 7 spec in the Claude Doc "Cabalmail on iPhone Duo: Poses and Transitions" (https://claude.ai/code/artifact/0c0feb74-4160-4721-9f21-a173161becdc), private to the maintainer's account; a session run by the maintainer can read it. Its "Your book, laptop and portrait spec" section and "Choices for you" are the maintainer's decisions and are not re-asked here; the rest of that doc is the design this plan follows unless a line below says otherwise. "Spec map" near the end gives every item and where it lands. Block ids such as 〔.48344〕 point into that doc.
**Depends on:** nothing hard. Order only: apple-ci-and-build-config.md (`create-sim.sh` before or with the CI leg; its Xcode choice must keep the iOS upload on 27.1 or later); ipad-layout-and-keyboard.md and mail-navigation-refactors.md (one open PR at a time in `SplitShell.swift`; ipad-layout-and-keyboard.md's PRs A and B also go before Session 2's device pass); live-verification.md (Step 1's `SoakBig` folder of about 800 messages); feed-bulk-actions.md (its PR D, with the bulk actions as a data list, before Decision 11's work); platform-conditionals.md (FU-1 before Session 3).
**Unblocks:** detached-reader-window.md (its "Open in New Window" gate is regular width with an in-place fallback, per the spec; no fold input needed); multi-window-and-restore.md and sqlite-mail-store.md (device evidence on list place across a close and open); docs-and-bookkeeping.md (the delete list for the Studio's Duo refs; #1962's close stays here, in Session 2); test-debt.md (PR 2 before its B1, PR 10 before its B4); platform-conditionals.md (PRs 6 and 10 go before its work in the reader files and `MessageListView+Rows.swift`); flags-and-cross-media.md B5.1 (waits on Decision 9).
**Duo groundwork:** This is the Duo plan: one fold adapter, the maintainer's Oct 7 spec built on the Wave 3 shells, a CI guard that keeps Duo code compiled, and the first proof on hardware.
**Written:** 2026-10-12 against stage 50e6022. **Revised 2026-10-13** against the Oct 7 spec and stage 271e2e16 (1.31.1); the first version was written without the spec and re-landed several `duo` branch fixes the spec replaces. Re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| Decisions 1 to 9 (start of Session 1); 10 and 11 (Session 2) | None asked yet (2026-10-15) |
| Session 1, PR 1: CI probe, then the leg | Not started (2026-10-15) |
| Session 1, PR 2: fold adapter | Not started (2026-10-15) |
| Session 1, PR 3: columns by the spec (#1666) | Not started (2026-10-15) |
| Session 1, PR 4: toasts and banners on the fold rule (#1648) | Not started (2026-10-15) |
| Session 1, PR 5: Search on the vertical tab bar (#1963) | Not started (2026-10-15) |
| Session 1, PR 6: mail reader in system bars (#1667) | Not started (2026-10-15) |
| Session 1, PR 7: compose as a sheet (#1680) | Not started (2026-10-15) |
| Session 1, PR 8: nothing re-marked on a close or open | Not started (2026-10-15) |
| Session 1, PR 9: crease margins in book pose | Not started (2026-10-15) |
| Session 1, PR 11: Duo docs | Not started (2026-10-15) |
| Session 1, PR 10: compact row drag (#1681; R2) | Not started (2026-10-15) |
| Session 1, PR 12: drops into compose (R2) | Not started (2026-10-15) |
| Session 1: the Studio simulator pass | Not started (2026-10-15) |
| Session 2: with the device | Not started (2026-10-15); the device ships about 2026-10-23 |
| Session 3: the one-tree merge (with Decision 9), or the reader-bar refactor alone | Not started (2026-10-15) |

## Words used here

The spec's terms, which earlier plans used loosely:
- **Close and open** move the app between the outer and inner displays. The window narrows to compact width or widens to regular. On stage this swaps `TabShell` and `SplitShell`.
- **Fold** means book or laptop pose: an active fold region crosses the same 951 × 669 pt window (or 669 × 951 pt in laptop), with no size-class change and no shell swap 〔.6967〕.
- **Wide** and **tall** are the window's shape at regular width. Open wide and book are wide; open portrait and laptop are tall; so are iPad landscape and portrait.

## Decisions for the maintainer

Asked at the start of Session 1, in its scope doc:

1. **The Duo CI leg (only if the runner can boot a Duo simulator).** (a) Runs on stage pushes and on PRs labelled `duo`, and never blocks a merge. **Recommended.** (b) As (a), and it joins `apple-gate` after two weeks green. (c) Every Apple PR. Consequence of (a): ordinary PRs keep their six macOS jobs, and a red Duo leg is visible but advisory. Default: (a).
2. **Device Hub clicks.** May Studio sessions click Device Hub's device row and its Closed, Book and Open posture buttons, and its hinge slider, with a screen capture before each click, as you allowed for the 3.2 layout-shells session? Yes **(recommended)** / No. Consequence of yes: the Studio pass folds the simulator without you. Default: the session checks whether those click rules are still in the Studio's permission settings; if not, it asks you to click when it needs a fold.

   > **Erratum (2026-10-16):** The plan does not record which permission settings hold those click rules or how to read them. So the default becomes: the session asks the maintainer whether the click permission given to the 3.2 layout-shells session still stands, and if it does not, asks the maintainer to click when it needs a fold.

3. **The Studio's Xcode.** When CI moves to the 27.1 release candidate or final build, may a Studio session install that same build beside the others? Yes **(recommended)** / No. Consequence of yes: Studio builds keep matching CI's compiler. Default: no install.
4. **A fact.** Did you already run the Wave 3 TestFlight checklist's "At the Studio" Duo fold check ("Duo fold keeps the list's place", under "Background from the rearchitecture") in the open pose? Yes / No. Default: no, and the Studio pass runs it.
5. **#1667 timing.** Put the mail reader's actions into system bars in R1 (bottom placement, so they join the side strip and sit below a laptop fold, per the spec), or wait for the reader-bar refactor? R1 **(recommended)**. Consequence of R1: the first TestFlight build after R1 merges shows the reader's actions in the strip on your Duo. Default: R1.
6. **#1681, compact row drag, which changes every iPhone.** Its own release after R1 **(recommended)**, or inside R1? Consequence of its own release: a long-press regression on any iPhone traces to one release, and drag reaches prod one promotion later. Default: own release.
7. **Do Duo device checks hold Promote once you have the device?** Yes, for Duo PRs merged after it arrives **(recommended)**. No: Duo stays best-effort. Consequence of yes: an open Duo `needs-verification` issue also holds every other plan's changes on `stage` until you check it, so each session hands you its device checks in one batch. Default: yes from arrival; R1 promotes on simulator evidence.
8. **Compose as a sheet (#1680) in R1?** Your spec makes compose a sheet in every layout, with a window only on request, and gives iPad the same sheet 〔.47994〕〔.17848〕. That is not Duo-only: iPad Reply and New Message stop opening a window. In R1 **(recommended)**, because Reply on today's open Duo takes the whole display. Or its own release after R1. Consequence of R1: iPad and the Duo change together, and a compose regression on iPad traces to R1. Default: R1, as R1's last PR so it can be cut.
9. **One view tree (the spec's structure) or the two Wave 3 shells?** The spec asks for one tree: a root tab view (Mail, Feeds, Addresses, Search) on both displays, split views inside that the system collapses on the outer display, Settings as a sheet, and folders as the system sidebar 〔.9897〕〔.18738〕〔.19069〕. You accepted the iPad tab bar that comes with it 〔.19772〕. Wave 3 shipped the Oct 2 proposal's design instead: `TabShell` and `SplitShell`, swapped on a close or open, with the window's state held above the swap (the proposal: "a fold or unfold swaps only the layout shell, while the route, selection and search live in the window's navigator above it"; `Shell/SectionLayoutPolicy.swift:32-36`). The swap was chosen because a `NavigationSplitView` expanding and collapsing inside the tabs caused the "wider screen" bugs (the reader not pushed, the inspector stuck as a sheet; `SectionLayoutPolicy.swift:38-60`). It still loses what sits below it: the reader is rebuilt, sheets other than compose close, the folder panel and inspector close, and the list shows its top until its refresh.
   - (a) **A timeboxed one-tree spike on the Studio in Session 2, then a yes or no on a merge session.** **Recommended.** The spike builds the spec's root on a branch and runs the spec's Device Hub chain plus the two "wider screen" bugs. Consequence: about a day of session time; no app change; you decide with evidence.
   - (b) **Commit to the merge now** as Session 3. Consequence: the iPad gets the tab bar and Settings becomes a sheet everywhere in that release; `ShellHandOff`, the shell hand-off code and several sibling-plan items go away.
   - (c) **Keep the two shells** and fix each loss in place (sheets hoisted to the root, the reader kept across the swap). Consequence: no iPad tab bar, and the spec's four tabs stay unbuilt.
   Default: (a). Decision 10 and the folder-sidebar choice follow from it.

Asked at the start of Session 2, after the device pass:

10. **#1692, the addresses inspector.** (a) **Remove it on iOS** once Addresses is a tab on both displays, moving its jobs to the message header's address menu (which has Copy, Compose To and From, and Revoke today; add Show Mail to This Address), the Addresses tab and "New Address…" in the From picker 〔.17356〕. **Recommended if Decision 9 lands the merge.** (b) Under the two shells, the inspector takes the reader's page while open, and the list keeps the left page. **Recommended if it does not**, because without the merge the split has no Addresses tab. (c) Keep today's three-column squeeze. Default: follows Decision 9.
11. **#1647, Select mode on vertical bars.** (a) **Select mode hides the tab bar and its actions become system bottom-toolbar items**, so Move, Flag, Read and Archive own the strip 〔.13393〕〔.12267〕. **Recommended.** (b) Keep today's custom horizontal bar on purpose. Consequence of (a): the custom bar stays only where bars are horizontal; feed Select mode follows through feed-bulk-actions.md. Default: (a), after feed-bulk-actions.md PR D.

Not asked again, on purpose:
- **Your Oct 7 choices:** the drag handle and a stored width when flat; the list pinned to the fold in book pose; one animation back to your width on unfolding; the iPad-portrait overlay for open portrait; the laptop layout with the message on top and the list and controls below the fold; compose's laptop and open-portrait arrangements; no Cabalmail taps above a laptop fold or within 44 pt of a book crease; replies on the trailing side in a flat wide window; the iPad tab bar (built only with Decision 9's merge).
- **Earlier rearchitecture decisions:** the toast stays one app-wide slot (3.3), now carrying the column that raised it so each window can place it; the list's place across a close or open stays "Anchor only" (3.3: each list keeps building its own model, so after a close or open the list's top shows until the rebuilt list's first refresh lands, then it moves to your row, and rows past the top 250 reload); the `duo` branch is a reference, not a merge (3.2); deployment targets stay at iOS 18 (3.2).
- **Replaced by the spec:** the first version's Decision 9 (Reply in a window beside the message) and Decision 10 (a laptop layout as an optional prototype). The spec settles both.

## What you'll see change

Session 1. R1 is everything below except the CI probe and the two R2 items; each R1 PR is listed in priority order, and whatever has not merged by the R1 cut moves to R2:
- **CI probe and fold adapter:** nothing visible. CI goes red if Duo code stops being compiled, for example if CI's Xcode falls back to 27.0.
- **Search on the vertical tab bar (#1963):** on the closed Duo, the Search button opens Search instead of the current tab's filter.
- **Compose as a sheet (#1680; Decision 8):** on the open Duo and on iPad, Reply, Reply All, Forward and New Message open a sheet over the mail window instead of a separate window. In a wide window the sheet sits on the trailing side if the 27.1 SDK allows it. A window opens only when you ask for one. Mac and visionOS are unchanged.
- **Columns (#1666):** flat, the list keeps the width you drag it to, per tab and per window, or sits at the fold if you never set one; a double tap on the handle, or Reset to Fold, clears it. In book pose the list snaps to the fold and the handle hides; unfolding animates back to your width. On iPad the width also becomes per window.
- **Toasts and banners on the fold rule (#1648):** in book pose a toast sits in the half of the column that raised it, never across the crease. In laptop pose a toast with a button (Resume, Retry) sits below the fold and a status-only banner above it.
- **Mail reader in system bars (#1667):** on the open Duo the reader's actions sit in the side strip, as the feed reader's do; in laptop pose they sit below the fold.
- **Nothing re-marked on a close or open:** opening or closing the Duo, or resizing an iPad window across compact, no longer re-marks read a message you marked unread, and keeps Load Images on if you turned it on.
- **Crease margins in book pose:** list-bar items and confirmation prompts move off the 44 pt band beside the crease, and message text starts at least 44 pt from it.
- **Duo docs:** nothing in the app.
- **R2, compact row drag (#1681):** on every iPhone and in a Duo Split View half you can drag a message out as an `.eml`; a held press still opens the menu.
- **R2, drops into compose:** images and files dropped onto compose become attachments, on every iOS device.

Each R1 PR changes the stage TestFlight app on a Duo as soon as it merges, because CI builds that app with the 27.1 SDK.

Session 2: one device checklist for you, findings filed as issues, and #1962, #1651 and #1652 closed. Then, bugs first: open portrait becomes the overlay (the message full width, the list sliding over it), on the Duo and in iPad portrait; the laptop layout; sheets placed by window shape; the empty reader shows the folder's unread count; Select mode per Decision 11; the inspector per Decision 10; and the one-tree spike per Decision 9. Session 3 (with Decision 9's merge): the same four tabs on both displays and on iPad, Settings as a sheet everywhere, folders in the system sidebar.

## Why

The Duo is the long-term target of the rearchitecture, and nothing Duo-specific has shipped. Waves 2 and 3 built the pieces a close and open need (2.3's per-window `SceneNavigator`, 3.2's `ShellLayout`, 3.3's per-window restore), but every brief from 2.3 on called Duo behaviour best-effort because there was no device. None of them read the Oct 7 spec, a Claude Doc in the maintainer's account that the rearchitecture's sessions did not have.

- **No Duo code on stage.** A grep of `apple/` for `reservedRegion`, `hostHasFold`, `.division`, `hinge` and `ArrangementView` finds nothing; the fold work exists only on the unmerged `origin/duo` branch, through PRs #1675, #1676, #1677 and #1687, which merged into `duo`, not `stage`.
- **The shipped app already meets the Duo's bugs.** CI's `latest-stable` has selected "27.1.0 (27A9269)" from `/Applications/Xcode_27.1_beta.app` since at least 2026-09-25 (job 107988484017), including the iOS TestFlight uploads on stage (job 114506992226, 2026-10-11) and prod (job 113958211841, 2026-10-09). #1651's setup comment says "Only a build against the 27.1 SDK reaches the screen edge and gets vertical bars", and #1963 happens only on such a build.
- **Stage departs from the spec in ways a Duo owner meets at once:** Reply opens a full-screen window (#1680); the list ignores the crease; toasts hang across it; the reader's actions are a custom bar that cannot join the strip; open portrait tiles a narrow list beside the reader instead of the overlay; and a close or open rebuilds the reader.
- **Duo code would compile in CI but never run there.** Every iOS test job runs on an iOS 27.0 runtime (job 114626873483), so `#available(iOS 27.1, *)` branches are never executed.
- **Many Wave 3 Duo checks never ran.** The 3.2 scope planned Duo checks for its shell PRs C to H and none for 3.2 B; 3.2 D's session could not type into the split's search on the unfolded simulator (the TestFlight checklist's optional "Duo fold in the middle of a search"); the list-place check was done closed only ("Duo fold keeps the list's place"). Both checks are under "Background from the rearchitecture".
- **Posture cannot be scripted.** `simctl` and SimDrive have no posture command. Folds were done by clicking Device Hub's posture buttons on the Studio's screen. So CI can test at Duo sizes but cannot fold.

## Where things stand

**Toolchain and CI (run logs, read 2026-10-12).**
- The runner image `xcode-27-arm64` 20261006.0244.1 has Xcode 27.0 (27A266a, default), "27.1" 27A9269 at `Xcode_27.1_beta.app` with no beta flag (so `setup-xcode` treats it as stable), and 27.2 beta 2. Its only installed simulators are on iOS 27.0, with no iPhone Duo listed. The comment at `apple.yml:46-55` ("skips the betas") is wrong; apple-ci-and-build-config.md owns that comment.
- iOS legs pick `.[0]` of the device types whose name starts with "iPhone" (`apple.yml:174-179, 409-414`). That is iPhone 18 Pro today and could become the Duo if the order changes. apple-ci-and-build-config.md's `create-sim.sh` fixes it.
- Apple was accepting Duo-optimized submissions by 2026-10-07, and its 27.1 release candidate (27A9275) was out by then. Whether App Store review accepts a binary built with 27.1 beta 1 is unverified. App Store submissions need Duo screenshots from April 2027 〔row .4238〕.
- The Studio: default Xcode 27.0, plus 27.1 beta 1 with the Duo simulator. The spec's measurements were taken there on Oct 7 with 27.1 beta. The working agreements also mention a 27.2 beta; Session 1 records what is installed, and a reading that differs from the spec's on another Xcode is re-measured, not taken as a regression.
- Deployment targets are iOS 18, macOS 15, visionOS 2, watchOS 11 (`apple/project.yml:28-32`). So every Duo API stays behind `#if os(iOS) && canImport(SwiftUICore, _version: 8.0.85)` plus `#available(iOS 27.1, *)`, because "The compiler version cannot tell 27.0 from 27.1" (`FoldRegionQuery.swift` on origin/duo). The ratchet counts any `#if` containing `os(` outside `Shell/` and `Platform/` (`scripts/check-platform-conditionals.py:16-21`), so guarded code lives only there.

**The device.** It ships about 2026-10-23: #1652 ("ships 2026-10-23") and press headlines.

**The shells today** (stage 271e2e16; paths under `apple/CabalmailUI/`).
- **Two trees.** `SignedInRootView` draws `SplitShell` or `TabShell` (`Shell/SignedInRootView.swift:145-168`), chosen from both size classes and a 600 pt measured floor (`Shell/SectionLayoutPolicy.swift:78, 91-95`). Above the swap: the `SceneNavigator` (route, open message, search, selection and list place through `FolderListHold`), the toast overlay and compose's sheet (`Compose/Windows/ComposeRequestRouter.swift:66`). Below it, and lost on a close or open: the reader's model and web view, the folder panel, the inspector, and every other sheet (Move, Filters, New Folder, New Address, invite, Source, Contact editor). `ShellHandOff` turns the Settings sheet into the Settings tab and back (`Navigation/ShellHandOff.swift:49-62`).
- **Tabs.** `TabShell` has five tabs: Mail, Feeds, Addresses, Settings, Search (`Shell/CompactTab.swift:76`). `SplitShell` has none; Settings is a sheet from the folder panel's gear, Search a field in the list header, Feeds a section of the folder panel, and Addresses the `@` inspector.
- **Columns.** `SplitShell` keeps one app-wide width, `@AppStorage("cabalmail.layout.listColumnWidth")`, default 360 (`Shell/SplitShell.swift:51`), shared by every tab and window and written on every frame of a drag (`Shell/Columns/ColumnResizeHandle.swift:174-185`; `SplitShell.swift:301-306`). Bounds are 300 pt up to the split width less the 360 pt reader floor and 16 pt slack (`Shell/Columns/ListColumnWidth.swift:38, 45, 156, 168-171`): 575 pt at 951 pt. There is no reset and no fold handling. Column visibility is fixed at `.doubleColumn` (`SplitShell.swift:64-66`), so a tall window tiles a list of about 293 pt beside the reader.
- **Reader bar.** `ReaderToolbarPolicy.placement` (`Shared/Chrome/ReaderToolbarPolicy.swift:85-88`) gives `.topBar` at compact width, a system `.bottomBar` before iOS 27, and `.ownBar` at regular width on iOS 27, which is a custom `HStack` in a bottom safe-area inset (`Mail/Reader/MessageDetailView+Toolbar.swift:72-89`), not a system bar. A custom bar never moves into the Duo's strip 〔.12267〕. The feed reader uses `.topBar` at every width.
- **Toasts.** One overlay at the bottom of the whole layout, 57 pt inset on the tabs and 6 pt elsewhere (`Shared/Banners/StatusBannerPlacement.swift:31-55`; `SignedInRootView.swift:91-96, 188-223`). One app-wide `AppState.toast` (`App/AppState.swift:47`); a `Toast` carries no origin (`App/AppStateSignals.swift:19-39`). There is no Undo toast and no new-mail pill today; Retry is `FailedSendBanner` in the same overlay.
- **Compose.** A window whenever the host supports multiple windows: iPad and the open Duo; a sheet on other iPhones and the closed Duo (`Compose/Windows/ComposeWindowScene.swift:37-79`). The comment there records the closed Duo reporting no multi-window support on the 27.1 simulator (:40-44). The spec's Studio run saw the opposite: a window opened on the closed display, and the app was told multiple windows were supported 〔.13943〕〔row .27118〕. Hardware settles it. There is no "Open in New Window" for a message or draft. Compose accepts no drops.
- **Reader across a close or open.** The reader is rebuilt: a new model loads the body (from the body cache, not the network) and, with "mark read on open" set, marks it read again, undoing a Mark Unread; the per-message Load Images toggle resets (`Mail/Reader/MessageDetailView.swift:245-271`; `MessageDetailViewModel.swift:135, 172, 221-223`; inferred from code, not run). Feeds mark read on the restored selection the same way (inferred). Remote images are blocked by default (`Shared/BodyRendering/HTMLBodyView.swift:12-19`). Reading position is anchored to content and re-applied (`HTMLBodyView.swift:627-640`).
- **Already as the spec asks:** multi-selection and Select mode survive a close and open (2.3 F, `Navigation/FolderListHold.swift`; `Shared/Primitives/SelectionModel.swift:54-58`); the search model is per window; nothing auto-opens a message to fill an empty reader (`Shell/Columns/MailReaderColumn.swift:57-63`, which shows no unread count); addresses drag out as text.
- **Elsewhere.** Row drag is attached only on wide layouts (`Mail/MessageList/MessageListView+Rows.swift:155-172`, gate at `:163`). The Search tab takes the `.search` role on the tabs layout (`Shell/CompactTab.swift:62-68`; `Shell/TabShell.swift:54-55`); #1963: with the 27.1 SDK's vertical tab bar, the system routes that role to the selected tab's `.searchable`. `BulkActionBarLayout` is a custom bar under `Mail/MessageList/`, inside the ratchet's scope. No sheet uses a placement or detent on iOS.

**The `duo` branch.** `origin/duo` (tip 4d7aee2) is 16 commits ahead of `origin/stage` and 643 behind. `git cherry -v origin/stage origin/duo` lists six commits with no equivalent on stage. All sit on pre-1.0 paths (`apple/Cabalmail/Views/`) that no longer exist, so they are a reference. The spec decides what each becomes:

| Commit | What it does | Issue (PR) | Under the spec |
|---|---|---|---|
| e95fe36 | Crease and `SplitGeometry`; list pinned to the crease, including on a flat device; no handle on a folding host | #1666 (#1675) | Reuse the geometry only. Pin only on an active vertical fold; keep the handle and stored width when flat (PR 3) |
| 03673de | Pin only to a vertical hinge; portrait falls back to a tiled list | #1686 (#1687) | The horizontal pin goes, as the spec agrees 〔row .16947〕. Portrait gets the overlay instead (Session 2) |
| 09fc37e | `hostHasFold`; reader's actions as top items on a folding host | #1667 (#1676) | Replace: system items placed at the bottom, chosen by vertical bars and an active fold, not a device input (PR 6) |
| be16467 | `FoldRegionQuery`; banners classify the pose; width cap | #1648 (#1677) | Reuse the region query only. Drop the pose classification for the fold rule; laptop toasts with buttons go below the fold, not above (PR 4) |
| 0cfa6a8 | Drag on compact rows | #1681 | Re-implement (PR 10) |
| 39948ea | Swipe container; deployment targets to 27 | #901 | Superseded: stage has the container (c9b5cfa, 83b246f) |

The Studio also holds `claude/duo-fold-diag` (two diagnostic commits, never pushed), `tmp/duo-test-build` (`duo` plus four local commits) and three September rescue refs (5d0ff1aa8, 7c34d7497, a5cdc73ac), parked under `refs/rescue/2026-10-11/` by the Studio's 2026-10-11 git cleanup; its local `duo` branch is fully contained in `origin/duo`.

**Issue notes (GitHub, 2026-10-13).** #1962 passes on the Duo simulator at stage 73175cac ("Not checked on a physical Duo", 2026-10-10). #1647's triage found the reader and compose bar order right; what is left is Select mode's bar and the 27.1 vertical-bar modifiers. #1651 section E is unchecked (tab-bar shield with a side tab bar; toasts in book and laptop poses; every sheet on both displays and a partial fold; a feed article in book pose; a push tap with two windows; reader HTML at inner width); the spec already answers several of its placements. #1651's Sept 19 notes asked for columns split exactly 50/50 on the crease; the Oct 7 spec replaces that with a stored width when flat and the pin in book pose only. #1652's first gate ("the GitHub runner image ... carries Xcode 27.1") is met by accident; its second (a physical device) is Session 2. #1682 stays an accepted limitation.

## The plan

### Session 1: before the device (now to about 2026-10-23)

Rules for every PR: if a release PR is open, nothing merges to `stage` until it has merged. Build with the Xcode CI actually selects (read "Xcode is set to" in the latest Apple run; 27.1 beta 1 today), chosen per command with `DEVELOPER_DIR`, never `xcode-select`. At most two open Apple PRs, and only PR 1 may run beside another. Never edit a source scan's text or anchor without the maintainer's yes up front. Layout follows size class, window shape and the active fold region, never the device: no `hostHasFold`, no idiom check, no pose names in code 〔.7625〕〔.19772〕. Cabalmail adds no animation of its own on a close, open or fold, except the divider's 〔.22320〕.

Priority for the R1 cut: PR 2, PR 5, PR 7, PR 3, PR 4, PR 6, PR 8, PR 9, PR 11. Whatever has not merged when R1 is cut moves to R2.

**PR 1, CI probe, then the leg (`apple.yml` only; `no-changelog`).** A draft PR whose first push adds a throwaway job that prints:
- each Xcode in `/Applications` with version and build;
- the installed iOS runtimes, and the device types matching "Duo" under `DEVELOPER_DIR=/Applications/Xcode_27.1.app`;
- whether a Duo simulator can be created and booted on the iOS 27.0 runtime;
- the time and size of downloading an iOS 27.1 runtime (`xcodebuild -downloadPlatform iOS`);
- any posture or fold command in `xcrun simctl help`.

Then one of two outcomes. If a 27.1 runtime can be had in about ten minutes, replace the probe with an `ios-duo` leg: Xcode by path (`/Applications/Xcode_27.1.app`, the image's symlink), the Duo by explicit name (through `create-sim.sh` if apple-ci-and-build-config.md has landed it, otherwise an inline parameter for this leg only), then build and run the iOS-hosted app tests. No Kit tests. Trigger per Decision 1, `continue-on-error`, outside `apple-gate`. Verify with a throwaway commit that breaks code inside the 27.1 guard. If no runtime is attainable, close the PR, comment the probe's findings on #1652, and re-probe when the image version changes. PR 2's tripwire is then the only guard. Risk: medium; the missing runtime is the likely case.

**Status:** Not started (2026-10-15).

**PR 2, fold adapter (`no-changelog`).** New `Platform/FoldGeometry.swift`, behind the guards:
- The active `.division` regions, filtered to active explicitly, because Apple's reference says inactive ones come back too while the runtime returns only active ones 〔row .27350〕.
- A `FoldState` value published to the environment: none, vertical or horizontal, with the crease frame in the window's own coordinates, never a physical half 〔.26611〕.
- The hinge hold, the spec's only use of hinge data 〔.47449〕〔.10518〕: once a fold state is entered from an active region, hold it while the hinge angle changes (the region drops out during any motion), and end it on a fully open hinge status, after about 0.6 s at rest with no region (a starting value; the Studio tunes it at 110, 130, 170 and 180 degrees), or when the window changes shape. Hinge data never enters a fold state.
- A view modifier that reports the window's safe frame minus the fold region, settling only when two consecutive layout passes agree, because the first frame after a change can be stale 〔.7366〕.
- The pure rules as plain types with Mac-host tests: a region to a fold state, the hold's timing with an injected clock, and the two-pass rule.
- A `foldAPICompiled` flag and an iOS-hosted test that asserts it, so CI turns red if its Xcode stops compiling the guarded code.

**Status:** Not started (2026-10-15).

**PR 3, columns by the spec (#1666; `Apple:`).** In `SplitShell`, reading PR 2's `FoldState`; it does not use `WideMail.swift`'s width, which the Mac shares.
- **Flat.** The list keeps a stored width per tab (Mail, Feeds, Search) and per window, in scene storage, replacing the app-wide `@AppStorage` key (an iPad behaviour change: two iPad windows stop sharing a width). With no stored width, the list sits at the fold when the window has one, else at today's default. The range is 320 pt (the spec's proposed floor; stage's is 300) up to the split width less the 360 pt reader floor; the Studio confirms whether the measured split width already excludes the 84 pt side strip, since the spec computes a 507 pt ceiling and stage's rule gives 575 pt if it does not. The #1716 slack rule stays.
- **Handle.** A drag starts only on the visible grabber. Letting go records the width; frames during a drag do not. A double tap, or Reset to Fold in the handle's menu, clears it. If iOS 26's own separator drag proves live on the Duo, use it instead, as the spec allows 〔.48592〕.
- **Book (active vertical fold).** The list is pinned to the fold, the handle hides, and a drag in progress is cancelled unsaved. On unfolding, one animation back to the stored width, none with Reduce Motion.
- **Horizontal fold:** no pin 〔row .16947〕.
- Verify on the Studio simulator flat, book, open portrait and laptop, and on the iPad simulator (handle, per-window width). If ipad-layout-and-keyboard.md PR H or mail-navigation-refactors.md PR 2 is open on `SplitShell.swift`, wait for it. If test-debt.md's iOS shell harness exists, add layout tests at 951 pt flat and folded.

**Status:** Not started (2026-10-15).

**PR 4, toasts and banners on the fold rule (#1648; `Apple:`).** The spec says to keep #1677's goal and drop its pose classification 〔row .17672〕.
- `Toast` gains an origin: the window and the column (list or reader) that raised it, or none for window-level ones (offline, the cross-device Resume). The one app-wide slot stays; each window places it from the origin.
- `StatusBannerPlacement` becomes a pure rule over the safe frame minus the fold region (PR 2's modifier): on a vertical fold, the piece of the column that raised it, and window-level ones in the reader's piece; on a horizontal fold, toasts with a button (Resume, Retry, and later Undo and a new-mail pill) below the fold, status-only banners above it 〔.10855〕〔.54034〕. No pose names. Elements move only when two layout passes agree.
- `SignedInRootView` reads the region through PR 2's modifier. Keep `measuredWidth: measuredWidth` (`SignedInRootView.swift:181`) verbatim, because ReaderColumnFloorSourceScanTests pins it.
- Verify book and laptop on the simulator with an offline banner and a Resume toast.

**Status:** Not started (2026-10-15).

**PR 5, Search on the vertical tab bar (#1963; `Apple:`).** Start by re-running #1963's steps on the closed simulator. Since 2026-10-22 the phone's tab view activates the Search tab's own field when the tab is selected (`.tabViewSearchActivation(.searchTabSelection)` in `TabShell`), and the Search tab opens over the tab in front, showing a dimmed capture of it until a search runs (`SearchBackdrop`). #1963 was seen before that, when nothing told the system which field the search role belonged to. If the vertical bar's Search button now opens the Search tab's field, this PR is that check and #1963's close. If it still engages the current tab's filter, go on as follows: `CompactTab.role(in:)` gets an input that says the tab bar is vertical and returns no `.search` role there. First look in the 27.1 SDK for a value that reports the bars' edge or orientation, read behind the guards in `Shell/` or `Platform/`. If none exists, measure the tab bar's frame in a `Platform/` UIKit adapter (inferred fallback). Publish the result as a `barsAreVertical` environment value, which PR 6 also reads. Never assume the strip is on the right; read its edge 〔row .5290〕. Verify on the closed simulator from the Addresses tab, in both landscape orientations, and on an iPhone simulator (unchanged).

**Status:** Not started (2026-10-15).

**PR 6, mail reader in system bars (#1667; `Apple:`).** When bars are vertical (PR 5) or a horizontal fold is active (PR 2), `ReaderToolbarPolicy.placement` returns a new placement: the reader's actions as system toolbar items at the bottom, Reply and Archive at high visibility priority, every item with a symbol and a title 〔.12921〕〔.12267〕. In the strip they then sit near the thumb and the tabs; in laptop pose they sit below the fold. If the Studio shows bottom items in the reader column do not join the strip, use top placement in wide windows only; never top placement in a tall window. Everywhere else (iPad, open portrait, ordinary iPhones) the placement is unchanged. `MessageDetailView.actionPlacement` passes the environment values inside its existing iOS block, with no new `#if`. The message, compose and article screens ask the strip to give up tabs before their own actions. The list's bar items (the folder button, Compose, `@`), which are image-only today, gain titles so the strip can label them. Verify on the Studio simulator closed, flat and book, and laptop, and confirm iPad's bar is unchanged.

**Status:** Not started (2026-10-15).

**PR 7, compose as a sheet (#1680; `Apple:`; per Decision 8).** `ComposeSurfacePolicy` on iOS returns a sheet in every layout; Mac and visionOS keep windows. The sheet already comes from the window's root (`ComposeRequestRouter.swift:66`), so a close or open cannot take it down and it is never presented again on a fold 〔.51454〕.
- A window opens only on request: an "Open in New Window" action in the compose sheet, shown only at regular width and falling back to the sheet if the scene request fails 〔.13943〕.
- In a wide window the sheet sits on the trailing side, if the 27.1 SDK offers a trailing sheet placement (read behind the guards in `Platform/`); otherwise the default placement, and Session 2 revisits it. Centered in a tall window.
- When the sheet opens, the draft captures the original's ID and quoted text; while a reply is up, the message behind cannot be archived, moved or swapped 〔.13567〕.
- ComposeWindowSlot and SceneAppearance scans read `ComposeWindowScene.swift`; any change to their text needs the maintainer's yes first. multi-window-and-restore.md's R5 (a mailto while compose is open) is re-read against the sheet before either merges.
- Verify Reply, New Message and a mailto on the iPad simulator and the Duo simulator closed, flat and book.

**Status:** Not started (2026-10-15).

**PR 8, nothing re-marked on a close or open (`Apple:`).** A reader rebuilt by a shell swap does not run mark-as-read again and keeps the message's Load Images state; a feed list's restored selection does not mark read. Carry an "already opened" mark with the parked message in `SceneNavigator`'s hand-off; only an explicit open marks read 〔.15446〕. Behaviour tests: Mark Unread, then a layout change, stays unread. Verify on the iPad simulator (resize across compact) and the Duo simulator (close and open). Decision 9's merge would make this unnecessary, and the merge PR deletes it.

**Status:** Not started (2026-10-15).

**PR 9, crease margins in book pose (`Apple:`).** The spec's 44 pt rule 〔row .53420〕, while a vertical fold is active:
- the list bar's trailing items, which on the Studio sat about 40 pt from the crease, move to its leading end, the folder-panel button included;
- message and article text starts at least 44 pt from the crease (a reader leading inset on the trailing page);
- confirmation dialogs, which present as popovers about 20 pt from the crease, become alerts, through `Platform/ConfirmationDialogPolicy.swift`;
- full-width text fields keep to one half.
Verify by measuring each against the crease on the Studio simulator.

**Status:** Not started (2026-10-15).

**PR 11, Duo docs (`no-changelog`).** An "iPhone Duo" section in `docs/apple.md`: the guard rule and where guarded code may live; `FoldGeometry` and the hinge hold; the spec's rules, with a link to it; the Studio posture procedure, including the spec's keyboard steps (Device > Keyboard, uncheck Simulate Hardware Keyboard; ⌥⌘K for one field) 〔item .54876〕; the CI leg or tripwire; and the line in `CLAUDE.md`'s CI notes if a leg landed. `docs/apple.md` is shared with docs-and-bookkeeping.md; one open PR at a time.

**Status:** Not started (2026-10-15).

**R1 is PRs 2 to 9 and 11, by the cut above.** Each PR says what the Duo simulator showed and what it could not check. PRs 2 to 6 and 9 change only the Duo, because each reads the fold region or vertical bars; PR 3 also makes the iPad width per window, and PRs 7 and 8 change iPad too. One caveat: if other iPhones on iOS 27.1 also get a vertical tab bar, PRs 5 and 6 change them too, which is the right fix there as well (unknown; #1963 saw a horizontal bar on iOS 27.0).

**PR 10, compact row drag (#1681; `Apple:`; R2, per Decision 6).** Attach the drag payload on every layout and keep only the sidebar drop gated on wide layouts. The fragment says it changes every iPhone. Prefer a behaviour test to the branch's source scan. Verify iPhone, iPad and the Duo Split View half on simulators, and open a `needs-verification` issue for a held press on a real iPhone. Revert path: the gate at `MessageListView+Rows.swift:163` comes back.

**Status:** Not started (2026-10-15).

**PR 12, drops into compose (`Apple:`; R2).** Images and files dropped onto the compose sheet become attachments, through the same path as the photo and file pickers 〔.14407〕. Verify a drag from Photos and Files in a Duo Split View half and on iPad.

**Status:** Not started (2026-10-15).

**The Studio simulator pass (no code, in Session 1, before and after PRs 3 to 9).** Ask before taking the Studio's screen. Triage the Studio's Duo refs read-only first and hand the maintainer a one-line delete list. Then run, filing one issue per finding:
- the spec's Device Hub chain on every screen, with a sheet open, the keyboard up and Select mode on: closed, Book, Open, rotate, Book (laptop), rotate back, closed; plus a cold launch while open, two windows, and closing with a draft in a background window 〔.28681〕;
- the spec's "What the Studio can test now" list 〔.28652〕, marking the items it already answered, and the "Watch for" column of its screen-by-screen table 〔.22580〕 (sign-in across a fold, Settings editors that save only on Done, a search re-run on a resize);
- book, laptop and open tall rotated 180°: `apple/project.yml:176-179` leaves out portrait upside down for the phone idiom, which the Duo reports, so those may be refused or boxed (inferred);
- continuity checks the shell swap may fail: Mark Unread then close and open (before PR 8); each sheet (Move, Filters, New Folder, New Address, invite, Source) across a close and open; the narrowing rule (a focused field wins, then Select mode, then an opened item) 〔.20662〕; VoiceOver focus after a close or open;
- whether a window can open, and is reported as supported, on the closed display, and what the closed display shows with a second window open (stage's comment and the spec disagree);
- a throwaway laptop prototype on a branch: the reader column showing only the message in the top half and a list panel below, checking that the message's web view survives the move without reloading 〔.49942〕;
- 3.2 B's list on the inner display, and typing into the split's search, then closing (the checklist's "Duo fold in the middle of a search"); 3.3 B to E (all under "Background from the rearchitecture");
- G1 at rows 30, 300 and 700 with repeat close-and-opens and a scroll during the refresh, and G2 across a pose change (the checklist's "Duo fold keeps the list's place", under "Background from the rearchitecture"); rows 300 and 700 use live-verification.md's `SoakBig` folder if it is seeded, also with the Unread pill on; skip what Decision 4 says is done;
- #1651 section E; #1962 on current stage;
- if merged by then: refresh-scheduling.md PR 4's check and multi-window-and-restore.md R6's instant placement.

Write the consolidated device checklist from this pass, the spec's "What needs hardware" list 〔.30260〕, #1651 E, and the 2.3, 3.1 and 3.3 Duo checks under "Background from the rearchitecture". On the Mini, also compare one ordinary-iPhone screen built with Xcode 27.0 and with CI's Xcode (Risk 6).

**Status:** Not started (2026-10-15).

### Session 2: with the device (from about 2026-10-23)

**Status:** Not started (2026-10-15).

1. **Device pass, part a (on arrival, on whatever TestFlight build is current).** The maintainer runs the checklist; the session prepares builds and files issues. The spec's hardware questions come first: the inner display's point size and fold frame (every number here assumes 951 × 669 pt); the keyboard in book, laptop, open wide and open portrait (height, hide key, formatting row, and whether it keeps the caret off the fold); tap accuracy at 20, 32, 44, 56 and 64 pt from the crease; whether taps on a laptop's upright half rock the device and how many list rows fit below the fold; fold-region timing for the hinge hold; tent; StandBy; flipping; Split View halves; a pinned video; leading swipes and the edge Back swipe with the strip on the left. Also record without re-proposing: duplicate toasts with two scenes; the list showing its top until the refresh after a close or open; the inspector and folder panel closing; address drag direction (#1682); notifications with two windows; a fold mid-gesture. Note whether two closed iPhone issues show up on the Duo, without reopening them: #2029 (a stray Reply after Command-R on the iPhone tab layout) and #1669 (a safe-area shift after rotation).
2. **Part b (once R1 is on a stage TestFlight build).** Re-run R1's rows: the columns, toasts, Search, the reader bar, compose, margins.
3. Pass list-place findings to multi-window-and-restore.md and sqlite-mail-store.md. Close #1962 on a pass, #1651 when section E is covered, #1652 when both gates are met. Ask the maintainer whether to delete `origin/duo`.
4. Ask Decisions 10 and 11 in one batch, then one PR each, bugs first:
   - the issues the pass filed;
   - **open portrait as the overlay** (#1686): in any tall regular window, the Duo's open portrait and iPad portrait alike, the message takes the full width and the list slides over it from a back button or an edge swipe, shown first when nothing is selected 〔.49274〕;
   - **the laptop layout** (#1649), from the Session 1 prototype: in laptop pose the reader column shows only the message in the top half, with the navigation bar hidden, and a panel below the fold holds the header (folder button, folder name, Filter, Select, Settings), the list (same anchor and checked rows), the bottom toolbar (Reply, Archive or Trash, Flag, Read, Page Up, Page Down, a Message menu, Compose) and the tab bar if the system puts it at the bottom 〔.49942〕〔.50159〕. Feeds and Search use the same panel; Addresses puts its list there. The Message menu and the page buttons go in every tall window's bottom toolbar 〔.50681〕. Compose in laptop pose: the body above the fold, fields and buttons below while the keyboard is down 〔row .51954〕;
   - **sheets by window shape:** trailing in a wide window, book included; centered in a tall one; Cabalmail's own sheets other than compose take only the region below a laptop fold 〔.13567〕;
   - the empty reader shows the folder's unread count 〔.14932〕;
   - Select mode per Decision 11, with any 27.1 modifier in a `Platform/` adapter (after feed-bulk-actions.md PR D);
   - #1692 per Decision 10;
   - turning on detached-reader-window.md's open-Duo entry point if it has landed (regular width, on request, falling back in place).
   Then Decision 9's spike on a branch.
5. Releases R3 (and R4 if the filed issues are many), each soaked on the Mini and the Studio simulator, and checked on the device per Decision 7. Open portrait and sheet placement change iPad too, so each says so in its fragment. If a fix needs `Navigation/SceneNavigator.swift`, wait for mail-navigation-refactors.md PR 1, since the type body is at 241 of 250 lines.

### Session 3: the one-tree merge (with Decision 9), or the reader-bar refactor alone

**Status:** Not started (2026-10-15).

**With the merge.** After platform-conditionals.md's FU-1 and Session 2. One root on iOS: a tab view with Mail, Feeds, Addresses and Search on both displays and on iPad, split views inside Mail, Feeds and Search that the system collapses on the outer display, Settings as a sheet from a gear on each tab's first screen, and folders as the system sidebar with one control for it (Cabalmail's folder button in book and laptop poses) 〔.18737〕〔.19068〕. Whether the folder sidebar overlays or the leading column becomes a stack is the spec's open choice 〔.19313〕, decided by prototyping both in Decision 9's spike. The merge deletes `ShellHandOff`, the tab and split shells' hand-off rules and PR 8's carry, hoists every sheet to the root, and keeps the split view's preferred column current so a collapse lands where the narrowing rule says 〔.20662〕. It carries FU-12 with it: the reader reads layout and window shape, not the size class. Several PRs, its own release or two; the source scans on `SplitShell.swift`, `TabShell.swift` and `ShellHandOff.swift` need the maintainer's yes. Risk: high.

**Without it (optional).** FU-12 alone, as `../platform-conditionals-followups.md`, FU-12 ("Reader action bar on ShellLayout") describes, renamed "the reader bar on layout and window shape": the reader reads `ShellLayout` and the window's shape instead of the size class, `ReaderToolbarPolicy.Placement` gains `.desktop`, and 15 blocks leave the allowlist. It must keep PR 6's inputs and the tall-window Message menu. Screenshots before and after on iPad (26 and 27 behaviour), narrow iPad, iPhone, Mac, visionOS and the Duo simulator. Risk: medium-high. If it never runs, nothing breaks.

### Hotspots

| File | This plan | Also edited by |
|---|---|---|
| `.github/workflows/apple.yml` | PR 1 | apple-ci-and-build-config.md, test-debt.md |
| `Shell/SplitShell.swift` | PRs 3, 9; S2 overlay, laptop, #1692; S3 | ipad-layout-and-keyboard.md PR H, mail-navigation-refactors.md PR 2, test-debt.md (scan conversions) |
| `Shell/SignedInRootView.swift`, `Shared/Banners/*`, `App/AppStateSignals.swift` | PR 4; S3 | kit-split.md PR 0 (the `canImport(Network)` guard at :260), detached-reader-window.md PR 4 (the banner stack) |
| `Shell/CompactTab.swift`, `Shell/TabShell.swift` | PR 5; S3 | platform-conditionals.md |
| `Mail/Reader/MessageDetailView*.swift`, `ReaderToolbarLayout.swift`, `ReaderToolbarPolicy.swift` | PRs 6, 8, 9; S2 laptop; S3 | platform-conditionals.md (FU-1), shared-load-error-state.md B3, detached-reader-window.md PR 2, hardening-web-and-writes.md PR 3 |
| `Compose/Windows/ComposeWindowScene.swift`, `ComposeRequestRouter.swift` | PR 7 | platform-conditionals.md (FU-2), multi-window-and-restore.md session 1, detached-reader-window.md |
| `Navigation/SceneNavigator.swift` | PR 8; S3 | mail-navigation-refactors.md PR 1, multi-window-and-restore.md |
| `Mail/MessageList/MessageListView+Rows.swift` | PR 10 | platform-conditionals.md, detached-reader-window.md PR 3 |
| `BulkActionBarLayout.swift` | S2 #1647 | feed-bulk-actions.md PR D |
| `docs/apple.md` | PR 11 | docs-and-bookkeeping.md |

> **Erratum (2026-10-15):** hardening-web-and-writes.md PR 3 merged to `stage` on 2026-10-15 as #2057 (`f078467`). It changed the body-rendering bridges (`HTMLBodyView.swift` and its bridge extensions), not the reader files in this row, so it no longer contends for them.

## Background from the rearchitecture

What the Studio pass and the device checklist take from the Wave 2 and 3 scope docs and the Wave 3 TestFlight checklist, which are not in the repo. Those waves ran every gate with Xcode 27.0, believing it matched CI; where they differ from this plan's Session 1 rules, as on the Xcode choice, this plan's rules win.

**3.2 (layout shells), Duo.** Behaviour on a real Duo was best-effort. The scope doc planned these checks for every shell PR (C to H): folding and unfolding on the Duo simulator while reading a message, a feed item and a search, and from the Settings tab; and narrowing and widening an iPad window across the size-class line and through the 700-725 pt band (#1716). No Duo check was planned for 3.2 B, which made the iPad's wide list the Mac's list (#1985; on iPad it was checked with the simulator's hardware keyboard: arrows, ⌘A, Esc, shift-click, Select mode with two rows, drag a row to the folder panel). 3.2 D carried search across a fold (the Search tab searches everywhere, #1970; narrowing or folding mid-search opens the Search tab, #1989) and kept Settings open across one.

- The 27.1 beta (27A9269) was used only to build and run on the Duo simulator, selected for that command alone with `DEVELOPER_DIR`, never `xcode-select`.
- 3.2 used no Duo API: the shells swap on the signal the size classes drive. One that proved necessary was to go in a `Platform/` adapter behind a compile-time check that is false under Xcode 27.0, plus `#available`, built with 27.0 before pushing.
- "Don't port the duo branch; its pieces are Duo extras." Each PR was to say what the Duo simulator showed and which Duo behaviour it expected but couldn't check on a real device. Every shell PR was to have screenshots before and after on macOS, iPad wide and narrow, the Duo inner display and iPhone. Every source scan was to stay green with its text untouched, except the changes the maintainer approved. Simulator runs were signed in as test account 1, tapping by accessibility id with SimDrive.
- 3.2 also named where each `duo`-branch piece would land after the shells; none has landed. `FoldRegionQuery` (`reservedRegions(kind: .division)` behind `canImport(SwiftUICore, _version: 8.0.85)` and `#available(iOS 27.1, *)`) as a `Platform/` adapter; `FoldingHost` (`hostHasFold`) set by `SplitShell` from the adapter and read by `ReaderToolbarLayout` (#1667); `MailRootView`'s `foldCrease`, `SplitGeometry` and crease pin (no resize handle on a folding host) as `SplitShell`'s geometry input and `ListColumnWidth.resolved(stored:minimum:maximum:crease:)` (#1686); `SignedInRootView`'s `FoldGeometry` and pose-aware banner insets in its chrome and `StatusBannerPlacement` (#1648); compact row drag in `MessageListView+Rows` by `shellLayout` (#1681); deployment target 27 not adopted. The table under "The `duo` branch" above replaces that mapping where the spec decides otherwise.

**3.3 (per-window restore), Duo.** The scope doc planned these checks for each PR on the Duo simulator (27.1 beta), and each PR was to say what it showed and what it expected but couldn't check on a device (for example which window a notification opens in on the real hinge, and whether the system restores both inner-display windows after a fold):

- **B** (a restore slot per window): unfolded, open two windows on one folder and Resume in one. Then fold and unfold while reading a message (the parked slot goes with the window).
- **C** (each window remembers its route): background the app, terminate it from Xcode (which keeps scene sessions), relaunch, and check each window's route comes back, folded and unfolded.
- **D** (one deep-link router): a notification tap folded and unfolded, cold and warm.
- **E** (one compose coordinator): Reply folded gives a sheet and unfolded gives a window. Run New Message and a mailto: in both states. Closing compose returns to the window it came from. (After this plan's PR 7, Reply gives a sheet in both.)
- **G1** (the list keeps its place across a fold): fold and unfold with INBOX scrolled to about row 30, row 300 and row 700. The list comes back at the same row after its refresh, repeat folds don't drift, and scrolling during the refresh wins.
- **G2** (the list reopens where you left it, #1896): as C, with each window's list scrolled.

**2.3 and 3.1, for the device checklist.** 2.3 (per-window navigation) named the checks that matter when a Duo arrives: open a message folded, unfold, and it is open beside its list; fold again and it is still open; the same with a feed item; a search's query and results survive a fold and an unfold; the Search, Addresses or Settings tab survives an unfold and fold back. 3.1 (per-window menu commands, its B and C): open a message folded, unfold, and use Reply and Mark as Read from the keyboard; then fold and use them again; each acts once, on that message; with the Search tab in front while folded, the Message menu follows the Search tab. XCUITest-synthesized chords don't reach SwiftUI commands (#1929's tester comment), so on the Duo simulator use the Mac's keyboard through Simulator.app's hardware keyboard.

**The Wave 3 TestFlight checklist, "At the Studio".** These need Xcode or the Duo simulator, so they cannot be done from a TestFlight build.

- **Duo fold keeps the list's place** (#2013, #2015). Only the closed pose was checked. The fold is set by clicking Device Hub's posture buttons on the Studio's screen.
  - Setup: Xcode 27.1 beta, a stage build on a copy of the iPhone Duo simulator, signed in. The row 300 and 700 steps need an account with 700 or more messages in INBOX.
  - Do: (1) INBOX, All pill, default sort, no search. Scroll so a message several rows down (about row 30) is at the top; note it. (2) Fold (Closed) in Device Hub, wait for the refresh, note the top message. Unfold (Open) and note it again. Repeat two or three times. (3) If the account allows, repeat with about row 300 and row 700 at the top. (4) Fold or unfold and start scrolling straight away. (5) Unfolded, with a message several rows down at the top, wait five seconds, stop the app from Xcode, and relaunch. Do it once more, changing the pose between the stop and the relaunch. Steps 1 to 4 exercise G1, step 5 G2.
  - You should see: after each fold or unfold, once the refresh lands, the same message at the top, with no creep over repeated folds. A scroll you start during the refresh is not undone. After each relaunch, the noted message at the top in either pose.
  - Wrong if: the list goes to the top or to a different message after a fold, creeps each fold, jumps back over your scroll, or reopens at the top in the open pose or after a pose change.
  - The maintainer approved fold clicks for the 3.2 layout-shells session, which drove real folds for #2006 and #2008, so a Studio session given GUI time can run this, though its click points may need re-measuring first.
- **Optional: Duo fold in the middle of a search** (#2006). The 3.2 D session's driver could not type on the unfolded display; the same rule was shown on the iPad simulator, so this was lower priority.
  - Do: folded, tap Mail and open INBOX. Unfold. Click in the search field at the top of the list, type a word that matches some mail, and press Return. Without touching anything else, fold. Note the selected tab and what it shows. Tap Mail, then Search again.
  - You should see: after folding, the Search tab is selected with your word and the same results. The Mail tab shows INBOX. Back on Search, the search is still there.
  - Wrong if: you land on Mail, on a page titled Search with no field (the old #1989 bug), or on an empty Search tab.

## How to start it

**Session 1 brief (paste):**

> Run Session 1 of the iPhone Duo plan (duo-support.md, read with 00-working-agreements.md from `docs/1.x/post-wave-3/`) for the Cabalmail Apple clients on current `stage`. The design is the maintainer's Oct 7 spec in the Claude Doc linked at the top of the plan; read it in full with the Claude Docs connector before writing anything, and treat its "Your book, laptop and portrait spec" and "Choices for you" as decided. Re-check every file:line first. Do not merge anything to `stage` while a release promotion PR is open. Write a one-page scope doc with Decisions 1 to 9 at the top, quoted in full, and one line per PR; post it and wait for the answers. Build with the Xcode CI selects ("Xcode is set to" in the latest Apple run), chosen per command with `DEVELOPER_DIR`, never `xcode-select`. Do not merge or port `origin/duo`; read it as a reference. Any Duo API goes in `Platform/` or `Shell/` behind `#if os(iOS) && canImport(SwiftUICore, _version: 8.0.85)` plus `#available(iOS 27.1, *)`. Before driving the Studio's screen, check that the maintainer's tester is not using it, and coordinate test account 1 sign-ins with other sessions.

> **Erratum (2026-10-16):** Before the scope doc, confirm that the spec doc opens through the Claude Docs connector. If it does not, stop and ask the maintainer to connect it: the Studio pass and the device checklist need its lists 〔.28652〕, 〔.22580〕, 〔.28681〕 and 〔.30260〕, which this plan does not restate. "Coordinate test account 1 sign-ins with other sessions" now means telling the maintainer first (00-working-agreements.md, "Working from the repo"); the rig's credential helper does not serve test account 1. Session 1 records its answers under this plan's decisions and its device checklist as `needs-verification` issues linked from its Status lines, as that section says.

**Read:** this plan and `00-working-agreements.md` from `docs/1.x/post-wave-3/`. What the session needs from the 3.2 and 3.3 scope docs and the Wave 3 TestFlight checklist is in "Background from the rearchitecture", and the Studio's Duo refs are listed under "The `duo` branch". Link the spec doc. Point at #1651, #1652 and #1963.

**Session 2 brief (paste when the device is in hand):** "Run Session 2 of duo-support.md. Here are Session 1's device checklist and its PR list. Start with part a of the device pass on the current TestFlight build, then ask Decisions 10 and 11 in one batch." Give it the same files plus Session 1's scope doc and checklist, and point it at `../platform-conditionals-followups.md`, FU-12.

> **Erratum (2026-10-16):** Session 1's scope doc, answers and device checklist are not files a later session can be handed. Session 2 reads the answers under this plan's decisions, the PR list in its Progress table, and the device checklist from the `needs-verification` issues its Status lines link (00-working-agreements.md, "Working from the repo"). If Session 1 did not record them there, ask the maintainer for them first.

**Rigs:** the Mac Studio (the Duo simulator, Device Hub, the stage-credential helper); the Mac mini for soaks and iPad and iPhone simulators; CI; the maintainer's Duo from about 2026-10-23.

## Risks and checks

1. **The simulator is not the device**, and every number in the spec is a simulator reading. Check: Session 2 on hardware, starting with the inner display's point size.
2. **R1 is live on a Duo the day it merges.** Check: each PR's Studio run before merge, and Session 2 part b.
3. **CI could stop compiling Duo code.** If `latest-stable` ever resolves to 27.0, or apple-ci-and-build-config.md pins 27.0, the guard turns false and the shipped app loses every Duo fix and runs boxed in on both displays. Check: PR 2's tripwire, and the leg selects its Xcode by path.
4. **The probe may find no 27.1 runtime** (the image lists none). Check: PR 1's stop rule.
5. **App Store acceptance of a beta-Xcode build is unverified.** Check: apple-ci-and-build-config.md owns it; this plan only needs 27.1 or later.
6. **The 27.1 SDK reportedly zeroes default view margins** on every iPhone (press, unverified). Check: Session 1 compares one ordinary-iPhone screen against a 27.0 build and files an issue if something moved.
7. **iPad changes ride along.** PR 3 (per-window width), PR 7 (compose sheet), PR 8, and Session 2's overlay and sheet placement change iPad because the spec chooses by window shape, not device. Check: each fragment says so, and each PR verifies iPad.
8. **R1 is larger than ten days.** Check: the priority order and the R1 cut; the rest moves to R2 without harm.
9. **Hotspot collisions.** Check: the table; one open PR per file.
10. **Source scans.** ReaderColumnFloor, ColumnToolbarOccupants and SidebarToggleRemoval read `SplitShell.swift`; ReaderColumnFloor also reads `SignedInRootView.swift`; ComposeWindowSlot and SceneAppearance read `ComposeWindowScene.swift`; CompactBrandMark reads `TabShell.swift` and `MessageDetailView.swift`. Any edit needs the maintainer's yes first. Session 3's folder control would change what SidebarToggleRemoval pins.
11. **Studio contention across plans.** ipad-layout-and-keyboard.md, multi-window-and-restore.md, refresh-scheduling.md, mail-navigation-refactors.md, feed-bulk-actions.md and platform-conditionals.md all verify on the Studio's Duo simulator. Check: one Studio GUI session at a time; each session posts before taking the screen and when it is done, and the maintainer settles clashes.
12. **A torn-down tree stays writable after a close or open** (`Navigation/TreeGate.swift:37-39`). No write has been seen. Check: watch in the Studio and device passes, including a close with Settings open (inferred trigger).

## Spec map

Every item in the Oct 7 spec doc, and where it lands. "Decided" marks the maintainer's Oct 7 choices.

| Spec item | Here |
|---|---|
| Flat: drag handle, stored width, at the fold if none (decided) 〔.48344〕 | PR 3 |
| Book: list pinned to the fold, handle hidden (decided) 〔.48854〕 | PR 3 |
| Unfold: one animation back to your width (decided) | PR 3 |
| Hinge data only to hold a fold layout 〔.47449〕 | PR 2 |
| Open portrait: the iPad-portrait overlay, iPad portrait too (decided) 〔.49274〕 | Session 2 |
| Laptop: message on top, list and controls in a panel below (decided) 〔.49942〕 | Session 1 prototype, Session 2 build |
| No taps above a laptop fold or within 44 pt of a book crease (decided) 〔row .53420〕 | PRs 3, 4, 6, 9; Session 2 laptop |
| Compose: a sheet in every layout, a window only on request 〔.51454〕 | PR 7 (Decision 8) |
| Compose in open portrait and laptop (decided) 〔.51710〕 | PR 7 (open portrait); Session 2 (laptop) |
| Replies on the trailing side in flat wide windows (decided) 〔item .54741〕 | PR 7; Session 2 sheets |
| Fold rule for floating elements 〔.10855〕 | PR 4 |
| System bars; bottom toolbar for message actions 〔.12267〕〔.12921〕 | PR 6; Session 2 laptop |
| Select mode hides the tab bar 〔.13393〕 | Decision 11 |
| Sheets trailing when wide, centered when tall, bottom half in laptop 〔.13567〕 | PR 7 (compose); Session 2 (the rest) |
| "Open in New Window" only at regular width, on request 〔.13943〕 | PR 7; detached-reader-window.md |
| Drag and drop for Split View 〔.14407〕 | PRs 10, 12 |
| Swipes with the strip on the left 〔.14697〕 | Device pass |
| Never open a message to fill a pane; unread count 〔.14932〕 | Met on stage; count in Session 2 |
| Mark read only on an explicit open; never reload on a resize 〔.15446〕 | PR 8; Decision 9 |
| Anchor scroll to content 〔.15645〕 | Met (reader); list stays "Anchor only" |
| Tent, StandBy, flipping, pinned video 〔.15883〕 | Device pass; no fixed heights checked in the Studio pass |
| One view tree; four tabs; Settings a sheet; folders the system sidebar; iPad tab bar (iPad tab bar decided) 〔.9897〕〔.18737〕 | Decision 9; Session 3 |
| @ inspector removed on iOS 〔row .17356〕 | Decision 10 |
| Multi-select kept across a fold 〔row .18218〕 | Met for mail on stage (2.3 F); feeds in feed-bulk-actions.md PR E |
| Search and tab state per window 〔row .18434〕 | Met for search on stage; the tab hand-off goes with Decision 9 |
| Narrowing and widening rules, VoiceOver focus, Back history 〔.20661〕 | Studio pass; ipad-layout-and-keyboard.md PR B; Session 3 |
| Sheets from the window's root 〔.21551〕 | Compose met; the rest with Decision 9 |
| State per window, including list width 〔.21788〕 | PR 3 (width); the rest met or Decision 9 |
| No Cabalmail animation on size or fold changes 〔.22320〕 | Rule for every PR |
| Studio test list and hardware list 〔.28652〕〔.30260〕 | Studio pass; device pass |

## Not in this plan

- **The detached reader window:** detached-reader-window.md, as its own session. No spanned shell is needed, because the spec keeps one split view in every open pose; its entry point follows the spec's gate (regular width, on request, in-place fallback), not a fold input.
- **CI's Xcode policy for every job, the `apple.yml` comment, `create-sim.sh` and explicit device types for the other legs, and App Store acceptance of beta-Xcode builds:** apple-ci-and-build-config.md (its Decision 2).
- **#2033, #1988, #1787, #2024, #2032** (iPad width transitions and keyboard commands that a close or open shares): ipad-layout-and-keyboard.md. Bugs there go first; its PR E waits on Decision 10.
- **List place across a close or open** (#2030, #2042, filter and search lists, rows past 250) and keeping the list model alive (declined): multi-window-and-restore.md and sqlite-mail-store.md. A rebuilt list must not drop a just-opened message from an Unread filter or re-run a search 〔row .23386〕〔row .24786〕; those plans own it. This plan reports device evidence.
- **FU-1 and the other platform-conditional follow-ups:** platform-conditionals.md. FU-12 stays here, in Session 3.
- **Non-Duo live checks and the `SoakBig` fixture:** live-verification.md. Every Duo check lives here.
- **SimDrive in CI and a non-fold smoke:** test-debt.md. SimDrive cannot fold.
- **Studio housekeeping** (merged branches, non-Duo rescue refs, the Duo simulator copy): docs-and-bookkeeping.md, after this plan's delete list.
- **A StandBy widget** (an unread count) and **Pencil markup**: not planned; the spec names them as later possibilities.
- **Android:** nothing foldable is planned.

## Sources

- The Oct 7 spec: Claude Doc "Cabalmail on iPhone Duo: Poses and Transitions" (https://claude.ai/code/artifact/0c0feb74-4160-4721-9f21-a173161becdc), read at doc rev 86 on 2026-10-13; block ids as cited.
- `00-working-agreements.md` in this folder; `../platform-conditionals-followups.md`, FU-12.
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Repo at 271e2e16, under `apple/CabalmailUI/`: `Shell/SignedInRootView.swift:39-49, 91-96, 118-130, 145-186, 188-223`; `Shell/SectionLayoutPolicy.swift:1-95`; `Shell/ShellLayout.swift:16-27`; `Shell/SplitShell.swift:28-94, 107, 139-188, 209-306`; `Shell/Columns/ColumnResizeHandle.swift:39-52, 174-185`; `Shell/Columns/ListColumnWidth.swift:38-52, 156-171`; `Shell/CompactTab.swift:62-78`; `Shell/TabShell.swift:54-83`; `Shell/WideMail.swift:15-42, 433-436`; `Shell/InspectorPresentationPolicy.swift:28-41`; `Navigation/ShellHandOff.swift:49-62`; `Navigation/SceneNavigator.swift:52-127, 233-316`; `Navigation/FolderListHold.swift:29-86`; `Navigation/TreeGate.swift:11-44`; `Shared/Chrome/ReaderToolbarPolicy.swift:85-88`; `Mail/Reader/MessageDetailView.swift:86-112, 203-216, 245-271`; `Mail/Reader/MessageDetailView+Toolbar.swift:72-89`; `Mail/Reader/MessageDetailViewModel.swift:135, 172, 221-223`; `Shared/Banners/StatusBannerPlacement.swift:31-55`; `App/AppState.swift:47, 101-108`; `App/AppStateSignals.swift:19-39`; `Compose/Windows/ComposeWindowScene.swift:37-79`; `Compose/Windows/ComposeRequestRouter.swift:58-110`; `Shell/Columns/MailReaderColumn.swift:46-63`; `Mail/MessageList/MessageListView+Rows.swift:155-196`; `Shared/BodyRendering/HTMLBodyView.swift:12-19, 627-640`; `apple/project.yml:28-32, 135-136`; `scripts/check-platform-conditionals.py:16-21`; `apple/CabalmailTests/*SourceScanTests.swift`.
- Git: `git rev-list --left-right --count origin/stage...origin/duo` (643, 16); `git cherry -v origin/stage origin/duo`; `git show origin/duo:apple/Cabalmail/Views/FoldingHost.swift`.
- CI logs: job 107988484017 (2026-09-25), 113958211841 (prod upload, 2026-10-09), 114506992226 (stage upload, 2026-10-11), 114626873483 (2026-10-12): each "Xcode is set to 27.1.0 (27A9269)"; iOS tests on "SimRuntime.iOS-27-0" and "iPhone-18-Pro". Runner image README: `actions/runner-images`, tag `xcode-27-arm64/20261006.0244`.
- GitHub, read 2026-10-13: open #1647, #1648, #1649, #1651, #1652, #1666, #1667, #1680, #1681, #1682, #1686, #1692, #1962, #1963; PRs #1675, #1676, #1677, #1687 merged into `duo`, not `stage`; #1555 closed 2026-09-13; closed not planned #1669 and #2029.
- Press: Hypebeast and MacRumors on the October 23 launch; GadgetReview, "Apple Now Accepting iPhone Duo App Store Submissions" (2026-10-07); Classmethod iOS weekly (2026-10-07).
- Sibling plans read for hand-offs: every plan in this folder.
