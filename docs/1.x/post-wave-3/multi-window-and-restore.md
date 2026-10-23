# Multi-window, restore and link routing backlog

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session, run as two sequential sessions (session 1: restore and routing; session 2: windows and window chrome). Every item is a small fix in Wave 3's per-window code with no server change or migration, the hotspot files force one PR at a time so parallel threads would buy nothing, and all six decisions fit in one batch.
**Size:** L overall: two M sessions, eleven small PRs, plus R6 only if the maintainer says Now to decision 6.
**Priority:** Next. These are minor user-visible bugs and open design questions from the Wave 3 soak and TestFlight pass. The maintainer, on them, during the Wave 3 TestFlight pass: "Please just file Issues ... I'll prioritize them for fixes after some more important work". ipad-layout-and-keyboard.md and duo-support.md (both Now) go first.
**Depends on:** Order only: ipad-layout-and-keyboard.md (its PRs B and D before R5; decision 2 asked with its decision 4); mail-navigation-refactors.md (its PR 1 preferably before R5; never open together in `SceneNavigator.swift`); platform-conditionals.md (S1 PR 3 shares W4's two files, S1 PR 5 shares R5's `ComposeWindowScene.swift`); account-isolation.md (C1 shares W3's keys). Soft: live-verification.md (Step 1's `SoakBig` folder for R6's rows 300 and 700), duo-support.md (device evidence for decision 6), refresh-scheduling.md (R4 can reuse its foreground poll), test-debt.md (B2's two-window Mac spike).
**Unblocks:** detached-reader-window.md (R3 and W1 before its PR 4). Soft: flags-and-cross-media.md (W4 before its B2.4, or B2.4 takes the feed stand-in); ipad-layout-and-keyboard.md PR C (its iPad New Message aims at "the main window in front", which R3 makes true); sqlite-mail-store.md PR 3.3 (builds on R6 if R6 exists).
**Duo groundwork:** R3 and R5 make "the window in front", link delivery and the compose return window right on any multi-scene iOS host, which should include the open Duo's two scenes (inferred: checked on iPad only); R6, if built, places a list at its row on a fold. No Duo API, no 27.1 SDK.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| Decisions 1 to 6 | Unanswered (2026-10-15) |
| Session 1, R1a. #2030, the place of a list picked after launch | Not started (2026-10-15) |
| Session 1, R3. #2035, the window in front on iPad | Not started (2026-10-15) |
| Session 1, R1b. #2030, a stale stored route after a foreground terminate | Not started (2026-10-15) |
| Session 1, R2. #2042, the Mac quit hook | Not started (2026-10-15) |
| Session 1, R4. #2028, the warm notification | Not started (2026-10-15) |
| Session 1, R5. Compose routing residue, decisions 1 and 5 | Not started (2026-10-15) |
| Session 2, W1. #2036, iPad window titles | Done (2026-10-22) |
| Session 2, W2. Mac File > New Window (decision 2), and two stale comments | Not started (2026-10-15) |
| Session 2, W3. #2039, tree expansion (decision 3) | Not started (2026-10-15) |
| Session 2, W4. #2016, the reader's toolbar stand-ins | Not started (2026-10-15) |
| Session 2, W5. #2041, one attempt | Not started (2026-10-15) |
| Session 2, R6 (decision 6 Now only). Placement before the refresh | Not started (2026-10-15); built only if decision 6 is Now |

> **Duo spec (2026-10-13):** This plan was written before the maintainer's Oct 7 Duo spec (the Claude Doc linked in duo-support.md) had been read in the rearchitecture project. duo-support.md now follows it; where this plan's text disagrees with the points below, the points win. In the spec, "fold" means book or laptop pose, which changes no size class and swaps no shell; what this plan calls folding or unfolding the Duo is closing or opening it.
>
> - Decision 6: the spec asks that a list come back at the first visible message and re-anchor once the width settles, including in the laptop panel 〔row .23386〕. R6 is what meets that; say so beside "Anchor only" when asking.
> - R5 assumes compose is a window on iPad. duo-support.md PR 7 makes it a sheet on iPad and the Duo, with a window only on request. Re-read R5 against that before either merges: a mailto while a compose sheet is open must never replace the draft.
> - Decision 1 covers the Settings sheet in every layout once Settings stops being a tab (duo-support.md Decision 9). Decision 3's per-window answer matches the spec's per-window state rule.

## Decisions for the maintainer

