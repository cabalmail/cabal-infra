# iPad layout regressions and keyboard commands

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Two sequential sessions, not a project. Session 1 (Now) fixes the three Wave 3 regressions and the iPad menu commands in one release; Session 2 (Next, after that release's soak) takes the older layout bugs and #1988. Every mechanism is already traced in the issues and matches the code, nothing needs a server change or a migration, and the PRs are serial on shared files, so a coordinator and parallel threads would add nothing. Splitting at the release boundary frees the shared files for mail-correctness.md, multi-window-and-restore.md and mail-navigation-refactors.md between the two halves.
**Size:** M overall (Session 1: five PRs, one of them possibly only a finding; Session 2: three PRs, the last droppable). #1988, #2026 and #1929 start as investigations and may ship nothing.
**Priority:** Now for Session 1: #2032, #2033 and #2034 are Wave 3 regressions that reached prod with 1.31.0 (promotion PR #2043, merged 2026-10-12), and duo-support.md wants these width-transition bugs fixed first ("Bugs there go first", its line 191). Next for Session 2: those bugs predate Wave 3.
**Depends on:** nothing hard. Order only: #2043 merging (decision 3; met, it merged on 2026-10-12); feed-bulk-actions.md (PR C moves one line in `FeedItemListView.swift`); duo-support.md and mail-navigation-refactors.md (one open PR at a time in `SplitShell.swift`, PR H; mail-navigation-refactors.md's PR 1 goes first only if PR B needs more than about five navigator class-body lines).
**Unblocks:** duo-support.md (PRs A and B before its device pass); mail-correctness.md (its PR 6 after PRs A and G); mail-navigation-refactors.md (its PR 1 after PR B); multi-window-and-restore.md (R5 after PRs B and D; W2 never open beside PR C); detached-reader-window.md (its PRs 2 and 5 after PR C); feed-bulk-actions.md (reuses decision 1's rule); flags-and-cross-media.md (A3 after PRs A, C and F); platform-conditionals.md (order only, four shared files); test-debt.md (Session A starts after Session 1 merges; its A1 waits for this plan's `MessageListView+Selection.swift` PRs).
**Duo groundwork:** Fixes the open search result lost across a fold or unfold (#2033), a split first laid out too narrow (#1988; the unfold case is inferred), Select mode and Compose-beside-the-inspector on the inner display, and the menu commands a Duo with a keyboard shares; it adds no Duo API.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| Session 1, PR A. Wide-path selection (#2032, #2034, #2033's second half) | Not started (2026-10-15) |
| Session 1, PR B. The open search result across a layout swap (#2033's first half) | Not started (2026-10-15) |
| Session 1, PR G. The first key after launch (#1929) | Not started (2026-10-15) |
| Session 1, PR C. iPad menu commands (#2027, #2024, #2026) | Not started (2026-10-15) |
| Session 1, PR D. The mid-width Settings sheet (#2004) | Not started (2026-10-15) |
| Session 2, PR E. Compose beside the inspector (#1787) | Not started (2026-10-15) |
| Session 2, PR F. Filter pills (#2014) | Not started (2026-10-15) |
| Session 2, PR H. #1988, droppable | Not started (2026-10-15) |
| Decisions | 1, 2 and 4 to 8: no answer recorded (2026-10-15); 3 needs no answer, since #2043 merged on 2026-10-12 |

> **Duo spec (2026-10-13):** This plan was written before the maintainer's Oct 7 Duo spec (the Claude Doc linked in duo-support.md) had been read in the rearchitecture project. duo-support.md now follows it; where this plan's text disagrees with the points below, the points win. In the spec, "fold" means book or laptop pose, which changes no size class and swaps no shell; what this plan calls folding or unfolding the Duo is closing or opening it.
>
> - The spec changes iPad too, and duo-support.md owns those changes: the list width per tab and per window (its PR 3), compose as a sheet (PR 7), the open-portrait overlay in iPad portrait (Session 2), and the iPad tab bar with Decision 9's merge. Check this plan's `SplitShell` fixes against them.
> - PR B: a focused search field wins a narrow (the field, its results and the keyboard stay; the result is not pushed); the re-presented result is not refetched or re-marked read; VoiceOver focus moves to it.
> - PR C: Cabalmail's New Window is enabled only when the front window is at regular width.
> - PR D: Settings may become a sheet in every layout (duo-support.md Decision 9), so test the sheet at compact width too; in a wide Duo window it will sit on the trailing side.
> - PR E waits on duo-support.md Decision 10: if the inspector is removed on iOS, PR E and Decision 6 drop and #1787 closes with the removal.

## Decisions for the maintainer

Session 1 asks 1 to 5 in its scope doc; Session 2 asks 6 to 8 when it starts. All eight can be answered now.

1. **#2032: in Select mode, what does the reader show?** (a) **Recommended:** with one or more boxes checked, "N Messages Selected" (so "1 Message Selected" too); with none checked, whatever it showed before you tapped Select. (b) It keeps what it showed before Select until two are checked, then the count. Consequence of (a): the reader always agrees with the boxes, and it matches #2032's own "Expected"; under (b) the reader can show a message that is not checked (check two, uncheck back to one). Under either, a checkbox never opens or marks a message. Default: (a).
2. **When you tap Select with a message open:** (a) **Recommended:** start with no box checked (a Shift- or Command-click selection of two or more still carries in); (b) start with the open message checked, which is what the code does today (inferred from code, medium-high confidence; PR A reproduces it first). Consequence of (a): a bulk Archive acts only on rows you checked. Default: (a).
3. **Merge this plan's PRs only after #2043 (1.31.0) merges?** Yes (**recommended**) / No. Consequence of yes: 1.31.0 reaches prod with #2032 to #2034, as you already accepted ("File Issue only, no need to hold the release"), and the fixes get their own soak and release notes. With No, a fix merged first rides 1.31.0 unsoaked, and its changelog entry lands in the next release's notes because 1.31.0 is already collated. Default: yes; PRs stay in draft until #2043 merges. #2043 merged on 2026-10-12, so this needs no answer now.
4. **#2027, asked only if iPadOS's own File > New Window already holds Command-N:** (a) **Recommended:** replace the system's File > New group with our own New Message (Command-N) and our own New Window (no shortcut); (b) leave New Window on Command-N and put New Message on Shift-Command-N. Consequence of (a): Command-N means New Message on iPad as on the Mac, and New Window stays in the File menu without a chord. This is the iPad twin of multi-window-and-restore.md's decision 2 (Mac New Window, no shortcut), so one answer can settle both. Option-Command-N is taken by Feeds > Subscribe to Feed. Default: (a).
5. **Issue closings, answer each:** (a) close #1985 once PR A has merged and the iPad keyboard and trackpad checks (the Wave 3 TestFlight checklist's, listed under "Background from the rearchitecture") pass on that stage build? (b) close #1929 if PR G shows that every first key press after launch is lost, in a text field too (iPadOS's own)? Yes to both (**recommended**). Consequence: each closes on recorded evidence, not on reading "Anything I haven't reported is good" as covering it. Default: comment on both, leave them open.
6. **#1787: may the fix change the test that pins which toolbar buttons are protected from the overflow menu (`ToolbarVisibilitySourceScanTests`)?** Yes (**recommended**) / No. Consequence of yes: New Message can be ranked above the other buttons while the Addresses inspector is open, and every rule that test protects keeps a test. platform-conditionals.md will ask to re-point the same test when it moves `ToolbarVisibility.swift`; one yes can cover both. Default: no test change; PR E tries only fixes that leave it alone and, if none works, reports and leaves #1787 open.
7. **#2014: when the filter pills don't fit on one line:** (a) **Recommended:** a tighter row (less spacing and padding) before they stack; (b) one row that scrolls sideways; (c) leave the stacking. Consequence of (a): All, Unread and Flagged should stay on one row at 322 to 360 pt (inferred, not measured). The change reaches the mail and feed lists on every platform, Mac, iPhone and visionOS included; the sidebar pill rows stay as they are. Default: (a).
8. **#1988: take on the narrow-then-Zoom fix as the last, droppable PR?** Yes (**recommended**) / No. Consequence of yes: about 30 lines in `SplitShell` that rebuild the split once, shipped only if an open message survives. Default: no fix PR; Session 2 re-measures once and comments on #1988. (The rearchitecture project's per-window restore and links discussion recorded "don't take it on unless [the maintainer] asks", speaker not recorded.)

## What you'll see change

Session 1:
- **PR A (#2032, #2034, half of #2033):** on iPad (and, inferred from code, in visionOS's Mail tab), checking a message in Select mode no longer opens it or marks it read. Tapping the last-opened row works again on visionOS's Search tab after Back, and on iPad after a narrow and widen.
- **PR B (rest of #2033):** a search result you are reading stays open when an iPad window narrows or widens, and when a Duo folds or unfolds.
- **PR G (#1929):** the first Command-A after launch selects every message, if the cause is ours. Otherwise nothing visible, and #1929 records the finding.
- **PR C (#2027, #2024, #2026):** File > New Message (Command-N) on iPad works from any screen, including Settings, a reader and an open inspector. #2024 has nothing visible: it removes a UIKit warning that the shared chords' behaviour is undefined. Command-comma changes only if the menu check finds a cause.
- **PR D (#2004):** in a mid-width iPad window, Settings opens with its category list beside the pane, and Done closes the sheet from every pane. The pane beside the list still reads "Select a category" until you pick one, because iOS deliberately opens Settings with nothing selected (`SettingsInitialSelectionTests`).

Session 2:
- **PR E (#1787):** with the Addresses inspector open, New Message and the `@` button stay in the bar or its overflow at every iPad width.
- **PR F (#2014):** the filter pills stay on one line in narrow list columns, per decision 7.
- **PR H (#1988):** after narrowing an iPad window and choosing Zoom, the list comes back beside the reader with the open message kept.

## Why

Wave 3 put the iPad split on the Mac's selection path (#2001, 3.2 B) and made a narrowing mid-search open the Search tab (#2006, 3.2 D). The 2026-10-12 soak found two regressions from those PRs (#2032, #2033) and a third on visionOS by the same mechanism (#2034). The maintainer's ruling after that soak was "File Issue only, no need to hold the release". They are live on stage and will reach prod with 1.31.0.

The maintainer's by-hand iPad pass of the Wave 3 TestFlight checklist (2026-10-11) found Command-N and Command-comma failing, then working, on the same build (#2027, #2026). A later code reading on #2027 found that iOS has no New Message menu command, so Command-N exists only while a list's toolbar button is on screen; that is a candidate cause, not tested. #2024 was found in passing by a session installing a stage build on the Duo simulator (iOS 27.1). The rest are pre-Wave 3 layout bugs the waves filed and left: #2004, #1787, #2014 and #1988. The checklist's "Known bugs you may hit" lists #2004, #2014 and #1988, plus #1929 (quoted under "Background from the rearchitecture").

These are the transitions a Duo makes. `ShellLayout` maps the iPad split and the Duo inner display to `.split`, and a compact iPad window and the Duo outer display to `.tabs` (`apple/CabalmailUI/Shell/ShellLayout.swift:16-27`). A fold is a split-to-tabs swap, so #2033 is the fold-mid-search case workstream 2.3 left out (its scope doc listed under "Left out": "The open search result surviving a fold. Today it doesn't").

## Where things stand

Issue states read on GitHub on 2026-10-12. Paths are under `apple/CabalmailUI/` unless noted.

| Issue | State | What happens, and where |
|---|---|---|
| #2032 | open; regression, needs-verification | One checked box opens the message and marks it read, because on the wide path the reader follows the selection set and the checkbox writes that same set. `wideList`'s `.onChange(of: model.selectedRefs)` sets `selection` at one ref (`Mail/MessageList/MessageListView+Selection.swift:381-385`); the checkbox calls `toggleSelection` (`MessageListView+Rows.swift:37-48`); the count pane starts at two (`Shell/Columns/MailReaderColumn.swift:19-20`), and its label is plural only (:49). |
| none | inferred from code | Select mode starts with the open message checked: opening a message on the wide path selects it (`+Selection.swift:424`), `toggleBulkMode` clears the set only when leaving (`MessageListViewModel+Bulk.swift:22-25`), and the box draws from `isSelected` (`+Rows.swift:30`). `SelectionModel.handOff` already treats a lone selection outside Select mode as "the open message" (`Shared/Primitives/SelectionModel.swift:46-58`). |
| #2033 | open; regression, needs-verification | Narrowing opens the Search tab without the open result, because the tab keeps its own: `ShellHandOff.layoutChanged` returns the Search tab (`Navigation/ShellHandOff.swift:49-56`), `SearchView` holds its result in `@State selectedEnvelope` (`Mail/Search/SearchView.swift:25`), and `rehand` clears the navigator's (`Navigation/SceneNavigator.swift:235`). Widening leaves the row highlighted but dead: `selectRow` assigns an equal one-ref set (`+Selection.swift:423-426`), so `onChange` never fires. |
| #2034 | open; needs-verification | visionOS Search, after Back: the same dead re-tap. `.ornament` is wide (`Mail/MessageList/MessageListLayout.swift:18`); Back clears `selectedEnvelope` through `navigationDestination(item:)` (`SearchView.swift:41`) but not `selectedRefs`. |
| #1985 | open | Fixed in code by #2001 (merged 2026-10-10, "Part of #1985"). Its keyboard and trackpad checks (the Wave 3 TestFlight checklist's, listed under "Background from the rearchitecture") have no recorded result on a real iPad; whether "Anything I haven't reported is good" covered them is disputed (live-verification.md). |
| #1929 | open; verified | The first Command-A after launch is ignored and a second works (#2001's Findings, iPadOS 27 simulator). The repro taps a row first, which already sets list focus (`+Selection.swift:411`), so focus may not be the cause. |
| #2027 | open | No New Message menu command on iOS: `.commands` holds the Message, Feeds and Settings menus only (`apple/Cabalmail/CabalmailApp.swift:69-77`). Command-N is a toolbar `.keyboardShortcut` at `Mail/MessageList/MessageListView.swift:365` (Mac branch) and :388 (iOS branch), and at `Feeds/ItemList/FeedItemListView.swift:152` on `composeButton`, which both branches use (:72-83). The Mac's is `CommandGroup(replacing: .newItem)` (`apple/CabalmailMac/CabalmailCommands.swift:38-54`), which is also why the Mac has no File > New Window (the Wave 3 TestFlight checklist: on the Mac, File > New is New Message). The iOS main `WindowGroup` has no id (`CabalmailApp.swift:49`). |
| #2026 | open | Not reproduced. Candidates in its 2026-10-11 comment: the system's own Settings item, or a swallowed first press. `SettingsMenuCommand` replaces `.appSettings` (`CabalmailApp.swift:100-111`). |
| #2024 | open | Both menus declare Command-T and Shift-Command-8 (`Commands/MessageMenuCommands.swift:51, 54`; `Commands/FeedsMenuCommands.swift:43, 46`); `SharedChordPolicy` enables one of each. AppKit accepts this; UIKit's MenuBuilder logs "undefined behavior". Nobody has pressed the chords to see a misbehaviour. |
| #2004 | open | The sheet's `NavigationSplitView` has no `columnVisibility` and no initial selection on iOS (`Settings/SettingsView.swift:24-36, 72-74`), so a mid-width sheet shows only "Select a category". The pane's Done uses the environment's `dismiss` (`Settings/SettingsSheet.swift:30-43`), which pops the pane, not the sheet (issue comment 2026-10-10). |
| #1787 | open; tester-found | With the inspector open, Compose leaves the bar and the overflow. On iOS Compose is a default-placement `ToolbarItem` with `.keepsInBar()` (`MessageListView.swift:381-393`); `@` is `.primaryAction` with `.keepsInBarFirst()` while open (`Shell/WideMail.swift:307-313`). At 714 pt `@` also left the bar (comment 2026-10-10). |
| #2014 | open | `FilterPillStrip` is one row, else a stack (`Shared/Chrome/FilterPill.swift:57-66`). Only the mail list (`MessageListView+Filter.swift:43`) and feed list (`FeedItemListView+FilterBar.swift:16`) use it; the sidebar rows draw `FilterPill` in a plain `HStack` (`Shared/Chrome/SidebarFilterPillRow.swift:35-43`). Seen at a 322 pt column, and at 360 pt in Select mode with two-digit counts (comment 2026-10-12). |
| #1988 | open; needs-verification | The split is sometimes first laid out at 534 pt during a Zoom, so UIKit floats the list and keeps it floating. A rebuild-once fix tiled 10 of 10 but lost the open message, because the second split in one swap got no hand-off (comment 2026-10-10). |
| #2029 | closed, not planned | See "Not in this plan". |

`SceneNavigator`'s class body is 241 of SwiftLint's 250 (non-blank, non-comment lines 50-524; mail-navigation-refactors.md:39 agrees), and `shellHandOff` is already a stored property (`SceneNavigator.swift:100`).

## The plan

**Rules for both sessions.** One PR at a time on any hotspot. One Apple PR from this plan in CI at a time; while another Apple session is active, push only when no other `apple.yml` PR run is going (mail-correctness.md follows the same rule; the working agreements say one run takes six to eight macOS jobs against about five at once). #2043 merged on 2026-10-12, so decision 3 holds nothing back. Each PR carries an `Apple:` changelog fragment unless it changes nothing visible. Each PR names the source scans that read its files before editing them; only PR E may move an anchor, and only with decision 6's yes; anything else that would goes to the maintainer first.

### Session 1 (Now): regressions and commands, one release

**PR A. Wide-path selection (#2032, #2034, #2033's second half; decisions 1 and 2).**
- First reproduce #2032 and the Select-entry case on the Mini's iPad simulator. If the entry case reproduces, file an issue for it.
- Scope: a pure rule for what the reader shows from Select mode, the checked set and the open message, extending `MailReaderChoice.choose`. Under decision 1 (a), in Select mode the set never writes `selection`, one or more checked shows the count (add the singular label), and none shows what was there. Outside Select mode, unchanged. Under decision 2 (a), entering Select mode drops a lone selection and keeps two or more. A tap on an already-selected row re-opens it when the reader is empty, so an equal set is not a dead tap. On visionOS's Search tab, clear the list's selection when the pushed reader pops. Keep the rule generic so feed-bulk-actions.md can reuse it.
- Files: `MessageListView+Selection.swift` (`wideList`, `selectRow`), `Shell/Columns/MailReaderColumn.swift` or a policy file beside it, `MessageListViewModel+Bulk.swift` (decision 2 only; a shared hotspot), `SearchView.swift`. Not `virtualizedList`. Scans: `SwipeActionContainerSourceScanTests` anchors on `func virtualizedList(` in `+Selection`; `CompactBrandMarkSourceScanTests` reads `SearchView.swift`.
- Tests: policy tests on the Mac host for one, two and back to one checked; entering Select with one and with three selected; a re-tap after the reader cleared; outside Select mode unchanged. `MailReaderChoiceTests`, `SelectionModelTests` and `MailEventSelectionPolicyTests` stay green.
- Verify: CI. Mini iPad simulator: #2032's steps with server read state before and after; check one box, then narrow and widen, and confirm the reader still ignores the box (Select mode crosses the swap); #2033's narrow, widen and re-tap. visionOS simulator for #2034 (PR CI only builds visionOS). Studio Duo simulator, inner display: Select mode, then one box checked across a fold and unfold.
- Risk: medium. This is the Mac's selection path too: click, Shift-click and Command-click on the signed Mac build.

**Status:** Not started (2026-10-15).

**PR B. The open search result across a layout swap (#2033's first half).**
- Scope: narrowing or folding mid-search opens the Search tab with the result pushed; widening or unfolding with a result open shows it in the split's reader. Hold the result in the `ShellHandOff` value beside the search hand-off it already makes, so the navigator gains no stored property, and let `SearchView` take it on appear, as the feed reader takes `takeItemForHandOff()` (`Navigation/FeedNavigationState.swift:73`). If mail-correctness.md's PR 2 left a search re-run that drops the open result to this plan (its line 83), fix it here.
- Files: `ShellHandOff.swift`, `SceneNavigator.swift` (inside the `ShellHandOff` extension at :700-728), `SearchView.swift`, `Shell/WideMail.swift` only if the split's reader needs the seed. Count class-body lines before writing. If B needs more than about five, stop and tell the maintainer: mail-navigation-refactors.md's PR 1 goes first (its line 112) and B rebases on it.
- Tests: `ShellHandOffTests` for both directions, and a leftover search behind another tab still ends (#1989's rule).
- Verify: iPad simulator narrow and widen, 2 of 2 each way; Studio Duo simulator fold and unfold mid-search with a result open (ask before driving the Studio's GUI).
- Risk: medium; the navigator is a shared hotspot.

**Status:** Not started (2026-10-15).

**PR G. The first key after launch (#1929). Investigation first; may ship nothing.**
- Run it on the Mini while B is in CI. Reproduce with #2001's steps. Since the repro's tap already requests focus, test the cheap question first: after the tap, press Down or Esc, then Command-A, and see whether the first press is lost whatever the key. Then the same in a text field (#1929's tester control). Lost everywhere means iPadOS's own: record it and apply decision 5b. Lost only in the list: try focus on appear, without taking the search field's focus (`SearchFieldFocusPolicy`, #1425).
- G comes before C because its answer also tests #2026's and #2027's swallowed-first-press candidate.
- Verify: Simulator.app's hardware keyboard. Synthetic XCUITest chords are unreliable here: workstream 3.1's scope doc, from #1929's tester comment, records them not reaching SwiftUI commands, yet #2026's body records one opening Settings on 2026-10-10, and #1929's tester showed Command-A reaching a text field. Real keyboard on the maintainer's list.

**Status:** Not started (2026-10-15).

**PR C. iPad menu commands (#2027, #2024, #2026; decision 4).**
- First, with the menu bar opened by the pointer on the iPad simulator: does File > New Window carry a shortcut, and does the app menu list Settings once or twice? Record both in the PR.
- #2027: a public `NewMessageCommand` in `Commands/`, installed by `CabalmailApp`. With no clash, `CommandGroup(after: .newItem)`. Under decision 4 (a), `CommandGroup(replacing: .newItem)` with New Message plus our own New Window item; replacing removes the system item, so ours must open a window itself (the `WindowGroup` needs an id or a scene-activation request; check that existing windows still restore). New Message opens compose for the main window in front, else the last active one, through `ComposeCoordinator.open(seed:from:)` (`Compose/Windows/ComposeCoordinator.swift:82-86`), and stays enabled with a composer in front. 3.1 removed the last-active fallback from the commands; #2027's comment asks for it here, and workstream 3.1's scope (its first risk: if `@FocusedValue` came back nil on a platform with nothing focused in the front window, keep the fallback there and say so) allowed keeping one where a gap showed. Say so in the PR.
- Then one Command-N per platform: delete the iOS branch's chord at `MessageListView.swift:388`; in `FeedItemListView.swift` move the chord from `composeButton` (:152) to the `#if os(macOS)` branch's call site (:74), which keeps the Mac's toolbar chord with no new conditional. Take that line only while no feed-bulk-actions.md PR is open there.
- #2024: on iOS, declare Command-T and Shift-Command-8 only on the front section's item, through the optional `.keyboardShortcut` and a runtime `HostPlatform` read (`Commands/` is under the conditional ratchet, so no new `#if`). The Mac keeps both declarations. Moving a chord at runtime makes iPadOS rebuild its key commands: switch Mail to Feeds and back in one window and in two, pressing Command-T in each, before relying on it. Confirm on the Studio's Duo simulator that the MenuBuilder lines are gone.
- #2026: if the system Settings item wins, move ours to `CommandGroup(after: .appSettings)` as the HIG asks (#2026's comment). Otherwise change nothing.
- Fix the "(hold Cmd)" comment at `CabalmailApp.swift:65-68` (#2025's closing comment); docs-and-bookkeeping.md leaves it to this PR. #2025's comments give the facts: holding Command shows shortcuts only on iPadOS 18 and earlier; on iPadOS 26 and later the commands sit in the menu bar, opened from the top edge or the app's name.
- Scans: `CabalmailApp.swift` is read by `ColorTokenSourceScanTests`, `ConfirmationDialogRoleTests`, `MenuPickerSourceScanTests` and `SceneAppearanceSourceScanTests`; `MessageListView.swift` by `ToolbarVisibilitySourceScanTests`, `SwipeActionContainerSourceScanTests`, `MessageListRefreshRoutingTests`, `LaunchRestoreSequencingSourceScanTests` and `CompactBrandMarkSourceScanTests`; `FeedItemListView.swift` by the last two.
- Tests: `SharedChordPolicy`'s declaration rule (Mac both, iOS one); `MessageMenuAvailabilityTests`, `FeedMenuAvailabilityTests` and `WindowCommandsTests` stay green.
- Verify: iPad simulator through the menu bar and Simulator.app's keyboard; visionOS (CI build, then Command-N on the visionOS simulator, since `CabalmailApp` is the iOS and visionOS app); the Mac's menus unchanged on the signed build.
- Risk: low to medium.

**Status:** Not started (2026-10-15).

**PR D. The mid-width Settings sheet (#2004).**
- Scope: hand the sheet's own dismiss to the pane's Done, and give the sheet's split a `columnVisibility` that shows the list beside the pane at regular width. Keep `initialSelection` as it is (`SettingsInitialSelectionTests`).
- Files: `Settings/SettingsSheet.swift`, `Settings/SettingsView.swift` (`CompactBrandMarkSourceScanTests` reads it; leave the `compactBrandMarkTitle` line).
- Verify: Stage Manager windows near 714 pt and at full width, both issue steps; iPhone Settings tab unchanged; Duo inner display.
- Risk: low. The close-on-navigate question (the one #2006 left open) is multi-window-and-restore.md's; whoever lands second rebases on `Shell/SettingsSheetPresenter.swift`.

**Status:** Not started (2026-10-15).

**Release and soak.** A, B, G, C and D ride one release. The Mini soak re-runs #2032's to #2034's steps with a second agent, plus the menu checks. A and B are the must-land pair for the Duo: they need to be on `stage` before duo-support.md's device pass (about 2026-10-23), which uses the current stage TestFlight build. The rest can follow.

### Session 2 (Next): older layout bugs and #1988, after Session 1's soak

**PR E. Compose beside the inspector (#1787; decision 6).**
- Measure first at 714 and 834 pt with the inspector open, walking the overflow. Try, least visible first: give Compose the explicit `.primaryAction` placement `@` has (the scan's counts stay); then, with decision 6's yes, rank Compose above `.high` while the inspector is open. `@` must stay reachable (#1670's rule).
- Files: `MessageListView.swift` (:381-393, which PR C also edited), `Shell/WideMail.swift`, maybe `Shared/Chrome/ToolbarVisibility.swift`; the scan only with decision 6's yes. `ToolbarVisibilitySourceScanTests` (:10-47) pins two `.keepsInBar()` in `MessageListView.swift`, the `@` toggle's text and one `.keepsInBarFirst()` in `WideMail.swift`, and the guard in `ToolbarVisibility.swift`. platform-conditionals.md's FU-19 moves that file and re-points the same scan: one open PR at a time on both.
- Verify: iPad simulator at both widths, inspector open and closed; Studio Duo inner display with the inspector open. The iOS Compose item is shared with the iPhone and the Duo outer display, where `.keepsInBar()` exists for #1647 (open), so also check an iPhone and a folded Duo. Screenshots before and after.
- Risk: low to medium. Ranking differs by OS version; `keepsInBar` does nothing before iOS 27 (`ToolbarVisibility.swift:17-18`).

**Status:** Not started (2026-10-15).

**PR F. Filter pills (#2014; decision 7).**
- Scope: under (a), a tighter one-row step in `FilterPillStrip` before the stack. If the pill's own padding (`FilterPill.swift:32-33`) must shrink, pass that from the strip so the sidebar rows don't change. Under (b), a horizontal scroll row.
- Files: `Shared/Chrome/FilterPill.swift`; `MessageListView+Filter.swift` only if the trailing controls need room.
- Verify: iPad Stage Manager at 698 to 714 pt; full width in Select mode with two-digit counts; the feed list. The strip has no OS gate, so also a narrow Mac list column, a small iPhone and visionOS. `FilterPillTests.swift:77` renders the strip.
- Risk: low. Pill identifiers (`filter.pill.*`) and VoiceOver labels must not change; soak lanes key on them.

**Status:** Not started (2026-10-15).

**PR H. #1988, droppable (decision 8).**
- Re-measure before writing code: does a second split built in one swap now get the open message? The re-park in `rehand` (`SceneNavigator.swift:256-262`) was already on stage (PR #1965, merged 2026-10-08) when 3.2 H's rebuild lost the message on 2026-10-10. What changed since is 3.3 B (#2003, each window parks its own restores) and 3.3 C (#2005, each window keeps its own route), both merged later that day, which #1988's comment named as the pending change. Whether they fix it is unknown (inferred, low confidence); the re-measure is the only evidence. If yes, land the value type that notes a first layout under 600 pt and asks for one rebuild at the next layout of 600 pt or more. If no, stop and comment on #1988.
- Files: `Shell/SplitShell.swift`, a small new type in `Shell/`, its tests. Not `SceneNavigator.swift` without asking. Scans: `ColumnToolbarOccupantsSourceScanTests`, `ReaderColumnFloorSourceScanTests` and `SidebarToggleRemovalSourceScanTests` read `SplitShell.swift`.
- Order: `SplitShell.swift` is also duo-support.md's PR 3 (columns on the crease) and mail-navigation-refactors.md's PR 2. If duo-support.md's PR 3 is open or about to open, H yields and re-measures after it changes the split's geometry.
- Verify: iPad simulator narrow-then-Zoom, 10 rounds with a message open and with a search result open; Studio Duo unfold, since an unfold may lay the split out first at the outer display's width (inferred). Check no write goes through the first tree after the second appears (`Navigation/TreeGate.swift:37-39`; duo-support.md's Risk 10 watches the same path).
- Risk: medium. A new identity resets column state.

**Status:** Not started (2026-10-15).

**Release and soak.** E and F ride one release; H in its own if the soak allows, so a regression is easy to trace. Device checks hold Promote, not merge.

**The maintainer's by-hand list (stage TestFlight, real iPad with keyboard and trackpad).** After Session 1: Command-N from the Settings tab, from a reader and with the inspector open; Command-comma right after a cold launch (if it fails, open the app menu and note what Settings shows); Command-T and Shift-Command-8 on a message and a feed item, switching Mail and Feeds between; the first Command-A after a cold launch; Select mode with one unread message checked; the #2001 keyboard and trackpad checks (listed under "Background from the rearchitecture") for decision 5a. After Session 2: Compose with the inspector open, and the pills at full width in Select mode.

**Hotspots.** Each held only while its PR is open. This plan: `MessageListView+Selection.swift`, `SearchView.swift`, `ShellHandOff.swift`, `SettingsView.swift`, `SettingsSheet.swift`, `FilterPill.swift`, `MessageMenuCommands.swift`, `FeedsMenuCommands.swift`, `CabalmailApp.swift`. Shared: `SceneNavigator.swift` and `MessageListView.swift` (mail-navigation-refactors.md, multi-window-and-restore.md, duo-support.md; the full list is in mail-navigation-refactors.md's table), `MessageListViewModel+Bulk.swift` (mail-correctness.md, shared-load-error-state.md), `Shell/WideMail.swift` and `ToolbarVisibility.swift` with its scan (platform-conditionals.md), `FeedItemListView.swift` (feed-bulk-actions.md), `SplitShell.swift` (duo-support.md, mail-navigation-refactors.md). platform-conditionals.md also edits `+Selection`, `SettingsView.swift` and `SearchView.swift`.

## Background from the rearchitecture

What the sessions need from the Wave 3.1 and 3.2 scope docs and the Wave 3 TestFlight checklist, which are not in the repo.

**Wave 3.2 (layout shells): the PRs this plan follows up.**
- **3.2 B (#2001, "Part of #1985"):** the iPad list in the split took the Mac's path (`isWideLayout` reads `shellLayout`; `MessageListView+Rows.swift`, a pure helper and its test). What it promised on iPad: a hardware keyboard moves the selection with the arrow keys, Home and End, and Page Up and Page Down; Command-A selects every row and Esc clears the selection; Shift-click and Command-click extend the selection; checking two or more rows in Select mode shows "N Messages Selected" in the reader; rows can be dragged onto a folder in the folder panel; the same for visionOS if its list was on the iPhone path too (unchecked then).
- **3.2 D (#2006):** `TabShell` and `OrnamentShell` replaced `CompactSectionTabs` and `VisionSectionView` on one tab list held as data, with a compact mail stack built from the shared columns. The Search tab no longer narrows itself to the Mail tab's folder (#1970), and narrowing an iPad window, or folding a Duo, mid-search opens the Search tab with its field, query and results (#1989). The #1989 rule sits in the navigator: when the layout turns to tabs while the search model holds an active search, the tab becomes `.search`; widening from the Search tab keeps the query. The compact mail stack has no search: a folder or feed pick ends the search only in the shells that show the search field (Desktop and Split, #1217), and on tabs the Search tab's search ends only from the Search tab. D was to touch the navigator only for that transition and, since 3.2's Settings-across-a-fold question was answered yes (2026-10-09), one Settings transition (the split's sheet and the Settings tab as one navigator state).
- **3.2 H (#1988, droppable):** investigate #1988 on the iPad simulator and take the least visible fix that works, in `SplitShell.swift` (possibly `Shell/Columns/ListColumnWidth.swift` or `SectionLayoutPolicy.swift`), so that after narrowing an iPad window to compact and choosing Zoom the list comes back beside the reader instead of floating over a dimmed one ("at the least, something on screen brings it back"). Its rebuild lost the open message (#1988's 2026-10-10 comment), so #1988 stayed open.

**Wave 3.2's regressions to re-test.** Each rule the layout shells moved, with how it was checked. Re-run the rows whose files or transitions a PR here touches.

| Issue | Rule | Check |
|---|---|---|
| #1679, #1716, #1714 | The split never builds below its width floor; no band of widths leaves the window with only a placeholder; growing to full screen and back keeps a list | `SectionLayoutPolicyTests`; on iPad, narrow and widen across 600 pt and through 700-725 pt, and go to full screen and back |
| #1690, #1626, #1670, #1647 | No sidebar toggle on iPad; the column bar's occupants and ranks; the inspector can always be closed | The layout scans (`ColumnToolbarOccupantsSourceScanTests`, `SidebarToggleRemovalSourceScanTests`, `ToolbarVisibilitySourceScanTests`); iPad and the Duo inner display, inspector open and closed |
| #1787 | With the inspector open, New Message vanishes from the bar and the overflow | Open, not 3.2's to fix. 3.2 E was to move the toolbar unchanged and screenshot it, so a later fix starts from a known state |
| #1624 | The Mac's content-column width write is deferred out of the layout pass | `ContentColumnWidthDeferralSourceScanTests`; resize the Mac window's columns |
| #1663, #1665 | The inspector doesn't open unasked; the Duo write-back filter | `InspectorPresentationPolicy` tests; Duo simulator inner display, open a message |
| #1425, #1426, #1047 | Search focus, the banner's placement, the Mac toolbar | Screenshots; Command-F on the Mac; a banner on iPad wide and narrow |
| #1217, #1510 | On Desktop and Split, a folder or feed pick ends the search, and "This folder only" follows the sidebar | Existing tests; macOS and iPad wide |
| #1970 | The Search tab doesn't take the Mail tab's folder as its scope | A test on the compact stack's absence of an anchor write; iPhone, manual |
| #1989 | Narrowing mid-search opens the Search tab; a Mail-tab pick leaves the Search tab's search alone | A navigator test; iPad narrowing, Duo simulator fold |
| #1555, #1644, #1654, #1664 | A swap renders the window's route, tab and search; a compact stack never gets list and reader in one update | Existing navigator tests; iPad narrow and widen, Duo fold and unfold, iPhone cold launch into a message and a feed item |
| #1962 | A feed item open folded survives an unfold | Duo simulator. If it still fails, it is a navigator feed hand-off fix |
| #1783 | The Settings gear and commands reach only their window | `CommandWindowTargetingTests`; two iPad windows, two Mac windows |
| #1929 | Command-A and the list's focus on iPad | After 3.2 B, on the iPad simulator. Whether 3.2 B alone fixes it needs a real keyboard (#1929's own note) |
| #1985 | The iPad list is the Mac's list | 3.2 B's test; on iPad with the simulator's hardware keyboard: arrows, Command-A, Esc, Shift-click, Select mode with two rows, drag a row to the folder panel |

**Wave 3.1 (menu commands go to the focused window): the rules PR C must keep.** Each rule 3.1 moved, with how it was checked.

| Issue | Rule | Check |
|---|---|---|
| #985 | A command is enabled only if it has something to act on | `MessageMenuAvailabilityTests`, `FeedMenuAvailabilityTests`; Mac with nothing selected |
| #1162 | New Message is live with every window closed; Refresh dims | `MailboxMenuAvailabilityTests`; Mac with every window closed |
| #1783 | A menu command and the Settings gear reach only their window | A test; two Mac windows, Command-R gives one reply; two iPad windows |
| #1824 | No later request re-aims an earlier one | The characterization rows 3.1 flipped; two Mac windows, Command-R then Mark All as Read at once |
| #1047 | Exactly one surface owns Command-Delete, now per window | `MessageMenuAvailabilityTests` plus a two-window test; Command-Delete in each of two Mac windows, one with a multi-selection and one with a message open |
| (cross-media Phase 1) | Command-T, Shift-Command-8 and Option-Command-T are never live in both the Message/Mailbox and Feeds menus (`SharedChordPolicy`) | `FeedMenuAvailabilityTests`; Mac with a feed open in one window and mail in the other |
| #1626, #1690 | The gear lives in the folder panel and opens Settings | `ColumnToolbarOccupantsSourceScanTests`; iPad wide |
| (audit 04 F3) | In the tab layouts, only the tab in front answers | A test; iPad narrow window and visionOS: Mail and Search tabs each with a message open, Command-R from each |
| #1796, #1821 | A manual refresh and a data-change reload are hard reloads; search re-runs in place | `OfflineListResetTests`, `CommandReceiverCharacterizationTests` |
| (none) | Feed catalog commands open their own sheet once per window, and item commands act on the list's row | `CommandReceiverCharacterizationTests`; Mac and iPad |
| (Phase 7 menu bar) | A Command-R after a compose window closes reaches the main window without a click (`apple/CabalmailMac/CabalmailCommands.swift`) | Mac, manual |

3.1's notes that still apply:
- **Keys on a simulator.** #1929's tester comment reports that XCUITest-synthesized chords don't reach SwiftUI commands. Use the iPadOS menu bar with the pointer on iPad, and the Mac's keyboard through Simulator.app's hardware keyboard on the Duo. Where neither can be driven, say so in the PR.
- **The Duo command check.** On the Duo simulator (built and run with the Studio's 27.1 beta Xcode), open a message folded, unfold, and use Reply and Mark as Read from the keyboard; then fold and use them again. Each acts once, on that message. With the Search tab in front while folded, the Message menu follows the Search tab.
- **The gates use CI's Xcode (27.0).** Use the 27.1 beta only for the Duo simulator run, selected for that command alone with `DEVELOPER_DIR`, never with `xcode-select`.
- **Risks.** `@FocusedValue` on iPadOS, the Duo and visionOS: the old fallback to the last active window would hide a nil there, so before 3.1 B the Studio was to confirm on the iPad simulator that the menu sees the front window's value with nothing focused inside it and, if it was nil, keep the fallback on that platform and say so. The Mac after a compose window closes: a gap before the main window republishes would dim the menus (the table's last row). Reporter ordering on a swap: the keyed reports, and the rule that only a report's own reporter clears it, are the guard; they are tested, and checked on the iPad widen-and-narrow and the Duo fold. A surface missing its tab value would answer from behind: every `Tab` content in both tab views gets it, and the policy test lists the tabs. Two windows are checked only live; no test hosts two windows.

**The Wave 3 TestFlight checklist's iPad checks** (written for the stage TestFlight build of stage 59d8ff8, 2026-10-10).
- **Opening a second window.** iPad: File > New Window from the menu bar, or touch and hold the Cabalmail icon and choose New Window. Mac: there is no File > New Window (File > New is New Message).
- **Keyboard and trackpad (#2001).** #2001 named five things the simulator could not drive: arrow keys, Esc, Shift-click, Command-click, and dropping a message into the folder panel.
  - **List keyboard keys.** Setup: hardware keyboard; the side-by-side layout (widen the window if you see the tab bar); a folder with more mail than fits on screen, no search, no filter pill. Tap a message first so the list has keyboard focus. (1) Down arrow a few times, then Up: the highlight moves, the reader follows, and the list scrolls to keep it in view. (2) Shift-Down twice: three rows selected, "3 Messages Selected" in the reader, the action bar under the list. (3) Esc: the selection clears and the reader says "No message selected". (4) Tap a message, then End, then Home: the list jumps to the bottom, then the top, without changing the open message. (5) Page Down a couple of times, then Page Up: about a screenful each, again without changing the selection. (6) Tap Select, tick two or three messages, press Esc: Select mode ends and the ticks clear. No Home, End or Page keys? Try Fn with the arrows. If the very first key after launch seems ignored, press it again before calling it a failure (#1929). Wrong if: keys do nothing on a second press, Shift-Down opens one message instead of growing the selection, Esc keeps the selection, or Home, End or Page change the open message. (#2001's changelog fragment says Home, End and the Page keys move the selection; the code scrolls without moving it, and this check follows the code.)
  - **Shift-click and Command-click.** Setup: keyboard, and a trackpad or mouse; side-by-side layout. Click a message first so it opens. (1) Shift-click a row three or four below: every row between is selected, and the reader shows the right "N Messages Selected". (2) Command-click one of the selected rows: it drops out and the count goes down by one. (3) Command-click an unselected row further down: it joins. (4) Shift-click a row a few past that: the rows from your last Command-click to here are added, and earlier picks stay. (5) Plain click one row: the selection collapses to it and it opens. Wrong if: a Shift-click or Command-click acts like a plain click.
  - **Drag a message onto a folder.** Touch and hold a message row until it lifts. Keeping that finger down, tap the folder-list button at the top left of the list with a second finger so the folder panel slides in. Drag over a folder until it is outlined and let go. Check that folder, then move the message back. You should see the folder under the drag get a coloured outline, and the message move there. Wrong if: the panel will not open mid-drag, nothing is outlined, the preview flies back, or the message stays put.
- **Menus (#1997, #1999).** Open the menu bar to see the menus (the checklist also said to hold Command; per #2025 that shows them only on iPadOS 18 and earlier).
  - **Message menu with two windows** (#1997). Setup: hardware keyboard; two windows side by side, each with a different message open. (1) Quit and reopen Cabalmail. Before tapping anything, look at the Message menu: it matches the window in front (Reply enabled if it reopened on a message), with no tap needed. (2) Tap the first window. Command-T twice toggles Mark as Read/Unread on its message only; Command-R opens one reply, to that message. (3) With the reply in front, the Message menu is dimmed and Command-R does nothing. (4) Close the reply without sending. Without tapping, Command-R opens a reply for the front window's message straight away. Close that too. Wrong if: the menu stays dimmed until you tap, the other window's message toggles, two replies open, or Command-R is dead after a reply closes.
  - **Message menu in the tab layout** (#1997, #2006). Setup: hardware keyboard; one window narrowed until the tab bar shows (Mail, Feeds, Addresses, Settings, Search). (1) In the Mail tab, open a message. (2) Switch to Search with nothing open there: the Message menu is dimmed. (3) Search, open a result, Command-T twice, then Command-R: only the search result toggles, and the reply is to it. Close the reply without sending. (4) Back on Mail, Command-T twice: the Mail tab still shows its own folder and message, and Command-T toggles that message. (5) Widen the window until the side-by-side layout returns, then narrow it again: the menu stays enabled for the open message both times. Wrong if: the menu is enabled in an empty Search tab, one shortcut acts in both tabs, the Mail tab shows the search results, or the menu dims after a resize.
  - **Command-comma in one window** (#1999). Setup: hardware keyboard; one window full screen or wide (in a mid-width window Settings can open on an empty pane with no Done button; that is #2004). (1) Command-comma: Settings opens as a sheet; close it with Done. (2) Start a New Message so the composer opens in its own window and is in front: Settings is dimmed, and Command-comma does nothing; close the composer. (3) Narrow the window until the tab bar shows, pick Mail, press Command-comma: the Settings tab is selected. Wrong if: Command-comma does nothing in step 1 or 3, a sheet opens instead of the tab in step 3, or Settings opens behind the composer in step 2. (Step 2's behaviour, new in Wave 3, is the "Command-comma dimmed behind a composer" item under "Not in this plan".)
  - **Command-comma with two windows** (#1999). Tap the first window and press Command-comma; look at both windows. Close Settings, tap the second window, and press Command-comma again. Each time Settings should appear only in the window in front (a sheet if wide, the Settings tab if narrow). Wrong if: it opens in the window behind, in both, or in neither.
- **The question #2006 left open.** #2006 shipped "keep it open", so a notification, Spotlight result or Resume leaves an open iPad Settings sheet up. That is the opposite of the recommendation put to the maintainer, which was unanswered when the checklist was written; choosing "Close it" means a small follow-up PR (multi-window-and-restore.md's).
- **Known bugs you may hit (not Wave 3 failures):**
  - #2004: in a mid-width iPad window, Settings opens on an empty "Select a category" pane with no Done button.
  - #2014: after a narrow-and-widen, an iPad window can come back slightly narrower and the filter pills wrap onto three lines.
  - #1929: on iPad, the first Command-A (or first key) after launch is ignored; a second one works.
  - #1988: after Zoom, the iPad list can float over the reader. The cause is on the issue; the only shell fix found closes an open message, so it is still open.

## How to start it

Session 1 opening brief, paste-ready:

> You are running Session 1 of "iPad layout regressions and keyboard commands" for the Cabalmail Apple clients (cabalmail/cabal-infra, branch `stage`). Read this plan (`docs/1.x/post-wave-3/ipad-layout-and-keyboard.md`, including "Background from the rearchitecture") and `00-working-agreements.md` in the same folder first, then re-check every line number against current `stage` and the state of #2043, #2032, #2033, #2034, #2027, #2026, #2024, #2004, #1929 and #1985. Write a short scope doc (decisions 1 to 5 at the top, quoted in full; one line per PR on what the maintainer will see) and post it. Then PRs A, B, G, C and D in that order. PR A needs decisions 1 and 2: build it on their defaults if the maintainer has not answered, as a draft. Every PR stays in draft until #2043 merges unless the maintainer answers No to decision 3. One open Apple PR from this session at a time, and push only when no other `apple.yml` PR run is going. Use the Mac mini for iPad and visionOS simulators and the Mac Studio only for the iPhone Duo simulator; ask before driving either Mac's GUI, check the tester is not using it, and coordinate use of the stage test accounts. Gates use CI's Xcode; select the Studio's beta Xcode per command with `DEVELOPER_DIR`, never `xcode-select`. Keyboard and trackpad checks the simulator can't make go on the maintainer's by-hand list.

Session 2 brief: "Run Session 2 of ipad-layout-and-keyboard.md (PRs E, F, H). Session 1 has merged and soaked; read its PRs. The maintainer's answers to decisions 6 to 8: `<paste>`. Same rules. Check whether duo-support.md's PR 3 is open in `SplitShell.swift` before PR H, and whether platform-conditionals.md's FU-19 is open on `ToolbarVisibility.swift` before PR E."

Both sessions read this plan and `00-working-agreements.md` from `docs/1.x/post-wave-3/`; what they need from the Wave 3.2 scope doc (B, D, H and its regressions to re-test), the Wave 3.1 scope doc (its regressions, Duo notes and risks) and the Wave 3 TestFlight checklist (its iPad checks, open questions and known bugs) is under "Background from the rearchitecture" above. Point at the issues above and the comments on #1988, #2004, #2026 and #2027. Rigs: CI; the Mini (iPad, visionOS and iPhone simulators, signed Mac build, soaks); the Studio (Duo simulator, Device Hub, per duo-support.md's decision 2); the maintainer's iPad.

## Risks and checks

1. **A selection change regresses the Mac.** The wide path is the Mac's. Check: policy tests on the Mac host, and click, Shift-click and Command-click on the signed Mac build.
2. **B pushes the navigator over its lint cap.** Check: count before writing; keep logic in `ShellHandOff`; let mail-navigation-refactors.md's PR 1 go first rather than split the class to fit.
3. **C changes the Mac menus by accident, or a moving chord misfires on iPad.** Check: the policy test asserts the Mac declares both; the Mail-Feeds switch test in one and two windows; the Mac Message and Feeds menus by eye.
4. **#2026 and #1929 stay unexplained.** Neither is reproduced with a known cause. Check: G's first-key test, C's menu check, and the maintainer's next failure with the app menu open. No speculative change ships.
5. **#1787's fix needs a scan edit the maintainer declines.** Then E reports and #1787 stays open; PR C's Command-N still lets a keyboard user compose.
6. **#1988's rebuild loses an open message or search result.** Check: H ships only at 10 of 10 tiled with the message kept, and after B so a search result is covered too.
7. **visionOS is build-only on PRs.** Check: #2034's steps, Select mode and Command-N on the visionOS simulator by hand for A and C.
8. **The Duo simulator is a beta, and the Studio is contended.** Each PR says what the simulator showed and what it expects on the device; one Studio GUI session at a time (duo-support.md's Risk 9).
9. **Merging before #2043** ships unsoaked fixes in 1.31.0. Check: draft until #2043 merges (decision 3). Met: #2043 merged on 2026-10-12.

## Not in this plan

- **#2029** (a stale Command-R replayed when a hidden tab comes forward): closed not planned on 2026-10-12, because "it needs a hardware keyboard on an iPhone, which no Cabalmail user has connected". The code shows the same path serves a compact iPad window and the folded Duo: both resolve to `.tabs` (`Shell/ShellLayout.swift:23-25`) and use `WindowCommandReceiver`'s `onChange` (`Commands/WindowCommands.swift:193-224`), where a keyboard is plausible (inferred, untested). Not reopened; duo-support.md records device evidence.
- **A Move shortcut on iPad:** the maintainer, during the Wave 3 TestFlight checklist pass: "I don't need a keyboard shortcut for move". The iOS Message menu still declares Command-M (`MessageMenuCommands.swift:57`), which iPadOS takes as Minimize; PR C leaves it unless the maintainer asks, since removing it was not part of that answer.
- **Command-comma dimmed behind a composer on iPad:** accepted (low-medium confidence) when the maintainer closed the checklist with "Anything I haven't reported is good".
- **The Settings sheet closing when a link or Resume navigates (the question #2006 left open), #2035, #2036, #2041, and the Mac's File > New Window:** multi-window-and-restore.md.
- **#1692, #1681, #1686, #1963, #1962's device check and #1647:** duo-support.md.
- **Page Up and Page Down in search and pills:** mail-correctness.md's PR 6, which may hand it here if this plan is still running.
- **The 1.31.0 CHANGELOG saying Home, End and the Page keys move the selection:** docs-and-bookkeeping.md.
- **Harness gaps (unreliable synthetic chords, no two-window test):** test-debt.md. **The rest of the Wave 3 checklist:** live-verification.md.
- **Global search as its own model and the navigator split:** mail-navigation-refactors.md, after PRs A and B.
- **The `compiler(>=6.4)` guards in `ToolbarVisibility.swift` (FU-19):** platform-conditionals.md.

## Sources

- GitHub, read 2026-10-12 (REST). Open: #1787, #1929, #1985, #1988, #2004, #2014, #2024, #2026, #2027, #2032, #2033, #2034, #1647, #1681, #1692, #1962, #2035, #2036, #2037, #2041; PR #2043 (Release 1.31.0, not draft). Closed: #2025 and #2029 (not planned), #1989 and #1670 (completed), #1783. Merged: #1965 (2026-10-08), #1999, #2001, #2003, #2005 and #2006 (2026-10-10). Comments used: #1787 (2026-10-10), #1929 (2026-10-07), #1988 (2026-10-10), #2004 (2026-10-10), #2014 (2026-10-12), #2025, #2026 and #2027 (2026-10-11), #2029 (2026-10-12); #2001's "Findings".
- Repo at 50e6022, under `apple/CabalmailUI/` unless noted:
  - `Mail/MessageList/MessageListView+Selection.swift:113-147, 369-392, 408-427`; `MessageListView+Rows.swift:19-21, 30, 37-48`; `MessageListViewModel+Bulk.swift:22-30`; `MessageListLayout.swift:15-21`; `MessageListView.swift:360-395`; `MessageListView+Filter.swift:43`; `Mail/Search/SearchView.swift:25, 41`.
  - `Navigation/ShellHandOff.swift:5-62`; `Navigation/SceneNavigator.swift:49-525 (class body), 100, 233-262, 700-728` (blame: lines 257-260 from e83e0bc0, 2026-10-08; 256 from 3.3 B); `Navigation/FeedNavigationState.swift:73`; `Navigation/TreeGate.swift:11-44`.
  - `Shell/ShellLayout.swift:16-27`; `Shell/WideMail.swift:295-321`; `Shell/Columns/MailReaderColumn.swift:6-52`; `Shared/Primitives/SelectionModel.swift:46-58`.
  - `Settings/SettingsView.swift:24-74`; `Settings/SettingsSheet.swift:28-46`; `Shared/Chrome/FilterPill.swift:29-66`; `Shared/Chrome/SidebarFilterPillRow.swift:35-43`; `Feeds/ItemList/FeedItemListView+FilterBar.swift:16`; `Shared/Chrome/ToolbarVisibility.swift:1-63`.
  - `Commands/MessageMenuCommands.swift:35-58`; `Commands/FeedsMenuCommands.swift:20-51`; `Commands/WindowCommands.swift:193-224`; `Compose/Windows/ComposeCoordinator.swift:82-86`; `Feeds/ItemList/FeedItemListView.swift:68-84, 145-153`; `apple/Cabalmail/CabalmailApp.swift:49, 65-111`; `apple/CabalmailMac/CabalmailCommands.swift:30-54`.
  - Tests and repo root: `apple/CabalmailTests/ToolbarVisibilitySourceScanTests.swift:10-47`, `SwipeActionContainerSourceScanTests.swift:30, 177`, `CompactBrandMarkSourceScanTests.swift:21-31`, `FilterPillTests.swift:77`; `apple/platform-conditionals-allowlist.txt`; `scripts/check-platform-conditionals.py:1-33`; `CHANGELOG.md:55-63`; `docs/releasing.md:55-59`.
- `00-working-agreements.md` in this folder.
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Sibling plans in this folder, read for hand-offs and order: duo-support.md, mail-correctness.md, feed-bulk-actions.md, flags-and-cross-media.md, detached-reader-window.md, mail-navigation-refactors.md, multi-window-and-restore.md, platform-conditionals.md, docs-and-bookkeeping.md, live-verification.md, test-debt.md.
