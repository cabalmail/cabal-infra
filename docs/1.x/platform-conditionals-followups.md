# Platform-conditional follow-up catalogue (FU-1 to FU-19): the grandfathered `#if`s

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of `5a70043`, the commit named under "Written", and have drifted since: match blocks by their condition text, not by line number.

**Written:** 2026-10-09 against stage `5a70043` ("Set release date for version 1.30.0"), before Workstream 3.2 landed. 3.2 has since merged in full; its PR G (#2012, `a67f942`) added the lint and seeded `apple/platform-conditionals-allowlist.txt`. The line numbers below have drifted (for example, FU-17's `RulesView.swift:129` is :139 at `50e6022`), so match blocks by condition text after re-running `python3 scripts/check-platform-conditionals.py`. At `50e6022` it printed "55 files, 141 blocks, all within the allowlist": one block fewer than the 142 counted below, because #2017 removed FU-17's `RulesView.swift:101`.

Sources: every `#if` line in `apple/CabalmailUI/`, `apple/Cabalmail/` and `apple/CabalmailMac/` at stage `5a70043` ("Set release date for version 1.30.0"), read block by block. A second reader tried to refute each block's disposition, a critic reviewed the plan for gaps, and the corrections are folded in. The source scans named below were read at the same commit. Nothing was compiled: these containers have no Swift toolchain. *(inf)* marks an inference. Paths are relative to `apple/`.

**Why this exists.** Scoping Workstream 3.2 (layout shells) raised the question of how far 3.2 takes "`#if` only in shells and adapters". The maintainer answered on 2026-10-09: "Ratchet, but let's document the rest for follow-up work." So 3.2 converts the layout `#if`s and the one-line modifier gates and adds a check that refuses new ones. This doc catalogues the 143 blocks 3.2 leaves behind, groups them into follow-up workstreams FU-1 to FU-19, and gives the ratchet's exact rule and its seed list.

**Nothing here needs an answer now.** Several FUs need the maintainer to approve a scan change before they start (the "Scan approval needed" column). Those questions come up when an FU is scheduled; none blocks 3.2.

**Names.** A block is one `#if` line, written `File.swift:line`. 3.2-A, 3.2-B, 3.2-F and 3.2-G are Workstream 3.2's PRs A, B, F and G: A added the `ShellLayout` signal and `\.shellLayout` (`dd7ebb2`), B pointed the list's `isWideLayout` at it (issue #1985, `2dc88ea`), F removed the remaining layout `#if`s outside `Shell/` and added `HostPlatform.alwaysWindows` (`b2c81f2`), and G added the one-line `Platform/` adapters and the ratchet (#2012, `a67f942`). "3.2-shell" is a block that PRs C to E absorb into a shell, and "the 3.2 shell PRs" are C (shared columns, `b166698`), D (`TabShell` and `OrnamentShell`, `c1d88c2`) and E (`DesktopShell` and `SplitShell`, `ede7b26`). "The lint" is the ratchet check 3.2-G adds, a stdlib Python script that runs beside SwiftLint (it isn't a SwiftLint rule because SwiftLint custom rules take only include and exclude path lists, so they could refuse a new file but not a growing count; a Python check also runs in the cloud containers, which have no Swift toolchain).

**What the follow-ups need from 3.2:**
- FU-12: the shell selector keeps calling `SectionLayoutPolicy.layout`, and `TabShell` keeps the compact size-class pin around its whole tab tree. FU-12 relies on tabs meaning compact and split meaning regular.
- FU-14: `TabShell` keeps setting `.environment(\.showsCompactBrandMark, true)`; the brand-mark modifier keeps reading that flag rather than `shellLayout`.
- FU-13: 3.2-F deletes `TitleSwitchMenu.swift:40`.
- FU-2 (`MessageDetailView.swift:177`) and FU-14 build on 3.2-G's inline-title adapter; FU-15 builds on its `formStyle` adapters.
- The seed list assumes 3.2-A, B, F and the shell PRs land before 3.2-G.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it. Block counts are the lint's at `50e6022` (141 in all).

| Work item | Status |
|---|---|
| FU-1: Dead and redundant gates | Not started (2026-10-15). 18 blocks. |
| FU-2: Small Platform/ adapters | Not started (2026-10-15). 15 blocks. |
| FU-3: Contacts and calendar sheets | Not started (2026-10-15). 7 blocks. |
| FU-4: Private-window link handoff | Not started (2026-10-15). 5 blocks, plus `HTMLBodyView.swift:173` in an exempt wrapper file. |
| FU-5: Compose window close gate | Not started (2026-10-15). 9 blocks. |
| FU-6: Photo-library attach capability | Not started (2026-10-15). 7 blocks. |
| FU-7: Push scope on visionOS | Not started (2026-10-15). 6 blocks. |
| FU-8: Mac residency settings | Not started (2026-10-15). 8 blocks. |
| FU-9: List selection input | Not started (2026-10-15). 5 blocks. |
| FU-10: Sign-in chrome | Not started (2026-10-15). 6 blocks. |
| FU-11: List primary-toolbar twins | Not started (2026-10-15). 2 blocks. |
| FU-12: Reader action bar on ShellLayout | Not started (2026-10-15). 15 blocks. |
| FU-13: Title-switch host | Not started (2026-10-15). 5 blocks. |
| FU-14: Compact brand-mark title | Not started (2026-10-15). 6 blocks. |
| FU-15: Sheet chrome | Not started (2026-10-15). 12 blocks: 6 in the four simple sheets and `MacSheetForm.swift`, 6 in `SearchFiltersSheet` and `NewAddressSheet`. |
| FU-16: One compose body | Not started (2026-10-15). 6 blocks. |
| FU-17: Rules list on macOS | Parked until Rules is next touched (2026-10-15). 1 block; its other block (:101, the Mac's inline Add row) went with #2017. |
| FU-18: Trackpad swipe bridge | Not started (2026-10-15). 6 blocks (5 in part 1). |
| FU-19: ToolbarVisibility adapter | Waits on dropping Xcode 26 (2026-10-15). 2 blocks. |

## Totals

Every `#if` block in `apple/CabalmailUI/` and the two app targets at stage `5a70043` comes to 287 blocks in 102 files.

| Disposition | Blocks |
|---|---|
| follow-up (grandfathered by the ratchet) | 143 |
| 3.2-G (one-line modifier adapters) | 45 |
| 3.2-shell (moves into a shell) | 29 |
| allowed-representable | 18 |
| allowed-platform | 14 |
| allowed-app-target | 11 |
| allowed-shell | 10 |
| 3.2-A (layout signal) | 6 |
| 3.2-F (which-layout reads, alwaysWindows) | 5 |
| not-platform | 5 |
| 3.2-B (isWideLayout) | 1 |
| **Total** | **287** |

By class, across all 287 blocks: a 109, b-leaf 89, b-scope 42, b-shell 42, n/a 5.

The ratchet's lint counts 142 of the 143 follow-up blocks, spread over 55 files. The remaining one is HTMLBodyView.swift:173. That file declares representables, so the lint exempts it (see "Initial allowlist"). FU-4 still removes the block.

| Follow-up kind | Blocks |
|---|---|
| os-api-adapter | 33 |
| product-scope | 27 |
| reader-bar | 21 |
| leaf-modifier | 19 |
| sheet-chrome | 11 |
| mac-toolbar | 11 |
| trackpad-swipe | 6 |
| compose-bodies | 6 |
| signin-chrome | 6 |
| other | 3 |
| **Total** | **143 (56 files; the allowlist holds 142 in 55)** |

## Follow-up workstreams

### Ground rules for every FU

- A gate goes away in one of three ways:
  - A Platform/ adapter that does nothing off its own platform.
  - A HostPlatform capability read in a runtime `if`.
  - A move into a file the ratchet already allows: a representable file, the app targets, Shell/ or Platform/.
- HostPlatform is also compiled into the watch app. Capabilities on it must therefore be plain `Bool` or enum computed properties: a `switch self`, no `#if`, no SwiftUI types. Anything that returns a SwiftUI type is either a Platform/ adapter or a policy type that takes a `HostPlatform`.
- A policy keyed on HostPlatform (the `ConfirmationDialogPolicy` pattern) can be unit-tested for every platform from the Mac test host. `#if` code cannot. That is the main benefit beyond the ratchet itself.
- Verification:
  - The cloud containers have no Swift toolchain, so the PR run of `apple.yml` is the only build check.
  - On a PR, visionOS is build-only. Any FU that touches visionOS behaviour needs a simulator check by hand.
- Changelog: unless an FU says otherwise, the user sees no change and its PRs take the `no-changelog` label for `apple-changelog.yml`. An FU that changes behaviour needs an `Apple:` fragment.
- Source scans: a scan's expected text or anchor is never edited just to make it pass. "The maintainer's approval" below means the route either changes what a pinned scan checks, or needs the scan turned into a behaviour test.

### Summary

| FU | Workstream | Blocks | Size | Scan approval needed | Worth doing |
|---|---|---|---|---|---|
| FU-1 | Dead and redundant gates | 18 | S | No | Yes |
| FU-2 | Small Platform/ adapters | 15 | M | No | Yes |
| FU-3 | Contacts and calendar sheets | 7 | M | No | Yes |
| FU-4 | Private-window link handoff | 6 (5 lint-counted) | S | No | Yes |
| FU-5 | Compose window close gate | 9 | S | No | Yes |
| FU-6 | Photo-library attach capability | 7 | S | No | Yes |
| FU-7 | Push scope on visionOS | 6 | M | No | Yes, moderate |
| FU-8 | Mac residency settings | 8 | S | No | Yes |
| FU-9 | List selection input | 5 | S | No | Yes |
| FU-10 | Sign-in chrome | 6 | S | Only to merge the two cancel buttons | Yes, modest |
| FU-11 | List primary-toolbar twins | 2 | S | Only for a shared toolbar type | Yes, cheap |
| FU-12 | Reader action bar on ShellLayout | 15 | L | No | Yes |
| FU-13 | Title-switch host | 5 | M | Yes | Yes |
| FU-14 | Compact brand-mark title | 6 | M | No, on the recommended route | Yes |
| FU-15 | Sheet chrome | 12 | M (part) / L (all) | Yes | Partly |
| FU-16 | One compose body | 6 | M | Yes, for the last gate | Partly |
| FU-17 | Rules list on macOS | 2 | S | Yes, on one route | Low |
| FU-18 | Trackpad swipe bridge | 6 | S now; deletion deferred | No for the split; :195 stays pinned | Split now; delete later |
| FU-19 | ToolbarVisibility adapter | 2 | S | Yes | No |

### FU-1: Dead and redundant gates

**Status:** Not started (2026-10-15).

**Goal:** Delete gates whose content already compiles everywhere, or that guard an unused or redundant import. No new types.

**For the user:** Nothing.

**Blocks (18):**
- CabalmailUI/Mail/Reader/AttachmentStrip.swift:3 — iOS/visionOS import of UIKit (unused) and QuickLook
- CabalmailUI/Mail/Reader/AttachmentStrip.swift:41 — .quickLookPreview attached on iOS/visionOS only
- CabalmailUI/Mail/Reader/AttachmentStrip.swift:55 — nested canImport(EventKitUI) check, always true wherever it compiles
- CabalmailUI/Mail/Reader/MessageSourceSheet.swift:5 — UIKit/AppKit import fork for the pasteboard
- CabalmailUI/Mail/Reader/MessageSourceSheet.swift:152 — UIPasteboard vs NSPasteboard copy
- CabalmailUI/Compose/Windows/ComposeRequestRouter.swift:3 — redundant import AppKit
- CabalmailUI/Feeds/Reader/FeedItemDetailView.swift:14 — iOS size-class read that never changes the feeds placement
- CabalmailUI/Feeds/Reader/FeedItemDetailView.swift:84 — bodyRunsUnderBottomBar, true in both arms for .feeds
- CabalmailUI/Session/SessionEnvironment.swift:160 — AppIntentsSessionHooks declared on iOS only
- CabalmailUI/Session/SessionEnvironment.swift:119 — sessionDidStart calls the App Intents hook on iOS only
- CabalmailUI/Session/SessionEnvironment.swift:135 — sessionWillEnd calls the App Intents hook on iOS only
- CabalmailUI/Mail/Reader/MessageDetailView+FlagOptions.swift:48 — flagMenuItems overflow rows, iOS only
- CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift:280 — readerModeMenuItem / remoteContentMenuItem overflow twins
- CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift:339 — replyMenuItems overflow rows, iOS only
- CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift:408 — display-toggle rows in the overflow menu
- CabalmailUI/Mail/Reader/MessageDetailView+MacToolbar.swift:13 — the Mac reader's eleven-slot toolbar members
- CabalmailUI/Mail/Reader/EmptyDetailToolbar.swift:1 — whole-file gate on the empty reader's Mac stand-ins
- CabalmailUI/Feeds/Reader/EmptyFeedDetailToolbar.swift:3 — whole-file gate on the empty feed reader's Mac stand-ins

**Approach:**
- AttachmentStrip: delete `import UIKit` and import QuickLook unconditionally. Attach `.quickLookPreview` on every platform. It does nothing on macOS, where `open(_:)` never sets `previewURL`. Delete the nested check at :55.
- MessageSourceSheet: call the existing `copyToPasteboard(_:)` in Platform/Pasteboard.swift and drop the import fork.
- ComposeRequestRouter: delete `import AppKit`, because SwiftUI already re-exports the AppKit symbols this file needs. ContactsPickerAffordance.swift:77-86 shows this. That file imports only `CabalmailKit` and `SwiftUI`, yet it calls `NSWorkspace.shared.open`, and CabalmailKit has no `@_exported import`. `NSApp` stays inside :81's gate, which FU-2 takes.
- FeedItemDetailView: delete the size-class property and return `true`.
  - Today the iOS arm asks `ReaderToolbarPolicy.placement(for: .feeds, ...)`. That call returns `.topBar` at every width and OS, because of `guard medium == .mail, isRegularWidth else { return .topBar }` in Shared/Chrome/ReaderToolbarPolicy.swift.
  - With a literal `true`, the coupling to the policy rests on ReaderToolbarPolicyTests.testTheFeedReaderAlwaysUsesTheSystemTopBar. That test already asserts that `.feeds` maps to `.topBar` for all four width and OS combinations.
  - Name that test in `bodyRunsUnderBottomBar`'s doc comment, and name `bodyRunsUnderBottomBar` in the test's doc comment. This changes prose only; the assertion stays as it is. A policy change that gives feeds a bottom bar then fails that test, and the comment points back here.
- SessionEnvironment: drop the `#if` on `AppIntentsSessionHooks` and call it unconditionally. Its default closures do nothing. CabalmailApp's install stays under its own `#if` in the app target.
- Reader twins:
  - Drop the gates on `flagMenuItems` and `replyMenuItems`. Their call sites already check `actionPlacement == .topBar` at runtime; those call sites are still inside FU-12's gates.
  - Delete the :280 twins and have :408 draw the ungated `readerModeButton` and `remoteContentButton`, which are view-for-view identical. Then drop :408's gate. `ReaderToolbarLayout.macToolbar` has no `.overflow` slot (checked), so `overflowMenuButton` is never drawn on macOS.
- Mac toolbar members and the two `Empty*DetailToolbar` files: drop the gates. Every symbol they use compiles everywhere, including `ReaderToolbarLayout.macToolbar`, and only macOS code instantiates them. If the maintainer prefers desktop-only chrome to stay gated, move the two `Empty*` files into Shell/ beside DesktopShell once the 3.2 shell PRs land.
- The same PR can delete the two `canImport(WebKit)` guards (see "Not platform checks").

**Source scans:** No scan pins these blocks. The doc-comment cross-reference in ReaderToolbarPolicyTests changes no expected text.

**Depends on:** Nothing. If it lands after 3.2-A/B/F and the shell PRs but before 3.2-G, the seeded allowlist starts 5 files and 18 blocks smaller: 50 files and 124 blocks.

**Risk:** Low. PR CI builds macOS, which covers the QuickLook import, and visionOS, which covers the overflow rows.

**Size:** S.

**Worth doing:** Yes. It removes 18 blocks and clears 5 files with no design work.

### FU-2: Small Platform/ adapters

**Status:** Not started (2026-10-15).

**Goal:** Replace leaf modifiers and one-call OS APIs with small adapters and HostPlatform-keyed policies.

**For the user:** Nothing.

**Blocks (15):**
- CabalmailUI/Mail/AvatarView.swift:3 — AppKit/UIKit import fork for the contact photo
- CabalmailUI/Mail/AvatarView.swift:78 — NSImage vs UIImage decode of the Contacts photo
- CabalmailUI/Mail/MoveToFolderSheet.swift:38 — macOS-only minimum sheet frame (360x460)
- CabalmailUI/Compose/Recipients/ContactPickerSheet.swift:44 — macOS-only minimum sheet frame (360x460)
- CabalmailUI/Mail/Reader/MessageSourceSheet.swift:75 — macOS-only minimum sheet frame (560x480)
- CabalmailUI/Mail/MessageList/MessageListView+Rows.swift:65 — visionOS gaze hover highlight on message rows
- CabalmailUI/Shared/Chrome/SidebarTreeRowLabel.swift:60 — visionOS gaze hover highlight on sidebar rows
- CabalmailUI/Addresses/AddressListView.swift:408 — visionOS gaze hover highlight on address rows
- CabalmailUI/Compose/Windows/ComposeRequestRouter.swift:81 — NSApp.activate after opening a compose window
- CabalmailUI/Compose/Recipients/ContactsPickerAffordance.swift:77 — open the Contacts privacy pane (NSWorkspace vs UIApplication)
- CabalmailUI/Compose/Windows/ComposeWindowScene.swift:98 — macOS defaultSize on the compose WindowGroup
- CabalmailUI/Compose/Windows/ComposeWindowScene.swift:172 — iPadOS reactivates the main scene when compose closes
- CabalmailUI/Mail/Reader/MessageDetailView+DisposeOptions.swift:70 — split-button chevron visible on macOS only
- CabalmailUI/Mail/Reader/MessageDetailView+DisposeOptions.swift:82 — destructive tint on the menu face off macOS only
- CabalmailUI/Mail/Reader/MessageDetailView.swift:177 — reader title: subject on macOS, empty inline title elsewhere

**Approach:**
- `Image(platformImageData:)` in Platform/, built over NSImage/UIImage, replaces both AvatarView forks.
- `.macSheetMinimumSize(width:height:)` in Platform/ applies the frame on macOS and is identity elsewhere. It covers three call sites. FU-15 can put its sheet-sizing rule in the same file.
- `.spatialHoverHighlight()` in Platform/ applies `contentShape` plus `hoverEffect(.highlight)` on visionOS and is identity elsewhere. It covers three call sites.
- `AppActivation.bringToFront()` in Platform/ calls `NSApp.activate` on macOS and does nothing elsewhere. It can optionally move to the non-deprecated `activate()`.
- Move the self-contained `ContactsPrivacySettings` enum unchanged into Platform/SystemSettings.swift.
- ComposeWindowScene:98: CabalmailMacApp applies `.defaultSize(width: 720, height: 640)` to the `ComposeWindowScene` it installs (CabalmailMacApp.swift:91). The gate moves into the allowed app target.
- ComposeWindowScene:172: add a no-op `MainMailScene.activate()` to MainSceneActivation.swift's `#else` arm. That file is already allowed because it defines a `UIViewRepresentable`. The call then compiles everywhere.
- DisposeOptions: a `ReaderOptionMenuPolicy` (`indicator(on:)`, `tintsDestructiveFace(on:)`) that takes a HostPlatform. It can sit beside the reader with no `#if`, and it is unit-testable for all platforms.
- MessageDetailView:177: a Platform/ `.readerNavigationTitle(subject)` adapter built on 3.2-G's inline-title adapter. It could ride with 3.2-G if the maintainer accepts the rule "subject in the Mac title bar, empty title on touch".

**Source scans:** None.

**Depends on:**
- 3.2-G, for the Platform/ adapter conventions, and for its inline-title adapter, which :177 uses.
- Otherwise each adapter is independent and can be its own small PR.

**Risk:** Low. Each adapter is identity off its own platform. The visionOS hover needs a simulator check.

**Size:** M (as two or three PRs).

**Worth doing:** Yes. It removes 15 blocks, clears 9 files (together with FU-1), and sets the adapter vocabulary that later FUs reuse.

### FU-3: Contacts and calendar sheets

**Status:** Not started (2026-10-15).

**Goal:** Present the Contacts editor and the calendar-invite sheet through adapters, so the reader and the attachment strip carry no Contacts/EventKitUI gates.

**For the user:** Nothing.

**Blocks (7):**
- CabalmailUI/Mail/Reader/AttachmentStrip.swift:22 — @State calendarInvite only where EventKitUI exists
- CabalmailUI/Mail/Reader/AttachmentStrip.swift:44 — CalendarEventSheet presented only where EventKitUI exists
- CabalmailUI/Mail/Reader/AttachmentStrip.swift:52 — open(_:): NSWorkspace on macOS, invite or QuickLook routing elsewhere
- CabalmailUI/Mail/Reader/MessageDetailView.swift:51 — @State contactEditorRequest, iOS/visionOS only
- CabalmailUI/Mail/Reader/MessageDetailView.swift:210 — ContactEditorView sheet, iOS/visionOS only
- CabalmailUI/Mail/Reader/MessageDetailView+AddressMenu.swift:93 — Add to Contact / New Contact menu items, iOS/visionOS only
- CabalmailUI/Mail/Reader/MessageDetailView+AddressMenu.swift:188 — requestContactEditor, iOS/visionOS only

**Approach:**
- Hoist the pure structs out of their guards:
  - `CalendarInvite` out of CalendarEventSheet.swift's `canImport(EventKitUI)`.
  - `ContactEditorMode` and `ContactEditorRequest` out of ContactEditorView.swift's guard.
  - Both files define representables, so they stay allowed, and the structs stay beside their sheets.
- Add `.calendarInviteSheet(item:)` and `.contactEditorSheet(item:)` modifiers. Each presents the representable where it exists and does nothing on macOS. They can live in those two representable files, which the lint exempts whole. Under a stricter reading of "part of the wrapper", put them in Platform/ instead.
- A Platform/ `AttachmentOpener` replaces :52. On macOS it hands the file to NSWorkspace and reports it handled. Elsewhere it reports it not handled, and the strip's ungated code routes the file to the invite sheet or to QuickLook.
- `HostPlatform.supportsContactEditor` gates the two menu items at runtime. `requestContactEditor` then compiles everywhere.

**Source scans:** None.

**Depends on:** FU-1, because it touches the same file: AttachmentStrip :3, :41 and :55 go first.

**Risk:** Low to medium. Check the Contacts permission flow and the calendar import by hand on iOS and visionOS. macOS is unchanged.

**Size:** M.

**Worth doing:** Yes.

### FU-4: Private-window link handoff

**Status:** Not started (2026-10-15).

**Goal:** Give PrivateLinkHandoff a surface on every platform, so the link menu and both body views stop gating the Mac-only private-window row.

**For the user:** Nothing.

**Blocks (6, of which the lint counts 5):**
- CabalmailUI/Shared/BodyRendering/PrivateLinkHandoff.swift:30 — AppKit and SafariServices imports
- CabalmailUI/Shared/BodyRendering/PrivateLinkHandoff.swift:133 — availability cache, prime, Safari-extension query and NSWorkspace open
- CabalmailUI/Shared/BodyRendering/LinkMenu.swift:87 — offersPrivateWindow, macOS only
- CabalmailUI/Shared/BodyRendering/LinkMenu.swift:119 — Open in Private Window row, macOS only
- CabalmailUI/Shared/BodyRendering/HTMLBodyView.swift:173 — .openPrivate action calls PrivateLinkHandoff.open on macOS. HTMLBodyView.swift is exempt from the lint as a representable file, so this block is tracked here as guidance and the ratchet does not enforce it.
- CabalmailUI/Shared/BodyRendering/PlainTextBodyView.swift:104 — the same action in the plain-text body

**Approach:**
- Split PrivateLinkHandoff.swift:
  - `redirectorURL`, `fragmentForm` and `normalizedControlDomain` stay ungated and need only Foundation.
  - `isAvailable`, `prime()`, `queryAvailability` and `open()` move to a Platform/ extension of `PrivateLinkHandoff` with the same names. Off macOS they return nil or false, or do nothing. CabalmailMacApp's `prime()` call and the link-menu callers still compile.
- LinkMenu then computes `offersPrivateWindow` on every platform; it is false off macOS.
- Both body views call `open` unconditionally. Optionally, they can share one link-menu action handler, so the switch exists in one place.

**Source scans:** None.

**Depends on:** Nothing beyond the 3.2-G conventions.

**Risk:** Low. It is a Mac-only feature, and iOS and visionOS never show the row.

**Size:** S.

**Worth doing:** Yes.

### FU-5: Compose window close gate

**Status:** Not started (2026-10-15).

**Goal:** Split the Mac close interceptor into cross-platform state plus an AppKit hook, so ComposeView's nine close-handling gates compile everywhere.

**For the user:** Nothing.

**Blocks (9):**
- CabalmailUI/Compose/ComposeView.swift:64 — @State closeCoordinator (an AppKit window delegate), macOS only
- CabalmailUI/Compose/ComposeView.swift:103 — binds onCloseAttempt to cancelOrAsk
- CabalmailUI/Compose/ComposeView.swift:124 — background ComposeWindowCloseInterceptor (NSViewRepresentable)
- CabalmailUI/Compose/ComposeView.swift:213 — cancelOrAsk pre-approves the close
- CabalmailUI/Compose/ComposeView.swift:232 — discard pre-approves the close
- CabalmailUI/Compose/ComposeView.swift:254 — save-draft pre-approves the close
- CabalmailUI/Compose/ComposeView.swift:273 — failed save re-arms the intercept
- CabalmailUI/Compose/ComposeView.swift:310 — send pre-approves the close
- CabalmailUI/Compose/ComposeView.swift:317 — failed send re-arms the intercept

**Approach:**
- A cross-platform `ComposeCloseGate`: a `@MainActor` class with `allowsClose` and `onCloseAttempt`, declared outside ComposeWindowCloseCoordinator.swift's `#if`.
- The `NSWindowDelegate` half and `ComposeWindowCloseInterceptor` stay in that file, which is allowed because it defines an `NSViewRepresentable`.
- A `.composeWindowCloseIntercept(gate)` modifier installs the interceptor on macOS and does nothing elsewhere.
- The @State and all seven assignments then compile everywhere and do nothing off macOS.
- Optionally, fold the seven assignments into two helpers named for their intent (`approveClose()`, `rearmClose()`).

**Source scans:** None.

**Depends on:** Nothing.

**Risk:** Low to medium. A regression would silently drop the Mac discard prompt on Cmd+W or the red close button. Check these by hand on macOS:
- Cmd+W with typed text.
- A failed save-draft.
- A failed send.

**Size:** S.

**Worth doing:** Yes. It takes 9 of ComposeView.swift's 17 blocks.

### FU-6: Photo-library attach capability

**Status:** Not started (2026-10-15).

**Goal:** Turn "the Mac composer has no Add Photo" into a HostPlatform capability, so the PhotosUI code compiles everywhere.

**For the user:** Nothing. If the maintainer instead decides the Mac composer should offer Add Photo, the capability and the single-Button arm go away entirely. That change would be user-visible on macOS and would need an `Apple:` fragment.

**Blocks (7):**
- CabalmailUI/Compose/ComposeView.swift:3 — PhotosUI and (redundant) UIKit imports, iOS/visionOS only
- CabalmailUI/Compose/ComposeView.swift:54 — photo picker @State
- CabalmailUI/Compose/ComposeView.swift:144 — .photosPicker plus the onChange ingest
- CabalmailUI/Compose/ComposeView.swift:373 — Attach menu (Photo + File) vs the Mac's single file Button
- CabalmailUI/Compose/ComposeView.swift:403 — ingestPhotoItems
- CabalmailUI/Compose/ComposeView+Subviews.swift:3 — PhotosUI import
- CabalmailUI/Compose/ComposeView+Subviews.swift:85 — photoTypeLabels

**Approach:**
- Add `HostPlatform.offersPhotoLibraryAttach`: true on iOS and visionOS, false on macOS.
- Import PhotosUI unconditionally in both files. `PhotosPicker`, `PhotosPickerItem` and `.photosPicker` exist on macOS 13+, iOS 16+ and visionOS 1+, so the import needs neither a capability nor a `canImport` check.
- Delete the `import UIKit` at :7, and delete the comment at :5-6 in the same change. The comment says "SwiftUI re-exports very little of UIKit", which is wrong for the symbols this file uses. The evidence is in the tree: Compose/Recipients/ContactsPickerAffordance.swift imports only `CabalmailKit` and `SwiftUI`, yet its :77-86 calls `UIApplication.openSettingsURLString` and `UIApplication.shared.open` on iOS, and `NSWorkspace.shared.open` on macOS. CabalmailKit has no `@_exported import`. So `UIResponder.keyboardDidShowNotification` at :475 resolves through SwiftUI. It stays inside :456's gate, because `UIResponder` does not exist on macOS.
- Compile the state, the picker modifier, the ingest and the type-label helper everywhere.
- Choose the Menu or the single Button at runtime. Both keep `compose.attach`.

**Source scans:** None. ComposeBodyScrollPolicyTests' texts are untouched.

**Depends on:** Nothing.

**Risk:** Low.

**Size:** S.

**Worth doing:** Yes.

### FU-7: Push scope on visionOS

**Status:** Not started (2026-10-15).

**Goal:** Express "no push on visionOS" as one capability plus a stub in an allowed folder, instead of six gates.

**For the user:** Nothing. visionOS still has no push and no Notifications settings.

**Blocks (6):**
- CabalmailUI/Settings/NotificationSettingsSection.swift:4 — whole-file gate keeps the Notifications UI out of visionOS
- CabalmailUI/Settings/SettingsView.swift:92 — visionOS filters .notifications out of the category list
- CabalmailUI/Settings/SettingsView.swift:146 — .notifications routes to NotificationsSettingsView on iOS/macOS only
- CabalmailUI/Session/SessionEnvironment.swift:68 — PushMirroringSecureStore on iOS/macOS, bare keychain store on visionOS
- CabalmailUI/Session/SessionEnvironment.swift:113 — PushRegistrar.sessionDidStart on iOS/macOS
- CabalmailUI/Session/SessionEnvironment.swift:129 — PushRegistrar.sessionWillEnd on iOS/macOS

**Approach:**
- Add `HostPlatform.supportsPush` (iOS and macOS).
- In Platform/Services/PushRegistrar.swift, hoist `PushFolderScope` (a `String`, `CaseIterable` enum) and `PushSettings` (UserDefaults only), together with `import Foundation`, above the `#if os(iOS) || os(macOS)` gate. Move them unchanged. Neither uses anything platform-specific. They are moved, not duplicated: one definition then compiles on every platform, so there is no visionOS copy to drift from the real one.
- Stub only PushRegistrar's own registration surface for visionOS, in the gate's `#else` arm, which is allowed in Platform/ and follows the WatchSessionBridge pattern.
  - The stub provides `shared`, `sessionDidStart(appState:client:)`, `sessionWillEnd()`, `enablePush()` (returns false), `disablePush()` and `updateFolderScope(_:chosenFolders:)`, all as no-ops.
  - These are the members that NotificationSettingsSection and SessionEnvironment call. The stub is what lets those calls compile; the capability decides at runtime whether they are reached.
- NotificationSettingsSection.swift then compiles everywhere.
- `SettingsCategory.available` filters `.notifications` on the capability. :92 can go first, on its own.
- The `.notifications` case always routes.
- SessionEnvironment picks `PushMirroringSecureStore` on the capability and calls the PushRegistrar hooks unconditionally. Alternatively, each app target supplies `SessionHooks.live` with the push wiring it owns.

**Source scans:** SectionFooterWrapTests.testEverySectionFooterOptsOutOfTheSingleLineProposal reads NotificationSettingsSection.swift. The footers stay and the scan does not depend on the :4 line, so no approval is needed.

**Depends on:**
- Nothing beyond the 3.2-G conventions.
- FU-8 is independent. Its blocks sit inside :4 and simply stop being nested.

**Risk:** Medium-low. The stub must never register for APNs on visionOS; project.yml already filters the push NSE to iOS. A by-hand check in the visionOS simulator should confirm that Settings shows no Notifications row.

**Size:** M.

**Worth doing:** Yes, but the value is moderate. It turns six scattered gates into one capability. The cost is that the Notifications UI (about 300 lines) is compiled into visionOS as dead code.

### FU-8: Mac residency settings

**Status:** Not started (2026-10-15).

**Goal:** Wrap SMAppService in a Platform/Services adapter and gate the residency rows at runtime.

**For the user:** Nothing.

**Blocks (8):**
- CabalmailUI/Settings/NotificationSettingsSection.swift:8 — ServiceManagement import
- CabalmailUI/Settings/NotificationSettingsSection.swift:12 — menuBarExtraDefaultsKey constant, macOS only
- CabalmailUI/Settings/NotificationSettingsSection.swift:55 — loginItemStatus and showInMenuBar state
- CabalmailUI/Settings/NotificationSettingsSection.swift:91 — Launch at login and Show in menu bar toggles
- CabalmailUI/Settings/NotificationSettingsSection.swift:101 — two-line residency footer on macOS
- CabalmailUI/Settings/NotificationSettingsSection.swift:177 — launchAtLoginBinding (SMAppService register/unregister) and residencyFooterText
- CabalmailUI/Settings/NotificationSettingsSection.swift:212 — denied-permission copy: "System Settings" vs "Settings"
- CabalmailUI/Settings/NotificationSettingsSection.swift:224 — re-reads loginItemStatus after a permission refresh

**Approach:**
- Platform/Services/LoginItem.swift wraps `SMAppService.mainApp`. It has its own status enum, including `.unsupported`, plus register, unregister and refresh. The state, binding and footer copy then compile everywhere.
- `HostPlatform.supportsResidency` (macOS only) gates the two toggles and the two-line footer at runtime. Both footer arms keep `.sectionFooter()`.
- `menuBarExtraDefaultsKey` loses its `#if` and stays public, because CabalmailMacApp reads it.
- `HostPlatform.systemSettingsName` is interpolated into the one denied-permission string.

**Source scans:** SectionFooterWrapTests reads :101's footer. Keeping `.sectionFooter()` keeps it green, so no approval is needed.

**Depends on:** Nothing.

**Risk:** Low. Check Launch at login on macOS by hand.

**Size:** S.

**Worth doing:** Yes.

### FU-9: List selection input

**Status:** Not started (2026-10-15).

**Goal:** Put modifier-click selection behind adapters on both input stacks, and turn the touch Select mode into a capability.

**For the user:** Nothing.

**Blocks (5):**
- CabalmailUI/Mail/MessageList/MessageListView+ModifierClick.swift:1 — ModifierClickGesture (UIKit recognizer for shift/command taps), whole file iOS only
- CabalmailUI/Mail/MessageList/MessageListView+Rows.swift:115 — wideRow attaches ModifierClickGesture on iOS
- CabalmailUI/Mail/MessageList/MessageListView+Selection.swift:3 — AppKit import for NSEvent
- CabalmailUI/Mail/MessageList/MessageListView+Selection.swift:421 — selectRow reads NSEvent.modifierFlags on macOS
- CabalmailUI/Mail/MessageList/MessageListView+Bulk.swift:20 — Select/Done toolbar button absent on macOS

**Approach:**
- Move `ModifierClickGesture` to Platform/ behind `.modifierClickSelection { kind in }`, which installs the UIKit recognizer on iOS and is identity elsewhere. `ModifierClickKind` becomes ungated.
- Add `PointerModifiers.current` in Platform/: `NSEvent.modifierFlags` on macOS, empty elsewhere. `selectRow` then branches at runtime.
- `HostPlatform.hasTouchSelectMode` gates the Select/Done button.
- Alternative for :1 only: widen the lint's representable exemption to `UIGestureRecognizerRepresentable`, which allows the file with no code change. :115 and the selection pair would still need the adapters.

**Source scans:** None.

**Depends on:**
- 3.2-B first, because it touches the same file (MessageListView+Rows.swift:20).
- FU-2 takes Rows:65.

**Risk:** Low to medium. Shift- and command-clicks from an iPad hardware keyboard, and Mac modifier clicks, can only be checked on a device.

**Size:** S.

**Worth doing:** Yes.

### FU-10: Sign-in chrome

**Status:** Not started (2026-10-15).

**Goal:** Move the Mac sign-in chrome and its button rows into Platform/ adapters, so SignInView carries no `#if`.

**For the user:** Nothing.

**Blocks (6):**
- CabalmailUI/Session/SignInView.swift:43 — MacSignInChrome wraps the form on macOS
- CabalmailUI/Session/SignInView.swift:73 — control-domain field title/prompt split on macOS
- CabalmailUI/Session/SignInView.swift:135 — Sign In row: trailing prominent button on macOS, full-width row elsewhere
- CabalmailUI/Session/SignInView.swift:183 — MFA code field title/prompt split on macOS
- CabalmailUI/Session/SignInView.swift:223 — MFA actions: dialog-style row on macOS, stacked rows elsewhere
- CabalmailUI/Session/SignInView.swift:303 — MacSignInChrome declaration, macOS only

**Approach:**
- Move `MacSignInChrome` into Platform/ as `.signInChrome()`: the Mac wrapper on macOS, identity elsewhere.
- A `PlatformFormActionRow` adapter lays out the primary action and an optional back action for each platform.
- A capability such as `HostPlatform.formsShowTitleAsRowLabel` picks the title/prompt split for the two fields.
- Keep both `role: .cancel` buttons written in SignInView.swift, as a runtime two-arm branch, rather than passing one button into the adapter.

**Source scans:** ConfirmationDialogRoleTests.testNoDialogHardcodesTheCancelRole covers :223. Its allowlist entry is `"CabalmailUI/Session/SignInView.swift": 2`.
- Keeping two cancel-role buttons in this file keeps it green.
- Merging them into one, or moving one into Platform/, changes the counted set and needs the maintainer's approval.

**Depends on:** 3.2-G.

**Risk:** Low to medium. This is the first-run screen on every platform. Check it on macOS, iPhone, iPad and visionOS.

**Size:** S.

**Worth doing:** Yes, but the gain is modest.

### FU-11: List primary-toolbar twins

**Status:** Not started (2026-10-15).

**Goal:** Choose at runtime between the Mac's grouped Compose+Reload toolbar and the touch platforms' ranked items.

**For the user:** Nothing.

**Blocks (2):**
- CabalmailUI/Mail/MessageList/MessageListView.swift:362 — Compose + Reload group on macOS, lone Compose elsewhere
- CabalmailUI/Feeds/ItemList/FeedItemListView.swift:73 — grouped New Message + Refresh on macOS, ranked separate items elsewhere

**Approach:**
- Use a runtime `if`/`else` on a capability (for example `groupsPrimaryToolbarActions`, macOS only) inside each toolbar builder. The codebase already uses `if`/`else` inside toolbar content at the iOS 18 / macOS 15 floors:
  - MessageDetailView.swift:294-344: `@ToolbarContentBuilder toolbarContent` branches with `if actionPlacement == .topBar { … } else if …` (iOS and visionOS).
  - SidebarBranding.swift:161: `if #available(iOS 26.0, *) { … } else { … }` around ToolbarItems.
  - TitleSwitchMenu.swift:102: the same shape inside `.toolbar { }` on macOS.
- Keep two separate declarations in MessageListView.swift.
- A shared `ComposeRefreshToolbar` type used by both lists would be tidier, but it moves those declarations out of the file.

**Source scans:** ToolbarVisibilitySourceScanTests.testComposeKeepsItsPlaceInTheListBar counts exactly two `.keepsInBar()` in MessageListView.swift. The in-place runtime branch keeps it green. The shared type needs the maintainer's approval.

**Depends on:** 3.2-A, which touches the same files (MessageListView.swift:55, FeedItemListView.swift:27).

**Risk:** Low.

**Size:** S.

**Worth doing:** Yes, because it is cheap and takes both list views off the allowlist. On its own merits the gain is small.

### FU-12: Reader action bar on ShellLayout

**Status:** Not started (2026-10-15).

**Goal:** Drive where the mail and feed readers put their action bar from ShellLayout instead of the size class plus `#if`, with a desktop placement case.

**For the user:** Nothing. The ShellLayout mapping reproduces today's size-class answer by construction:
- Shell/SectionLayoutPolicy.swift's `layout(isCompactWidth:isCompactHeight:measuredWidth:)` (:91-94) returns `.compactTabs` when the width or height is compact, or the measured width is under the floor. Otherwise it returns `.regularSplit`, so split is only ever chosen when the width is not compact.
- Shell/SignedInRootView.swift (:149-161) pins `.transformEnvironment(\.horizontalSizeClass) { $0 = .compact }` on CompactSectionTabs. So tabs reads compact everywhere in the tab tree, including Slide Over and narrow Stage Manager windows.

Requirement on 3.2: its shell selector keeps calling `SectionLayoutPolicy.layout`, and it keeps the compact size-class pin from SignedInRootView around the whole tab tree, wherever that tree's root ends up.

**Blocks (15):**
- CabalmailUI/Mail/Reader/MessageDetailView.swift:77 — iOS horizontalSizeClass read and readerPaneWidth state
- CabalmailUI/Mail/Reader/MessageDetailView.swift:91 — actionPlacement defined on iOS/visionOS only
- CabalmailUI/Mail/Reader/MessageDetailView.swift:96 — placement from size class plus the iOS 27 probe on iOS; .bottomBar (ornament) on visionOS
- CabalmailUI/Mail/Reader/MessageDetailView.swift:115 — drawsOwnActionBar
- CabalmailUI/Mail/Reader/MessageDetailView.swift:130 — bodyRunsUnderBottomBar
- CabalmailUI/Mail/Reader/MessageDetailView.swift:196 — bottom safeAreaInset that draws readerActionBar
- CabalmailUI/Mail/Reader/MessageDetailView.swift:296 — touch toolbar content (top-bar items or .bottomBar group) vs the Mac toolbar halves
- CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift:35 — ownBarActions sized to readerPaneWidth
- CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift:52 — displayTogglesAreOnBar
- CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift:59 — readerActionBar, the pane-scoped HStack bar
- CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift:387 — reply rows in the overflow menu on the top bar
- CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift:400 — flag rows in the overflow menu on the top bar
- CabalmailUI/Feeds/Reader/FeedReaderToolbar.swift:24 — touch top bar (menuBar) vs wideBar
- CabalmailUI/Feeds/Reader/FeedReaderToolbar.swift:124 — View menu vs More menu
- CabalmailUI/Shared/BodyRendering/ReaderBottomGlass.swift:20 — underBottomGlass ignores the bottom safe area on iOS 26+

**Approach:**
1. Replace :77's size-class read with the ShellLayout environment value (tabs means compact and split means regular, as shown above). This is the same swap 3.2-A makes in MessageListView. Ungate `readerPaneWidth`.
2. Add a `.desktop` case to `ReaderToolbarPolicy.Placement`, and compute `actionPlacement` on every platform:
   - desktop gives `.desktop`.
   - ornament gives `.bottomBar`.
   - tabs gives `.topBar`.
   - split uses the existing iOS 27 probe.

   Deciding the ornament case from ShellLayout before the probe also removes the visionOS trap, where `#available(iOS 27.0, *)` is true through the wildcard.
3. Once `actionPlacement` exists everywhere, ungate the members that the runtime placement checks already govern: `ownBarActions`, `readerActionBar`, `displayTogglesAreOnBar`, `drawsOwnActionBar`, `bodyRunsUnderBottomBar`, the safe-area inset and the two overflow rows.
4. Make :296 switch on `actionPlacement` at runtime. Route the `.bottomBar` placement, which macOS lacks, through a Platform/ placement adapter; macOS never reaches it. Alternatively, split the touch and Mac toolbars into two ToolbarContent types.
5. FeedReaderToolbar picks menuBar or wideBar, and the View or More menu, from a capability (`usesTouchReaderBar`, iOS only), or from ShellLayout being tabs or split, which is the same set.
6. ReaderBottomGlass reads a capability (`hasUIKitBottomBar`). Deleting the `#if` alone would be wrong, because FeedItemDetailView passes `true` on macOS and visionOS and relies on the no-op.

**Source scans:** None.

**Depends on:**
- 3.2-A: ShellLayout in the environment.
- 3.2-B: the same swap in the list.
- The 3.2 shell PRs: each shell publishes its value.
- FU-1: the reader twins are already gone.

**Risk:** Medium-high.
- Where the reader's bar sits is user-visible and has been tuned over several issues *(inf)*: iPad on 26 vs 27, regular vs compact, Stage Manager, and the visionOS ornament.
- `ReaderToolbarPolicy`'s exhaustive switches and its tests need the new case.
- visionOS is build-only on PR CI.

**Size:** L.

**Worth doing:** Yes. It is the largest cluster (21 reader-bar blocks counting FU-1's twins), and its question really is "which layout". Schedule it after 3.2 has settled on devices.

### FU-13: Title-switch host

**Status:** Not started (2026-10-15).

**Goal:** Make the folder and scope switch hosts one ShellLayout-driven enum with a desktop toolbar case.

**For the user:** Nothing.

**Blocks (5):**
- CabalmailUI/Mail/MessageList/MessageListView+FolderSwitch.swift:43 — macOS toolbar stand-in host vs the titleMenu/columnHeader switch
- CabalmailUI/Mail/MessageList/MessageListView+FolderSwitch.swift:109 — folderSwitchMenu, the borderless Mac toolbar menu
- CabalmailUI/Feeds/ItemList/FeedItemListView+ScopeSwitch.swift:33 — the same host fork for the feed scope switch
- CabalmailUI/Feeds/ItemList/FeedItemListView+ScopeSwitch.swift:72 — scopeSwitchMenu, the Mac toolbar menu
- CabalmailUI/Shared/Chrome/TitleSwitchMenu.swift:80 — titleSwitchToolbarHost (navigation-slot ToolbarItem, detached from shared glass)

**Approach:**
- Add a third `FolderSwitchHost` case (toolbar item). 3.2-A's ShellLayout-based `folderSwitchHost` and `scopeSwitchHost` return it for `.desktop`.
- Move `titleSwitchToolbarHost` into Platform/, built on a shared `.detachedFromSharedGlass()` ToolbarContent adapter, because `sharedBackgroundVisibility` is unavailable on visionOS.
- Ungate `folderSwitchMenu` and `scopeSwitchMenu`. Their width callbacks already do nothing off the Mac.
- Both host blocks become three-way runtime switches.
- This needs `TitleSwitchHeaderMenu` to compile on macOS. Its gate (TitleSwitchMenu.swift:40, `#if !os(macOS)`) belongs to 3.2-F and is not a follow-up block. 3.2-F removes it before FU-13 starts.

**Source scans:**
- FolderSwitchPlacementTests.testTheTouchBranchDrawsBothHosts slices the source up to :43's `#endif`, so the maintainer must approve.
- FolderSwitchPlacementTests.testTheHeaderMenuMatchesTheMacsIdentity, FolderSwitchMenuStyleSourceScanTests.testTheMacMenuIsBorderless and .testTheMenuIsFound read :109. Keep `folderSwitchMenu` in this file with its borderless style and identity key.

**Depends on:**
- 3.2-A.
- 3.2-F (TitleSwitchMenu.swift:40).
- The 3.2 shell PRs (DesktopShell).
- `.detachedFromSharedGlass()` is shared with FU-14; whichever lands first adds it.

**Risk:** Medium. Check the folder menu on macOS 26 and 27 (the macOS 27 toolbar quirks of #1601), and on visionOS (the SDK's `sharedBackgroundVisibility` gap).

**Size:** M.

**Worth doing:** Yes. It finishes what 3.2-A starts.

### FU-14: Compact brand-mark title

**Status:** Not started (2026-10-15).

**Goal:** Declare the brand-mark modifiers on every platform, built from Platform/ adapters, so the four tab roots and SidebarBranding drop their gates.

**For the user:** Nothing.

**Blocks (6):**
- CabalmailUI/Shared/Chrome/SidebarBranding.swift:122 — BrandMarkTitle, showsCompactBrandMark and the brandMarkTitle/compactBrandMarkTitle extensions, off macOS only
- CabalmailUI/Shared/Chrome/SidebarBranding.swift:156 — visionOS plain mark item vs the iOS 26+ item detached from glass
- CabalmailUI/Mail/Search/SearchView.swift:64 — Search tab title and brand mark, iOS only
- CabalmailUI/Feeds/Sidebar/FeedSidebarSection.swift:95 — Feeds tab brand mark, off macOS
- CabalmailUI/Addresses/AddressListView.swift:87 — Addresses tab brand mark, off macOS
- CabalmailUI/Settings/SettingsView.swift:43 — Mac sidebar column width vs the Done button and brand mark elsewhere

**Approach:**
- Build `BrandMarkTitle` from Platform/ adapters: 3.2-G's inline-title adapter, a leading-toolbar-placement adapter for `.topBarLeading`, and `.detachedFromSharedGlass()` for :156. Keep the CabalmailMark ToolbarItem inside SidebarBranding.swift, which the scan exempts by name.
- Declare `brandMarkTitle` and `compactBrandMarkTitle` on every platform. On macOS they return the content unchanged. FeedSidebarSection, AddressListView and SettingsView drop their `#if` and keep their exact modifier text.
- SearchView keeps its title literals verbatim, inside a runtime branch:
  - SearchView is reached only from the compact tab tree (Shell/CompactSectionTabs.swift:94, which becomes TabShell) and from visionOS (Shell/VisionSectionView.swift:64, which becomes OrnamentShell). So the condition is "compact tabs on iOS", which is `shellLayout == .tabs`.
  - Replace the `#if os(iOS)` with a `@ViewBuilder` helper that branches on that condition. The true arm still reads `stack.navigationTitle("Search").compactBrandMarkTitle(accessibilityTitle: "Search")`, and the false arm returns `stack` unchanged.
  - visionOS stays untitled.
  - Do not compute the title or pass it indirectly. The scan wants the two literals as written.
- SettingsView's column width goes through a desktop-only Platform/ adapter. `settingsSheetDoneButton` is already ungated by 3.2-F.
- Keep the `showsCompactBrandMark` flag and have TabShell set it. Switching the modifier to a ShellLayout read would change the pinned `.environment(\.showsCompactBrandMark, true)` line, which is the maintainer's call, in the 3.2 shell PR.

**Source scans:**
- CompactBrandMarkSourceScanTests.testEveryTabRootOptsInWithItsOwnTitle requires `.compactBrandMarkTitle(accessibilityTitle: "<title>")` and `.navigationTitle("<title>")` as literals in SearchView.swift, FeedSidebarSection.swift, AddressListView.swift and SettingsView.swift, so it covers SearchView:64, FeedSidebarSection:95, AddressListView:87 and SettingsView:43. For SearchView, both `.navigationTitle("Search")` and `.compactBrandMarkTitle(accessibilityTitle: "Search")` stay verbatim in the `.tabs` arm. The expected text is unchanged at every call site.
- .testOnlyTheSharedModifierBuildsTheToolbarItem covers SidebarBranding :122 and :156. The mark item stays in that file.
- No scan pins the `#if` lines; these scans match text and do not evaluate conditions. This route needs no approval.

**Depends on:**
- 3.2-A (ShellLayout in the environment), 3.2-G and 3.2-F.
- The 3.2 shell PRs (TabShell).
- `.detachedFromSharedGlass()` is added by FU-13 or by this FU, whichever lands first.

**Risk:** Medium. Toolbar placement and glass behave differently on iOS 18, 26 and 27 and on visionOS. Check each one visually.

**Size:** M.

**Worth doing:** Yes.

### FU-15: Sheet chrome

**Status:** Not started (2026-10-15).

**Goal:** Make MacSheetForm a cross-platform adapter (the hand-built layout on macOS, Form elsewhere), so form sheets lose their macContent/formContent forks.

**For the user:** Nothing, provided the adapter carries the row adapters, the uncaptioned section and the `scrolls:` option described under Approach. The Mac arms do more than relabel a Form. Without those pieces, the change would either put rounded-border fields and hidden picker labels into iOS Forms or drop them on the Mac. It would also lose FeedSubscriptionSettingsSheet's Mac scroll view or its iOS Unsubscribe section.

**Blocks (12):**
- CabalmailUI/Shared/Chrome/MacSheetForm.swift:1 — MacSheetForm/MacSheetSection, whole file macOS only
- CabalmailUI/Mail/Folders/NewFolderSheet.swift:59 — content picks macContent or formContent
- CabalmailUI/Mail/Folders/NewFolderSheet.swift:66 — macContent (MacSheetForm) and formContent (Form) bodies
- CabalmailUI/Feeds/Management/FeedFolderSheet.swift:44 — MacSheetForm vs Form body
- CabalmailUI/Feeds/Management/SubscribeFeedSheet.swift:43 — MacSheetForm vs Form body
- CabalmailUI/Feeds/Management/FeedSubscriptionSettingsSheet.swift:51 — scrolling MacSheetForm vs Form body
- CabalmailUI/Mail/Search/SearchFiltersSheet.swift:104 — content picks macContent or formContent
- CabalmailUI/Mail/Search/SearchFiltersSheet.swift:111 — Grid-based Mac filters vs Form filters with a section footer
- CabalmailUI/Addresses/NewAddressSheet.swift:91 — .fitted sizing on macOS, .form elsewhere
- CabalmailUI/Addresses/NewAddressSheet.swift:111 — content picks macContent or formContent
- CabalmailUI/Addresses/NewAddressSheet.swift:118 — macContent (MacSheetForm) and formContent (Form) bodies
- CabalmailUI/Addresses/NewAddressSheet.swift:202 — address preview fixedSize on macOS

**Approach:**
- Move `MacSheetForm` and `MacSheetSection` into Platform/ as a cross-platform adapter that keeps the names. On macOS it is the hand-built VStack; elsewhere it is Form and Section. Keep the file name `MacSheetForm.swift`, which does not end in `Sheet.swift` and so stays out of the scan's corpus. A captioned `MacSheetSection(caption:)` maps to `Section(caption)`. Bare children, such as the error labels, stay bare rows on both platforms, as they are today.
- The adapter needs four more pieces, because the Mac arms do more than relabel:
  1. **Mac-only row adapters in Platform/.**
     - `.sheetFieldStyle()` applies `.textFieldStyle(.roundedBorder)` on macOS and is identity elsewhere.
     - `.sheetPickerLabels()` applies `.labelsHidden()` on macOS and is identity elsewhere.
     - The four simple sheets' Mac arms apply these to the name, address or title field, and to the parent or folder picker. Examples: NewFolderSheet's `nameField.textFieldStyle(.roundedBorder)` and `parentPicker.labelsHidden()`, and FeedFolderSheet.swift:47 and :50. The sheets call the adapters in their single body.
  2. **An uncaptioned `MacSheetSection { … }`.** On macOS it draws its content bare: MacSheetSection without a caption is a leading VStack around the content, the same layout as today's bare `unsubscribeButton`. Elsewhere it maps to `Section { … }`, so FeedSubscriptionSettingsSheet keeps its iOS `Section { unsubscribeButton }`.
  3. **A `scrolls:` option on `MacSheetForm`.** On macOS it wraps the form in a `ScrollView`, as FeedSubscriptionSettingsSheet.swift:52 does today. Elsewhere it is ignored, because a Form already scrolls.
  4. **A sizing rule** (`.fitted` on macOS, `.form` elsewhere) that absorbs NewAddressSheet:91.
- Each sheet then has a single `MacSheetForm {` body.
- The four simple sheets (NewFolder, FeedFolder, SubscribeFeed, FeedSubscriptionSettings) map directly onto the adapter: captions become sections, plus the row adapters, the uncaptioned section and `scrolls:` where their Mac arms use them.
- SearchFiltersSheet and NewAddressSheet have genuinely different content on each platform: Grid rows, date pickers that dim on Mac versus hide on iOS, and one preview per arm. They need either a per-platform content slot in the adapter, or a runtime HostPlatform branch inside a section.
- NewAddressSheet:202's `fixedSize` can apply everywhere if a device check shows Form rows are unaffected. Otherwise it becomes a capability. The exact text stays inside `addressPreview`.

**Source scans:**
- MacSheetChromeSourceScanTests evaluates each sheet's `#if` lines (`compiledForMac`) to find the source that compiles for macOS.
  - testFormSheetsAskTheSharedChrome reads NewAddress, NewFolder and SearchFilters. On the macOS path it wants the literal `MacSheetForm {` and no bare `Form {`.
  - testNoSheetStillDrawsAMacForm reads every `*Sheet.swift` for a bare `Form {`, using the regex `\bForm\s*\{`.
  - testFormSheetsDoNotRestateTheChromesNumbers looks for `.padding(24)` or `frame(width: 460` on the macOS path.
  - What keeps all three green without editing the scan:
    - The type keeps the name `MacSheetForm`.
    - The adapter lives in a file whose name does not end in `Sheet.swift`.
    - No `*Sheet.swift` file is left with a bare `Form {`.
  - Dropping the `#if` makes these tests read what used to be iOS-only arms, since nothing is excluded any more. The PR must check that they pass for the right reason: each sheet's single body is `MacSheetForm {`. A `Form {` that the scan still skips behind a gate is not a valid pass.
  - The scan's header contract ("deleting the `#if os(macOS)` branch fails ... by name") stops meaning anything, so the maintainer should approve.
  - Renaming the type (for example to `PlatformSheetForm`) fails testFormSheetsAskTheSharedChrome for NewAddress, NewFolder and SearchFilters, because that test looks for `MacSheetForm {` by name. Under the CLAUDE.md rule a rename needs approval. A rename does not affect testNoSheetStillDrawsAMacForm: `\b` finds no word boundary between the `t` and the `F` in `PlatformSheetForm {`, so the regex does not match it.
- SectionFooterWrapTests needs SearchFiltersSheet's `.sectionFooter()` to stay in that file.
- NewAddressPreviewWrapSourceScanTests expects exactly two `addressPreview(preview)` calls, and the `fixedSize` text inside `addressPreview`. Collapsing NewAddressSheet's arms needs approval.

**Depends on:** 3.2-G (its `.formStyle(.grouped)` adapters) and FU-2 (the sheet-sizing file).

**Risk:** Medium. Every small sheet on iPhone and iPad changes from a hand-written Form to one the adapter produces. `.fitted` collapses the sheet on iPad, so the sizing rule must stay per platform. Compare each of the four simple sheets before and after, on macOS and on iPhone.

**Size:** M for MacSheetForm plus the four simple sheets (6 blocks). L for all 12.

**Worth doing:** Partly. Do MacSheetForm and the four simple sheets. Leave SearchFiltersSheet (2 blocks) and NewAddressSheet (4 blocks) on the allowlist unless the maintainer wants those scan contracts changed. Their two arms are genuinely different layouts, and the scans pin that shape on purpose.

### FU-16: One compose body

**Status:** Not started (2026-10-15).

**Goal:** Pick the Mac header-grid composer or the iOS Form composer at runtime, so both bodies compile everywhere.

**For the user:** Nothing.

**Blocks (6):**
- CabalmailUI/Compose/ComposeMacHeader.swift:1 — Mail-style header Grid, whole file macOS only
- CabalmailUI/Compose/ComposeView.swift:449 — composeContent picks macLayout or composeForm
- CabalmailUI/Compose/ComposeView.swift:456 — composeForm and its sections, off macOS only
- CabalmailUI/Compose/ComposeView.swift:598 — macLayout and macAttachmentStrip, macOS only
- CabalmailUI/Compose/Editor/ComposerBody.swift:51 — divider between the formatting bar and the editor on macOS
- CabalmailUI/Compose/Editor/ComposerBody.swift:61 — hidden ⌘⇧V Paste and Match Style button on iOS/visionOS

**Approach:**
- `HostPlatform.composeLayout` (`.headerGrid` on macOS, `.form` elsewhere) selects the body (:449) and the divider (ComposerBody:51).
- Ungate ComposeMacHeader, `macLayout` and `macAttachmentStrip`.
- Narrow :456 to the single `.onReceive(... UIResponder.keyboardDidShowNotification)` modifier. Keep `composeForm` in ComposeView.swift, ahead of `macLayout`.
- `HostPlatform.webContentReceivesCommandChords` (true on macOS) decides whether the hidden shortcut button is mounted.
- The narrowed keyboard gate stays a follow-up block. Removing it needs two things: a Platform/ keyboard-notification adapter, and the maintainer's approval to turn testTheFormScrollsAgainWhenTheKeyboardArrives into a behaviour test, because it wants that literal in ComposeView.swift.

**Source scans:** ComposeBodyScrollPolicyTests covers :456 and :598 (literals and ordering) through .testTheFormScrollsWhenTheEditorTakesFocus, .testTheFormScrollsAgainWhenTheKeyboardArrives and .testTheBodyRowIsTheScrollTargetAndLandsAtTheTop. None of them pins the `#if` line, so narrowing needs no approval. Removing the last gate does.

**Depends on:** FU-5 and FU-6, so ComposeView.swift's other 14 blocks are already gone.

**Risk:** Medium. iOS compose scroll-on-focus and the keyboard rescroll are pinned because they matter *(inf: they have regressed before)*.

**Size:** M.

**Worth doing:** Partly.
- ComposerBody's two blocks and ComposeMacHeader are cheap. Do them any time.
- Unifying the bodies pays off only if it takes ComposeView.swift off the allowlist, and that needs the keyboard-scan approval. Without that approval, the file keeps one smaller block and the gain is small.

### FU-17: Rules list on macOS

**Status:** Parked until Rules is next touched (2026-10-15). The :101 block below (the Mac's inline Add row) went with #2017, which put the Add row at the foot of the list on every platform; :129 (:139 at `50e6022`) remains.

**Goal:** Decide whether the Mac rules row and the inline Add row become capabilities or the only design.

**For the user:** Nothing on the capability route. The shared-row route changes the iOS and visionOS rules list and needs an `Apple:` fragment.

**Blocks (2):**
- CabalmailUI/Rules/RulesView.swift:101 — inline "Add rule" row on macOS
- CabalmailUI/Rules/RulesView.swift:129 — RuleRow: the Mac HStack row (#1299) vs the NavigationLink row

**Approach:**
- :101 reads a capability (`settingsListCarriesInlineAddRow`), or goes away if the macOS Settings-window toolbar rendering is fixed.
- :129 has two routes:
  - Use the Mac row on every platform. This deletes the touch arm and keeps RuleRowHitTargetTests green, but it changes the touch UX and needs a device check.
  - Keep both rows and choose at runtime. This needs approval, because the scan's macOS view would then contain the touch row's toggle inside a link label.

**Source scans:** RuleRowHitTargetTests.testMacRulesRowKeepsItsControlsOutOfTheLinkLabel pins the `#if` line at :129.

**Depends on:** Nothing.

**Risk:** Low to medium.

**Size:** S.

**Worth doing:** Low. These are two blocks that need a UX decision. Leave them until Rules is next touched.

### FU-18: Trackpad swipe bridge

**Status:** Not started (2026-10-15).

**Goal:** First, shrink the iPad trackpad swipe bridge's gates to the one UIKit type and move that type into Platform/. Later, delete the bridge once no supported iPadOS needs it.

**For the user:** Nothing.

**Blocks (6):**
- CabalmailUI/Mail/MessageList/TrackpadSwipe.swift:2 — UIKit import for the pan recognizer
- CabalmailUI/Mail/MessageList/TrackpadSwipe.swift:124 — coordinator, tracker, reveal modifier, capsule label and UIKit recognizer, all iOS only
- CabalmailUI/Mail/MessageList/SwipeActionRow.swift:131 — optional TrackpadSwipeCoordinator environment read
- CabalmailUI/Mail/MessageList/SwipeActionRow.swift:195 — withTrackpadSwipes applies .trackpadSwipeReveal on iOS
- CabalmailUI/Mail/MessageList/SwipeActionRow.swift:257 — row action closes open trackpad reveals first
- CabalmailUI/Mail/MessageList/SwipeActionRow.swift:335 — container adds .trackpadSwipeCoordination() on iOS

**Why waiting for a fix is not the plan:** The bridge serves the 27 container path. SwipeActionRow.swift gates that path with `if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *)` (:137 and :334), and the deployment floor is iOS 18. Suppose a later iPadOS lets `.swipeActionsContainer()` answer trackpad scrolls. iPadOS 27 is still supported and still needs the bridge. So the code cannot be deleted until the deployment floor passes the last iPadOS that needs it. That is far enough off that the split is worth doing now.

**Approach:**

Part 1, now (S, no scan impact):
- In TrackpadSwipe.swift, move these declarations out of :124's gate, unchanged and still in the same file:
  - `TrackpadSwipeCoordinator`
  - the `trackpadSwipeCoordination()` / `trackpadSwipeReveal(...)` View extension
  - the `TrackpadSwipeCoordination` modifier
  - `TrackpadSwipeTracker`
  - the `TrackpadSwipeReveal` modifier
  - `TrackpadSwipeCapsuleLabel`

  None of them uses UIKit. The recognizer's callbacks carry only `CGFloat`s, and `.onScrollPhaseChange` exists at the iOS 18 / macOS 15 / visionOS 2 floors.
- Leave only `TrackpadSwipeRecognizer: UIGestureRecognizerRepresentable` gated, together with its `Delegate` and `configuredRecognizer()`. Move it, and the `import UIKit` from :2, into a Platform/ wrapper file (for example Platform/TrackpadSwipeRecognizer.swift).
  - Off iOS, that file supplies an inert `TrackpadSwipeRecognizer` with the same four-closure init.
  - It also supplies a `.trackpadSwipeGesture(_:)` adapter, which attaches the recognizer with `.gesture(_:)` on iOS and returns the view unchanged elsewhere.
  - The reveal calls `.trackpadSwipeGesture(TrackpadSwipeRecognizer(...))`, so its `TrackpadSwipeRecognizer(` call and tracker hooks stay in TrackpadSwipe.swift and compile on every platform.
- SwipeActionRow then drops three gates:
  - :131, the coordinator environment read.
  - :257, `trackpadSwipes?.closeAll()`.
  - :335, so the container applies `.trackpadSwipeCoordination()` on every platform.

  Off iOS all three do nothing. No reveal ever claims the coordinator, so `owner` stays nil, and `closeAll()` writes only when `owner` is non-nil.
- :195 (`withTrackpadSwipes`) keeps its `#if os(iOS)`. The scan pins that literal, and it is the gate that keeps the reveal off macOS, whose container reads the trackpad natively.
- Result: 5 of the 6 blocks go, TrackpadSwipe.swift leaves the allowlist, and SwipeActionRow.swift drops to 1 block.

Part 2, deferred: once the deployment floor passes the last iPadOS whose swipe container ignores trackpad scrolls, delete the bridge. That means the Platform/ recognizer file, the reveal, the tracker and the coordinator, SwipeActionRow :195, and the iOS-bundle TrackpadSwipeTests. The deletion also removes the scan's trackpad assertions along with the behaviour they protect. That is a behaviour reason, not an edit to make a scan pass, but the maintainer still signs it off.

Alternative to the move in Part 1: widen the lint's representable exemption to `UIGestureRecognizerRepresentable`. The recognizer could then stay in TrackpadSwipe.swift, and the lint would exempt the whole file, coordinator and all.

**Source scans:**
- SwipeActionContainerSourceScanTests.testContainerPathCarriesTheTrackpadHalfOnIOS asserts all of the following, and Part 1 keeps all of them:
  - The literal `#if os(iOS)` in `withTrackpadSwipes`. This is :195, and it pins the `#if` line.
  - `.trackpadSwipeReveal(` in the same function.
  - `.trackpadSwipeCoordination()` in `coordinatedSwipeActionsContainer()`.
  - `TrackpadSwipeRecognizer(`, `tracker.began(`, `tracker.changed(` and `tracker.ended(` inside `private struct TrackpadSwipeReveal: ViewModifier {` in TrackpadSwipe.swift.

  Part 1 also keeps the reveal declared at column 0, so the scan's slice still finds its closing brace.
- .testCallSitesUseTheGatedWrapper covers :335. `swipeActionsContainer()` stays in SwipeActionRow.swift and out of the list file.
- The iOS-bundle TrackpadSwipeRecognizerTests call `TrackpadSwipeRecognizer.configuredRecognizer()` and `.Delegate()`. Both keep their iOS definitions in the moved file.
- Part 1 needs no approval. Part 2 does.

**Depends on:** Nothing.

**Risk:**
- Part 1: low. The iOS code is moved, not changed, and the additions off iOS do nothing. Check one trackpad swipe on an iPad running 27 anyway.
- Part 2: medium. iPad trackpad swipes can only be checked on a device.

**Size:** S for Part 1. Part 2 is S when its time comes.

**Worth doing:** Part 1, yes. Part 2, defer until the deployment floor allows it.

### FU-19: ToolbarVisibility adapter

**Status:** Waits on dropping Xcode 26 (2026-10-15).

**Goal:** None needed. This file already is the adapter: its call sites carry no `#if`.

**For the user:** Nothing.

**Blocks (2):**
- CabalmailUI/Shared/Chrome/ToolbarVisibility.swift:30 — keepsInBar() visibilityPriority, iOS/macOS with Swift 6.4+
- CabalmailUI/Shared/Chrome/ToolbarVisibility.swift:54 — keepsInBarFirst(), same gate

**Approach:** The only change available is a path move into Platform/.

**Source scans:** ToolbarVisibilitySourceScanTests.testTheHelperIsAvailabilityGuarded and .testTheOpenInspectorsToggleOutranksCompose read the file at its current path. They count the literal `#if (os(iOS) || os(macOS)) && compiler(>=6.4)` twice, which pins the `#if` lines. A move needs approval.

**Depends on:** Nothing.

**Risk:** None.

**Size:** S.

**Worth doing:** No. Keep the file on the allowlist permanently, or have the ratchet exempt it by name as a known adapter. Revisit when Xcode 26 support is dropped. The `compiler(>=6.4)` half can go then, which changes the counted literal and needs the same approval.

## Initial allowlist

**Ordering.** 3.2-G adds the lint and seeds this list. It lands after 3.2-A, 3.2-B, 3.2-F and the 3.2 shell PRs, and the counts below assume all of those have landed.

If 3.2-G landed earlier, the list would be wrong on day one:
- Two files would be missing: Mail/Search/GlobalSearchFieldPlacement.swift (`#if os(iOS)` :57) and Shared/Chrome/FilterPillCountStyle.swift (`#if os(visionOS)` :18).
- Six files would count higher: MessageListView+Rows (3), ComposeWindowScene (3), MessageListView (2), FeedItemListView (2), MessageListView+FolderSwitch (3) and FeedItemListView+ScopeSwitch (3).
- The lint would then either fail at once, or the list would have to be edited upward, which defeats a shrink-only ratchet.

If 3.2-G has to go first anyway, generate the seed with the lint itself from the tree at 3.2-G's merge. Each later 3.2 PR then lowers or deletes its own rows in the same PR.

**The lint rule, exactly:**
- **Scope.** Every `.swift` file under `apple/CabalmailUI/` except those under `Shell/` and `Platform/`. The app targets (`apple/Cabalmail/`, `apple/CabalmailMac/`) are outside its scope.
- **What counts.** A line counts when, after leading whitespace, it starts with `#if ` and its condition either contains `os(` or matches `canImport\((UIKit|AppKit|EventKitUI)\)`. Each counted line is one block.
  - `#elseif` and `#else` lines never count. MessageSourceSheet.swift's `#if canImport(UIKit)` / `#elseif canImport(AppKit)` pairs (:5/:7, :152/:154) therefore count once each.
  - A nested `#if` counts on its own line, for example AttachmentStrip.swift:55 and SidebarBranding.swift:156.
  - `canImport(EventKitUI)` is included because AttachmentStrip.swift uses it as a platform check (:22, :44, :55). Without it, that file would count 3 blocks, not 6.
- **What does not count.** `canImport(WebKit)`, `canImport(Network)`, `compiler(...)` and `DEBUG` on their own.
- **File exemption.** A file is exempt when a `struct`, `class` or `extension` declaration in it, outside comments, lists one of exactly these four names in its inheritance clause, matched literally as a whole word: `UIViewRepresentable`, `NSViewRepresentable`, `UIViewControllerRepresentable`, `NSViewControllerRepresentable`.
  - A loose `Representable` match would also exempt TrackpadSwipe.swift and MessageListView+ModifierClick.swift through `UIGestureRecognizerRepresentable`, which is not one of the four allowed kinds.
  - A name that appears only in prose does not exempt a file. For example, HTMLBodyView.swift:306 mentions `UIViewRepresentable.Coordinator` in a comment.
- **Ratchet.** An unlisted file fails at its first counted line. A listed file fails when its count rises above its row. A PR that lowers a file's count lowers or removes that file's row in the same change.

**HTMLBodyView.swift.** It declares `MobileHTMLView: UIViewRepresentable` (:184) and `MacHTMLView: NSViewRepresentable` (:232), so the rule exempts it and it is not on the list. That makes the list 55 files and 142 blocks. Its one follow-up block, :173, is tracked by FU-4 as guidance, not by the lint. Listing the file instead would mean a row of 7 blocks (:3, :108, :173, :183, :231, :393, :611), six of which are the wrapper itself, so I recommend the exemption.

**UIGestureRecognizerRepresentable.** MessageListView+ModifierClick.swift and TrackpadSwipe.swift define this kind, which the rule does not exempt. If the maintainer widens the exemption to include it, those two files (3 blocks) leave the list with no code change.

The list below holds the files that still have a platform `#if` once 3.2 lands, outside Shell/, Platform/, representable files and the app targets: 55 files and 142 blocks. Paths are relative to `apple/`. Recording a count per file lets the ratchet refuse both a new file and a growing count.

| File | Follow-up blocks | Cleared by |
|---|---|---|
| CabalmailUI/Addresses/AddressListView.swift | 2 | FU-2, FU-14 |
| CabalmailUI/Addresses/NewAddressSheet.swift | 4 | FU-15 |
| CabalmailUI/Compose/ComposeMacHeader.swift | 1 | FU-16 |
| CabalmailUI/Compose/ComposeView+Subviews.swift | 2 | FU-6 |
| CabalmailUI/Compose/ComposeView.swift | 17 | FU-5, FU-6, FU-16 |
| CabalmailUI/Compose/Editor/ComposerBody.swift | 2 | FU-16 |
| CabalmailUI/Compose/Recipients/ContactPickerSheet.swift | 1 | FU-2 |
| CabalmailUI/Compose/Recipients/ContactsPickerAffordance.swift | 1 | FU-2 |
| CabalmailUI/Compose/Windows/ComposeRequestRouter.swift | 2 | FU-1, FU-2 |
| CabalmailUI/Compose/Windows/ComposeWindowScene.swift | 2 | FU-2 |
| CabalmailUI/Feeds/ItemList/FeedItemListView+ScopeSwitch.swift | 2 | FU-13 |
| CabalmailUI/Feeds/ItemList/FeedItemListView.swift | 1 | FU-11 |
| CabalmailUI/Feeds/Management/FeedFolderSheet.swift | 1 | FU-15 |
| CabalmailUI/Feeds/Management/FeedSubscriptionSettingsSheet.swift | 1 | FU-15 |
| CabalmailUI/Feeds/Management/SubscribeFeedSheet.swift | 1 | FU-15 |
| CabalmailUI/Feeds/Reader/EmptyFeedDetailToolbar.swift | 1 | FU-1 |
| CabalmailUI/Feeds/Reader/FeedItemDetailView.swift | 2 | FU-1 |
| CabalmailUI/Feeds/Reader/FeedReaderToolbar.swift | 2 | FU-12 |
| CabalmailUI/Feeds/Sidebar/FeedSidebarSection.swift | 1 | FU-14 |
| CabalmailUI/Mail/AvatarView.swift | 2 | FU-2 |
| CabalmailUI/Mail/Folders/NewFolderSheet.swift | 2 | FU-15 |
| CabalmailUI/Mail/MessageList/MessageListView+Bulk.swift | 1 | FU-9 |
| CabalmailUI/Mail/MessageList/MessageListView+FolderSwitch.swift | 2 | FU-13 |
| CabalmailUI/Mail/MessageList/MessageListView+ModifierClick.swift | 1 | FU-9 |
| CabalmailUI/Mail/MessageList/MessageListView+Rows.swift | 2 | FU-2, FU-9 |
| CabalmailUI/Mail/MessageList/MessageListView+Selection.swift | 2 | FU-9 |
| CabalmailUI/Mail/MessageList/MessageListView.swift | 1 | FU-11 |
| CabalmailUI/Mail/MessageList/SwipeActionRow.swift | 4 | FU-18 (part 1 leaves 1; part 2 clears) |
| CabalmailUI/Mail/MessageList/TrackpadSwipe.swift | 2 | FU-18 (part 1) |
| CabalmailUI/Mail/MoveToFolderSheet.swift | 1 | FU-2 |
| CabalmailUI/Mail/Reader/AttachmentStrip.swift | 6 | FU-1, FU-3 |
| CabalmailUI/Mail/Reader/EmptyDetailToolbar.swift | 1 | FU-1 |
| CabalmailUI/Mail/Reader/MessageDetailView+AddressMenu.swift | 2 | FU-3 |
| CabalmailUI/Mail/Reader/MessageDetailView+DisposeOptions.swift | 2 | FU-2 |
| CabalmailUI/Mail/Reader/MessageDetailView+FlagOptions.swift | 1 | FU-1 |
| CabalmailUI/Mail/Reader/MessageDetailView+MacToolbar.swift | 1 | FU-1 |
| CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift | 8 | FU-1, FU-12 |
| CabalmailUI/Mail/Reader/MessageDetailView.swift | 10 | FU-2, FU-3, FU-12 |
| CabalmailUI/Mail/Reader/MessageSourceSheet.swift | 3 | FU-1, FU-2 |
| CabalmailUI/Mail/Search/SearchFiltersSheet.swift | 2 | FU-15 |
| CabalmailUI/Mail/Search/SearchView.swift | 1 | FU-14 |
| CabalmailUI/Rules/RulesView.swift | 2 | FU-17 |
| CabalmailUI/Session/SessionEnvironment.swift | 6 | FU-1, FU-7 |
| CabalmailUI/Session/SignInView.swift | 6 | FU-10 |
| CabalmailUI/Settings/NotificationSettingsSection.swift | 9 | FU-7, FU-8 |
| CabalmailUI/Settings/SettingsView.swift | 3 | FU-7, FU-14 |
| CabalmailUI/Shared/BodyRendering/LinkMenu.swift | 2 | FU-4 |
| CabalmailUI/Shared/BodyRendering/PlainTextBodyView.swift | 1 | FU-4 |
| CabalmailUI/Shared/BodyRendering/PrivateLinkHandoff.swift | 2 | FU-4 |
| CabalmailUI/Shared/BodyRendering/ReaderBottomGlass.swift | 1 | FU-12 |
| CabalmailUI/Shared/Chrome/MacSheetForm.swift | 1 | FU-15 |
| CabalmailUI/Shared/Chrome/SidebarBranding.swift | 2 | FU-14 |
| CabalmailUI/Shared/Chrome/SidebarTreeRowLabel.swift | 1 | FU-2 |
| CabalmailUI/Shared/Chrome/TitleSwitchMenu.swift | 1 | FU-13 |
| CabalmailUI/Shared/Chrome/ToolbarVisibility.swift | 2 | FU-19 |

## Not platform checks

All five are always true in CabalmailUI, whose destinations in project.yml are iOS, iPadOS, visionOS and macOS. None is dead code: every body compiles.

| Block | Condition | Verdict |
|---|---|---|
| CabalmailUI/Feeds/FeedWebStorage.swift:3 | canImport(WebKit) | Delete. WebKit exists on every destination, and HTMLBodyView.swift and ArticleWebView.swift already import it with no guard. |
| CabalmailUI/Feeds/FeedWebStorage.swift:31 | canImport(WebKit) | Delete with :3. The data-store cleanup body then runs unconditionally, as it already does in practice. |
| CabalmailUI/Mail/Folders/FolderListView+Helpers.swift:27 | canImport(Network) | Leave, or delete together with the Kit's guard. It mirrors `#if canImport(Network)` around `CabalmailClient.reachability` (CabalmailClient.swift:43). Network exists on every Apple platform, so the Kit's guard presumably serves a non-Apple toolchain *(inf)*. |
| CabalmailUI/Feeds/Reader/FeedItemDetailView.swift:101 | canImport(Network) | Same as above. |
| CabalmailUI/Shell/SignedInRootView.swift:268 | canImport(Network) | Same as above. It is in Shell/ anyway. |

The two WebKit deletions can ride in FU-1's PR. None of the five counts toward the ratchet; the lint rule above already ignores them.

## Recommended order

Each step lists the blocks it removes and the allowlist files it clears, assuming the steps before it have landed and the allowlist above is the starting point (that is, 3.2-A/B/F and the shell PRs have landed).

1. **FU-1, dead and redundant gates:** no design, no pins, no dependencies (18 blocks, 5 files). If possible, land it after 3.2-A/B/F and the shell PRs but before 3.2-G. The seeded allowlist then starts at 50 files and 124 blocks.
2. **FU-2, small Platform/ adapters:** sets the adapter and HostPlatform-policy pattern that the later FUs reuse (15 blocks, 9 files).
3. **FU-3, contacts and calendar:** self-contained and unpinned, and finishes AttachmentStrip after FU-1 (7 blocks, 2 files).
4. **FU-4, private-window link handoff:** a self-contained Mac feature, unpinned (6 blocks, 5 of them lint-counted, 3 files). HTMLBodyView.swift:173 is the sixth block; it goes too, but the lint does not track it.
5. **FU-5, compose window close gate:** mechanical and unpinned, and takes over half of ComposeView's 17 blocks (9 blocks, 0 files).
6. **FU-6, photo-library attach:** unpinned. After it and FU-5, ComposeView holds only its body blocks (7 blocks, 1 file).
7. **FU-7, push scope on visionOS:** one capability plus a stub, no approval (6 blocks, 1 file).
8. **FU-8, Mac residency settings:** small and independent of FU-7. It clears NotificationSettingsSection once FU-7 has removed :4 (8 blocks, 1 file).
9. **FU-9, list selection input:** after 3.2-B, to avoid conflicts in +Rows (5 blocks, 4 files).
10. **FU-10, sign-in chrome:** small, but it is the first-run screen, so check it on every platform (6 blocks, 1 file).
11. **FU-11, list primary-toolbar twins:** cheap after 3.2-A, and takes both list views off the allowlist (2 blocks, 2 files).
12. **FU-12, reader action bar on ShellLayout:** the largest cluster. Start it only after 3.2's shells have settled on devices (15 blocks, 4 files).
13. **FU-13, title-switch host:** after 3.2-F, which clears TitleSwitchMenu.swift:40. It needs the maintainer's approval for FolderSwitchPlacementTests, and it finishes 3.2-A's host work (5 blocks, 3 files).
14. **FU-14, compact brand-mark title:** needs 3.2-A, 3.2-F, 3.2-G and TabShell, and reuses FU-13's glass adapter (6 blocks, 5 files).
15. **FU-15, sheet chrome (MacSheetForm plus the four simple sheets):** needs the row adapters, the uncaptioned section and `scrolls:`, and the maintainer's approval of MacSheetChromeSourceScanTests' contract (6 blocks, 5 files). Leave SearchFiltersSheet and NewAddressSheet for a separate decision.
16. **FU-16, one compose body:** ComposerBody's two blocks can go any time. Do the rest only together with approval to convert the keyboard scan.
17. **FU-17, rules list on macOS:** when Rules is next touched and the touch-row UX has been decided.
18. **FU-18, trackpad swipe bridge:** Part 1 (hoisting the coordinator and reveal, and moving the recognizer into Platform/) is scan-neutral and can land any time (5 blocks, 1 file; SwipeActionRow.swift drops to 1). Part 2, which deletes the bridge and :195, waits until the deployment floor passes the last iPadOS that needs the bridge. A fix in the next iPadOS release is not enough, because the iOS 18 floor keeps iPadOS 27 supported after any fix.
19. **FU-19, ToolbarVisibility:** do not do it. Keep it on the allowlist or exempt it by name.
