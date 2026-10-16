# Mail and navigation hotspot refactors

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session, run in two passes by one plan. Every PR preserves behaviour over code that already has tests, there are two decisions in one batch, and nothing needs a server change, a migration, parallel threads or an outside event; the passes exist only because each PR waits for a different plan to free its file.
**Size:** M (six PRs, each S or M; PR 7, L, only if decision 1 is Yes).
**Priority:** Next overall. PR 6 and PR 3a: Now, because each is small and frees room in a file that a bug-fix PR edits next (shared-load-error-state.md's A3 and A4). PR 1: Next, after ipad-layout-and-keyboard.md's PR B. PRs 2, 3b and 4: Later.
**Depends on:** nothing hard. Order only, one open PR per shared file: ipad-layout-and-keyboard.md (PR B before PR 1; PR H in `SplitShell.swift`), duo-support.md (PR 3 in `SplitShell.swift`), hardening-web-and-writes.md (PR 1 and PR 5 in the compose model), shared-load-error-state.md (A3 in the test double; A1 and A4 in compose; B3 in the reader), platform-conditionals.md (FU-5 before PR 3b; FU-16), multi-window-and-restore.md (never open beside PR 1), detached-reader-window.md (PR 3 in the reader). Soft: refresh-scheduling.md (its loop type, if merged first).
**Unblocks:** flags-and-cross-media.md (PR 1 before B5.1), sqlite-mail-store.md (PR 1 before Phase 3; PR 6 frees the test double), shared-load-error-state.md (PR 6 before A3 and PR 3a before A4, inferred). Soft: hardening-web-and-writes.md (PR 3a goes first if its PR 1 needs the room), multi-window-and-restore.md (R5 prefers PR 1 first), duo-support.md (a Session 2 fix that needs `SceneNavigator.swift` waits for PR 1), feed-bulk-actions.md (order only), test-debt.md (PR 6 frees `FakeImapClient` room before its A2).
**Duo groundwork:** PR 1 puts the window's mail fold state (folder, open message, compact column and the tree gate a fold swaps) into one tested value type, which is where sqlite-mail-store.md's PR 3.5 message ref and any fix for the tree-gate gap duo-support.md watches would go, and every navigator change is checked folded and unfolded on the Studio's Duo simulator; it adds no Duo API.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| Decisions 1 and 2 | Unanswered (2026-10-15). |
| PR 6. `FakeImapClient`'s call gate | Not started (2026-10-15). |
| PR 3a. `ComposeAutosave` | Not started (2026-10-15). Hardening PR 1, which it waits for, merged as #2053 and shipped in 1.31.2. |
| PR 1. `MailNavigationState` (the navigator split) | Not started (2026-10-15). |
| PR 2. The split's width write (only if decision 2 is Yes) | Not started (2026-10-15). |
| PR 3b. `SendCoordinator` | Not started (2026-10-15). |
| PR 4. `MessageRenderer` (measure first) | Not started (2026-10-15). |
| PR 5 | Moved to sqlite-mail-store.md's Phase 3; not this plan's work. |
| PR 7. `GlobalSearchModel` (only if decision 1 is Yes) | Not started (2026-10-15). |

> **Duo spec (2026-10-13):** This plan was written before the maintainer's Oct 7 Duo spec (the Claude Doc linked in duo-support.md) had been read. duo-support.md now follows it; where this plan's text disagrees with the points below, the points win. In the spec, "fold" means book or laptop pose, which changes no size class and swaps no shell; what this plan calls folding or unfolding the Duo is closing or opening it.
>
> - PR 1: keep the tree gate behind one member so a one-tree navigator (duo-support.md Decision 9) can delete it, and name the spec's narrowing order as the rule a later PR adds. PR 2 removes the measurement only; duo-support.md PR 3 owns the width rules. PR 3b's `SendCoordinator` emits a toast value carrying its kind and origin, for duo-support.md PR 4's fold rule. PR 3a's `ComposeAutosave` gets a `flush()` for backgrounding. The fold check adds a book and a laptop step; "the Settings sheet becomes the Settings tab on close" is today's behaviour, not the target.

## Decisions for the maintainer

1. **Give global search its own model class now?** **No (recommended).** Consequence: global search stays a message-list model in "search" mode, and the question moves to sqlite-mail-store.md's Phase 3 question list, which already holds it (its line 203); that phase reshapes both lists anyway. Yes adds PR 7 (size L, pass 2) and approves moving one source-scan test's anchor (`MessageListRefreshRoutingTests.swift:60`). Default if unanswered: No.
2. **Remove the iPad split's unused width measurement?** **Yes (recommended).** Consequence: the split stops measuring a width nothing reads. One source-scan test ends its slice on a comment that goes away, so its end marker moves to the next heading in the same file; none of its checks change. Default if unanswered: No, and PR 2 is dropped, because a scan change needs your yes.

## What you'll see change

- **PR 6, test double:** nothing visible. It frees room in the shared fake that the #1903 fix (shared-load-error-state.md A3) edits.
- **PR 3a, compose autosave:** nothing visible. A composer's two autosave timers stop when the composer goes away, even if a close path forgets to stop them.
- **PR 1, navigator split:** nothing visible. Every fold, narrow, widen and launch behaves as today. It frees room in the navigator that three plans need to add to.
- **PR 2, split width (decision 2):** nothing visible.
- **PR 3b, after Send:** nothing visible. The Drafts list, the replied arrow and the "Message sent." or "queued" toast behave as today, now under unit tests.
- **PR 4, reader (only if a measurement shows a stall):** a large message with many attachments opens without the window stalling while it is parsed.
- **PR 7 (only if decision 1 is Yes):** nothing visible.

## Why

CI runs `swiftlint lint --strict` (`apple/.swiftlint.yml:1-4`), so every warning fails a merge. `type_body_length` stays at SwiftLint's default and warns above 250 counted lines (`.swiftlint.yml:36-45` says so). CLAUDE.md treats a length cap as a design signal: extract a type that owns behaviour, never a `Foo+Bar.swift` extension. Wave 3 worked against that ceiling in the navigator: the 3.3 brief says "`SceneNavigator`'s class body is 245 counted lines ... against `type_body_length`'s 250, which `--strict` makes an error", and its rule was "Extract types that own behaviour ... never a `SceneNavigator+Foo.swift`". PR #2007 ended at 244. Each workstream made room for itself and left none behind.

The compose model, the compose view and the shared IMAP test double now sit within five lines of the same cap. Four findings of the 2026-10-02 audits that asked for owning types are still open (each is summarized under "Background from the rearchitecture"): post-send effects in a view (audit 01, the mail audit, F9; its work item W6 asked for a `SendCoordinator`), MIME parsing on the main actor (audit 01 F12), autosave loops that never exit (audit 01 F14; audit 06, the tests and robustness audit, instance 8) and global search as its own model (audit 01 F1). The 2.2 brief promised that last one a weighing (its decision 5): "after both [2.1 and 2.3], a separate class is cheap and can be weighed then". Decision 1 is that weighing.

## Where things stand

Counts strip blank and comment-only lines, as SwiftLint does. The script reproduces PR #2007's 244 at its head (`714b1cdc`). Recount with `swiftlint` on a rig before each push.

| Type (file at 50e6022) | Body, of 250 | `file_length`, of 500 | Next editors |
|---|---|---|---|
| `SceneNavigator` (`Navigation/SceneNavigator.swift:49-525`) | 241 | 376 (728 raw) | ipad PR B (in the `ShellHandOff` extension, :700-728), multi-window R5 (one line), flags B5.1, sqlite PR 3.5 |
| `ComposeViewModel` (`Compose/ComposeViewModel.swift:34-523`) | 248 | 255 | hardening PR 1 (seed call, :385-401), shared-load A4 (:293, 459, 461) |
| `ComposeView` (`Compose/ComposeView.swift:28-432`) | 245 | 414 | platform-conditionals FU-5, FU-16 |
| `FakeImapClient` (`CabalmailKit/Tests/CabalmailKitTestSupport/FakeImapClient.swift:9-354`) | 248 | 252 | shared-load A3 |
| `MessageDetailViewModel` (`Mail/Reader/MessageDetailViewModel.swift:11-309`) | 143 | 196 | detached-reader PR 3, shared-load B3, sqlite PR 3.5 |
| `MessageListViewModel` (`Mail/MessageList/MessageListViewModel.swift:16-276`) | 97 | 231 (1,826 raw over 11 files) | mail-correctness PRs 2-3, shared-load B4, sqlite Phase 3 |
| `NavStateCoordinator` (`Navigation/NavStateCoordinator.swift:28-311`) | 183 | 213 | none; 3.3 B (`5035e28b`) took it from 244 |

- **Navigator.** The mail half's state sits in the class body: `selectedFolder` (:64), `selectedEnvelope` (:68), `compactColumn` (:73), the tree gate `mailTrees` (:127), the per-tree readers (:182-196) and the transitions (`setCompactColumn` :427, `canWrite` :451, `setFolder` :465, `applyMessage` :488). The feed half already lives in a value type, `FeedNavigationState` (`Navigation/FeedNavigationState.swift:19-120`), whose transitions return records the navigator applies in an extension (:627-650). Sixteen `SceneNavigator*Tests` files hold 180 tests; they read `selectedFolder` 61 times and the three readers 40 times, and set none of the members PR 1 moves. No source scan reads the navigator files.
- **Tree gate.** A torn-down tree stays writable after a fold (`Navigation/TreeGate.swift:37-39`, as duo-support.md's risk 10 puts it). No wrong write has been seen; that plan watches it.
- **Split width.** `SplitShell` keeps `@State contentColumnWidth` (`Shell/SplitShell.swift:44`), writes it from its one `.onGeometryChange` (:127-131, through `recordContentColumnWidth` at :181-189) and never reads it. PR #2008 left it: "removing it is a behaviour question for another PR".
- **Compose.** The Send button's closure (`ComposeView.swift:305-357`) posts the removal of every superseded draft UID, marks a reply's original answered and picks the toast. `perform(_:)` (:226-283) posts `.draftReplaced` with a raw `"Drafts"` at :245 and :267, though `FolderTree.draftsPath` exists (`CabalmailKit/Sources/CabalmailKit/Models/FolderTree.swift:32`) and :330 uses it. The model's half is tested (`DraftPruneOnSendTests`, `DraftReplacementTests`); the closure is not. The two autosave loops (`ComposeViewModel.swift:260-276`) capture `[weak self]` and call `self?.`, so a loop whose model is gone wakes every 5 or 60 seconds forever if `stop()` (:253-258) was missed.
- **Reader.** `MessageDetailViewModel` is `@MainActor` (:9-11). `load()` calls `MimeParser.parse(bytes)` and `hydrate(from:)` inline (:168-169); `hydrate` decodes the body, builds `data:` URLs for inline images and writes every attachment to disk (:336-378). `MimePart` and `MimeAttachmentPlan` are `Sendable` (`CabalmailKit/Sources/CabalmailKit/MIME/MimeTypes.swift:69`, `MimeAttachments.swift:21`). Audit 01 (F12) was sure the work runs on the main actor but only "Medium that it causes perceptible hitches". Nobody has measured it.
- **Global search.** One model type with a `.search` scope: 13 references to `isSearchScope` (9 branches, 2 declarations, and a parameter with its argument). `MessageListView` takes one concrete `MessageListViewModel`.
- **Issues.** No open issue tracks an item here (77 open issues checked by title on 2026-10-12). Related: #1970 and #1996 (open) are fixed on stage in `c1d88c23` with no closing keyword; #1912 (open) is fixed in `a587e8b6`, already on main. docs-and-bookkeeping.md closes all three by hand.

## The plan

**Rules for every PR.** Behaviour preserved. Forwarding members keep call sites and tests unchanged. A test edit, if unavoidable, changes only the receiver (`navigator.x` to `navigator.mail.x`), in its own commit, checked by a script for no assertion, expected-value or test-name change, as 2.2 did (its decision 8). Undo each moved rule once and watch a test fail (#2015 did 31 such mutations). Run `swiftlint --strict` and `python3 scripts/check-platform-conditionals.py` before each push. No new `Foo+Bar.swift`, no source-scan edit beyond decisions 1 and 2, no Kit source change. Code moved out of a view takes its client calls and `Task` bodies with it (audit 06 F14, view logic outside any test seam: "as views are touched"). `no-changelog`, except PR 4 if it ships. One open Apple PR at a time; none in the week before the Duo ships (about 2026-10-23) unless CI is idle. Rollback is a revert: no migration, no server change.

**Fold check** (PR 1, PR 2, PR 7). PR #2008's before-and-after tour: one SimDrive script on two fresh clones (stage, then the PR), screenshots compared pixel by pixel below the status bar, accessibility trees compared. Simulators: the iPad in a 714 pt Stage Manager window narrowed to 387 pt and back; visionOS, since `setFolder` carries its Folders-tab rule (`SceneNavigator.swift:483-485`); an iPhone cold launch with a back-out to the folder list before it loads (#1912's rule, :324-329); and the Studio's Duo, folded and unfolded with Device Hub's posture buttons. Cover: an INBOX message open, a feed item open, a search with results (not an open result, which is #2033), the Settings sheet, Select mode with two rows, a list at about row 30, a cold launch onto a stored route. Device Hub needs the Studio's console awake (#2015 checked only the closed pose for that reason); post before taking the screen, and ask the maintainer unless duo-support.md's decision 2 allowed the clicks. The maintainer checks the Mac window on the stage TestFlight build, which holds Promote, not merge.

### Pass 1 (Now and Next)

**PR 6. `FakeImapClient`'s call gate.** First, as soon as the session starts.
- Scope: move the hold-and-release machinery (`FakeImapClient.swift:174-228`: the search hold and the per-call hold keyed by the existing `HeldCall`) into a value type in `CabalmailKitTestSupport` that the actor stores and mutates. Keep it a stored value, not a second actor, so no new suspension point changes the order tests rely on. The fake's public methods stay. Test support is compiled by folder (`apple/project.yml:681-689`), so a new file needs no project edit.
- Target: a body of about 210 (inferred). Verify: `swift test` and the app suites in CI. Risk: low.

**Status:** Not started (2026-10-15).

**PR 3a. `ComposeAutosave`.** After hardening-web-and-writes.md's PR 1 merges (it edits the seed call in the same class body); if that PR needs more than two class-body lines, this goes first. Never open beside shared-load-error-state.md's A1 or A4.
- Scope: a small type that owns both autosave tasks, with `start` and `stop`, and ends a loop when its model is gone. Inside each loop, after the sleep, rebind with `guard let self else { return }`; binding before the loop would hold the model strongly, so it would never go away. Intervals stay at 5 and 60 seconds but are injected, with the sleep, the way `FolderPollTiming` does it (`Mail/Store/FolderPollers.swift:41`), so tests step instead of sleeping. If refresh-scheduling.md's PR 2 loop type has merged, build on it instead (its lines 66-67 and 115 expect that).
- Files: `Compose/ComposeViewModel.swift`, new `Compose/ComposeAutosave.swift`, tests. No source scan reads either file.
- Tests: new `ComposeAutosaveTests`: both bodies run on each step; `stop()` ends both; a released model ends both without `stop()`. Existing compose suites unchanged. Target: about 230 (inferred).
- Verify: CI; on the Mini, a composer open past 60 seconds still saves its draft. Risk: low.

**Status:** Not started (2026-10-15). Hardening PR 1, which this waits for, merged as #2053 (`5eb7284`) and shipped in 1.31.2.

**PR 1. `MailNavigationState` (the navigator split).** After ipad-layout-and-keyboard.md's PR B merges, with no multi-window-and-restore.md or feed-bulk-actions.md PR open in `SceneNavigator.swift`.
- Scope: a value type beside `FeedNavigationState` that owns the window's mail folder, open message, compact column and `TreeGate`, the per-tree readers, and the transitions now in `setFolder`, `applyMessage`, `setCompactColumn` and `canWrite`. As in the feed type, each transition returns records (folder, message, no message) and the navigator applies them to the route, the recorder, `listHold` and the tab, in the mail extension. Read-only forwarders keep `selectedFolder`, `folder(in:)`, `envelope(in:)` and `compactColumn(in:)`, so the 180 navigator tests stay as they are. `layoutIsWide` stays where it is.
- Keep `TreeGate`'s behaviour exactly, gap included; duo-support.md decides any clear-on-layout-change, and this type is where it would go.
- Shape for the next editor: sqlite-mail-store.md's PR 3.5 makes the navigator hold a message ref and resolve it from a table. Keep the open message behind one stored property and one reader, and the ref computation (today :502-505) in one place, so PR 3.5 changes one type.
- Observation: the shells read folder, message and column together today (`Shell/WideMail.swift:59-60, 91`; `CompactMailStack.swift:30-31, 53`; `OrnamentShell.swift:128-129`), so one observed struct should not re-render them more than the separate properties do (inferred). The tour confirms it.
- Target: a body of about 205, leaving at least 35 lines of room (inferred). If it frees less, also move the landing bookkeeping (`didLand`, `awaitingLaunchReconcile`, `loadedFolders`, `resolvedFolder`, :105-114 and :290-399) into a small type with read-only forwarders. Say in the scope doc whether that is likely, because it moves the #1535 and #1912 rules too.
- In its own commit, rewrite the four `MailRootView` comments in `SceneNavigator.swift` and the one in `FeedNavigationState.swift`.
- Files: `Navigation/SceneNavigator.swift`, new `Navigation/MailNavigationState.swift`, `FeedNavigationState.swift` (comment), new tests.
- Tests: new `MailNavigationStateTests` for each transition's records and the gate; every `SceneNavigator*`, `ShellHandOff`, `WindowCommand*` and `ListPlace*` suite unchanged.
- Verify: CI, the mutation pass, then the fold check. Risk: medium. This code keeps an open message across a fold, and its rules came from bugs (#1535, #1555 and #1664, closed; #1912, open but fixed).

**Status:** Not started (2026-10-15).

**PR 2. The split's width write (only if decision 2 is Yes).** When `SplitShell.swift` is free: after duo-support.md's PR 3 and ipad-layout-and-keyboard.md's PR H, or before either opens. In pass 1 if that slot comes; otherwise pass 2.
- Scope: delete `contentColumnWidth`, its `.onGeometryChange` and `recordContentColumnWidth`, and move `ColumnToolbarOccupantsSourceScanTests`' end marker (`:114`) to `// MARK: - Floating folder panel` (`SplitShell.swift:191`) with every assertion unchanged. `ReaderColumnFloorSourceScanTests` and `SidebarToggleRemovalSourceScanTests` also read the file and stay unedited and green.
- Verify: CI, then the fold check on the iPad and the unfolded Duo. Risk: low.

**Status:** Not started (2026-10-15).

**End of pass 1.** PR 1 is the one structural change in its release, so a fold regression traces to one PR; the maintainer picks which release, avoiding duo-support.md's R1 and ipad-layout-and-keyboard.md's Session 1 release where possible. Hand off to the soak. The session can stop here; pass 2 resumes from this plan when its files are free.

### Pass 2 (Later)

**PR 3b. `SendCoordinator`.** After platform-conditionals.md's FU-5 merges (it rewrites the close-gate lines inside the same closures: `ComposeView.swift:230, 252, 271, 308, 315`); never beside FU-16.
- Scope: a `@MainActor` `SendCoordinator` (the audit's name) owns what happens after Send, Save Draft and Discard: the removal event for superseded drafts, `markAnswered`, the toast, and the `.draftReplaced` event built with `FolderTree.draftsPath`. The view keeps only the close-gate lines.
- Files: `Compose/ComposeView.swift`, new `Compose/SendCoordinator.swift`, tests. `ComposeBodyScrollPolicyTests` reads `ComposeView.swift` (:177-205: the scroll reader, `ComposerBody(model: model)`, the keyboard re-scroll and the scroll anchor); it stays unedited and green.
- Tests: new `SendCoordinatorTests`: a sent reply marks its original answered; a queued send shows the warning toast and prunes nothing (`supersededDraftUIDs` is empty unless sent, `ComposeViewModel+Internals.swift:359-360`); a send from a draft removes every superseded UID; a discard and a save post `.draftReplaced` for Drafts. Existing compose suites unchanged. Target: `ComposeView` about 215 (inferred).
- Verify: CI; on the Mini, signed in as a stage test account, send from a draft and watch its Drafts row go, and reply and see the arrow; the visionOS composer unchanged. The maintainer on the Mac: Command-W with text, a failed send while offline, and a failed Save Draft each keep the window and its prompt (the re-arm at :271-277 and :315-317 is Mac only). Risk: low to medium.

**Status:** Not started (2026-10-15).

**PR 4. `MessageRenderer` (the reader off the main actor).** Measure first; no PR open on `MessageDetailViewModel*.swift`.
- Measure: a Mac-host test times `MimeParser.parse` plus `hydrate` on a 10 MB fixture with 20 attachments (the mail tiers accept up to 50 MiB, `docker/templates/in-sendmail.mc:21`, and the raw body arrives through a presigned S3 URL, `lambda/api/fetch_message/function.py:72`). Under 4 ms on the Mac: record it and drop this PR (the default). Over 8 ms, one frame at 120 Hz: ship. Between: a Time Profiler run with `xctrace` on the Mini's iPhone simulator decides, as audit 01's W6 asked (an Instruments check that a large message open shows no main-thread hitch). The thresholds are inferred: a phone is slower than the Mini.
- If it ships: a `nonisolated` `MessageRenderer.prepare` in `Mail/Reader/`, not the Kit (to stay out of kit-split.md's way), returns the decoded body, headers, inline images and written attachment files; `hydrate` becomes assignments on the main actor. Cancellation stays as #403 and #1815 (both closed) left it.
- Tests: `MessageDetailLoadTests`, `MessageDetailLoadFailureTests` and `MessageDetailAttachmentTests` unchanged (no test calls `hydrate` directly), plus a renderer test on a fixture and one that `prepare` runs off the main thread. No source scan reads the file. Fragment `Apple:` under `changed`. Risk: medium; the reader's load and cancel paths have regressed before.

**Status:** Not started (2026-10-15).

**PR 5. Moved.** `RowAnimationState` and the advance targets now go to sqlite-mail-store.md's Phase 3 (see "Not in this plan").

**Status:** Moved; not this plan's work.

**PR 7. `GlobalSearchModel` (only if decision 1 is Yes).** After mail-correctness.md's PRs 2 and 3 and shared-load-error-state.md's B4, which edit `+Search.swift` and the list's state. Scope doc first: the list view takes a protocol both models satisfy, the `.search` scope and its 9 branches go, and the scan anchor moves as approved. The scope doc lists every scan that reads a `MessageListView*` file (8 test files name one by path at 50e6022). Size L; fold check; risk medium to high.

**Status:** Not started (2026-10-15).

## Background from the rearchitecture

What this plan uses from the rearchitecture's scope docs and the 2026-10-02 audits, which are not in the repo. The audits read the code as of 2026-10-02; their counts are from then.

- **Wave 3.3's lint rule** (2026-10-09): "`SceneNavigator.swift` must not end longer than it started. Extract types that own behaviour (`WindowRestores`, `DeepLinkRouter`, `ComposeCoordinator`, the registry), never a `SceneNavigator+Foo.swift` (CLAUDE.md)." Its risk note counted `SceneNavigator`'s class body at 245 and `NavStateCoordinator`'s at 244, against `type_body_length`'s 250, which `--strict` makes an error.
- **Wave 2.2's decisions 5 to 8** (2026-10-08, the `MessageListViewModel` split):
  - **5.** Global search is a list without a loader, not a new class (yet). A separate class would have had to copy or share the mutation and selection code that 2.1 and 2.3 were about to take out of the list model; "after both, a separate class is cheap and can be weighed then". `MessageListScope.search` stopped yielding a sentinel `Folder`, and no request may name an empty folder path (a test asserts it). `AppState.searchModelStore` kept holding the model; 2.3 moved it per window.
  - **6.** Who reaches what: views and tests reach window and search state through the part that owns it (`model.window.…`, `model.search.…`). The list model keeps what spans parts and the members the shell and the scans use, so 2.2 edited no `MailRootView*` or `AppState*`.
  - **7.** One seam to the rows on screen: the event handler, the row animation and the move bookkeeping stay on the list model, which reaches whichever source is showing through a read-write `envelopes` and `adjustTotalMessages`. Rows stay in the lists, so the seam lasts until the SQLite mail store moves them.
  - **8.** Test edits: apart from pins named for replacement, every existing test passes unchanged in every PR, and every replaced or changed test is listed in the PR. The structural PRs change existing tests only by receiver (`model.windowStart` to `model.window.windowStart`), in a commit of their own that a script checks is receiver-only: no assertion, expected value or test name changes in that commit. The executed test count is the merge-base's plus the tests added.
- **Audit 01 (the mail feature stack):**
  - F1: `MessageListViewModel` was one object split across files for lint size, not cohesion, with three modes sharing one `envelopes` array. Among its recommendations: give global search its own view model (or `MailSearchSession` plus a shared list view) so `.search` stops being a sentinel-folder mode.
  - F9: business logic lives in views. One case is the post-send effects (pruning Drafts with a hard-coded `"Drafts"` path, `markAnswered` and the toasts) in the Send button's closure. Recommendation: a `ComposeSession` or `SendCoordinator` that owns post-send effects, with views that only bind and dispatch intents.
  - F12: the reader's `load()` runs `MimeParser.parse` and `hydrate` (the attachment plan, base64 `data:` URLs and a file write per attachment) synchronously on the main actor. Confidence high that it runs on main, "Medium that it causes perceptible hitches", which depends on message size. Recommendation: a `nonisolated` or Kit-side `MessageRenderer.prepare(bytes)` run off the main actor.
  - F14: compose is the best-factored part of the slice, with rough edges: two independent autosave loops built on `Task.sleep`, post-send effects left to the view, and a raw `"Drafts"` string.
  - W6, the work item for F9, F14 and F12: a `SendCoordinator` owning post-send effects (Drafts prune via a `FolderTree` constant, `markAnswered`, toasts) and `MessageRenderer.prepare` off the main actor, verified by unit tests for `SendCoordinator` and an Instruments check that a large message open shows no main-thread hitch.
- **Audit 06 (tests and robustness):**
  - Instance 8: autosave and poll loops that capture `[weak self]` and call `self?.` never exit if the owner goes away without `stop()`; they keep waking and do nothing. `ComposeViewModel` relies on `stop()` being called from `onDisappear` and every dismiss path. The fix is `guard let self else { return }` inside the loop.
  - F14: view logic outside any test seam (162 `Task {}` blocks and 27 direct client calls in views at the time). Recommendation: "As views are touched, move client calls into view models or coordinators, so behaviour becomes testable without scans."
  - T6: a typed command bus to replace the roughly 20 `AppState` tick counters, which act as an untyped event bus that every window observing the one shared `AppState` reacts to.

## How to start it

Point the session at this plan and `00-working-agreements.md`, both in `docs/1.x/post-wave-3/`; at "Background from the rearchitecture" above (the 3.3 lint rule, 2.2's decisions 5 to 8, and the audit 01 and 06 findings); and at `../platform-conditionals-followups.md`, FU-5 (Compose window close gate). PR #2008's body describes the tour. Rigs: the Mini (iPad, iPhone and visionOS simulators, the two stage test accounts) and the Studio (the Duo simulator and Device Hub).

Opening brief, ready to paste:

> Run pass 1 of the "Mail and navigation hotspot refactors" plan (`docs/1.x/post-wave-3/mail-navigation-refactors.md`) for the Cabalmail Apple clients on current `stage`. Read 00-working-agreements.md (same folder) first. The maintainer's answers: decision 1 `<answer>`, decision 2 `<answer>`. Recount every type in the plan's table with `swiftlint --strict` on a rig, then post a one-page scope doc: the two decisions quoted at the top with the answers, then one line per PR saying what the maintainer will see. Order: PR 6, PR 3a, PR 1, then PR 2 if `SplitShell.swift` is free. Before each PR, check that no other plan has a PR open on its files (the plan names them). Every PR preserves behaviour: tests unchanged except receiver-only commits, no source-scan edits beyond the approved ones, `no-changelog`, one open Apple PR at a time. Run the fold check on PRs 1 and 2, and post before taking the Studio's screen. Hand off to the soak after PR 1 (or PR 2), and stop; pass 2 is a later session.

For pass 2, the same brief with "pass 2" and the order PR 3b, PR 4 (measure first), then PR 7 if decision 1 was Yes.

## Risks and checks

1. **A fold or landing regression from PR 1.** Check: forwarders, the 180 navigator tests, the mutation pass, the fold check on four simulators, and the maintainer's Mac window check before Promote.
2. **A plan grows the navigator first.** ipad-layout-and-keyboard.md's PR B keeps its lines in the `ShellHandOff` extension and stops if it needs more than about five class-body lines (its line 85). multi-window-and-restore.md's R5 is one line. If any plan needs more than five lines before PR 1 merges, PR 1 goes first.
3. **The Duo posture cannot be scripted, and the Studio is shared.** Only Device Hub on the Studio sets it, and six plans verify there (duo-support.md risk 9). Check: one Studio GUI session at a time. If the console is locked, run the iPad narrow and widen, mark the Duo check as owed, and run it before Promote.
4. **The autosave type keeps its model alive.** A strong capture would make the "released model" test fail. Check: that test must step, not sleep.
5. **Lint counts are estimates.** The script matches #2007, but `swiftlint` on a rig is the authority.
6. **The reader's cancel paths (#403, #1815).** PR 4 keeps every model property on the main actor; only `prepare` runs elsewhere.
7. **CI starvation.** One open Apple PR at a time; push only to fix something; yield to duo-support.md in the week before the device ships.

## Not in this plan

- **`RowAnimationState` and the advance targets (old PR 5):** sqlite-mail-store.md's Phase 3, whose gate G2 already allows "its PR 5 merged or folded in" (its line 177). 2.2 decision 7 kept the row animation on the list model until the SQLite store moves rows. There is no lint pressure (97 of 250); six test files and a scan read the state through the model, so forwarders would add lines; and a struct holding the disposal phases would make each phase flip re-run the whole list body, which `DisposingRow` exists to prevent (`DisposingRow.swift:18-22`). shared-load-error-state.md's B4 gate on PR 5 becomes order only.
- **The list write paths (`+Optimistic` prune and restore, `+Bulk`, `+Move`, `+Purge`, `+Flags`):** sqlite-mail-store.md's PR 3.2, which takes them (its line 143). `+Refresh`, `+Search` and `+MarkAllRead` stay as they are: they route to the types 2.2 extracted, and mail-correctness.md and shared-load-error-state.md edit them next.
- **Renaming `layoutIsWide` to `isWideSplit`:** declined. 3.2 decided "The navigator's `layoutIsWide` keeps its name". A rename changes assertion and setter lines in 9 test files and edits three files other plans hold (`ShellHandOff.swift`, `Commands/WindowCommands.swift`, `ListPlaceTracking.swift`), for no behaviour. Reopen only if a plan rewrites those lines anyway.
- **The four tick counters (audit 06 T6, the proposed typed command bus):** checked and closed. Each is a broadcast every window should hear (`App/AppState.swift:69-73`; `Mail/Store/MailSessionStore.swift:38-43`), a per-reader print request (`MessageDetailViewModel.swift:95-97`) or a nonce in a parked restore (`WindowRestores.swift:80-82`), so none has the multi-window fault the audit described (an untyped tick on the shared `AppState` that every observing window reacts to). `moveRequestTick` stays: 3.1 dropped its registry under its brief's condition, "D is dropped if the registry turns out larger than the tick it replaces", at about 43 lines against 23.
- **The open search result across a swap and the dead row after Back (#2033, #2034, open):** ipad-layout-and-keyboard.md, PRs A and B. **Page Up and Page Down in search:** mail-correctness.md.
- **A shared `Debouncer`:** test-debt.md (refresh-scheduling.md's "Not in this plan" sends it there). **The loop type:** refresh-scheduling.md PR 2; `ComposeAutosave` may adopt it later.
- **`LoadState`, and the replacement for `ComposeViewModel.describe`:** shared-load-error-state.md. **The compose close gate and one compose body (FU-5, FU-16):** platform-conditionals.md. **The `try?` local draft save:** hardening-web-and-writes.md PR 5.
- **`MailRootView` comments outside the two navigator files, and closing #1912, #1970 and #1996:** docs-and-bookkeeping.md.
- **Moving logic out of every view (audit 06 F14, handed here by test-debt.md; a count of about 107 `Task` blocks in 84 view files, made while test-debt.md was drafted, did not reproduce, as test-debt.md says, and another rearchitecture count put it at about 120):** not taken as a backlog. F14's own advice is "as views are touched", which is a rule for every plan that edits a view; this plan applies it to the views it edits.
- **Keeping the list model alive across a fold:** the maintainer chose "Anchor only" on 2026-10-09 (Wave 3.3's question 5): each list keeps building its own model, and after a fold the list shows its top until the rebuilt list's first refresh lands, then moves to the user's row. A model shared by the old and new trees during a fold would end up off its poller, with its page loads cancelled.
- **Splitting the `MessageListView` files:** no length pressure (body 122), and scans pin several of them.
- **Heads-ups, not owned here:** `Shared/BodyRendering/HTMLBodyView.swift` is at 500 of `file_length`'s 500, so one more code line fails CI; hardening-web-and-writes.md's PR 3 and platform-conditionals.md's S1 PR 6 edit it and need an extraction first. `FeedItemListViewModel` is at 243 (`Feeds/ItemList/FeedItemListViewModel.swift:27-381`): feed-bulk-actions.md should add its selection in a type of its own. `CabalmailClient` is at 249 (`CabalmailKit/Sources/CabalmailKit/CabalmailClient.swift:9-389`): kit-split.md, hardening-web-and-writes.md PR 5 and test-debt.md.

> **Erratum (2026-10-15):** Hardening PR 3 merged to `stage` as #2057 (`f078467`) without an extraction. It kept `HTMLBodyView.swift` code-line-neutral (one-for-one line changes; `apple/.swiftlint.yml` sets `ignore_comment_only_lines: true`) and extracted no type, so the file stays at its 500-line `file_length` cap and the extraction falls to the next PR that adds a code line there, platform-conditionals.md's S1 PR 6.

## Sources

- `00-working-agreements.md` (this folder) and `../platform-conditionals-followups.md`, FU-5 (Compose window close gate).
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Repo at 50e6022, under `apple/` unless noted: `.swiftlint.yml:1-50`; `CabalmailUI/Navigation/SceneNavigator.swift:47-728`; `FeedNavigationState.swift:19-120`; `TreeGate.swift:11-46`; `Shell/SplitShell.swift:44, 127-131, 181-191`; `Shell/WideMail.swift:59-60, 91`; `Shell/CompactMailStack.swift:30-31, 53`; `Shell/OrnamentShell.swift:128-129`; `Compose/ComposeView.swift:226-357`; `ComposeViewModel.swift:36-43, 156-157, 253-276`; `ComposeViewModel+Internals.swift:359-360`; `Mail/Reader/MessageDetailViewModel.swift:9-26, 95-97, 152-169, 336-378`; `Mail/MessageList/MessageListViewModel.swift:150-165, 297`; `DisposingRow.swift:15-50`; `Mail/Store/FolderPollers.swift:41`; `MailSessionStore.swift:36-43`; `App/AppState.swift:69-73, 87`; `Navigation/WindowRestores.swift:76-82`; `Shared/BodyRendering/HTMLBodyView.swift` (740 lines, 500 counted); `CabalmailKit/Tests/CabalmailKitTestSupport/FakeImapClient.swift:9-354`; `CabalmailTests/ColumnToolbarOccupantsSourceScanTests.swift:109-122`; `ReaderColumnFloorSourceScanTests.swift:10-21`; `SidebarToggleRemovalSourceScanTests.swift:10-16`; `ComposeBodyScrollPolicyTests.swift:177-205`; `MessageListRefreshRoutingTests.swift:60`; `project.yml:681-689`; `docker/templates/in-sendmail.mc:21`; `lambda/api/fetch_message/function.py:67-76`. Git: `5035e28b` (3.3 B), `714b1cdc` (#2007's head), `c1d88c23` (3.2 D), `a587e8b6` (#1912, on main).
- PRs: #2007 (class body 244), #2008 (the width write left on purpose; the tour at 714 and 387 pt, visionOS and the Duo), #2015 (the Duo closed-pose limit; 31 mutations), #2043 (1.31.0, open).

> **Erratum (2026-10-15):** #2043 merged later on 2026-10-12, releasing 1.31.0.

- Issues, read 2026-10-12: open #1903, #1912, #1970, #1996, #2033, #2034, #2037; closed #403, #1535, #1555, #1654, #1664, #1815.
- Sibling plans in this folder, as read on 2026-10-12 (their line numbers, here and above, are from those versions and have since shifted): duo-support.md (:6, 114, 143, 154, 184-185), ipad-layout-and-keyboard.md (:6-7, 85, 132), sqlite-mail-store.md (:6, 143, 146, 177, 203), flags-and-cross-media.md (:6, 153), multi-window-and-restore.md (:6, 162, 197, 211), shared-load-error-state.md (:81-82, 107), hardening-web-and-writes.md (:91, 137), mail-correctness.md (:131), detached-reader-window.md (:144, 192), feed-bulk-actions.md (:91), platform-conditionals.md (:44, 67), refresh-scheduling.md (:66-67, 114-115), test-debt.md (:68, 147), swift6-and-strict-checking.md (:121), docs-and-bookkeeping.md (:45, 50, 98, 133).
