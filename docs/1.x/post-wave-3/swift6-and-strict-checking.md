# Swift 6 mode and strict checking for the app

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Two sequential sessions. Session A clears the app's Swift warnings and turns warnings into errors; session B, started only when the maintainer sends its brief, moves each target to the Swift 6 language mode over two releases. The work is compiler-driven and strictly ordered, with one batch of decisions, no server change and no migration, so a project's parallel threads would buy nothing. If the soak between B's two releases runs long, B may run as two sessions (B-Kit for B1 and B2, B-app for B3); the B-app brief below is written to start cold.
**Size:** M (A is S to M; B is M).
**Priority:** Next, with A1 allowed Now. A1 is one PR: it fixes the six warnings in shipping code and #1841, and turns the gate on for every shipping target, so the app-layer plans starting now (duo-support.md first) cannot add warnings unnoticed. It takes a CI slot only when duo-support.md does not need one. The rest is test code and a language-mode switch with nothing user-visible, so bugs go first.
**Depends on:** nothing hard. Order only: apple-ci-and-build-config.md (its Xcode-change annotation, its decision 2, before or with A4, preferred; one open PR at a time in `apple/Base.xcconfig`); test-debt.md (A2 never open beside its A3 or A4); sqlite-mail-store.md (B2 needs a Kit-quiet window, decision 5).
**Unblocks:** nothing hard. sqlite-mail-store.md prefers session A before its Phase 1; kit-split.md's new targets start in Swift 6 mode if B2 lands first. Order only: test-debt.md (its A3 waits for A2 if this session is running).
**Duo groundwork:** No layout or scene code changes. Duo code already compiles in every CI job (CI builds with the 27.1 SDK), so from A1 on a Duo PR that adds a warning fails `apple-gate`; B3's soak adds a fold and unfold on the Studio's Duo simulator if duo-support.md's fold adapter has landed.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
| --- | --- |
| A0. Thread Sanitizer baseline | Not started (2026-10-15) |
| A1. Shipping code, #1841 and the shipping-target gate | Not started (2026-10-15) |
| A2. Shared wait helper and ignored results | Not started (2026-10-15) |
| A3. The main-actor test pattern and the rest | Not started (2026-10-15) |
| A4. The gate on the test bundles | Not started (2026-10-15) |
| B1. The small targets | Not started (2026-10-15) |
| B2. The Kit | Not started (2026-10-15) |
| Release and soak 1 | Not started (2026-10-15) |
| B3. The app layer | Not started (2026-10-15) |
| Release and soak 2 | Not started (2026-10-15) |
| Decisions 1 to 5 | Unanswered (2026-10-15) |

## Decisions for the maintainer

1. **Should the gate cover Release builds too?** Debug only (**recommended**) / Debug and Release. Debug only: every PR job builds Debug, so a warning still fails before merge, but a runner Xcode change between a PR's run and its merge push can never fail a TestFlight or App Store upload, which archive Release (`apple.yml:842, 1241`). Default: Debug only.
2. **Thread Sanitizer runs?** On a Mac rig at the start of A and after each Swift 6 step (**recommended**) / also a manual-run CI job / a weekly CI job. Rig only costs no CI minutes but depends on a session running it; a CI job would go to apple-ci-and-build-config.md. Default: rig only.
3. **Go on to the Swift 6 language mode?** Yes, as session B after A merges (**recommended**) / stop at warnings as errors. Swift 6 mode adds run-time checks, so a threading mistake in a framework callback crashes instead of racing silently: that finds bugs, but each step needs a soak. B starts only when you send its brief. Default: yes.
4. **Make the app layer assume the main thread unless code says otherwise?** (Xcode's "default actor isolation: MainActor".) Not now (**recommended**) / yes, as its own PR after B3. Not now keeps today's explicit marks and behaviour, so the language mode is the only change in its release. Xcode's related "approachable concurrency" setting, which changes where some async functions run, is out either way. Default: not now, and session B files an issue so the option is not lost.
5. **When does the Kit move to Swift 6 mode (B2)?** Before sqlite-mail-store.md's Phase 1 (**recommended**) / in a gap between its phases / after that project. Before: the new store code runs under the run-time checks from its first release, and B2's short Kit freeze falls between SQLite's Phase 0 and Phase 1, when the Kit should be quiet (inferred; hardening-web-and-writes.md's Kit PRs must not be open either). Default: before Phase 1 if session A has soaked by then; otherwise the first gap the SQLite coordinator announces.

