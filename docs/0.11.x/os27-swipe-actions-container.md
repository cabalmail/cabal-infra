# OS 27 Swipe Actions Container Adoption Plan

## Context

iOS 27's `.swipeActionsContainer()` brings swipe actions to any view in a
scroll container, no longer `List`-only — and it **fixes the iPad
leading-swipe defect that was closed as a structural won't-fix in June
2026**, including with the folder sidebar persistently tiled.

That defect forced three compromises still in the tree today:

1. The iPad folder sidebar cannot tile persistently.
   [MailRootView.swift](../../apple/Cabalmail/Views/MailRootView.swift)
   pins `columnVisibility` to `.doubleColumn` and floats a hand-built
   `folderPanelOverlay` over the message list instead, purely so the list
   stays the leftmost tile.
2. Every loaded message row embeds a single-row `List` solely to borrow
   native `.swipeActions`
   ([SwipeActionRow.swift](../../apple/Cabalmail/Views/SwipeActionRow.swift)),
   which also forces `.draggable` to sit *outside* that wrapper because
   the inner `List` swallows a drag placed within its row.
3. Because a stack of UICollectionView-backed per-row `List`s is
   expensive to lay out, rows collapse to a cheap placeholder while
   `scenePhase == .background`, to dodge a scene-update watchdog kill.

Removing the embedded `List` unwinds all three.

## Machine and toolchain constraint

**Local work must be done on the Mac Studio.** It is the only machine
with the Xcode 27 beta toolchain and the iOS/iPadOS 27 simulator
runtimes, so all interactive investigation — reduction-harness runs,
simulator driving, screenshots — happens there. The Mac mini runs
Xcode 26.

The compile rule that drives everything else: **Xcode 26 cannot compile
the iOS 27 SDK even behind `#available`**, because the availability check
needs the SDK to declare the symbols. Gating the *code* does not make it
buildable on an older SDK.

### CI can build it today, on a preview image

GitHub ships a dedicated **`xcode-27` runner image**, announced
[actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404)
on 2026-07-16 (`runs-on: xcode-27`, also `xcode-27-xlarge`). As of the
2026-07-28 image refresh it carries Xcode **27.0 beta 4, build
`27A5228h`** — the same build the measurements below were taken on — the
full 27.0 SDK set, and iOS/tvOS/watchOS/visionOS 27.0 simulator runtimes.

So "CI cannot build OS 27 code" is **no longer true**. Three properties
of that image shape how it can be used:

- **It is a preview.** GitHub warns that software may be unstable and
  that capacity is still being balanced, so queueing delays are expected.
- **It ships exactly one Xcode** (the 27 beta), with `Xcode.app` pointed
  at it. The workflow's shared `XCODE_VERSION: 'latest-stable'` has
  nothing to resolve to there, so jobs on this image must skip the
  `setup-xcode` step.
- **It ships only 27.0 simulator runtimes.** With a deployment target of
  iOS 18.0, a job on this image cannot exercise a 26.x runtime without a
  slow runtime download — so genuine 26.x coverage has to stay on the
  `macos-26` jobs.