1. **iPad Settings sheet when a notification, Spotlight result or Resume opens a message: Close it or Keep it?** Close it (**recommended**, and the original card's recommendation): the message shows at once instead of behind the sheet. Keep it: no change. **Default:** Keep it, which #2006 shipped.
2. **Mac File > New Window: Add with no shortcut, Add with Shift-Command-N, or Leave out?** Add with no shortcut (**recommended**): a second Mac main window is one menu click away and Command-N stays New Message. Ask with ipad-layout-and-keyboard.md decision 4, which recommends the same rule on iPad. **Default:** add, no shortcut.
3. **Folder and feed tree expansion (#2039): Per window or Device-wide?** Per window (**recommended**): Collapse All, Expand All and a chevron change only the window you used, as #1999 says its menu items do; a new window starts from the last change anywhere. Device-wide: today's behaviour stays and `docs/apple.md` says so. **Default:** per window.
4. **If the Mac quit hook (R2) cannot get every window's place saved, add a small per-window place store instead? Yes or No.** No (**recommended**): #2042 needs "Close windows when quitting" turned off; with the default, the window that comes back reopens at its place (#2042's controls), so the issue stays open with the finding rather than gaining a store. **Default:** No.
5. **A mailto while signed out, with several windows: open it in the window last used, or keep today's "the first window to sign in"?** Keep today's (**recommended**): the rule is deliberate and tested, and the case is rare. Last used: R5 changes the coordinator's rule and flips its test. **Default:** keep.
6. **Show the list at your row from its saved rows straight after a fold, before the refresh lands: Now or Wait?** Wait (**recommended**): you accepted the top showing until the refresh with 3.3's "Anchor only", and duo-support.md's device pass will record how that feels on the real Duo. Now: R6 is built last in session 2 and needs the Studio. **Default:** Wait.

## What you'll see change

Session 1, restore and routing:
- **R1a (#2030):** on iPhone and a folded Duo, a folder you picked after launch reopens at your row after a relaunch.
- **R3 (#2035):** on iPad, after switching windows with the app switcher or the Window menu, a mailto composer closes back to the window you were in; links aimed at no window and the place the app resumes from follow that window too.
- **R1b (#2030, second half):** after a crash or an Xcode stop, the app reopens on the folder you were last in, not the one from the last time it went to the background.
- **R2 (#2042):** on the Mac with windows kept on quit, every window reopens at its own row after Command-Q. Nothing visible if the measurement fails and decision 4 is No.
- **R4 (#2028):** tapping a new-mail notification while the app is running opens the new message, as a cold start does.
- **R5:** a mailto that arrives while an iPad composer is open opens a second composer instead of replacing your draft. With decision 1 Close, a notification, Spotlight result or Resume closes an open iPad Settings sheet. With decision 5 Last used, a signed-out mailto opens in the window you last used.

Session 2, windows and chrome:
- **W1 (#2036):** iPad windows are named after what they show (INBOX, Archive, Feeds) in the Window menu and app switcher, not all "Addresses".
- **W2 (decision 2):** the Mac File menu gains New Window.
- **W3 (#2039, decision 3):** expanding or collapsing a folder or feed tree changes only that window.
- **W4 (#2016):** on the Mac, the reader's toolbar buttons no longer jump sideways when a message or feed item opens.
- **W5 (#2041, one attempt):** on the Mac with the tab bar shown, the Addresses panel sits below the tab bar.
- **R6 (decision 6 Now only):** after a fold or an iPad resize, the list shows at your row at once.

## Why

Wave 3 made restore, links and compose per window (3.3 B to G2, PRs #2003 to #2015). The Wave 3 soak on stage `e87fd419` and the maintainer's TestFlight pass then found where per-window state is still stale, app-wide or misrouted. Every soak issue below was reproduced by two independent runs; #2028 is one by-hand report and #2016 was seen by the maintainer on the Mac.

- **The "window in front" goes stale on iPad.** `lastActiveMainWindow` moves only on `onAppear` and `appearsActive` (`apple/CabalmailUI/Commands/MainWindowCommandScope.swift:26-38`). After a switch between full-screen iPad windows through the app switcher or Window menu it stays on the old window (#2035, 6 of 7). #2035 infers that `appearsActive` never flips there, because the switcher showed both cards as Active. Four things read the value: the mailto composer and its return (`Shell/AppRootLifecycle.swift:59`, `Compose/Windows/ComposeWindowScene.swift:195`), `DeepLinkRouter`'s fallback for an unaimed link (`Navigation/DeepLinkRouter.swift:85`), the resume recorder (`Navigation/WindowRecorder.swift:156`), and `WindowPlaceKeeper`, which stores each window's `wasLastUsed` flag and hands the resume session over (`Navigation/StoredRoute.swift:102-111`).
- **List-place holes in 3.3 G2** (#2015, the relaunch place). A list for a folder picked after launch never records its place (#2030, 8 of 8): the resume session held `{folder: Sent}` and no anchor. Separately, `@SceneStorage` reaches disk only when a scene backgrounds, so after a foreground terminate an older stored route beats the fresher session (#2030; "users rarely hit this"). On the Mac, a window that is not the last used stores its place only on leaving it, a route change or backgrounding, and Command-Q does none of these (#2042, 5 of 5; #2015 predicted it and named "a terminate hook in the Mac app entry").
- **A warm notification misses its message.** The list takes a parked restore once, looks only among loaded rows and gives up on a miss (`Mail/MessageList/MessageListView.swift:606-613`). A warm tap on a folder already on screen arrives before the list has the new message, and nothing retries (#2028).
- **Per-window state that is still per device.** Tree expansion is `@AppStorage` (`Mail/Folders/FolderListView.swift:45, 90`, `Feeds/Sidebar/FeedSidebarSection.swift:79`), so #1999's "act on the window in front only" cannot be seen (#2039, 8 of 8). Every iPad window is titled "Addresses", apparently from the inspector's `AddressListView` (`Addresses/AddressListView.swift:86`; inferred in #2036).
- **The Mac has no menu route to a second main window.** `CommandGroup(replacing: .newItem)` holds only New Message (`apple/CabalmailMac/CabalmailCommands.swift:38-54`). The rearchitecture proposal decided "Many" main windows (on 2026-10-02: many per device, not one main window on macOS, because two iPad windows were already possible and the Duo needs it), and the shell audit of 2026-10-02 (audit 04 F7: multi-window behaviour differs by platform and is implicit, and a second Mac main window is not normally reachable) asked to "decide explicitly". Today a second window probably takes the tab bar's + and a drag (View > Show Tab Bar, click + in the tab bar, then drag the new tab out into its own window), which no session has confirmed.
- **Compose leftovers that PR #2009 (3.3 E) disclosed under "Not covered":** a mailto delivered to an open iPad compose window replaces its draft (`ComposeWindowScene.swift:163-165`), and a signed-out mailto opens in whichever window's compose surface registers first. PR #1793 left four compose paths "for the planned per-window compose and restore rework"; three were never re-measured.

## Where things stand

- **Issues this plan takes on, all open on 2026-10-12, none with a fix on stage 50e6022:** #2030, #2035, #2036, #2039, #2041, #2042 (`bug`, `apple`, `needs-verification`), #2016 (`verified`), #2028 (no labels).
- **Already done:** #2018 (Mac links with every window closed) is closed, fixed by `7335224f`. #1966 and #1987 are fixed by `5035e28b`; #1987 is closed, #1966 closed when Release 1.31.0 (#2043) merged on 2026-10-12. #1896 closed with it too (`1b5830c1`); its leftovers are #2030 and #2042.
- **Settings card:** #2006 shipped "keep it open"; the decision card, asked in the rearchitecture project's chat, is still unanswered (the Wave 3 TestFlight checklist lists it as an open question; see "Background from the rearchitecture"). The 3.2 D (layout shells) work recorded the follow-up: "If he picks closing on navigation ... you add the two-line rule". The card itself is not in the repo; decision 1 restates it.
- **Mac mailto:** the comment at `CabalmailMacApp.swift:71-78` says `.onOpenURL` still reaches the main window; `ComposeWindowScene.swift:157-161` says the system spawns a compose window. PR #1793's measured Mac run found "the main window's handler does not fire", so the first comment is stale. Nobody has reported the Wave 3 TestFlight checklist's Mac "A mailto: link opens one composer" check (under "Background from the rearchitecture") either way.
- **Code the PRs build on (glosses in brackets):**
  - A list records its place only while it holds a claim [a token from `FolderListHold` that a later folder change voids] and after it has landed (`Mail/MessageList/ListPlaceTracking.swift:139-152, 262-278`; `Navigation/FolderListHold.swift:93-121`; `setFolder` voids at `Navigation/SceneNavigator.swift:475`). `recordListAnchor` writes only when `session.folder == folderPath` (`Navigation/NavStateCoordinator+Session.swift:190-194`). Which of these drops #2030's anchor is unknown.
  - `WindowPlaceKeeper.store()` writes on a route change, a scene-phase change and a change of last-used window, and skips a write equal to what is stored (`StoredRoute.swift:93-118`). `placeToReopen` prefers the session's place only for the window flagged `wasLastUsed` (:43-48). A stored route is read in the navigator's convenience init (`WindowRecorder.swift:150-162`), outside the class body.
  - The macOS `AppDelegate` (`Platform/Services/AppDelegate.swift`, macOS branch :49-128) reaches only `PushRegistrar.shared` and `DeepLinkRouter.shared`; it has no `AppState`, which `CabalmailMacApp.init` builds (:45-47). No terminate hook exists anywhere in the app.
  - `MainSceneActivation.swift` is iOS-only (`#if os(iOS)` at :3, `#else` at :140) and holds the scene recorder that maps scene sessions to window IDs (:76-120). visionOS keeps the `appearsActive` path.
  - `ComposeCoordinator.open` drops a seed's window name when that window has no presenter (`ComposeCoordinator.swift:84`); a nameless seed goes to the last registered presenter (:163-166). The header comment states the rule (:15-19) and `testARequestWhileNoWindowHasASurfaceOpensInTheFirstThatDoes` pins it (`CabalmailTests/ComposeCoordinatorTests.swift:75`).
  - `WindowRestores.consumePendingRestore` is one-shot, pinned by `RestoreTickCharacterizationTests.swift:101-117` ("one-shot", :112).
- **Size limits at 50e6022:** `SceneNavigator`'s class body (:49-525) is about 241 counted lines of the 250 that `type_body_length` allows under `--strict`. `FolderListView`'s body is about 211. `LaunchRestoreSequencingSourceScanTests.swift:31-37` requires exactly 3 occurrences of `applyPendingRestoreWhenReady()` in `MessageListView.swift`, counted in raw text.

## The plan

**Rules for both sessions.** #2043 merged on 2026-10-12, so the sessions may start. One PR at a time on `stage`, each user-visible one with an `Apple:` fragment. A PR that completes an issue says "Fixes #N" (the release dashboard then holds Promote until it closes); a partial one says "Refs #N". Every new test is a behaviour test, and every moved rule is undone once to watch its test fail. Run `swiftlint --strict` and `scripts/check-platform-conditionals.py` before each push. Never edit a source scan's expected text or anchor. Scans that name files here: `LaunchRestoreSequencing`, `SwipeActionContainer`, `ToolbarVisibility`, `CompactBrandMark` (reads `FeedSidebarSection.swift` and `AddressListView.swift`), `ComposeWindowSlot`, `ComposeWindowOrphan`, `SceneAppearance`, plus `MessageListRefreshRoutingTests.swift:55-64`, which pins `await model?.refresh()` in the list's re-appear branch. Whole-tree walkers also read every new or edited file without naming it: `ColorTokenSourceScanTests`, `MenuPickerSourceScanTests`, `ConfirmationDialogRoleTests`, `AddressMenuTitlePolicyTests`, `MacSheetChromeSourceScanTests`; `ColorToken`, `MenuPicker`, `ConfirmationDialogRole` and `SceneAppearance` also probe `CabalmailMacApp.swift` by path. Before editing a file, grep `CabalmailTests` for its path and run the walkers. Keep `SceneNavigator.swift`'s class body at or under 242 lines; new behaviour goes into `WindowRestores`, `FolderListHold`, `ListPlaceTracker`, `ShellHandOff` or a new type. Each PR that changes a rule in the `Navigation/` row of `docs/apple.md` (:1025) updates that row. Builds and simulator runs go through Remote Control on the Mini (iPhone and iPad simulators, a visionOS simulator if one is installed, the signed Mac build, the two stage test accounts). Only R6 needs the Studio.

### Session 1: restore and routing

**R1a. #2030, the place of a list picked after launch.**
- Scope: write the failing test first: a list for a folder picked after the first landing scrolls, and the resume session must hold its anchor. Then find which guard drops it (the voided claim, `didLand` never set, or the `session.folder` guard) and fix that one.
- Files: `ListPlaceTracking.swift`, `FolderListHold.swift`, maybe `NavStateCoordinator+Session.swift`.
- Tests: `ListPlaceTrackingHostedTests` [renders a real list], `ListPlaceSessionTests`, `SceneNavigatorListAnchorTests`.
- Verify: CI; Mini iPhone simulator, #2030's steps with a background first (pick Sent, scroll, wait, terminate, relaunch), 4 of 4; the launch-folder control still restores. "Refs #2030".
- Risk: low to medium.

**Status:** Not started (2026-10-15).

**R3. #2035, the window in front on iPad.** Before R1b, because it changes which window `WindowPlaceKeeper` flags `wasLastUsed`.
- Spike first, about an hour on the Mini's iPad simulator: log `UIScene.didActivateNotification` and `UIWindow.didBecomeKeyNotification` per main scene while swapping full-screen windows through the app switcher and the Window menu. If neither fires on a swap, comment on #2035 with the log and stop R3.
- Scope: in the iOS scene recorder, note the main window as active when its scene activates or its window becomes key (`noteActiveMainWindow`). Compose scenes never count. The Mac and visionOS keep `appearsActive`.
- Files: `Compose/Windows/MainSceneActivation.swift` (keep `ComposeWindowOrphanSourceScanTests`' anchors at :14-15), maybe `MainWindowCommandScope.swift`.
- Tests: a pure rule (which window an activation names; compose scenes ignored). Activation itself cannot be unit-tested.
- Verify: #2035's steps and its mirror, both switch routes; then a `xcrun simctl push` notification aimed at no window, and which window writes the resume session. visionOS: CI build only, behaviour not checked.
- Risk: low to medium. If iPadOS reports a compose scene as key, the rule must skip it, or a mailto would return to the composer.

**Status:** Not started (2026-10-15).

**R1b. #2030, a stale stored route after a foreground terminate.** Its own PR, so it can be reverted alone.
- Scope: `StoredRoute` gains an optional `savedAt`. For the window flagged `wasLastUsed`, a stored route older than the resume session's `savedAt` (set at `NavStateCoordinator+Session.swift:231`) is ignored, so the window starts as one with no stored route, on the session's folder and message (inferred that this is today's no-stored-route landing, the #1555 rule; confirm in tests). The rule sits beside `placeToReopen` and is applied in the convenience init, so the navigator's landing order is untouched. `store()`'s equality check must ignore `savedAt`, or every store becomes a write that re-renders the window. Old data decodes with `savedAt` nil and behaves as today.
- Files: `StoredRoute.swift`, `WindowRecorder.swift`.
- Tests: `StoredRouteTests`, `NavStateCoordinatorStoredRouteTests`, `WindowPlaceKeeperTests`.
- Verify: #2030's foreground-terminate case on the iPhone simulator; on iPad, two windows, an Xcode stop and a relaunch, each window back where it was (the Wave 3 TestFlight checklist's "Two iPad windows come back after an Xcode stop", under "Background from the rearchitecture"). "Fixes #2030".
- Risk: medium; it changes which place wins on a relaunch.

**Status:** Not started (2026-10-15).

**R2. #2042, the Mac quit hook.**
- Measure first, before production code: on a throwaway branch, does a scene-storage write made while the app holds `.terminateLater` reach the restored window? Use #2042's steps with `NSQuitAlwaysKeepsWindows` on. If not, decision 4 decides (No: comment on #2042 and stop).
- Scope: the macOS `AppDelegate` answers `applicationShouldTerminate` with `.terminateLater` and posts a notification (or calls a hook `CabalmailMacApp.init` sets); `AppState` turns it into a quit signal; each `WindowPlaceKeeper` stores on it; on the next main-actor turn the delegate replies yes. Plan B (decision 4 Yes): a stable window ID in scene storage and a small per-install place store keyed by it, saved like the session.
- Files: `Platform/Services/AppDelegate.swift`, `App/AppStateSignals.swift`, `StoredRoute.swift`, maybe `CabalmailMac/CabalmailMacApp.swift`.
- Tests: `WindowPlaceKeeperTests` (the signal stores route and place); an `AppState` signal test.
- Verify: signed Mac build on the Mini, #2042's steps 3 of 3, and its controls (default setting; clicking B first). `kill -TERM` stays out of scope.
- Risk: low to medium; AppKit's restoration timing, settled by the measurement.

**Status:** Not started (2026-10-15).

**R4. #2028, the warm notification.**
- Scope: a restore whose message is not among the loaded rows waits for that list's next refresh, then retries once; it is dropped on a folder change, a newer park or a second miss. Keep the consume at `MessageListView.swift:608` one-shot so the characterization row stays green: on a miss, the view hands the restore back to `WindowRestores` in a separate slot that the `onChange` at :582-584 does not watch, awaits one refresh, then asks for it back. The keep, retry and drop rules live in `WindowRestores`; in the view only the miss branch after :613 changes. Do not add or quote `applyPendingRestoreWhenReady()`.
- Observe, not deliver: whether a relaunch target past row 250 (one of #1834's untracked limits) is now re-selected. Report it in the PR body; if not, it stays with sqlite-mail-store.md Phase 3, which rebuilds lists past 250 rows. Keep it out of R4's tests.
- Files: `Navigation/WindowRestores.swift`, `MessageListView.swift`.
- Tests: `SceneNavigatorWindowRestoreTests` (a kept miss, a hit after the refresh, each drop); a `ListPagingWorld` case for a message that arrives on refresh.
- Verify: Mini iPad simulator, two windows on INBOX, `xcrun simctl push` and a banner tap, warm and cold; a Mac warm tap if the rig can drive one (#2028 does not know whether the Mac fails; the code is shared). "Fixes #2028"; the maintainer's real warm notification holds Promote.
- Risk: medium. This is the restore path #1664 guards [the reader opens only after the list has appeared and its first load has run]; both gates stay.

**Status:** Not started (2026-10-15).

**R5. Compose routing residue, decisions 1 and 5.** After ipad-layout-and-keyboard.md's PRs B (`ShellHandOff.swift`) and D (the Settings sheet).
- Mailto into an open composer: in `ComposeWindowContent`'s `onOpenURL` (`ComposeWindowScene.swift:155-167`), a window with a slot hands the mailto to `appState.compose.open(seed:from:)`, which opens a second composer, instead of `reseed`. Keep `ownSeed = mailto.draft()` (`ComposeWindowSlotSourceScanTests.swift:51`).
- Decision 1 Close: a rule that a navigation closes the Settings sheet, in `ShellHandOff` or in `Shell/SettingsSheetPresenter.swift` if PR D moved the state there, called from `navigate(to:)` (`SceneNavigator.swift:390`): one line in the class body, about 242 of 250. Only `navigate(to:)` closes it: restores and other windows' changes still must not, and the comment at `ShellHandOff.swift:6-10`, which records today's keep-open design, is updated to say so. This flips `testANavigationLeavesSettingsOpen` (`SceneNavigatorShellTransitionTests.swift:236`), a behaviour test that answer approves.
- Decision 5 Last used: keep the last-used window's name on a seed that arrives while no window has a presenter, until that window registers, and clear the name if that window closes first. Update the header rule (:15-19) and flip the test at `ComposeCoordinatorTests.swift:75`. Medium risk.
- Measure #1793's three iPadOS and visionOS paths: a system close that skips `onClose`, a close while "Sign in required", a restored slot not marked occupied. Fix only what reproduces; if no visionOS simulator is free, say visionOS is unmeasured.
- Files: `ComposeWindowScene.swift`, `ShellHandOff.swift` or `SettingsSheetPresenter.swift`, `SceneNavigator.swift` (one line), `ComposeCoordinator.swift` (decision 5 only).
- Tests: `ComposeCoordinatorTests`, `ShellHandOffTests`, `SceneNavigatorShellTransitionTests`.
- Verify: iPad simulator, a mailto into an open composer (two composers, draft intact); Mac, a mailto with a compose window open (#1793 saw no replace on the Mac; record it); Settings open, then a `simctl push` notification tap. Spotlight on the Mini never lists Cabalmail, so the Spotlight case goes on the maintainer's device list.
- Risk: low; medium for decision 5's half.

**Status:** Not started (2026-10-15).

### Session 2: windows and chrome

**W1. #2036, iPad window titles.**
- Scope: each main scene takes a title from its route (the folder name, "Feeds", or the app name), set as `UIWindowScene.title` from the iOS scene recorder. If the simulator shows SwiftUI overwriting it, use a root-level title that outranks the inspector's. `AddressListView` keeps `.navigationTitle("Addresses")` and its brand mark.
- Files: `MainSceneActivation.swift`, maybe `Shell/SignedInRootView.swift`. Tests: a pure title rule.
- Verify: Mini iPad simulator, Window menu and switcher, one and two windows. visionOS: CI build only.
- Risk: low; whether the scene title survives SwiftUI is inferred.

**Status:** Done (2026-10-22). Built as scoped: a pure `MainWindowTitle` rule plus a `namesMainWindowScene(_:)` hook on `SignedInRootView` that writes `UIWindowScene.title`. The scene title does survive SwiftUI on iPadOS 27 — measured on the iPad Pro 11-inch (M5) simulator, where the app-switcher card read `Cabalmail / Addresses` on INBOX before and `Cabalmail / INBOX`, then `Cabalmail / Archive`, after, with the Addresses inspector open for the last arm. The root-level-title fallback was not needed. Still unmeasured, for the harness reason #2036 and #2035 both record: the Window menu itself, and two windows.

**W2. Mac File > New Window (decision 2), and two stale comments.**
- Scope: a New Window item that opens a fresh main window with `openWindow(id: mainWindowID)`, not `MainMailWindow.bringToFront()`. Correct the mailto comment at `CabalmailMacApp.swift:71-78` and the deleted-`requestCompose()` comment at `CabalmailCommands.swift:40-47`. Then run the Mac "exactly one composer" check (the Wave 3 TestFlight checklist's "A mailto: link opens one composer", under "Background from the rearchitecture") on the Mini.
- Files: `CabalmailMac/CabalmailCommands.swift`, `CabalmailMac/CabalmailMacApp.swift` (comment only; the `ColorToken`, `MenuPicker`, `ConfirmationDialogRole` and `SceneAppearance` scans read it).
- Verify: Mini; New Window with one window open and with none; the new window lands on the live session (#1555).
- Risk: low. No file overlap with ipad-layout-and-keyboard.md PR C; only the shortcut question links them.

**Status:** Not started (2026-10-15).

**W3. #2039, tree expansion (decision 3).**
- Either answer: move the two keys duplicated across files, `cabalmail.feeds.collapsedFolders` and `cabalmail.feeds.filter` (`FolderListView.swift:45, 81`; `FeedSidebarSection.swift:79, 82`), into a `DefaultsKey` enum in `CabalmailUI`. Every other app key literal is used in one file at 50e6022, including `SessionManager.swift:709-721`, so this closes audit 06 F16 (the tests-and-robustness audit of 2026-10-02: app `UserDefaults` keys duplicated as string literals across files, with the recommendation of one `DefaultsKey` namespace in the app, mirroring the Kit's `static let` style).
- Per window: `@SceneStorage` holds the window's collapsed mail set (`cabalmail.folder.collapsedPaths`, only in `FolderListView.swift:90`) and feed set, tagged with the account as `StoredRoute` is. account-isolation.md's C1 resets the device-wide keys on a different-account sign-in and cannot reach scene storage, so a set stored for another account is ignored. A window with none seeds from the device-wide value; every change also writes the device-wide value for the next new window. The Mail and Feeds section disclosures (`:43, :70`) and the pills stay device-wide. The rule goes in a small type.
- Device-wide: the key move plus one sentence in `docs/apple.md`; close #2039 with a link.
- Files: `FolderListView.swift`, `FeedSidebarSection.swift`, a new `DefaultsKey` file, `docs/apple.md`. Tests: the seeding and account rules as pure functions.
- Verify: Mini, two Mac windows, #2039's steps (menu, in-sidebar buttons, a chevron); two iPad windows.
- Risk: low.

**Status:** Not started (2026-10-15).

**W4. #2016, the reader's toolbar stand-ins.**
- Scope: build each stand-in from the same control kind as its live twin, as #2016 suggests: a disabled `Menu` with the same indicator for Reply, dispose, read and Flag, and for the feed's More; Flag reads the palette state to pick its shape. The spacing cause is untraced; measure it first.
- Files: `Mail/Reader/EmptyDetailToolbar.swift`, `Feeds/Reader/EmptyFeedDetailToolbar.swift`.
- Verify: Mini screenshots of the Mac toolbar, empty and opened, mail and feeds.
- Risk: low. platform-conditionals.md S1 PR 3 (FU-1) edits the same two files: whichever is ready first goes first, never both open.

**Status:** Not started (2026-10-15).

**W5. #2041, one attempt.**
- Scope: try to keep the `.inspector` (`Shell/WideMail.swift:433`) below the window tab bar. `ToolbarVisibilitySourceScanTests` reads this file. Files: `WideMail.swift`.
- Verify: Mini with the tab bar shown, full and half-width windows. If there is no clean fix, comment on #2041 and leave it open; it is cosmetic and predates Wave 3.

**Status:** Not started (2026-10-15).

**R6 (decision 6 Now only). Placement before the refresh, last in session 2.**
- Scope: a new `ListPlaceTracker` entry point lands the anchor once the saved rows are in place (`hydrateFromCache`) and the list has appeared, if the anchor's Message-ID is among them. It does not set `didLand`, so the existing `land` (called only from `MessageListView.swift:597`, behind the pinned guard) still corrects once after the refresh; the user's scroll wins. The message restore and reader push still wait for both gates. No `MessageListViewModel*` change; `proxy.scrollTo(model.rowSlot(at:` stays at 3.
- Files: `ListPlaceTracking.swift`, `MessageListView.swift` (one call). Tests: `ListPagingWorld` (land before refresh, no jump after, scroll wins, an anchor outside the saved rows waits).
- Verify: the Studio's Duo simulator with its Duo-capable beta Xcode (27.1 or 27.2 beta; check on the machine) through `DEVELOPER_DIR` only; folds at rows 30, 300 and 700 (the Wave 3 TestFlight checklist's "Duo fold keeps the list's place", under "Background from the rearchitecture") on live-verification.md's `SoakBig` folder (about 800 messages, in the stage account live-verification.md calls test account 3) or the maintainer's account; an iPad divider drag on the Mini. Book the Studio with duo-support.md.
- Risk: medium.

**Status:** Not started (2026-10-15); built only if decision 6 is Now.

**Releases and soak.** Two releases if the maintainer promotes between sessions: session 1, then session 2. If R4 shares a release with R1b, that is acceptable: they change different restores (the message restore versus which stored route wins), each has its own issue's steps in the soak, and each is one PR to revert. The Mini soak re-runs each issue's steps with a second agent before `make promote`. The maintainer's device list (holds Promote, not merge): the iPad app-switcher return (#2035), a real warm notification (#2028), the iPad Settings sheet with a Spotlight result (decision 1 Close), iPad window titles (#2036), and Mac New Window plus Command-Q with two windows. Rollback is plain: `savedAt` is optional and older builds ignore it, the scene-stored sets are local, and nothing touches a server.

**Hotspots, one open PR per file.**

| File | PRs here | Also edited by |
| --- | --- | --- |
| `Navigation/SceneNavigator.swift` | R5 (one line) | mail-navigation-refactors.md PR 1, ipad-layout-and-keyboard.md PR B, feed-bulk-actions.md, duo-support.md, flags-and-cross-media.md, sqlite-mail-store.md Phase 3 |
| `ListPlaceTracking.swift` | R1a, R6 | sqlite-mail-store.md Phase 3, shared-load-error-state.md B4 |
| `FolderListHold.swift` | R1a (maybe) | feed-bulk-actions.md, mail-navigation-refactors.md, ipad-layout-and-keyboard.md |
| `MessageListView.swift` | R4, R6 | sqlite-mail-store.md Phase 3 (which took mail-navigation-refactors.md's old PR 5), ipad-layout-and-keyboard.md PR C, flags-and-cross-media.md, docs-and-bookkeeping.md |
| `StoredRoute.swift`, `WindowRecorder.swift`, `WindowRestores.swift` | R1b, R2, R4 | flags-and-cross-media.md (its B5.1 gate wants `StoredRoute.swift` quiet) |
| `AppState.swift`, `AppStateSignals.swift` | R2 | account-isolation.md C1 |
| `MainSceneActivation.swift` | R3, W1 | platform-conditionals.md S1 PR 5 (FU-2 B), detached-reader-window.md |
| `ComposeWindowScene.swift`, `ComposeCoordinator.swift` | R5 | platform-conditionals.md S1 PR 5, duo-support.md (#1680), detached-reader-window.md |
| `ShellHandOff.swift`, `SettingsSheetPresenter.swift` | R5 | ipad-layout-and-keyboard.md PRs B and D |
| `CabalmailCommands.swift`, `CabalmailMacApp.swift` | W2 | detached-reader-window.md PR 4, platform-conditionals.md |
| `FolderListView.swift`, `FeedSidebarSection.swift` | W3 | account-isolation.md C1 (the same keys) |
| `EmptyDetailToolbar.swift`, `EmptyFeedDetailToolbar.swift` | W4 | platform-conditionals.md S1 PR 3, flags-and-cross-media.md B2.4 |
| `WideMail.swift` | W5 | ipad-layout-and-keyboard.md, feed-bulk-actions.md |
| `docs/apple.md` | R1b, R2, R3, R4, W3 | docs-and-bookkeeping.md, duo-support.md PR 7, apple-ci-and-build-config.md |

> **Erratum (2026-10-16):** duo-support.md's `docs/apple.md` work is its PR 11 (Duo docs); its PR 7 is compose as a sheet. Read PR 11 where this hotspot list says PR 7 for `docs/apple.md`.

R1a and R6 should land before sqlite-mail-store.md's Phase 3 takes `ListPlaceTracking.swift`. None of this plan's PRs touches `AppRoute.swift` or `DeepLinkRouter.swift`, and none touches `PushRegistrar.swift`: #2028's fix is R4, so account-isolation.md and mail-correctness.md can drop this plan from that file's sharers.

## Background from the rearchitecture

What the sessions need from the workstream 3.3 (restore and routing) scope doc of 2026-10-09 and the Wave 3 TestFlight checklist, which are not in the repo.

**3.3's questions 4 and 5: the list's place (G1, G2).** The maintainer added G ("Yes, please", 2026-10-09) as two PRs: G1 keeps a message list's place across a fold or an iPad narrowing, and G2 reopens it at its place after a relaunch (#1896). A check of the design against stage then found that the window's navigator could not safely hold each folder's list model: during a fold the old and new trees are both alive for a moment, the old list stops watching late on a detached task, and the pollers count each list once, so a model shared by both trees would end up off its poller with its page loads cancelled; the rebuilt list's scroll view starts at row 0 either way. Question 5 offered:

- **Anchor only** (recommended; the maintainer's answer, 2026-10-09). Each list keeps building its own model, as today. After a fold the top of the list shows until the rebuilt list's first refresh lands (the #1664 gate), then it moves to your row. Rows past the top 250 reload, so a deep place costs one more page load. Nothing in `MessageListViewModel*` changes.
- **Hold the model.** The place and every loaded row come back at once; G would also add attach counting to `MessageListViewModel*` (a hotspot), stop the rebuilt list's row 0 from pulling the loaded window back to the top, and clear a lone selection the hand-off drops: roughly 150 to 250 more lines *(inferred)*.

**3.3's risk 10, the list's place.** The geometry is inferred: whether the content offset plus the top inset gives the top row under the pill bar, and whether the first layout reports it, needs the simulator; the formula is a pure function with tests. The jump: a fold shows the top of the list until the first refresh, then moves; applying earlier, from the snapshot, is a possible follow-up (this plan's R6). Tight class bodies: `SceneNavigator`'s class body was 245 counted lines and `NavStateCoordinator`'s 244 (at `5a70043`, before 3.3), against `type_body_length`'s 250, which `--strict` makes an error, so G recounted before each push and put new state in its own types.

**What 3.3 left out.**

- The toast slot stays app-wide (3.3's decision 14): the cross-device check still posts to the one slot, every window shows the banner, Resume moves only the window tapped, and dismissing it in one window dismisses it everywhere.
- Menu commands (3.1's) and layout work (3.2's: #1970 and #1989, the `platformAlwaysWindows` swap, and #1680, a Duo compose window taking the whole display, which stays Duo backlog; the compose coordinator puts the window-or-sheet decision in one place, so a later fix there is a policy change).
- Keeping the list model alive across a fold (question 5). Also the place in filter and search lists (a plain `ForEach`), and a place per folder: switching folders, or backing out to the folder list on iPhone, still opens a list at its top.
- #1973 (notification actions write outside the mail store), a mail-store change.
- Detached reader windows and other Duo extras.
- A single main window on macOS. The shell audit's alternative of a single main `Window` on macOS is out: 3.3 makes N main windows work, which dual-screen needs.
- Scene storage for compose windows. Drafts already persist through the draft store, and a restored compose window keeps the slot-less behaviour.
- Kit, server and `project.yml` changes: none, except G2's four optional `ResumeSession` fields.

**3.3's source scans for the files this plan edits.** Their expected text and anchors are never edited without the maintainer's yes.

- `Mail/MessageList/MessageListView.swift`: every anchor stays, and no comment may quote `applyPendingRestoreWhenReady()` or `.keepsInBar()`, because these scans count raw text. `LaunchRestoreSequencingSourceScanTests` (the guard `guard hasAppeared, initialLoadComplete, let model else { return }` and exactly three `applyPendingRestoreWhenReady()`); `SwipeActionContainerSourceScanTests` (including `private func withdrawPurgeCandidate()`, `private var purgeDialogBinding: Binding<Bool> {` and the "Delete Forever?" Cancel button); `ToolbarVisibilitySourceScanTests` (two `.keepsInBar()`); `MessageListRefreshRoutingTests` (`} else if !isSearchScope {` through `await model?.refresh()`); `CompactBrandMarkSourceScanTests`.
- `Mail/MessageList/MessageListView+Selection.swift`: `SwipeActionContainerSourceScanTests`' `ForEach(model.rowSlots(count: rowCount), id: \.self)` and `MessageRowIdentity.identify(` text inside `virtualizedList`, and exactly three `proxy.scrollTo(model.rowSlot(at:`. G1's restore scroll lives in `ListPlaceTracking.swift`, and a behaviour test shows it scrolls by slot.
- `Compose/Windows/ComposeWindowScene.swift`: `ComposeWindowSlotSourceScanTests` (`appState.composeSlots.mayCompose(seed, closedOn: closedOn)`, `closedOn = appState.composeSlots.closedCompose(for: seed)`, `seed(forWindowWith: slot, ownSeed: ownSeed)`, `ownSeed = mailto.draft()`, `if let slot { appState.composeSlots.release(slot) }`, and no `ComposeSlot(index:` literal); `SceneAppearanceSourceScanTests` (the scene inventory is CabalmailApp 1, ComposeWindowScene 1, CabalmailMacApp 3).
- `App/AppState.swift`: `ComposeWindowSlotSourceScanTests` (`composeSlots.endSession()`).
- `Compose/Windows/MainSceneActivation.swift`: `ComposeWindowOrphanSourceScanTests` (`UISceneSessionActivationRequest(role: .windowApplication)` is present, and `guard let session else { return }` is absent).
- `Shell/SignedInRootView.swift`: `ReaderColumnFloorSourceScanTests` (`measuredWidth: measuredWidth`, 3.2's line).
- `apple/CabalmailMac/CabalmailMacApp.swift`: `ColorTokenSourceScanTests`, `ConfirmationDialogRoleTests` and `MenuPickerSourceScanTests` list or probe it; they need the file to exist and new code to follow the rules they check.

**3.3's regressions to re-test.** "3.3's test" is a behaviour test 3.3 added; the by-hand checks are what its sessions ran.

| Issue | Rule | Check |
| --- | --- | --- |
| #1987 | A Resume, notification, Spotlight or Siri open lands in the window it targets when another window shows the same folder | 3.3's test (two navigators); two Mac windows on INBOX, Resume in each; two iPad windows, notification tap |
| #1965 known limits | Narrowing one of two windows on one folder keeps its message; two windows rebuilt in one pass each keep their own | 3.3's tests; two iPad windows in Split View, drag the divider across the size-class line |
| #1966 | A window opened after a notification launch lands on the live session | 3.3's test; iPad: quit, tap a notification, open a second window |
| #1555 | First landing: launch snapshot; later windows: live session; rebuild: window route | Navigator tests; 3.3's test for the stored route ahead of both |
| #1664 | A compact stack never gets list and reader in one update | The scan; iPhone cold launch into a message and into a feed item |
| #1535, #1912 | Provisional landing swap; backing out before folders load | Navigator tests |
| #1845 item 3 | Resume moves only the window tapped | Two Mac windows |
| #1873, #1895 | UIDVALIDITY stays with its message; the reading fraction is restored | `RestoreTickCharacterizationTests` |
| (none) | A stored route from another account, or after sign-out, is ignored | 3.3's test; sign out and in as another stage account on iPad, background-terminate, relaunch |
| #1162 | File > New Message with every main window closed opens compose | Mac, by hand; `MailboxMenuAvailabilityTests` |
| #1084 | Compose windows recycle slots | `ComposeSlotRegistryTests`, `ComposeWindowSlotSourceScanTests` |
| #1688 | A lone compose window (mailto cold launch into compose on iPad) closes on Send and Cancel | The orphan scan; iPad, by hand |
| #1783 | A reply opens for the reader's own window | `CommandWindowTargetingTests`; two iPad windows, reply in each |
| (App Review) | A mailto: arriving on iPhone's Addresses or Settings tab presents compose | iPhone, by hand |
| #1824 compose variants | Two iPad windows, no window recorded: a mailto: opens one composer; two mailto: links behind a sheet both open | 3.3's flipped tests; iPad and iPhone, by hand |
| (inferred) | macOS mailto: with a main window open opens exactly one composer | Mac, by hand |
| #1460 | Every scene pins the theme | `SceneAppearanceSourceScanTests` |
| #1992, #1827 | Restore leaves the code form and an error alone; sign-out during a restore ends that session | 3.3's flipped tests; teardown tests; Mac with test account 2 (MFA on): reach the code form, open a second window |
| (push) | Account-switch and parked-tap rules | `PushAccountSwitchTests` |
| (Spotlight) | Parked before sign-in; dropped at sign-out and expiry; macOS delegate path | 3.3's ported tests; Mac cold launch from a Spotlight result |
| (Siri) | Open Folder cold and warm | iPad, by hand |
| #1644 | A new window's tab is seeded from its route, else the session | `CompactTabSeedTests`; iPhone relaunch onto Feeds |
| (G1) | A fold or a size-class change brings each window's list back at its row; repeat folds don't drift; scrolling during the refresh wins | 3.3's tests; Duo simulator at about rows 30, 300 and 700; two iPad windows, drag the divider |
| (G1), #1664 | A compact list that reappears after a reader pop stays where it was; a cold launch into a message still opens the reader | 3.3's test; iPhone |
| #1816 | After a fold and after a reader pop, the list is back on its folder's poller | `MessageListRefreshRoutingTests`; new mail arriving |
| #1823, #1868, #1870 | Home, End, Page Up, Page Down and the arrow keys still scroll by slot; deep scrolling still loads pages; a search stands down the window's loads | Paging tests; Mac and iPad keyboard |
| (2.3) | The selection hand-off across a fold, multi-selection included, is unchanged | `SceneNavigatorSelectionTests`; Select mode, then fold |
| #1896 | Relaunch: each restored window gets its own folder and row; after a swipe-away, the last-used window's; a deep link wins; nothing carries across a sign-out; a deleted folder lands on INBOX at the top; a folder left on the Unread pill opens on Unread at the top | 3.3's tests; iPad, iPhone and Mac |

**The Wave 3 TestFlight checklist** (written for the stage TestFlight build from the #2015 merge, stage `59d8ff8`, 2026-10-10). The checks this plan reruns or relies on:

- **Opening a second window.** Mac: there is no File > New Window (File > New is New Message). View > Show Tab Bar, click + in the tab bar, then drag the new tab out into its own window should work, but no session tried it. iPad: File > New Window from the menu bar, or touch and hold the Cabalmail icon and choose New Window.
- **Mac: composers open as windows** (#2009, #2010). Do: click New Message in the toolbar above the list; close it with Command-W (Discard Draft if asked). Open a message, click Reply, close that the same way. Then close every main window with Command-W (do not quit), Command-Tab back to Cabalmail and choose File > New Message (Command-N). Optional: close that and choose New Message from the menu-bar icon. You should see: each composer in a window of its own, not a sheet sliding down from the main window; with every main window closed, File > New Message and the menu-bar item still open a composer. Wrong if: a composer attaches as a sheet, nothing opens, or a main window opens instead of a composer.
- **Mac: a mailto: link opens one composer** (#2009). Setup: one main window open; Cabalmail set as the default email reader (Mail app > Settings > General > Default email reader); a mailto: link in Safari or Notes. Do: click the link once and count compose windows; close it without sending. You should see: exactly one composer, addressed to the link's address, and no extra main window. Wrong if: two composers, none, or a second main window.
- **At the Studio: Duo fold keeps the list's place** (#2013, #2015). Only the closed pose had been checked. The fold is set by clicking Device Hub's posture buttons on the Studio's screen.
  - Setup: Xcode 27.1 beta, a stage build on a copy of the iPhone Duo simulator, signed in. The row 300 and 700 steps need an account with 700 or more messages in INBOX.
  - Do: (1) INBOX, All pill, default sort, no search. Scroll so a message several rows down (about row 30) is at the top; note it. (2) Fold (Closed) in Device Hub, wait for the refresh, note the top message. Unfold (Open) and note it again. Repeat two or three times. (3) If the account allows, repeat with about row 300 and row 700 at the top. (4) Fold or unfold and start scrolling straight away. (5) Unfolded, with a message several rows down at the top, wait five seconds, stop the app from Xcode, and relaunch. Do it once more, changing the pose between the stop and the relaunch.
  - You should see: after each fold or unfold, once the refresh lands, the same message at the top, with no creep over repeated folds. A scroll you start during the refresh is not undone. After each relaunch, the noted message at the top in either pose.
  - Wrong if: the list goes to the top or to a different message after a fold, creeps each fold, jumps back over your scroll, or reopens at the top in the open pose or after a pose change.
  - The maintainer approved fold clicks for the 3.2 layout-shells session, which drove real folds for #2006 and #2008, so a Studio session given GUI time can run this, though its click points may need re-measuring first.
- **At the Studio: two iPad windows come back after an Xcode stop** (#2005, #2015). A swipe-away throws saved windows away, so only an Xcode stop tests this. Use the Studio's iPad simulator with Stage Manager, or a real iPad connected to the Studio. Do: open two windows wide enough to show the list beside the reader: one on INBOX, one on another folder (say Sent), both on the All pill, default sort. In each, scroll so a different message is at the top and open a message; note each window's folder, open message and top message. Tap into each in turn, wait five seconds, and go to the Home Screen. Click Stop in Xcode, then launch Cabalmail from the Home Screen. You should see: both windows back, each on its own folder, with its own message open and its own top message. Wrong if: both on the same folder or on INBOX, a list at the top, or the wrong message open.
- **Open question: Command-comma behind a composer on iPad** (#1999). It does nothing while a compose window is in front; before Wave 3 it opened Settings in the window behind. The maintainer was asked whether to bring that back.
- **Open question: the Settings sheet when something navigates** (#2006). #2006 shipped "keep it open", so a notification, Spotlight result or Resume leaves an open iPad Settings sheet up. That is the opposite of the decision card's recommendation, and choosing "Close it" means a small follow-up PR (this plan's decision 1 and R5).

## How to start it

Session 1 opening brief (paste):

> Run post-wave-3 plan multi-window-and-restore.md, session 1 (R1a, R3, R1b, R2, R4, R5, in that order), on cabalmail/cabal-infra `stage`, once Release 1.31.0 (#2043) has merged. Read the plan and 00-working-agreements.md (both in `docs/1.x/post-wave-3/`) first. The maintainer's answers to the plan's six decisions: [paste]. Re-check every file:line and issue state against current stage. Write a short scope doc (decisions at the top, quoted in full; one line per PR), post it, then open R1a. One PR at a time. R3 and R2 each start with their measurement; stop R3 if no activation signal fires. R5 waits for ipad-layout-and-keyboard.md's PRs B and D. Use the Mini over Remote Control; check the maintainer's tester is not using it, and coordinate sign-ins to the two stage test accounts. If the context runs long, stop after R4 and hand R5 to session 2. Hand off with a list of merged PRs and anything left open.

Session 2 opening brief (paste):

> Run multi-window-and-restore.md, session 2 (W1 to W5, then R6 only if decision 6 is Now). Session 1 has merged: read its PRs for changes to `MainSceneActivation.swift`, `AppStateSignals.swift` and `StoredRoute.swift`. Decisions 2, 3 and 6: [paste]. Same rules. Before W3, check account-isolation.md's C1 is not open; before W4, check platform-conditionals.md's S1 PR 3 is not open. R6 needs the Studio: book it with duo-support.md first.

Point at: this plan and `00-working-agreements.md` (both in `docs/1.x/post-wave-3/`); this plan's "Background from the rearchitecture", which carries what the sessions need from the 3.3 scope doc (questions 4 and 5, what 3.3 left out, its source scans and regressions to re-test, risk 10) and the Wave 3 TestFlight checklist (opening a second window, Mac compose, the Studio checks and the open questions), with audit 06 F16 stated under W3; the bodies of PRs #1793 ("Left for"), #2007, #2009 and #2015 ("Not covered", "For you").

## Risks and checks

- **Scene storage and AppKit restoration cannot be unit-tested** (R1b, R2). Check: each has a Mini run with its issue's own steps as the gate; R2 measures before writing code, and decision 4 settles the fallback in advance.
- **R3 may find no signal to listen to** (#2035's own inference). Check: the spike; stop with a comment rather than invent a touch hook.
- **R3 moves `wasLastUsed` on iPad.** Check: it lands before R1b, and R1b's iPad two-window run is after it.
- **The restore path is #1664-sensitive** (R4, R6). Check: both reader gates stay; grep the scan count (3) and the `refresh()` pin before every push; the one-shot characterization row stays green.
- **Navigator size.** About 8 lines of headroom. Check: recount before R5's push; prefer mail-navigation-refactors.md PR 1 first.
- **Behaviour-test flips** (decisions 1 and 5). Check: only with the maintainer's answer, named in the PR body.
- **Studio contention** (R6). Check: one Studio GUI session at a time; R6 is droppable.
- **The Duo claim is inferred.** Check: if the Studio is free during session 1, one mailto with two scenes on the open Duo simulator after R3.
- **visionOS is unmeasured.** R3 and W1 leave its code path alone, and nobody knows whether #2035 or #2036 happen there. Check: CI builds it; if a visionOS simulator is free, one two-window look during R3 and W1 records the answer on the issue.

## Not in this plan

- **#2033, #2034, #1988, #2004, #2026, #2027, #2024, #1929** (iPad width transitions, the search result across a swap, iPad keyboard commands): ipad-layout-and-keyboard.md.
- **#1680** (a Duo compose window takes the whole inner display) and **#1962** (an open feed item lost on unfold), both open: duo-support.md.
- **Keeping the list model alive across a fold:** declined by the maintainer ("Anchor only", 2026-10-09); nothing here re-proposes it. **Rows past 250** and **#1834's re-read cost under a non-default sort:** sqlite-mail-store.md (Phase 3, PR 3.4), which accepts both.
- **A list place for filter, search and non-default-sort lists, and one place per folder:** left out on purpose in 3.3 (see "What 3.3 left out" under "Background from the rearchitecture"; #2015 "Not covered"). Reopen only if the maintainer asks. sqlite-mail-store.md's "Not in this plan" now says so too. `list_scroll` stays dead on Apple.
- **The deep link that races a wide window's first landing** (PR #2007, "Not covered"; a few milliseconds, pre-existing): not planned unless it reproduces.
- **The soak rig's Spotlight gap:** live-verification.md (its 30-minute rig-prep investigation). **Hosted multi-window UI tests:** test-debt.md (B2). **Wave 3's by-hand checklist and Studio fold checks not tied to R6:** live-verification.md and duo-support.md.
- **Other stale comments** (`MailRootView` mentions, the `SplitShell` width write, `layoutIsWide`) and **merged-with-a-question defaults other than the Settings sheet:** docs-and-bookkeeping.md and mail-navigation-refactors.md.
- **The toast slot** stays app-wide (3.3's decision 14). **A single Mac main window:** rejected (3.3's "Left out"). **iPad Command-comma behind a composer:** accepted under "Anything I haven't reported is good" (the maintainer, closing the Wave 3 TestFlight checklist; low confidence). **#1973:** mail-correctness.md.

## Sources

- GitHub, checked 2026-10-12: issues #2016, #2028, #2030, #2035, #2036, #2039, #2041, #2042, #1896, #1966, #1680, #1962, #2026, #2027 (open); #2018, #1987 (closed); PRs #1793, #1834, #1999, #2006, #2007, #2009, #2015 (merged); #2043 (Release 1.31.0, open).
- Commits on stage: `5035e28b` (3.3 B, "Fixes #1987", "Fixes #1966"), `7335224f` (#2018), `1b5830c1` (3.3 G2, "Fixes #1896"), `5a88a56b` (3.3 E).
- Code at 50e6022 (under `apple/CabalmailUI/` unless named): the lines cited above; `Navigation/StoredRoute.swift:1-118`; `Navigation/WindowRecorder.swift:144-162`; `Compose/Windows/ComposeCoordinator.swift:1-30, 82-107, 150-175`; `Compose/Windows/MainSceneActivation.swift:1-145`; `Mail/MessageList/MessageListView.swift:577-620`; `Shell/SettingsSheetPresenter.swift`; `Navigation/ShellHandOff.swift:1-80`; `apple/CabalmailMac/CabalmailMacApp.swift:20-91`; `apple/CabalmailTests/` files named above; `apple/.swiftlint.yml:44-50`.
- `00-working-agreements.md` in this folder.
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Sibling plans in this folder checked for hand-offs: duo-support.md, detached-reader-window.md, sqlite-mail-store.md, mail-correctness.md, flags-and-cross-media.md, shared-load-error-state.md, ipad-layout-and-keyboard.md, platform-conditionals.md, mail-navigation-refactors.md, account-isolation.md, refresh-scheduling.md, test-debt.md, live-verification.md, docs-and-bookkeeping.md.
