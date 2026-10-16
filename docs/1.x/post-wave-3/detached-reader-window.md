# Detached reader window

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session. One scope doc, one batch of seven decisions and five sequential PRs, with no server change, no data migration and no outside wait; the one Duo question is designed out by leaving the entry point off on every iPhone.
**Size:** L (five PRs; the upper end of one session, because the new window touches menus, the reader, iPad scene handling and four platforms' checks).
**Priority:** Later. No issue or tester asks for it, bugs go first, the Duo no longer needs it, and the reader, menu and window files it edits are held by Now and Next plans for the next few weeks.
**Depends on:** order only, one open PR per shared file: mail-correctness.md (PR 1, the #1990 server fix, before this plan's PR 4; PR 2, #2037, before this plan's PR 2), multi-window-and-restore.md (session 1's R3 and session 2's W1 before PR 4), ipad-layout-and-keyboard.md (its command PRs before PR 2, its PR C before PR 5), duo-support.md (its PR 6 in the reader files; Session 2's #1680 finding before an open Duo gets the entry point), platform-conditionals.md (FU-1 and FU-2 part B), shared-load-error-state.md (B3), mail-navigation-refactors.md (`MessageDetailViewModel*`). Later PR 6 only: flags-and-cross-media.md (B5.1's two-case item identity). Soft: test-debt.md (B2's two-window Mac spike).
**Unblocks:** nothing hard. duo-support.md's Session 2 gets an entry point to turn on for the open Duo.
**Duo groundwork:** It adds a second scene keyed by a stored message identity that an open Duo can host once duo-support.md's device pass answers #1680; it builds no spanned shell, because the crease-pinned `SplitShell` already is the list-beside-reader layout on an open Duo.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| Decisions 1 to 7 | Unanswered (2026-10-15). Decision 1's default keeps the plan parked until the maintainer says yes. |
| PR 1. Kit: envelopes by UID | Not started (2026-10-15). |
| PR 2. Menus and the removal notice | Not started (2026-10-15). |
| PR 3. Reader seams | Not started (2026-10-15). |
| PR 4. The message window | Not started (2026-10-15). |
| PR 5. Command-O, double-click and docs | Not started (2026-10-15). |
| PR 6, later. Feed items | Not started (2026-10-15). |

> **Duo spec (2026-10-13):** This plan was written before the maintainer's Oct 7 Duo spec (the Claude Doc linked in duo-support.md) was read in the rearchitecture project. duo-support.md now follows it; where this plan's text disagrees with the points below, the points win. In the spec, "fold" means book or laptop pose, which changes no size class and swaps no shell; what this plan calls folding or unfolding the Duo is closing or opening it.
>
> - An open Duo shows the list beside the reader only in open wide (your stored width, a drag handle) and book (the list pinned to the fold). Open portrait is the iPad-portrait overlay and laptop a list panel below the fold. None needs a spanned shell, so the conclusion stands; the "crease-pinned `SplitShell`" wording does not.
> - #1680 is settled for compose: a sheet in every layout, a window only on request (duo-support.md PR 7). The open-Duo entry point no longer waits on a #1680 finding. Decision 3 gains the spec's option: show "Open in New Window" at regular width on any iOS host, on request, falling back to opening the message in place if the scene request fails. `MessageWindowPolicy` on iOS keys on the window's regular width, not the iPad idiom and not a fold input; test a compact window on a Duo (a Split View half) and a compact iPad window.
> - Whether the closed Duo can hold a window is open: `ComposeWindowScene.swift:40-44` records the closed display reporting no multi-window support, and the spec's Studio run saw a window open there. Do not rely on either; the Duo turn-on check closes the device with a message window open.
> - Compose from a message window follows the same surface policy (a sheet on iPad, a window on request). A message window marks read only when opened by the user, never when restored or re-resolved, and its re-check updates flags in place without reloading the body. The banner stack PR 4 moves carries duo-support.md PR 4's fold rule.

## Decisions for the maintainer

1. **Build it, or retire it?** The Duo reason is gone (see Why), so what is left is the Mac, iPad and visionOS habit of opening a message in its own window. **(a) Keep it, as Later (recommended).** (b) Retire it, and docs-and-bookkeeping.md records why. Consequence of (a): about a week of session time when the shared files are quiet, plus one scan edit. Default: it stays parked, and no session starts without your yes.
2. **What can open in a window?** **(a) Mail messages, except in Drafts (recommended).** (b) Mail and feed items now. Drafts are left out because each autosave gives a draft a new number, which only a list follows (`Mail/Store/MailEvents.swift:36-42`). Consequence of (a): feed items follow as one more PR (PR 6) once flags-and-cross-media.md's B5.1 gives mail and feed items one identity; (b) adds a second window kind now that has to be merged into one later. Default: (a).
3. **Where is it offered?** **(a) Mac, iPad and visionOS; on no iPhone, the open Duo included, until duo-support.md's Session 2 has seen #1680 on the device (recommended).** (b) Mac and iPad only. Consequence of (a): visionOS is checked only on the simulator. Default: (a).
4. **A message removed while its window is open** (moved or deleted from another window or device). **(a) The window stays and says "This message is no longer in Inbox", with its buttons off and a Close button (recommended).** (b) The window closes itself. Either way, archiving, deleting or moving from the window itself closes it. This is the same question as mail-correctness.md's Decision 1 (c) for the main window's reader; if you pick (c) there, that plan builds the note and PR 3 here only reuses it. Default: (a).
5. **Command-O.** **(a) Message > Open in New Window with Command-O (recommended).** (b) The context menu only. Consequence of (a): one more Message menu item on the Mac and in the iPad menu bar. Apple Mail uses Command-O under File > Open Message (inferred, medium confidence), so the chord matches and the menu differs. Default: (a).
6. **Double-click on the Mac.** **(a) Yes, if a single click still selects at once (recommended).** (b) No. The row's click target is a button, and a tap gesture inside the list once never fired on macOS 27 (#984, closed), so this is built by reading the click's count, and dropped if it slows a single click. Default: (a), with that condition.
7. **May PR 4 add one row, `"CabalmailUI/Mail/Windows/MessageWindowScene.swift": 1`, to the scene inventory in `apple/CabalmailTests/SceneAppearanceSourceScanTests.swift:61-71`?** **Yes (recommended):** the scan keeps its purpose (every scene pins the Theme, #1460), its own comment (:61-62) expects new scenes, and the new scene pins the Theme. No: PR 4 first turns that inventory check into a behaviour test, about a day more. Default: PR 4 waits for your answer.

Not asked again: the toast stays one app-wide slot (Wave 3.3's decision 14: every window shows the banner, Resume moves only the window tapped, and dismissing it in one window dismisses it everywhere), and a single main window on the Mac stays rejected (3.3 left out the 2026-10-02 shell audit's (audit 04's) alternative of one main `Window` on macOS: 3.3 makes N main windows work, which dual-screen needs). Dropped on evidence and not asked, so say if you want it asked: a spanned list|reader shell for the open Duo. The 2026-10-02 platform-split audit (audit 07) argued that the Duo needs no shell of its own (the inner display is regular/regular, so `SplitShell` with a narrower budget; the outer is compact, so `TabShell`; a Duo shell would duplicate `SplitShell` and still need the same state hand-off on every fold), and duo-support.md pins `SplitShell` to the crease instead.

## What you'll see change

- **PR 1, envelope lookup:** nothing visible. The app can fetch one message's summary by folder and number, which a window restored at launch needs.
- **PR 2, menus and removal notices:** nothing visible. The Message menu learns about a window that shows one message, and a list that finds messages gone tells the rest of the app.
- **PR 3, reader seams:** nothing visible. The reader learns to live in a window with no list beside it.
- **PR 4, message windows** on the Mac, iPad and visionOS:
  - "Open in New Window" in a message's context menu, in folder lists and search results (not in Drafts).
  - The window shows the message with the reader's toolbar; Reply, Forward, flags and Move act on it while it is in front.
  - Opening the same message again brings its window forward.
  - Archive, delete or move from the window closes it; a message removed elsewhere is marked as gone (Decision 4).
  - It comes back after a relaunch, and closes at sign-out.
- **PR 5:** Message > Open in New Window (Command-O), double-click on the Mac, and a "Message windows" section in `docs/apple.md`.
- **PR 6, later:** feed items open in a window too, after flags-and-cross-media.md's B5.1.

## Why

- **Platform habit.** On the Mac a mail client opens a message in its own window by double-click; on iPad, "Open in New Window" from a long press. Today a reader exists only as a column or a pushed view (audit 04's gap 9: there is no explicit "list here, reader there" scene type).
- **The Duo reason has gone.** The rearchitecture proposal listed this only as a Duo piece: "Later, as separate projects ... the Duo-specific pieces (a detached reader window ...)"; audit 04 sketches it as WS8 (later, Duo-specific: a `WindowGroup(for: MessageRef.self)` reader scene and an optional spanned list|reader shell driven by `ShellLayout`, checked by two scenes side by side keeping independent routes, Reply targeting the focused scene, and fold and unfold preserving both). Since then, an open Duo shows list and reader side by side in `SplitShell`, and a folded Duo cannot open a window at all (`ComposeWindowScene.swift:39-44`: "the closed Duo reports false").
- **Wave 3 built the prerequisites**, so the work is a scene, a resolver and seams, not an architecture change. 3.3 left it out on purpose ("Detached reader windows and other Duo extras"), and 3.1 noted that its per-window commands are groundwork for it ("Commands that follow the window in front are also what a future detached reader window would need").
- **No issue asks for it.** A search on 2026-10-12 found only closed, unrelated issues (#716, #1162, #1987). Hence Later, and Decision 1.
- **It stays inside 2.1's decision 1,** which the maintainer confirmed on 2026-10-08: "Rows stay in each list ... a table of envelopes by ref waits for the SQLite mail store. Readers follow flag events for their own ref". The window resolves one message on demand and builds no table; sqlite-mail-store.md's PR 3.5 later replaces its cache step.

## Where things stand

**Scenes.** The app has main windows and compose windows, and nothing that shows one message in its own window. Three files in the iOS, visionOS and macOS app layers declare scenes: the iOS main `WindowGroup` (`apple/Cabalmail/CabalmailApp.swift:49`); the compose group (`CabalmailUI/Compose/Windows/ComposeWindowScene.swift:98`), which both apps install (`CabalmailApp.swift:94`, `CabalmailMacApp.swift:91`); and the Mac's main group, `Settings` and `MenuBarExtra` (`apple/CabalmailMac/CabalmailMacApp.swift:51, 92, 108`). The watch's `WindowGroup` (`CabalmailWatch/CabalmailWatchApp.swift:15`) is outside the scene scan by design. iPad multi-window is on (`apple/project.yml:136`).

**The precedent.** Compose windows already do most of what a message window needs. `WindowGroup("New Message", id: composeWindowID, for: ComposeSlot.self)` (`CabalmailUI/Compose/Windows/ComposeWindowScene.swift:98`) pins the Theme (:108), restores the session when launched first (:114), shows a "Sign in required" placeholder (:208-215), activates a main window before dismissing on iPad (:194-196), and sets a Mac size behind `#if os(macOS)` (:119-121). PRs #2005 and #2009 (both merged 2026-10-10) added per-window routes and the compose coordinator.

**Identity and stored formats.** A message is named by folder and number, and every stored format keeps its own shape. `MessageRef` is equal on folder and UID only (`CabalmailKit/Models/MessageRef.swift:61-70`), and its header says "No stored or wire format embeds it ... each keep their own shape and convert at the boundary" (:23-26). `AppRoute.Mail` follows that with its own keys (`Navigation/AppRoute.swift:45-69`). A main window's stored route carries its account, so a restore never lands on another account (`Navigation/StoredRoute.swift:16-57`).

**Menus.** The menus act on the main window in front, and dim when anything else is in front.
- `WindowCommands` takes a whole `SceneNavigator` only to know which tab is in front (`Commands/WindowCommands.swift:89-136`). Each main window builds one (`Shell/SignedInRootView.swift:73`) and publishes it as a focused value (:119). The Message menu reads it and dims with none (`Commands/MessageMenuCommands.swift:26-39`).
- Several menus enable whenever any `WindowCommands` is in front: iPad Command-comma (`CabalmailApp.swift:101-108`), the Mac's Expand and Collapse All Folders (`CabalmailMac/CabalmailCommands.swift:94-97`), and the Feeds menu's catalog items (`Commands/FeedsMenuCommands.swift:24-59`). The availability reporter also tells the Mailbox menu that a list is on screen (`Commands/MessageMenuAvailability.swift:71`).
- The reader answers only Reply, Reply All and Forward (`Mail/Reader/MessageDetailView.swift:232-234`); the list answers the rest (`Mail/MessageList/MessageListView.swift:540-555`).

**The reader.** The reader assumes a main window around it.
- It takes a `Folder` and an `Envelope` (`MessageDetailView.swift:17-23`), builds its model on appear (:245-272) and names its main window on its mail events (:363-369).
- Its compose goes to its window's compose surface, else the one registered last (`+Compose.swift:83-85`; `Compose/Windows/ComposeCoordinator.swift:82-86, 163-166`). With no navigator, its scroll reports go to the cross-device cursor (`+Scroll.swift:120-126`).
- Its mark-read and dispose menus offer "and go to next" choices (`+SeenOptions.swift:60-78`, `+DisposeOptions.swift`). Its dispose is optimistic: on a refusal the row comes back and a toast shows (`MessageDetailViewModel.swift:231-260`).
- On iOS it hides its inline title so the subject is not shown twice (:185-190), and it picks its action bar from the size class (:98-112). Outside a main window the layout signal defaults to the iOS tabs (`Shell/ShellLayout.swift:73-75, 93`); audit 04's gap 10 (a new shell has no first-class layout signal to set) names this gap for "a reader-only scene".

**Removal (#2037).** Today a removal that a refresh finds reaches no reader in any window.
- The reader hears only flag changes (`MessageDetailViewModel+Flags.swift:94-97`). Removals the app makes are `.removed` events: the window the user acted in advances, other windows let go, and an event naming no window advances every window (`Mail/MessageList/MailEventSelectionPolicy.swift:39-48`). So a message window's events must name the window.
- Removals a refresh finds prune rows and caches silently (`WindowRefresher.swift:247-289`). #2037 (open, `needs-verification`) is owned by mail-correctness.md, whose recommended fix queues a reaction inside each list and posts nothing on the store (its Decision 1 (a), PR 2). A message window has no list, so it would not hear that fix.

**Liveness.** A body fetch cannot tell that a message is gone; an envelope lookup can, when it succeeds.
- `fetch_message` serves a cached body even after the message is gone (`lambda/api/_shared/helper.py:1218-1250`). `/list_envelopes?ids=` leaves a missing UID out of its reply (`lambda/api/list_envelopes/function.py:20-35`; the helper notes a UID FETCH for a missing UID "succeeds and returns an empty dict").
- But #1990 (open) shows that endpoint returning a 502 in about 1 call in 400 to 700 while another session changes flags in the same folder, plus an inferred second hazard where a stray update collides with a requested UID. mail-correctness.md's PR 1 fixes it on the server.
- The client calls the endpoint only while paging (`IMAP/ApiBackedImapClient.swift:435, 458`), and `ImapClient` has no by-UID method (`IMAP/ImapClient.swift:12-106`). `FakeImapClient`'s actor body is at 248 of SwiftLint's 250 lines (`CabalmailKitTestSupport/FakeImapClient.swift:9-354`).

**iPad scenes.** On iPad, closing a window needs another scene activated first. `dismissWindow()` cannot dismiss an app's last scene on iOS (#1688, closed), and `MainMailScene.activate` knows only main windows' sessions (`Compose/Windows/MainSceneActivation.swift:56-73`). macOS and visionOS bring a sibling forward on their own (:140-146). The file holds a `UIViewRepresentable`, so the platform ratchet exempts it.

**External events.** Which window receives a link is partly up to the system, and the repo's two comments disagree. `CabalmailMacApp.swift:71-79` says a `mailto:` still reaches the main window's handler; `ComposeWindowScene.swift:157-162` says the system spawns a compose window for it. multi-window-and-restore.md plans to correct one of them. The iOS main group declares no `handlesExternalEvents`, and both `mailto:` and Spotlight are handled in `Shell/AppRootLifecycle.swift:52-67`. On the Mac, `MainMailWindow.bringToFront` matches windows whose id is `main` or starts `main-` (`CabalmailMac/MainMailWindow.swift:21-31`).

**Scans and lint.** One scan needs an edit; the rest must stay green untouched.
- `SceneAppearanceSourceScanTests` asserts the exact scene inventory (:61-71).
- These read files this plan edits: `SwipeActionContainerSourceScanTests` (`+Selection.swift`), `CompactBrandMarkSourceScanTests` (`MessageDetailView.swift`), `ComposeWindowOrphanSourceScanTests` (`MainSceneActivation.swift`), and the whole-tree walkers that read every new file and probe both app entries (`ColorTokenSourceScanTests`, `ConfirmationDialogRoleTests`, `MenuPickerSourceScanTests`; Wave 3.3's full list of whole-tree walkers also has `SceneAppearanceSourceScanTests`, `AddressMenuTitlePolicyTests`, `CompactBrandMarkSourceScanTests`' `testOnlyTheSharedModifierBuildsTheToolbarItem` and `SwipeActionContainerSourceScanTests`' `rowCallSites`; the same 3.3 scan list has `ReaderColumnFloorSourceScanTests` reading `Shell/SignedInRootView.swift`, which PR 4 edits, for `measuredWidth: measuredWidth`).
- No new platform `#if` outside `Shell/` and `Platform/` (`scripts/check-platform-conditionals.py`). `file_length` warns at 500 lines, comment-only lines ignored (`apple/.swiftlint.yml:47-50`): `MessageListView+Rows.swift` counts about 425 (`rowContextMenu` at :199), and `ApiBackedImapClient.swift` about 340.

**Related open issues (2026-10-12), none naming a message window:** #2035 and #2036 (iPad window in front, iPad window titles), #2039, #2041 and #2042 (Mac multi-window), #1680 (Duo compose window), #1995 (visionOS Mail tab Message menu; open, fix merged on stage in c1d88c23), #2024, #2026 and #2027 (iPad menu commands).

## The plan

Five PRs to `stage`, one open at a time, each green before the next is pushed. Rules the PRs follow without asking: a failed lookup, a server error or being offline never marks a message removed; a window closes at once after its own archive, delete or move, and a refusal puts the row back in the list with the toast in the window in front; a window offers no "and go to next" choices.

**PR 1. Kit: envelopes by UID.** Can go any time; it touches only the Kit.
- Scope: `ImapClient.envelopes(folder:uids:)` with a default that throws (the fake inherits it), and the API-backed version over `api.listEnvelopes(host:folder:ids:)` and `makeEnvelope`. It keeps only envelopes whose UID was asked for, a client-side guard for #1990's second hazard, and passes errors up rather than returning an empty list.
- Files: `IMAP/ImapClient.swift`, `IMAP/ApiBackedImapClient.swift`.
- Tests: Kit tests through the HTTP transport double: present, absent, an extra UID in the reply dropped, a 502 thrown.
- Verify: `swift test` in CI on macOS and iOS. Risk: low. `no-changelog`.

**Status:** Not started (2026-10-15).

**PR 2. Menus and the removal notice.** After mail-correctness.md's PR 2 and ipad-layout-and-keyboard.md's command PRs.
- A second `WindowCommands` initializer for a window with no navigator, whose front is always the window. Main windows keep `init(navigator:)`, so `SignedInRootView.swift:73` and the tests do not change.
- A separate focused value for a message window's commands. The Message menu acts on the main window's commands, else the message window's. Every other menu reads only the main window's, so with a message window in front Settings, Mailbox and Feeds dim exactly as they do for a compose window (the #985 and #1162 rule: no advertised command that does nothing).
- One new mail event, `.vanished(refs)`, posted where mail-correctness.md's PR 2 queues its reaction for rows a refresh proved gone. Lists ignore it, so main windows do not change.
- Files: `Commands/WindowCommands.swift`, `Commands/MessageMenuCommands.swift`, `Mail/Store/MailEvents.swift`, `Mail/MessageList/MessageListViewModel.swift`.
- Tests: the menu's target rule; main-window menus unchanged; a list hearing `.vanished` changes nothing. `MailEventSelectionPolicyTests` and `MailEventSearchSurfaceTests` green unchanged.
- Verify: CI app-layer and iOS-hosted suites. Risk: low. `no-changelog`.

**Status:** Not started (2026-10-15).

**PR 3. Reader seams.** When no duo-support.md, platform-conditionals.md, shared-load-error-state.md B3 or mail-navigation-refactors.md PR is open in the reader files.
- One environment value, `ReaderHost`: `.pane` by default, `.window(id:)` in a message window. Main-window behaviour is unchanged everywhere it is read.
- In a window only: the reader answers Mark as Read, Flag and Move itself (in a main window the list does, and both answering would act twice); compose opens a compose window directly with this window as its origin; scroll is saved locally with `savePosition(for:)`; the seen and dispose menus offer no "and go to next" and post no `.readAdvance`; after its own archive, delete or move it asks the window to close.
- A removed state, set only under `.window`: by `.removed` or `.vanished` naming its message, cleared by `.restored`. The body shows Decision 4's note. Main-window readers ignore it, because #2037 there is mail-correctness.md's call.
- Files: `MessageDetailView.swift`, `+Compose`, `+Scroll`, `+SeenOptions`, `+DisposeOptions` (or `ReaderOptionMenuPolicy.swift`), `MessageDetailViewModel+Flags.swift`, `Compose/Windows/ComposeCoordinator.swift`. No new `#if`; if a type nears its body cap, extract a type that owns the host behaviour.
- Tests (Mac host): a main-window reader does not answer Mark as Read; the removed state for its own message, another message, a restore, and in a main window; no advance rows in a window; compose names the window as origin.
- Verify: CI. Risk: medium (the most-tuned view in the app; the edits are small and gated on the host). `no-changelog`.

**Status:** Not started (2026-10-15).

**PR 4. The message window.** After mail-correctness.md's PR 1 is deployed to stage and multi-window-and-restore.md's R3 and W1 have merged.
- `MessageWindowValue`: the account, folder, UID and Message-ID under its own coding keys, converted to a `MessageRef` at the boundary as `AppRoute.Mail` does, and equal on account, folder and UID.
- `MessageWindowScene` at `CabalmailUI/Mail/Windows/MessageWindowScene.swift`: `WindowGroup("Message", id: "message", for: MessageWindowValue.self)`, the Theme pinned, `.handlesExternalEvents(matching: [])`, and the session restore that compose runs. No `#if`: the Mac's default size goes where `CabalmailMacApp.swift` installs the scene, as platform-conditionals.md's FU-2 part B does for compose. Installed in both app entries.
- The resolver takes its lookup as a closure, so its tests need no change to `FakeImapClient`. Order: the envelope the opener handed over (held in memory by message, on `MailSessionStore`, inferred home), the envelope cache snapshot, then PR 1's lookup. A lookup that succeeds without the UID, or finds another Message-ID at it, means removed. An error or no network shows the reader's error pane with Retry. Wrong account or signed out: a sign-in placeholder worded like compose's, and the window closes when the account is forgotten (`AppState.accountForgottenTick`).
- It hosts the reader in a `NavigationStack` under `ReaderHost.window`, with its own `WindowCommands` reporting one open message, and publishes a layout resolved from its own size, as `SignedInRootView.swift:175-186` does (inferred to give the same bar as a main window of that size; checked by screenshots).
- Title: the Mac's title bar shows the subject, as the reader already sets there; on iPad the Window menu and app switcher get the subject by W1's mechanism, and the reader's inline title stays empty.
- Toasts: the banner stack in `SignedInRootView.swift:189-216` moves into a shared view that both windows draw. In a message window the resume offer's button goes to the main window last used.
- Links: the window forwards any `mailto:` or Spotlight result it receives to the handlers in `AppRootLifecycle.swift`, naming no window, so it opens in a main window.
- iPad: closing activates a main window first (`MainMailScene.activate`, as compose does), using FU-2 part B's no-op on other platforms or adding it in the exempt file. The message scene records its session under its own kind, so a compose opened from it returns to it, while notification routing and R3's "window in front" skip it.
- On coming to the front, the window re-checks its message with PR 1's lookup, at most once a minute (inferred interval). This catches removals no list saw, and refreshes flags changed on another device.
- Entry point: "Open in New Window" in `rowContextMenu` (`MessageListView+Rows.swift:199`, used at :91 and `+Selection.swift:322`), not in Drafts, shown by a pure `MessageWindowPolicy`: always on the Mac and visionOS, on iOS only on the iPad idiom. An open Duo reports the phone idiom (inferred, medium confidence), so it gets nothing until duo-support.md's Session 2 adds its fold input.
- The scan row, per Decision 7.
- Tests: the value's coding and equality; the account check; resolver order and the removed and error cases; the policy for iPhone, iPad, Mac and visionOS; events name the window, and main windows let go without advancing.
- Verify on the Mini, with the signed Mac build and the iPad simulator (iOS 26 and 27, regular and compact width):
  - open from a folder and from search; Reply from the toolbar and from the menu with the window in front, then the main window's Reply acts on its own message;
  - flag in the window and watch the list row; archive in the window closes it and the row goes; move the message from another client, then bring the window forward;
  - relaunch, also offline; sign out with one open; a `mailto:` and a notification tap with a message window in front open in a main window; iPad titles and the return to the main window on close.
  - Use the iPadOS menu bar with the pointer for commands (#1929). visionOS simulator: open, Reply, one Message menu item, close. Screenshot the reader's bar in the window on each. Coordinate test account 1's sign-ins.
- Risk: medium. `Apple:` fragment.

**Status:** Not started (2026-10-15).

**PR 5. Command-O, double-click and docs.** After ipad-layout-and-keyboard.md's PR C, never open beside it.
- Message > Open in New Window with Command-O, enabled with one open message or one selected row in a main window. No code in the app declares Command-O today; the scope doc checks the iPadOS system menus.
- Mac double-click (Decision 6): read the click's count in the row's select path through a `Platform/` adapter (inferred to work), not a new gesture.
- A "Message windows" section in `docs/apple.md` beside "Compose scene" (:1409).
- Verify: Mini Mac build (double-click, Command-O, a single click still selects at once), iPad menu bar, visionOS Message menu. Risk: low to medium. `Apple:` fragment.

**Status:** Not started (2026-10-15).

**PR 6, later. Feed items.** After flags-and-cross-media.md's B5.1 lands its two-case item identity: widen `MessageWindowValue` with a decoder that still reads the mail-only shape, and host the feed reader. At the end of this session if B5.1 is in, else a short follow-up session. `Apple:` fragment.

**Status:** Not started (2026-10-15).

**Release.** PRs 1 to 5 ship as one release, its only structural change, soaked on the Mini. The maintainer's TestFlight checks on the Mac and an iPad hold Promote, not merge: about five lines from PR 4's list. Rolling back needs no migration; a revert leaves system-saved windows for a group that no longer exists, which the system is expected to drop (inferred).

**Hotspots.** One open PR per file at a time.

| File | Here | Also edited by |
|---|---|---|
| `Mail/Reader/MessageDetailView*.swift`, `MessageDetailViewModel*.swift` | PR 3 | duo-support.md (PR 6; optional Session 3), platform-conditionals.md (FU-1, FU-2 B), shared-load-error-state.md (B3), mail-correctness.md, mail-navigation-refactors.md |
| `Commands/WindowCommands.swift`, `MessageMenuCommands.swift` | PR 2, PR 5 | ipad-layout-and-keyboard.md (owns `MessageMenuCommands.swift` while it runs), multi-window-and-restore.md |
| `Mail/Store/MailEvents.swift`, `MessageListViewModel.swift` | PR 2 | mail-correctness.md, refresh-scheduling.md, shared-load-error-state.md (B4), sqlite-mail-store.md |
| `MessageListView+Rows.swift`, `+Selection.swift` | PR 4, PR 5 | ipad-layout-and-keyboard.md (owns `+Selection` while it runs), duo-support.md (PR 8), platform-conditionals.md, mail-correctness.md |
| `Shell/SignedInRootView.swift` | PR 4 (banners) | duo-support.md, multi-window-and-restore.md |
| `Compose/Windows/MainSceneActivation.swift`, `ComposeCoordinator.swift` | PR 3, PR 4 | multi-window-and-restore.md (R3), platform-conditionals.md (FU-2 B) |
| `Cabalmail/CabalmailApp.swift`, `CabalmailMac/CabalmailMacApp.swift` | PR 4 | ipad-layout-and-keyboard.md (owns `CabalmailApp.swift` while it runs), multi-window-and-restore.md (W2), platform-conditionals.md (FU-2 B) |
| `IMAP/ImapClient.swift`, `ApiBackedImapClient.swift` | PR 1 | sqlite-mail-store.md, kit-split.md |
| `CabalmailTests/SceneAppearanceSourceScanTests.swift` | PR 4 | none known |

**When to start.** After mail-correctness.md and ipad-layout-and-keyboard.md have merged and multi-window-and-restore.md's session 1 is done, with no open PR from the plans above in the reader files. PR 4 also waits for that plan's W1 (its session 2). The simplest slot is straight after multi-window-and-restore.md's session 2, which edits the same window and activation files. PR 1 can go earlier if a slot is free.

## How to start it

**Opening brief (paste into a new session):**

> Build message windows for the Cabalmail Apple clients, at the current `stage`. Read the plan (`docs/1.x/post-wave-3/detached-reader-window.md`) and the working agreements (`docs/1.x/post-wave-3/00-working-agreements.md`) first. Check the start gates in "When to start": mail-correctness.md's PRs 1 and 2 and multi-window-and-restore.md's R3 merged, W1 merged before PR 4, and no other plan with an open PR in the reader files. Re-check every file:line in the plan. Then write a short scope doc with the plan's seven decisions at the top, quoted in full, and post it; do not edit `SceneAppearanceSourceScanTests` before the maintainer answers decision 7. Build what the maintainer's answers to decisions 2 and 3 say, with `ComposeWindowScene.swift` as the precedent. Open PRs 1 to 5 in order, one at a time. No spanned shell and no Duo API. Before driving the Mini's GUI, check that the maintainer's tester is not using it, and coordinate sign-ins on test account 1.

**Read or point at:** this plan and `00-working-agreements.md` (both in `docs/1.x/post-wave-3/`); what the plan uses from the rearchitecture's shell audit (gaps 9 and 10, WS8) and the 2.1, 3.1 and 3.3 scope docs is stated in "Decisions for the maintainer", "Why", "Where things stand" and "Scans and lint" above; issues #2037, #1990 and #1680 and the PRs that fixed the first two; mail-correctness.md (Decision 1, PRs 1 and 2); duo-support.md ("Not in this plan" and Session 2).

**Rigs:** CI; the Mac mini (signed macOS build, iPad, iPhone and visionOS simulators). The Studio is not needed: the Duo checks belong to duo-support.md's Session 2.

## Risks and checks

1. **Acting twice in main windows.** If the reader answered Mark as Read or Flag in a main window, the list would too. Check: PR 3's regression test and the host gate.
2. **A main window's behaviour changing.** Check: every new path is gated on `ReaderHost.window` or the message window's own commands; the existing app-layer suites stay green unchanged.
3. **Links landing in a message window.** A `mailto:`, a Spotlight result or a notification could reach the new group (inferred). Check: the empty external-events set, the window's forwarding to the shared handlers, and PR 4's link checks on Mac and iPad, before and after the new group.
4. **Another account's message after a restore.** Check: the account test, and a sign-out and sign-in as test account 2 with a window open.
5. **A stale message with live buttons (#2037's class).** Check: the removal tests, the re-check, and PR 4's move from another client.
6. **An error read as "removed".** #1990 makes lookups fail under concurrent flag changes. Check: PR 1's 502 test and PR 4's error case; PR 4 waits for mail-correctness.md's PR 1 on stage.
7. **Double-click slowing selection on the Mac.** Check: Decision 6's condition, timed by hand in PR 5.
8. **The window value is saved by the system.** A later change of shape could drop windows open at the upgrade (inferred). Check: own coding keys now; PR 6's decoder still reads the mail-only shape.
9. **Scans, lint and the ratchet.** Check: the scans named in "Scans and lint" green with anchors unchanged; no new `#if` outside `Shell/` and `Platform/`; `+Rows.swift` has about 75 lines of room, so extract a type rather than add a `+Foo` file.
10. **visionOS is build-only on PRs.** Check: the Mini simulator runs in PRs 4 and 5.
11. **CI pacing.** Six to eight macOS jobs per Apple PR. Check: one open PR from this session; push only to fix.
12. **Duo placement.** A second window on the inner display may take the whole display, as compose does (#1680). Check: no iPhone gets the entry point until duo-support.md's Session 2.

## Not in this plan

- **Turning it on for the open Duo:** duo-support.md's Session 2 lists it ("turning on detached-reader-window.md's open-Duo entry point if it has landed and #1680's finding allows"). That change adds the fold input to `MessageWindowPolicy` and must check a fold and an unfold with a message window open, since a folded Duo runs one scene.
- **A spanned list|reader shell:** dropped on evidence (see Decisions).
- **#2037 in main windows:** mail-correctness.md. This plan adds the `.vanished` notice beside its fix and the window's own re-check.
- **#1990:** mail-correctness.md's PR 1.
- **Mac File > New Window, #2035, #2036, #2039, #2041, #2042 and the Mac `mailto:` comments:** multi-window-and-restore.md.
- **iPad menu-command bugs (#2024, #2026, #2027):** ipad-layout-and-keyboard.md's PR C.
- **One shared load and error type for the window's states:** shared-load-error-state.md. This plan uses the reader's existing error pane and can adopt `LoadState` later.
- **Resolving the message from a local store:** sqlite-mail-store.md's PR 3.5 replaces the cache step.
- **Opening notifications or Spotlight results in a message window:** not proposed; they keep opening in a main window.
- **Freeing room in `FakeImapClient`:** mail-navigation-refactors.md's PR 6; not needed here, since the resolver takes a closure.
- **A foldable CI leg:** duo-support.md.

## Sources

- `00-working-agreements.md` in this folder.
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Sibling plans in this folder: duo-support.md (Unblocks, Session 2, PR 6, hotspots, "Not in this plan"); flags-and-cross-media.md (B5.1, hand-off to this plan); sqlite-mail-store.md (PR 3.5); mail-correctness.md (Decision 1, PRs 1 and 2), multi-window-and-restore.md (R3, W1), ipad-layout-and-keyboard.md (PR C), platform-conditionals.md (FU-1, FU-2 B, hotspots), shared-load-error-state.md (B3), mail-navigation-refactors.md (PR 6), test-debt.md (B2), account-isolation.md (touches no scene code).
- App entries: `apple/Cabalmail/CabalmailApp.swift:49-108`; `apple/CabalmailMac/CabalmailMacApp.swift:8, 51-108`; `CabalmailMac/CabalmailCommands.swift:94-97`; `CabalmailMac/MainMailWindow.swift:21-31`; `CabalmailWatch/CabalmailWatchApp.swift:15`; `apple/project.yml:136`.
- Scenes, windows and links (under `apple/CabalmailUI/`): `Compose/Windows/ComposeWindowScene.swift:39-44, 98-121, 157-215`; `Compose/Windows/ComposeCoordinator.swift:82-86, 163-166`; `Compose/Windows/MainSceneActivation.swift:56-73, 132-146`; `Shell/AppRootLifecycle.swift:52-67`; `Shell/SignedInRootView.swift:73, 119, 175-216`; `Shell/ShellLayout.swift:73-75, 93`.
- Identity and navigation: `CabalmailKit/Models/MessageRef.swift:23-26, 61-70`; `Navigation/AppRoute.swift:16-69`; `Navigation/StoredRoute.swift:16-57`; `Navigation/NavStateCoordinator.swift:348`.
- Commands: `Commands/WindowCommands.swift:89-136`; `Commands/MessageMenuCommands.swift:26-58`; `Commands/MessageMenuAvailability.swift:60-77`; `Commands/FeedsMenuCommands.swift:24-59`.
- Reader and lists: `Mail/Reader/MessageDetailView.swift:17-23, 98-112, 185-190, 232-272, 363-369`; `+Compose.swift:83-85`; `+Scroll.swift:120-126`; `+SeenOptions.swift:60-78`; `MessageDetailViewModel.swift:231-260`; `MessageDetailViewModel+Flags.swift:94-97`; `Mail/Store/MailEvents.swift:18-47, 74-87`; `Mail/MessageList/MailEventSelectionPolicy.swift:39-48`; `WindowRefresher.swift:247-289`; `MessageListView.swift:540-555`; `MessageListView+Rows.swift:91, 199`; `MessageListView+Selection.swift:300-324`; `SwipeActionRow.swift:249-268`.
- Kit and server: `CabalmailKit/IMAP/ImapClient.swift:12-106`; `IMAP/ApiBackedImapClient.swift:259, 417-461`; `CabalmailKit/Tests/CabalmailKitTestSupport/FakeImapClient.swift:9-354`; `lambda/api/list_envelopes/function.py:20-35`; `lambda/api/_shared/helper.py:179-187, 1218-1250`.
- Lint and scans: `apple/.swiftlint.yml:47-50`; `scripts/check-platform-conditionals.py`; `apple/platform-conditionals-allowlist.txt`; `apple/CabalmailTests/SceneAppearanceSourceScanTests.swift:30-35, 61-71, 153`; `SwipeActionContainerSourceScanTests.swift:30`; `CompactBrandMarkSourceScanTests.swift:32`; `ComposeWindowOrphanSourceScanTests.swift:13`; `ConfirmationDialogRoleTests.swift:87-89`; `ColorTokenSourceScanTests.swift:32-34`; `MenuPickerSourceScanTests.swift:27`; `docs/apple.md:1409`.
- GitHub, read 2026-10-12. Open: #2037, #1990, #1680, #1995, #2024, #2026, #2027, #2035, #2036, #2039, #2041, #2042, #1929. Closed: #716, #984, #1162, #1688, #1987. PRs #2005 and #2009 merged to stage 2026-10-10. Git: c1d88c23 (3.2 D, the #1995 fix).