Defaults the sessions take unless you object: every Xcode target is gated, test bundles from A4 on (#1842's tester and audit 05 both assume this); deprecations stay warnings, as in the Kit since PR #1844; no source-scan expectation or anchor changes, and if one must, the session stops and asks with the diff (`ContentColumnWidthDeferralSourceScanTests` and the Kit's `AsyncStreamTerminationCaptureScanTests` pin concurrency shapes B may touch); A's PRs carry `no-changelog`; each of B's two releases gets one `Apple:` fragment so the TestFlight notes ask testers to report any crash.

## What you'll see change

Session A rides any release, since it changes nothing at run time:
- **A1, shipping-code warnings, #1841, gate on shipping targets:** nothing visible. Builds lose 66 asset-catalog warnings and 6 compiler warnings, and a PR that adds a Swift warning to app code fails `apple-gate`. Watch colours do not change.
- **A2 and A3, test-bundle warnings:** nothing visible; test code only.
- **A4, gate on the test bundles:** nothing visible. A PR that adds a warning to a test fails `apple-gate`.
- **Thread Sanitizer baseline:** nothing visible unless it finds a race, which becomes a bug issue for the plan that owns the file.

Session B, two releases:
- **B1 and B2 (one release):** notification extensions, Safari extensions, watch and Kit in Swift 6 mode. Nothing visible intended; a hidden threading mistake in that code now crashes, and the soak looks for one.
- **B3 (next release):** the app layer, both apps and both test bundles. As above, for the app.

## Why

- **Nothing stops warnings in the app.** `apple/project.yml:42` sets `SWIFT_VERSION: "5.10"` and `:49` sets `SWIFT_STRICT_CONCURRENCY: complete`. Nothing in `apple/`, `.github/` or `scripts/` sets `SWIFT_TREAT_WARNINGS_AS_ERRORS`. Audit 05 F17 (audit 05 is the rearchitecture's 2026-10-02 audit of the Apple targets, build configuration and CI; F17 sized the Swift 6 migration) flagged it: "`SWIFT_TREAT_WARNINGS_AS_ERRORS` is not set, so warnings may have built up unseen." The 1.0 packaging note (Wave 1.0's scope note on how to package `CabalmailUI`) said to "add app warnings-as-errors in a later PR". No later workstream did.
- **The count is climbing, and new code adds warnings nobody fails on.** On 2026-10-05 #1842's tester counted 50 distinct warnings in the macOS test bundle and 4 in the iOS app, under Xcode 27.0. On 50e6022 the macOS test job shows 182 distinct warnings, about three and a half times as many. Part of the rise may be the newer compiler CI now uses; much of it is test code added since, such as the 20 `SceneNavigator*` test files of 2026-10-08 to 10-10 (inferred). Before this, warnings from new code were found and hand-fixed one issue at a time: #1507 (RSS phase 5b, closed 2026-09-13) and #1624 (the Mac divider drag, closed 2026-09-29).
- **Toolchains add warnings too.** #1761 (closed 2026-09-30) was Xcode 27's implicit-strong-capture warning. The two warnings at `PlainTextBodyView.swift:36-37` appear in CI on 27.1 beta 1 but not in the tester's 27.0 build of the same file (inferred, high confidence).
- **The Kit already has the gate.** PR #1844 (0.7, merged 2026-10-05, requested by the maintainer) set `checkedSettings` (`apple/CabalmailKit/Package.swift:13-18`): Swift 5 mode, complete checking, every warning an error except deprecations. The app is the gap.
- **Swift 6 mode is the planned end state.** Audit 05 WS-C (its "Kit strict concurrency on, then Swift 6 readiness" workstream): "try `SWIFT_VERSION: 6` per target, starting with the NSE and Watch (small), then Kit, then the apps". 0.7 left it "outside the stated scope", which was a scope line, not a decline. Swift 6 mode also turns on run-time isolation checks (Swift's SE-0423), which catch callback threading mistakes compile-time checking cannot see.
- **Thread Sanitizer.** Audit 06 S7 (audit 06 is the 2026-10-02 audit of the Apple tests and robustness; S7 is its safety-net step before Kit concurrency hardening) asked to "Run the existing Kit suite under TSan in CI once", and T3 (its Kit strict-concurrency and logging workstream) made a clean run an exit check. It ran once, on the Mini under 27.0 during 0.7 (PR #1844: Kit "green again under Thread Sanitizer with no reports"). It never ran in CI or on the app-layer suite. Since #1844's head (`c040b8b7`) the Kit sources changed in 49 files (+1,842/-293), and the app-layer suite grew from 1,292 tests to 2,107.

## Where things stand

**Compilers.** Apple CI run 38192104714 (PR #2043, the 1.31.0 promotion, building 50e6022): `XCODE_VERSION: 'latest-stable'` (`.github/workflows/apple.yml:71`) selected "Xcode 27.1.0 (27A9269)" from `/Applications/Xcode_27.1_beta.app` on runner image xcode-27-arm64 20261006.0244.1. That is 27.1 beta 1; the image carries it without a beta flag, so `setup-xcode` treats it as stable, and the comment at `apple.yml:46-54` ("skips the betas") is wrong. Per duo-support.md, CI has used it since at least 2026-09-25 and Apple's 27.1 RC (27A9275) was out by 2026-10-07, so the next runner image may change the compiler under unchanged code. The Studio is recorded with 27A9269 beside a default 27.0; the working agreements also mention a 27.2 beta there. The Mini had 27.0 on 2026-10-05 (#1842 tester, PR #1844). So the Studio, not the Mini, is the rig known to match CI; re-check both.

**Warnings in run 38192104714** (distinct = unique message-and-snippet pairs; raw logs repeat warnings):

| CI job | Raw / distinct | Where |
|---|---|---|
| Test app layer (macOS) | 244 / 182 | 180 in about 48 files under `apple/CabalmailTests/` (file attribution inferred by matching snippets), plus 2 in `PlainTextBodyView` |
| Test app layer (iOS) | 6 / 6 | `ContactsPickerAffordance.swift:84` (2), `PlainTextBodyView.swift:36-37` (2), `IntentSupport.swift:94-98` (2) |
| Build visionOS | 4 / 4 | `ContactsPickerAffordance` (2), `PlainTextBodyView` (2) |
| Build watchOS, Kit tests | 0 | The Mac app, NSEs and Safari extensions also compile clean. Any Kit Swift warning is already an error; actool's 66 (#1841) do not show through xcbeautify |

Test-bundle families (distinct pairs, recounted from the log):
- 93: main-actor properties read or written from a nonisolated context, mostly `@MainActor` test classes whose `setUp()`/`tearDown()` overrides are nonisolated because XCTest's are, across about 22 classes. Example: `apple/CabalmailTests/SceneNavigatorVisionTests.swift:9-24`.
- 33: unused `Task.value` results of type `MailMutationService.FlagOutcome` or `RemovalOutcome`, from tests that write `await mutations.setFlag(...).value` (for example `MessageListPillCountTests.swift:47-52`). `setFlag` and `remove` already carry `@discardableResult` (`MailMutationService.swift:116, 206`); it does not reach `.value`.
- 29: "sending value of non-Sendable type" closures, mostly passed to the shared `waitUntil`, whose closure is nonisolated (`CabalmailKitTestSupport/WaitUntil.swift:14-19`; a main-actor variant exists at `:40`).
- 11: calls to main-actor methods or initializers from nonisolated helpers.
- 7: "consider using asynchronous alternative function", the seven `view.evaluateJavaScript(..., completionHandler: nil)` calls in async tests at `ReaderScrollBridgeTests.swift:58, 78, 91, 96, 98, 126, 129`.
- 7 others: three `weak var` never mutated, two needless `await`, one unused value, one main-actor default value.
- 32 distinct pairs (36 raw lines) say "this is an error in the Swift 6 language mode". As #1842's tester noted, every warning must go before the gate, not only those.

Shipping-code sites:
- `apple/Cabalmail/Intents/IntentSupport.swift:94-98` (iOS only): the `requestToContinueInForeground` closure is sent as a non-Sendable `@MainActor () async -> Bool`, and it `await`s a synchronous call.
- `apple/CabalmailUI/Compose/Recipients/ContactsPickerAffordance.swift:84` (iOS, visionOS): `UIApplication.shared.open` inside nonisolated `ContactsPrivacySettings.open()` (`:75-89`). Its only caller is a view (`RecipientFieldWithSuggestions.swift:117`).
- `apple/CabalmailUI/Shared/BodyRendering/PlainTextBodyView.swift:36-37` (all platforms): "cannot form key path that captures non-Sendable type" for `attributed[range].link` and `.underlineStyle`, the attribute-scope key paths behind those dynamic-member setters. Not an isolation problem. `PlainTextLinkDetector.scan` is also called synchronously from the nonisolated `PlainTextLinkDetectorTests` (`apple/CabalmailTests/PlainTextLinkDetectorTests.swift:21-93`), so marking it `@MainActor` would move warnings into that test.
- #1841: `scripts/generate-color-tokens.py:134` emits a watch high-contrast entry for each of the 66 colour sets. The tester's experiment (removing it from one set took the count from 66 to 65) shows that entry causes the warning; the tester reasons that deleting `:134` clears all 66 and changes no rendering, because actool never places the entry and the watch already falls back to its plain value. Count with `swift package clean && swift build 2>&1 | grep "unassigned child" | sort -u | wc -l` in `apple/CabalmailKit`; the issue's own recipe gives 0 or 264.

Swift 6 readiness:
- Escape hatches in shipping code: 5 `@unchecked Sendable` (`ConfigLoader.swift:95`, `ResumeSession.swift:194` and `PushEnrichmentStore.swift:26` wrap only `UserDefaults`; `NotificationService.swift:118` and `WatchSessionBridge.swift:24` are lock-guarded), no `nonisolated(unsafe)`, 5 `@preconcurrency import WebKit` in `CabalmailUI` (`HTMLBodyView.swift:2`, `+LinkBridge.swift:2`, `+ScrollBridge.swift:2`, `ArticleWebView.swift:3`, `RichTextEditorView.swift:3`), and 1 `MainActor.assumeIsolated` (`Shell/DesktopShell.swift:154`, pinned by `ContentColumnWidthDeferralSourceScanTests`).
- `NotificationService.swift:59-66` accepts a spurious region-isolation warning "until a toolchain fixes the checker or the Swift 6 language-mode migration forces the issue". CI compiled that file with no warning, so the toolchain seems to have fixed it (inferred, medium-high).
- `CabalmailMacTests` compiles the Kit's TestSupport sources itself (`project.yml:681-690`), so `WaitUntil.swift` is checked under both the Kit's and the app's settings.
- The second Xcode project, `extensions/safari/project.yml:24`, also says Swift 5.10 with complete checking: two Swift files, built by `extensions.yml` on `macos-26`, store uploads not yet wired. `apple/Tools/SimDrive/project.yml:23` says 5.10 too; CI never builds it.
- Issues: #1842 and #1841 are open (bug, apple, verified; locked), with no linked PR.

## The plan

**Working method.** Count and iterate with the Xcode CI uses (read "Xcode is set to" in the latest Apple run; 27A9269 today), chosen per command with `DEVELOPER_DIR`, never `xcode-select`. If the Mini still has only 27.0, ask the maintainer to install CI's Xcode there, or build on the Studio over Remote Control: command-line builds need no screen, so they can run beside Duo work, but `app-test` and the app-layer TSan run host `Cabalmail.app` and need the logged-in GUI session, so first check that the maintainer's tester is not using it. Use `scripts/build-apple.sh` (`app-test`, `ios-app-test`, `visionos`, `watchos`) into a fresh `-derivedDataPath` outside the repo, count distinct `file:line:col`, and push only when the local count is zero. Each Apple PR run costs about six macOS jobs.

### Session A: the gate (rides any release)

- **A0, Thread Sanitizer baseline (rig, no PR).** Kit: `swift test --sanitize=thread` in `apple/CabalmailKit`. App layer: `xcodebuild test -scheme CabalmailMac -enableThreadSanitizer YES`, and if time allows the iOS-hosted suite on a simulator the same way. Reproduce any report twice, then file each real race as a bug with its stack and route it to the plan that owns the file (mail-correctness.md, refresh-scheduling.md and so on). Races do not block A; they gate B's start. Post the result on A1's PR. Triage benign races in test scaffolding rather than suppressing them.

  **Status:** Not started (2026-10-15).

- **A1, shipping code, #1841 and the shipping-target gate (one PR, three commits).** (1) `ContactsPrivacySettings.open()` becomes `@MainActor`. `PlainTextLinkDetector.scan` stops using the dynamic-member key paths: set the attributes through explicit key types (`attributed[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url`, and SwiftUI's `UnderlineStyleAttribute` likewise), which form no key path; `mergeAttributes(AttributeContainer()...)` may not help, since its builder also uses key paths (inferred). Drop the needless `await` in the intent closure and make it `@MainActor @Sendable` if the compiler still asks (needs a 27A9269 compile to confirm). (2) Delete `generate-color-tokens.py:134`, fix its comment at `:131-132`, regenerate the 66 colour sets under `apple/CabalmailKit/Sources/CabalmailKit/Design/ColorTokens.xcassets`; `ColorTokensDriftTests` and `scripts/tests/test_check_color_tokens.py` prove the catalog matches. (3) The gate, as in A4, with `SWIFT_TREAT_WARNINGS_AS_ERRORS: NO` set temporarily on the `CabalmailMacTests` and `CabalmailiOSTests` targets in `project.yml` until A4. Verify: iOS and visionOS jobs show no warning outside test files; a clean `swift build` shows 0 "unassigned child"; existing suites, including `PlainTextLinkDetectorTests`, stay green. `no-changelog`. Risk: low. Optional check on the stage TestFlight build: create an address with Siri while the app is in the background, accept "Continue in Cabalmail", and paste it.

  **Status:** Not started (2026-10-15).

- **A2, shared wait helper and ignored results.** Give `waitUntil` the caller's isolation (an `isolation: isolated (any Actor)? = #isolation` parameter, so a main-actor test's closure stays on the main actor), or move main-actor callers to `waitUntilOnMainActor`; pick whichever clears more warnings without changing what any test waits for. At the 33 unused `.value` results write `_ =`, or assert the outcome where the outcome is what the test is about. Files: `WaitUntil.swift`, its forwarder `CabalmailKitTests/TestHelpers.swift:21-26`, about 15 test files. The Kit's tests compile `WaitUntil.swift` with warnings as errors, so CI checks it under both settings. `no-changelog`.

  **Status:** Not started (2026-10-15).

- **A3, the main-actor test pattern and the rest.** Try one fix on one file first (for example `override func setUp() async throws`, or building the fixture inside each test), then apply it. Replace the seven completion-handler `evaluateJavaScript` calls with awaited ones: `callAsyncJavaScript` or `evaluateJavaScript(_:in:contentWorld:)`, which return `Any?` and cope with `window.scrollTo` returning undefined (the plain async `evaluateJavaScript(_:)` may throw on that, inferred); check that awaiting the scroll does not change what the tests prove about the bridge's timing. Split by folder if the diff passes about 40 files. The macOS test count must not drop (2,107 at 50e6022). `no-changelog`.

  **Status:** Not started (2026-10-15).

- **A4, the gate on the test bundles.** Re-measure on current stage and fix stragglers in the same PR, since the app-layer plans add tests daily. Remove A1's two temporary `NO` lines. The gate itself (written in A1): `SWIFT_TREAT_WARNINGS_AS_ERRORS[config=Debug] = YES` in `apple/Base.xcconfig`, above its `#include? "Local.xcconfig"` line (`:21`), not in `project.yml`, so a rig on a newer beta can switch it off in its gitignored `Local.xcconfig` (project-level settings in `project.yml` would beat the xcconfig). Deprecation exemption: `-Wwarning DeprecatedDeclaration` in `OTHER_SWIFT_FLAGS[config=Debug]`; confirm in the build log that swiftc gets it after `-warnings-as-errors`, as 0.7 did for the Kit. First check whether Xcode 27 has a build setting for Swift diagnostic groups (unverified). If the order cannot be controlled, put both flags in `OTHER_SWIFT_FLAGS` through one xcconfig variable that `Local.xcconfig` can blank; if that fails too, ask the maintainer whether deprecations become errors. Confirm with `xcodebuild -showBuildSettings` that every target resolves to YES in Debug and NO in Release, and that no XcodeGen preset sets it. Prove the gate on the rig (add a warning, see the build fail); no red scratch push to CI. Docs: one paragraph in `docs/apple.md` by `:963-968` (the setting, the exemption, Debug only, the local switch) and one line in `CLAUDE.md`'s Apple section. Closes #1842 (A1 closes #1841); the soak verifies both, and the release dashboard holds Promote until they are closed. `no-changelog`.

  **Status:** Not started (2026-10-15).

### Session B: Swift 6 language mode (two releases)

Before starting: A has soaked; A0's races are fixed or triaged; no PR is open under `apple/CabalmailKit/Sources` (B2 needs a short Kit freeze, announced to sqlite-mail-store.md's coordinator); `Package.swift` and `project.yml` have no open PR.

- **B1, the small targets.** Target-level `SWIFT_VERSION: "6.0"` on `CabalmailNotificationService`, `CabalmailMacNotificationService`, `CabalmailWebExtension`, `CabalmailMacWebExtension` and `CabalmailWatch`. The watch compiles two `CabalmailUI` files by path (`project.yml:378-379`); they compile in Swift 6 mode there and Swift 5 mode in `CabalmailUI` until B3, which is harmless. Once the build shows no diagnostic, delete the stale comment at `NotificationService.swift:59-66`. Also `extensions/safari/project.yml:24` (two files), without a warnings gate there, since that workflow runs Xcode 26. Risk: low (inferred).

  **Status:** Not started (2026-10-15).

- **B2, the Kit.** In `Package.swift:13-18`, `.swiftLanguageMode(.v6)` and drop `.enableUpcomingFeature("StrictConcurrency")`, which Swift 6 implies; keep `treatAllWarnings` and the exemption; rewrite the comment at `:4-12`. This also moves `CabalmailShared`, which the extensions link. Check the three `UserDefaults`-only `@unchecked Sendable` types against the current SDK and drop the exemption if `UserDefaults` is now `Sendable`. Rerun the Kit suite under TSan.

  **Status:** Not started (2026-10-15).

- **Release and soak 1.** B1 and B2 share a release. That bends "one structural change per release"; it is accepted because both are the same one-line kind of change and a crash stack names its module (an extension, the watch, the Kit or `CabalmailShared`). If the maintainer prefers, they ship one release apart. By-hand checks on the stage TestFlight build: a push arrives enriched on iPhone and on Mac; the watch gets its token after sign-in and clears on sign-out (its `WCSessionDelegate` runs on the session's queue, `CabalmailWatch/WatchSessionRelay.swift:34-60`); each Safari web extension (iOS, Mac) creates an address; a compose reply loads and links in it do not navigate (`RichTextEditorController.swift:498-506`); a network drop and return; a request in flight when the app goes to the background; a Contacts change while the app runs.

  **Status:** Not started (2026-10-15).

- **B3, the app layer.** First commit: a test like the Kit's `RichTextEditorNavigationPolicyTests` that asks the Objective-C runtime whether WebKit still sees each app-layer delegate method: `HTMLBodyCoordinator` (`HTMLBodyView.swift:361, 402`), `ArticleWebCoordinator` (`ArticleWebView.swift:176-207`) and the two script-message relays (`HTMLBodyView+LinkBridge.swift:116`, `+ScrollBridge.swift:116`). PR #1844 found a concurrency change had made the composer's `decidePolicyFor` stop matching, so "WebKit would have allowed every navigation"; for the reader that would let a mail link navigate in place instead of opening the link menu. Then project-level `SWIFT_VERSION: "6.0"` at `project.yml:42`, removing B1's per-target lines; this moves `CabalmailUI`, both apps and both test bundles. Expect few compile errors after A (inferred: Swift 6 mode turns complete-checking warnings into errors, and A leaves none). Review `WatchSessionBridge.swift:24` and drop each `@preconcurrency import WebKit` the compiler no longer needs. Reword `ComposeViewModel.swift:251` ("Swift 5.10 strict concurrency makes `deinit` nonisolated"; still true in Swift 6 mode without an isolated deinit). Rerun the app suite under TSan. Decision 4, if yes, is its own PR after this one.

  **Status:** Not started (2026-10-15).

- **Release and soak 2.** By-hand checks: notification actions and taps (`AppDelegate.swift:164` onward, delegate methods at `:176` and `:211`); the watch again; the Siri address intents; Contacts and Calendar sheets from the reader; reader link taps open the link menu; a feed article loads in the article view; the Mac compose-window close prompt; the Mac column-divider drag (`DesktopShell.swift:154`); trackpad swipe and column resize on iPad; if duo-support.md's fold adapter has landed, fold and unfold on the Studio's Duo simulator.

  **Status:** Not started (2026-10-15).

**During both soaks,** look for crashes in TestFlight's crash reports (App Store Connect or Xcode's Organizer) and in Settings, Debug Log, where the opt-in MetricKit collector writes crash reasons (`MetricKitCollector.swift:85-92`). A crash whose stack shows an executor or queue assertion is the run-time check firing (inferred). File it as a bug. If its fix is not ready before Promote, revert that one target's `SWIFT_VERSION` line and keep the bug open.

**Hotspots, one open PR at a time each:** `apple/Base.xcconfig` (A1, A4; apple-ci-and-build-config.md's PR C also inserts above the include line, either order); `apple/project.yml` (A1, A4, B1, B3; apple-ci-and-build-config.md, kit-split.md, platform-conditionals.md, test-debt.md A6); `apple/CabalmailKit/Package.swift` (B2; kit-split.md, sqlite-mail-store.md, apple-ci-and-build-config.md's floor change); `scripts/generate-color-tokens.py` and `ColorTokens.xcassets` (A1; kit-split.md PR B re-points them); `PlainTextBodyView.swift` and `ContactsPickerAffordance.swift` (A1; platform-conditionals.md S1 PRs 4 and 6); `IntentSupport.swift` (A1; shared-load-error-state.md A5); `NotificationService.swift` (B1; account-isolation.md D); `CabalmailKitTestSupport/*` (A2; test-debt.md A3, A4); the navigator test files (A2, A3; multi-window-and-restore.md, mail-navigation-refactors.md); `HTMLBodyView*.swift` and `ArticleWebView.swift` (B3; hardening-web-and-writes.md); `docs/apple.md` and `CLAUDE.md` (A4; docs-and-bookkeeping.md, apple-ci-and-build-config.md, duo-support.md PR 7). This plan does not edit `.github/workflows/`.

> **Erratum (2026-10-16):** duo-support.md's `docs/apple.md` work is its PR 11 (Duo docs); its PR 7 is compose as a sheet. Read PR 11 where this hotspot list says PR 7 for `docs/apple.md`.

## Background from the rearchitecture

What session A's brief used to point at in the rearchitecture's records, stated here so the session needs nothing outside the repo. Audits 05 and 06 are two of the seven audits of the Apple code made on 2026-10-02 at the start of the rearchitecture, read-only and with nothing compiled.

- **Audit 05 F17, "Swift 6 language-mode migration: likely low cost in the app layer, unknown in the Kit".** Audit 05 covered the targets, build configuration, platform extensions and CI. F17, from static counts with no build: the app layer was fully on Observation and already compiled under `complete` checking; the NSE documented one region-isolation warning it could not silence; and "`SWIFT_TREAT_WARNINGS_AS_ERRORS` is not set, so warnings may have built up unseen. I could not build to count them." Estimate: app layer S-M, "mostly turning existing `complete` warnings into errors and fixing them"; Kit M until F2 (the Kit not being covered by complete checking, fixed in 0.7 by PR #1844) was fixed and the diagnostic count known. Optionally, Swift 6.2's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for the UI module (decision 4 here). Confidence medium; severity low (not urgent), "but it is a prerequisite for strict hygiene".
- **Audit 05 WS-C, "Kit strict concurrency on, then Swift 6 readiness".** Scope: strict-concurrency `swiftSettings` in `Package.swift` and its test target, fix the diagnostics, review the Kit's `@unchecked Sendable` types (actors or `Mutex` where practical), "Then try `SWIFT_VERSION: 6` per target, starting with the NSE and Watch (small), then Kit, then the apps." Risk medium (actor-isolation changes in networking and auth); size M for the Kit, S-M for the app. Verification: "zero warnings with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` on all 4 platform builds" and the Kit suites green.
- **Audit 06 S7 and T3.** Audit 06 covered the tests and robustness. S7, in its list of characterization tests to add before each workstream, was the step before Kit concurrency hardening: "Run the existing Kit suite under TSan in CI once; add a SendQueue/Outbox concurrent enqueue+drain test". T3, its Kit strict-concurrency and logging workstream, set the verification "Zero concurrency warnings; TSan run of Kit suite clean".
- **The 1.0 packaging note.** Wave 1.0's scope note on how to package `CabalmailUI` recommended a static XcodeGen target, then SwiftPM later with the Kit split. Such a target inherits `project.yml`'s `:42` and `:49`, "so the app layer can't quietly lose `complete` checking; that is the trap 0.7 fixes for the Kit". Warnings as errors there is opt-in, through `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` plus a flag to keep deprecations as warnings (inferred). Because containers have no Swift toolchain and each try costs a PR run, it said to make commit 1 a one-file spike that proves the link, `@testable`, all 4 builds and both test bundles, "and add app warnings-as-errors in a later PR"; SwiftPM was the choice "if the owner wants warnings-as-errors and `swift test` for the UI layer" at once.

## How to start it

Session A, paste-ready:

> Run session A of swift6-and-strict-checking.md for the Cabalmail Apple clients: clear every Swift warning in the Xcode app targets and test bundles, fix #1841, and turn on warnings as errors (Debug only unless the maintainer says otherwise). Read 00-working-agreements.md and the plan first (both in docs/1.x/post-wave-3/), and re-check every file:line. The maintainer's answers to the plan's decisions: [paste]. Read "Xcode is set to" in the latest Apple CI run and use exactly that Xcode on the rig, per command with DEVELOPER_DIR; the Mini had only 27.0 on 2026-10-05, so check it or use the Studio for command-line builds. Re-measure on current stage (distinct file:line:col from a fresh -derivedDataPath outside the repo) and compare with the plan's table, then run the Thread Sanitizer baseline (A0). Write a short scope doc with the PR list and post it, then open A1. No Swift toolchain in this container: iterate on the rig and push only clean branches. Never change a source scan's text or anchor; stop and ask instead.

The session reads this plan and `00-working-agreements.md` from `docs/1.x/post-wave-3/`. Point it at "Background from the rearchitecture" above (audit 05 F17 and WS-C, audit 06 S7 and T3, the 1.0 packaging note), issues #1841 and #1842 (read both tester comments) and PR #1844. Rigs: the Mac mini or the Studio over Remote Control, with GUI time for `app-test` and the TSan run. A stage account is needed only for the optional Siri check.

Session B (or B-Kit), paste-ready:

> Run session B of swift6-and-strict-checking.md: move the Apple targets to the Swift 6 language mode in the plan's order (B1 and B2 in one release, B3 in the next). Session A merged as [PRs] and soaked clean in [release]; A0's TSan races are [fixed / issue numbers]. The maintainer's answers to decisions 3 to 5: [paste]. Before B2, check that no PR is open under apple/CabalmailKit/Sources, Package.swift or project.yml, and announce the Kit freeze to the SQLite project's coordinator if it is running. Use the Xcode CI uses, per command with DEVELOPER_DIR. Run the Kit and app suites under Thread Sanitizer after each step. Do not edit ContentColumnWidthDeferralSourceScanTests or AsyncStreamTerminationCaptureScanTests, or any other scan; if Swift 6 mode forces a change there, stop and ask with the diff. Add one Apple: changed fragment per release asking testers to report crashes. After each release, put the plan's soak list on the maintainer's checklist and watch TestFlight crash reports and the Debug Log. If a run-time check crashes and no fix is ready before Promote, revert that target's SWIFT_VERSION line and keep the bug open. File issues for decision 4 (if "not now") and for an isolated deinit in ComposeViewModel.

For a separate B-app session, use the same brief with "Run B3 only; B1 and B2 shipped in [release] and soaked clean". The session reads this plan and `00-working-agreements.md` from `docs/1.x/post-wave-3/`; give it session A's scope doc and PR numbers, and B1/B2's PRs.

## Risks and checks

1. **A runner image brings a new Xcode and unchanged code fails.** Likely soon, since CI is on 27.1 beta 1 and the RC is out. With the Debug-only gate this turns PRs red, never an upload; the fix is a small PR. apple-ci-and-build-config.md's annotation (its decision 2) shows the change the day it happens. If the image changes during session A, re-measure before A4.
2. **A rig on a different Xcode miscounts.** The Mini on 27.0 would miss the 27.1-only `PlainTextBodyView` warnings. Check: compare `xcodebuild -version` with CI's before every count.
3. **The local switch does not cover the Kit.** `Package.swift`'s `treatAllWarnings` cannot be switched off in `Local.xcconfig`, so a newer beta's Kit warning already stops a local Kit build (true since #1844). The switch helps only the Xcode targets, on a rig ahead of CI.
4. **Silencing instead of fixing.** No new `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency` or `MainActor.assumeIsolated` without a comment saying why it is sound. Each PR body states the counts against the table above.
5. **Run-time checks crash in callbacks.** Mitigated by two releases, the soak lists, TSan runs and the one-line per-target revert.
6. **Duo work meets the gate.** duo-support.md's optional `ios-duo` leg builds with the same Xcode, so a warning in Duo code fails it too (that leg sits outside `apple-gate`). The Duo coordinator should expect this.
7. **Hotspot collisions and CI capacity.** A2 and A3 touch files that test-debt.md and the navigation plans also edit; run them when those plans have no open PR on the same files. Push clean branches only and let outdated runs cancel.

## Not in this plan

- A TSan job in CI (decision 2's other options), the Xcode choice and its change annotation, the wrong comment at `apple.yml:46-54`, SwiftLint pinning, making `apple-gate` required, and whether to revive the Studio's 27.x forward-compat sweep (#851, open, last digest 2026-09-24) as an early warning for the next beta: apple-ci-and-build-config.md.
- Swift settings for new Kit targets (they reuse `checkedSettings`) and moving `CabalmailUI` into SwiftPM: kit-split.md (its decision 6 recommends no).
- Test refactors beyond what clearing the warnings needs (local wait helpers, scan triage, `FakeImapClient`'s size): test-debt.md.
- The reader's and composer's web-content rules: hardening-web-and-writes.md. B3 adds only the delegate-visibility test.
- Moving the NSE's `DeliveryState` lock to `Mutex`: an optional refactor with no defect behind it.
- SimDrive's Swift 5.10 setting: a hand-run tool CI never builds.
- An isolated `deinit` for the compose autosave loops, and main-actor default isolation if the maintainer answers "not now": no plan owns them; session B files an issue for each so they are not lost.
- Watch Increase Contrast: actool has no slot for it, so there is nothing to build.

## Sources

- Repo at 50e6022: `apple/project.yml:40-49, 366-381, 441, 506, 558, 624, 681-735`; `apple/Base.xcconfig:1-21`; `apple/CabalmailKit/Package.swift:1-18, 60, 78, 89, 95`; `apple/Cabalmail/Intents/IntentSupport.swift:84-100`; `apple/CabalmailUI/Compose/Recipients/ContactsPickerAffordance.swift:72-89`; `apple/CabalmailUI/Shared/BodyRendering/PlainTextBodyView.swift:17-53, 92`; `apple/CabalmailTests/PlainTextLinkDetectorTests.swift:7-93`; `apple/CabalmailTests/ReaderScrollBridgeTests.swift:58-129`; `apple/CabalmailTests/SceneNavigatorVisionTests.swift:9-24`; `apple/CabalmailTests/MessageListPillCountTests.swift:43-53`; `apple/CabalmailUI/Mail/Store/MailMutationService.swift:116-123, 206-213`; `apple/CabalmailKit/Tests/CabalmailKitTestSupport/WaitUntil.swift:10-44`; `apple/CabalmailKit/Tests/CabalmailKitTests/TestHelpers.swift:21-26`; `apple/CabalmailKit/Tests/CabalmailKitTests/RichTextEditorNavigationPolicyTests.swift`; `apple/CabalmailNotificationService/NotificationService.swift:55-70, 118`; `apple/CabalmailWatch/WatchSessionRelay.swift:25-62`; `apple/CabalmailUI/Platform/Services/WatchSessionBridge.swift:24`; `apple/CabalmailUI/Platform/Services/AppDelegate.swift:164-211`; `apple/CabalmailUI/Shared/BodyRendering/HTMLBodyView.swift:309-402`; `apple/CabalmailUI/Feeds/Reader/ArticleWebView.swift:94-207`; `apple/CabalmailKit/Sources/CabalmailKit/Compose/RichTextEditorController.swift:498-523`; `apple/CabalmailKit/Sources/CabalmailKit/Logging/MetricKitCollector.swift:85-92`; `apple/CabalmailUI/Shell/DesktopShell.swift:150-157`; `apple/CabalmailUI/Compose/ComposeViewModel.swift:248-252`; `scripts/generate-color-tokens.py:126-136`; `scripts/build-apple.sh:15-34`; `.github/workflows/apple.yml:40-71, 467-481, 839-842, 1238-1241`; `extensions/safari/project.yml:22-30`; `docs/apple.md:961-968`; `CLAUDE.md:83-92`.
- CI: run 38192104714 (PR #2043): jobs 114626873626 (macOS app tests; 244 raw, 182 distinct warnings, recounted 2026-10-12), 114626873483 (iOS app tests; Xcode path and 6 warnings), 114626873544 (visionOS; 4), 114626873522 (watchOS), 114626873517 and 114626873503 (Kit); six macOS jobs plus `apple-gate` on ubuntu. Run 38084273190 (2026-10-10).
- GitHub (checked 2026-10-12): #1842 and #1841 open, with the 2026-10-05 tester comments; PR #1844 merged 2026-10-05; #1507, #1624 and #1761 closed; #851 open.
- `00-working-agreements.md` in this folder.
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Sibling plans in this folder: duo-support.md (CI Xcode history, the `ios-duo` leg), kit-split.md (decisions 4 and 6, PR B, hotspots), sqlite-mail-store.md (Depends on, decision 7, Phase 1 timing), platform-conditionals.md, shared-load-error-state.md, account-isolation.md and hardening-web-and-writes.md (hotspot tables); apple-ci-and-build-config.md (decision 2, PR C) and test-debt.md (A3, A4).