**GA is not announced.** The only notices in the runner-images repo are
the preview announcement and routine image refreshes. Last year's
precedent is the best available estimate: Xcode 26 betas rode along on
the `macos-15` image through the summer and
[#13024, "Update Xcode 26 to 26.0 Release"](https://github.com/actions/runner-images/issues/13024),
landed **2025-09-15**, within days of Apple's GM. Expect the 27.0 release
build on the image around mid-September 2026, tracking Apple. Treat that
as inference, not a commitment.

### Forward-compatibility check (already in place)

[apple.yml](../../.github/workflows/apple.yml) carries temporary
`kit-test-next` and `app-test-next` jobs that mirror `kit-test` and
`app-test` onto `xcode-27`, so code produced against the current stable
toolchain gets compiled and tested against next year's SDK before being
promoted to `main`. They are deliberately **advisory**:
`continue-on-error: true` so preview instability cannot fail a run or
block promotion, and absent from `approval`'s `needs` so the TestFlight
upload jobs can never depend on a preview runner. A failure raises a
warning annotation rather than a red run.

Remove them, or promote them to required by dropping
`continue-on-error`, once Xcode 27 is GA on the runner images.

### What still gates the merge

Not the toolchain — a **risk judgment**. Once app-target sources contain
OS 27 API calls, those targets can only compile against the 27 SDK, so
`app-build`, `app-test`, and both TestFlight upload jobs would have to
move to the preview image wholesale. That would make the Apple CI path
the Mini's daily pipelines and the release uploads depend on a preview
runner.

Recommended sequencing:

- Prove the CI shape on a spike branch against `xcode-27` first.
- Hold the merge to `stage` until the image is GA, unless there is a
  reason to accept preview-runner risk on the release path.
- **Re-validate at GM.** APIs move between betas; the measurements below
  were taken against beta `27A5228h`.
- App Store Connect currently accepts beta-built binaries for internal
  and external TestFlight testing, so a spike *can* reach testers from
  the Studio ahead of GM. Release submission still requires GM.

## What was measured

iPad Pro 11" (M5) simulator, iPadOS 27.0 (24A5390f), Xcode 27.0 beta
(27A5228h), landscape, held-reveal measure, same method and drag
distances as the June 2026 matrix. Minimum drag distance at which the
action reveals:

| Mechanism | Sidebar | Leading | Trailing |
| --- | --- | --- | --- |
| OS 27 container swipe | **tiled + visible** (`.all`) | **120pt** | **120pt** |
| OS 27 container swipe | collapsed (`.doubleColumn`) | 120pt | not run |
| June baseline: embedded per-row `List` | tiled `.all` | **never** | 120pt |
| June baseline: embedded per-row `List` | collapsed | 120pt | 250pt |

Reveal held at every distance tested (120/250/400/520pt); 120pt is the
shortest, i.e. a normal swipe. Vertical scrolling survived
(`scrolled=true`) — the failure mode that killed the hand-rolled
`SwipeRow` in PR #527. No gesture surgery, no UIKit introspection, no
private API.

Measured in the `~/swipe-repro` reduction harness (standalone, untracked;
scenarios `containerSwipe` and `containerSwipeSidebarHidden`). Full
write-up and repro commands: `~/swipe-repro/FINDINGS-os27.md`.

### Why the June conclusion was wrong

June's investigation concluded that a persistently tiled, visible sidebar
can *never* have a working leading swipe, having established it across
the full `displayMode` × edge matrix and by disabling every candidate
gesture recognizer without effect. That was true **only for the
embedded-per-row-`List` mechanism**: the blocker was that inner `List`
losing leading-edge arbitration to the split view's interactive column
gesture, not the column tiling itself. A first-party container swipe does
not have to arbitrate.

## Goals

- Both swipe edges reveal at a normal drag distance on iPad with the
  folder sidebar persistently tiled.
- 26.x behaviour byte-for-byte unchanged.
- Cash in the three simplifications the change unlocks.

## Non-goals

- Dropping iOS/macOS 26 support. Every OS 27 path stays behind
  `#available` with the existing embedded-`List` implementation as the
  fallback.
- Merging to `stage` before Xcode 27 GM reaches CI.
- Testability and accessibility work, which is 26.x-native and tracked
  separately in
  [apple-testability-and-accessibility.md](apple-testability-and-accessibility.md).
- Other OS 27 features (App Intents, Core Spotlight, Foundation Models,
  reorderable containers, new toolbar APIs). Additive feature work, out
  of scope.

## Prerequisite

Verifying this in the *real app* by automation needs the accessibility
identifiers and, critically, the `.accessibilityElement(children: .contain)`
grouping fix from Phase 1 of
[apple-testability-and-accessibility.md](apple-testability-and-accessibility.md).
Without `.contain`, a row-level identifier merges its subtree and the
revealed swipe buttons are invisible to XCUITest even while plainly
visible on screen — this cost two full measurement runs in the reduction
harness, where results read `revealed=false` against screenshots showing
the buttons.

The reduction harness measurements above did **not** need it, so Phase A
below can proceed in parallel; the dependency binds only at real-app
verification.

## Phase A — Adopt `.swipeActionsContainer()`

Replace the embedded single-row `List` in `SwipeActionRow` with plain row
content carrying `.swipeActions` directly, and mark the virtualized
`ScrollView` in `virtualizedList`
([MessageListView+Selection.swift](../../apple/Cabalmail/Views/MessageListView+Selection.swift))
with `.swipeActionsContainer()`.

Constraints to preserve:

- The **fixed `rowHeight` invariant** that index-addressed virtualization
  depends on: the scroll extent is `rowCount * rowHeight` and
  placeholders align to it, so a row whose footprint changes drifts
  placeholders out of alignment with their slots.
- 16pt horizontal content insets and the full-width selection background,
  matching `placeholderRow`.
- Both paths coexisting behind
  `#available(iOS 27, macOS 27, visionOS 27, *)`, with the
  embedded-`List` implementation serving 26.x.

A flag-gated prototype of exactly this exists on branch
`claude/os27-swipe-proto` (commit `ed0d58ca`): `SwipeProto.containerSwipe`
drops the embedded `List` and marks the scroll container, and
`SwipeProto.tiledSidebar` tiles the real folder sidebar. Both read launch
environment variables, so one build A/Bs every combination in the
simulator. It builds for iPadOS 27 and is SwiftLint `--strict` clean. It
is a spike, not a merge candidate.

**Acceptance:** on a 27.x device, both swipe edges reveal at a normal drag
distance with the sidebar tiled; vertical scroll, drag-to-folder, and the
macOS two-finger trackpad swipe all still work; 26.x behaviour unchanged.

## Phase B — Cash in the simplifications

Depends on Phase A. Each item is independently verifiable and each
*removes* code.

1. **Restore the real tiled iPad sidebar.** Retire the `.doubleColumn`
   pin and the `folderPanelOverlay` floating panel in `MailRootView`,
   which exist solely to keep the message list the leftmost tile. This
   returns genuine Apple sidebar chrome, which the hand-built panel could
   only approximate. **Assumed, not yet measured in the real app** —
   validated in reduction only.
2. **Re-test the background watchdog gate.** Rows currently collapse to
   `placeholderRow` while `scenePhase == .background` because the
   synchronous background scene-update snapshot, with a per-row `List`
   for every visible message, could exceed the 10-second watchdog
   (`0x8BADF00D`, `WatchdogVisibility: Background`, PR #528). With the
   embedded `List` gone that cost should be gone too.

   **Verification must be on device: the simulator cannot fire the
   watchdog**, and watchdog crashes do not appear in TestFlight's Crashes
   organizer — pull the device's Analytics Data `.ips` or use the
   MetricKit collector. **Do not remove this gate on simulator
   evidence.**
3. **Simplify the drag composition.** `.draggable` currently sits
   *outside* `SwipeActionRow` because the embedded `List` swallows a drag
   placed inside its row. On plain rows both drag and scroll survived in
   reduction, so the wrapper dance may be removable.

## Sequencing

| Step | Depends on | Where |
| --- | --- | --- |
| A — Container swipe | Phase 1 of the testability plan, for real-app verification only | Studio locally; `xcode-27` image in CI |
| B — Simplifications | A | Studio; item 2 needs a real device |

Merge to `stage` once the `xcode-27` image is GA (estimated mid-September
2026, not announced), re-validating the measurements against the GM
toolchain first. Merging earlier is possible but puts the release path on
a preview runner — see
[What still gates the merge](#what-still-gates-the-merge).
