# Apple Client Testability and OS 27 Adoption Plan

## Context

Two findings from a single session (2026-08-01, Mac Studio, iPadOS 27.0
beta) turn out to be the same piece of work seen from two sides.

**First**, iOS 27's `.swipeActionsContainer()` fixes the iPad
leading-swipe defect that was closed as a structural won't-fix in June
2026. That defect forced two workarounds still in the tree today: the
iPad's folder sidebar cannot tile persistently
([apple/Cabalmail/Views/MailRootView.swift](../../apple/Cabalmail/Views/MailRootView.swift)
pins `columnVisibility` to `.doubleColumn` and floats a hand-built
`folderPanelOverlay` instead), and every message row embeds a single-row
`List` purely to borrow native `.swipeActions`
([apple/Cabalmail/Views/SwipeActionRow.swift](../../apple/Cabalmail/Views/SwipeActionRow.swift)).
That embedded `List` is in turn the reason rows collapse to placeholders
while backgrounded, to dodge a scene-update watchdog kill. Removing it
unwinds all three compromises.

**Second**, the same session could not drive the app past sign-in on the
iPadOS 27 simulator at all, and the reason is that the Apple clients
expose no machine-readable interface: there are **zero**
`accessibilityIdentifier` calls in `apple/` (verify with
`rg -c accessibilityIdentifier apple`). Every automated interaction has
to fall back to matching visible label text or tapping raw screen
coordinates. Both are brittle, and both are unavailable to assistive
technology for the same reason they are unreliable for a test harness:
the interface communicates position and rendered text, not identity and
semantics.

The two threads meet at the accessibility tree. `hittable=false` — the
symptom that blocked automated sign-in — is XCUITest reporting that an
accessibility hit-test does not resolve to the element, which is the same
query VoiceOver direct-touch and Switch Control use. Work done for the
test harness is largely work done for accessibility, and vice versa.

This plan sequences that work. It is written to be picked up by several
independent sessions, so each phase states its own dependencies,
acceptance criteria, and whether its premises are **measured** or
**assumed**.

## Goals

- Give the Apple clients a stable, machine-readable control surface:
  identifiers on the controls automation and assistive technology need,
  with correct grouping so revealed affordances stay reachable.
- Make full-app simulator testing reproducible from a clean checkout,
  without tribal knowledge about build flags or hand-patched harnesses.
- Remove the auth-form defects that make sign-in unautomatable, and
  determine whether the Verify-button unreachability also affects real
  users of assistive technology.
- Adopt `.swipeActionsContainer()` when the toolchain allows, and cash in
  the three simplifications it unlocks.

## Non-goals

- Shipping any OS 27-only code before Xcode 27 GM. See
  [Toolchain gate](#toolchain-gate).
- Dropping iOS/macOS 26 support. Every OS 27 path stays behind
  `#available`, with the existing implementation as the fallback.
- A full accessibility audit (VoiceOver rotor order, Dynamic Type at
  every size, contrast, reduce-motion). This plan covers identity,
  grouping, and hit-testing — the parts that overlap with testability.
  A broader audit deserves its own plan.
- Replacing the `~/swipe-repro` reduction harness. It stays a standalone
  scratch project; only the *full-app* drive harness is proposed for
  in-repo adoption.
- Android or React admin testability.

## Toolchain gate

Xcode 27 beta compiles and runs the OS 27 paths today, and App Store
Connect currently accepts beta-built binaries for internal and external
TestFlight testing. Release submission still requires the GM toolchain.

The binding constraint is different, and stricter: **CI
([.github/workflows/apple.yml](../../.github/workflows/apple.yml)) and
the Mac mini run Xcode 26, which cannot compile the iOS 27 SDK even
behind `#available`** — the availability check needs the SDK to declare
the symbols. So any branch containing OS 27 API calls will not build in
the normal pipeline until CI's Xcode moves.

Consequence for sequencing: **Phases 1–3 are shippable now** and have no
OS 27 dependency. **Phases 4–5 must stay on spike branches** until
Xcode 27 GM lands in CI, and should be re-validated then, because APIs
move between betas.

## Phase 1 — Accessibility identifiers and grouping

No OS 27 dependency. Independently shippable. Splittable across sessions
by view area, and the largest single unblocker for everything else.

Add `accessibilityIdentifier` to the controls automation and assistive
technology need to address by name, and fix grouping where it currently
hides children. Suggested naming convention: `area.control`, e.g.
`signin.username`, `signin.submit`, `mfa.code`, `mfa.verify`,
`message.row.<uid>`, `folder.row.<path>`, `compose.subject`.

Note that `accessibilityIdentifier` itself is machine-facing only — it is
never announced to users — so it is pure automation benefit. The
user-facing dividend comes from the neighbouring work in this phase:
meaningful labels, correct traits, and sensible grouping.

Work items, each a reasonable single session:

1. **Auth surface** —
   [SignInView.swift](../../apple/Cabalmail/Views/SignInView.swift):
   control domain, username, password, Sign In, MFA code, Verify, Back to
   sign in.
2. **Message list** —
   [MessageListView+Rows.swift](../../apple/Cabalmail/Views/MessageListView+Rows.swift),
   [MessageListView+Selection.swift](../../apple/Cabalmail/Views/MessageListView+Selection.swift):
   rows keyed by UID, swipe action buttons, bulk-mode checkboxes,
   filter pills.
3. **Folder and address lists** —
   [FolderListView.swift](../../apple/Cabalmail/Views/FolderListView.swift),
   [AddressListView.swift](../../apple/Cabalmail/Views/AddressListView.swift).
4. **Reader and compose toolbars** —
   [MessageDetailView+Toolbar.swift](../../apple/Cabalmail/Views/MessageDetailView+Toolbar.swift),
   [ComposeView.swift](../../apple/Cabalmail/Views/ComposeView.swift).

### The subtree-merge trap

**Measured, and it cost two full measurement runs.** A row-level
`accessibilityIdentifier` **merges its whole subtree into one
accessibility element**. The revealed leading/trailing swipe buttons then
become invisible to XCUITest *while plainly visible on screen* — two runs
reported `revealed=false` against attached screenshots showing the
buttons sitting right there.

Any row that takes an identifier must also take
`.accessibilityElement(children: .contain)`. This is not a test hook: a
merged row announces itself to VoiceOver as one undifferentiated blob and
its swipe actions are unreachable. Same fix, two beneficiaries.

**Acceptance:** an XCUITest can complete sign-in, select a folder, select
a message, and reveal both swipe edges using only identifiers — no
coordinate taps, no visible-label matching. VoiceOver reaches a revealed
swipe button on a message row.

## Phase 2 — Auth form defects

No OS 27 dependency. Small, but gates automated sign-in on every
simulator and runtime.

1. **Return does not submit.** Neither the sign-in form nor the MFA form
   submits on Return. *Owner: the maintainer has taken this one.* Add
   `.submitLabel` plus `.onSubmit` to both forms.
2. **Auto-submit the one-time code.** Submit as soon as six digits are
   present in the MFA field, rather than requiring the Verify button.
   This is the standard OTP pattern, better for humans, and it routes
   around item 3 entirely.
3. **Verify button unreachability — investigate.** On iPadOS 27,
   `Button("Verify")` inside the `mfaForm` `Form` reports
   `hittable=false` and ignores a coordinate tap at its own frame centre
   *and* Return, with no error text appearing — so the action never fires
   rather than the code being rejected.

   **Status: unconfirmed as user-facing.** XCUITest hittability is not
   the same as human tappability; a finger may work fine. Not yet filed
   as a bug for that reason. What makes it suspicious: iPadOS 27 shows a
   new floating numeric keypad popover for `.oneTimeCode` +
   `.keyboardType(.numberPad)` fields, and it sits directly over the
   button's region. Dismissing the *visible* popover did not restore
   hittability, which hints at a window lingering in the hit-test chain.

   Investigate in this order: (a) does VoiceOver direct-touch reach the
   button on a real device; (b) does moving the primary action to a
   toolbar or keyboard accessory make it reachable; (c) is the `Form`
   `Section` wrapping implicated. If (a) fails on device, this is a real
   accessibility bug and should be filed and fixed, not merely
   worked around.

**Acceptance:** MFA can be completed by keyboard alone and by automation,
on both a 26.x and a 27.x simulator. A definite answer, either way, on
whether Verify is reachable by assistive technology on device.

## Phase 3 — Simulator tooling in-repo

No OS 27 dependency. Turns per-session rediscovery into checked-in
tooling.

1. **Signed-simulator build script** (`apple/scripts/build-sim.sh`). The
   working invocation is non-obvious and currently survives only in
   session notes. It must **omit** `CODE_SIGNING_ALLOWED=NO` — the CI
   recipe strips entitlements and sign-in then fails with keychain error
   `-34018` — and **add** `ENABLE_DEBUG_DYLIB=NO`, or the notification
   service extension's preview-dylib link step fails. `ONLY_ACTIVE_ARCH=YES`
   keeps it quick. Simulator ad-hoc signing is sufficient; do not try to
   hand-sign an unsigned build with `codesign --entitlements`, which
   produces launch denials.
2. **Full-app drive harness** (`apple/Tools/SimDrive/`). A small XCUITest
   command REPL — host writes a command line to a file in the runner's
   container, the test executes it against the installed app and writes
   the result back. It currently lives outside the repo and was
   hand-extended in `/tmp` during the session. Verbs worth having from
   the start: `launch`/`activate`, `env` (launch environment, for
   flag-gated experiments), `dump`/`focus`, `tap` (by query or
   coordinate), `type`, `cmdv`, `orient`, `drag` with a configurable
   **hold**, `swiperow`, `exists`, `wait`.

   The hold-during-drag verb is what makes gesture work possible at all:
   a swipe reveal cannot be observed without holding the drag and
   screenshotting from *outside* the runner (gestures occupy the main
   thread; query and screenshot from a background thread during the
   hold).
3. **Secure-field entry note.** A SwiftUI `SecureField` does not accept
   the keyboard assistant bar's Paste button, but does accept hardware
   **Cmd-V** (`app.typeKey("v", modifierFlags: .command)`) against a
   pasteboard seeded host-side with `simctl pbcopy`. This keeps secrets
   out of the harness and its logs, which is the required handling.
4. **First-run overlay pre-flight.** Two system interruptions ate cycles:
   an iPadOS "Copy and Paste" keyboard education overlay covering the
   form, and a "Save Password?" alert (dismiss: `Not Now`) after
   sign-in. Either script the dismissal sequence or seed the relevant
   simulator defaults before launch.
5. **Documentation** — fold the above into
   [docs/apple.md](../apple.md) so it is discoverable from a clean
   checkout rather than inferred.

**Acceptance:** from a fresh clone, one documented command builds and
installs a sign-in-capable simulator build, and a second drives it
through a scripted scenario.

## Phase 4 — Adopt `.swipeActionsContainer()`

**Blocked on Xcode 27 GM in CI.** Spike branches only until then.

### What was measured

iPad Pro 11" (M5) simulator, iPadOS 27.0 (24A5390f), Xcode 27.0 beta
(27A5228h), landscape, held-reveal measure, same method and distances as
the June 2026 matrix:

| Scenario | Sidebar | Leading | Trailing |
| --- | --- | --- | --- |
| OS 27 container swipe | **tiled + visible** (`.all`) | **120pt** | **120pt** |
| OS 27 container swipe | collapsed (`.doubleColumn`) | 120pt | not run |
| June baseline: embedded per-row `List` | tiled `.all` | **never** | 120pt |
| June baseline: embedded per-row `List` | collapsed | 120pt | 250pt |

Reveal held at every distance tested (120/250/400/520); 120pt is the
shortest, i.e. a normal swipe. Vertical scrolling survived
(`scrolled=true`) — the failure mode that killed the hand-rolled
`SwipeRow` in PR #527. No gesture surgery, no UIKit introspection, no
private API.

### Why the June conclusion was wrong

June's matrix concluded a persistently tiled, visible sidebar can *never*
have a working leading swipe, having established it across the full
`displayMode` × edge matrix and by disabling every candidate gesture
recognizer without effect. That was true **only for the
embedded-per-row-`List` mechanism**: the blocker was that inner `List`
losing leading-edge arbitration to the split view's interactive column
gesture, not the column tiling itself. A first-party container swipe does
not have to arbitrate.

### Implementation

Replace the embedded single-row `List` in `SwipeActionRow` with plain row
content carrying `.swipeActions` directly, and mark the virtualized
`ScrollView` in `virtualizedList` with `.swipeActionsContainer()`.
Preserve the fixed `rowHeight` invariant that index-addressed
virtualization depends on (the scroll extent is `rowCount * rowHeight`
and placeholders align to it), keep 16pt horizontal content insets, and
keep the full-width selection background.

Both paths must coexist behind `#available(iOS 27, macOS 27, visionOS 27, *)`
with the embedded-`List` implementation as the 26.x fallback.

A flag-gated prototype of exactly this exists on branch
`claude/os27-swipe-proto` (commit `ed0d58ca`): `SwipeProto.containerSwipe`
and `SwipeProto.tiledSidebar` read launch environment variables so one
build A/Bs every combination. It builds for iPadOS 27 and is SwiftLint
`--strict` clean. It is a spike, not a merge candidate.

**Acceptance:** on a 27.x device, both swipe edges reveal at a normal
drag distance with the sidebar tiled; vertical scroll, drag-to-folder,
and the macOS two-finger trackpad swipe all still work; 26.x behaviour is
byte-for-byte unchanged.

## Phase 5 — Cash in the simplifications

Depends on Phase 4 landing. Each item is independently verifiable and
each *removes* code.

1. **Restore the real tiled iPad sidebar.** Retire the `.doubleColumn`
   pin and the `folderPanelOverlay` floating panel in `MailRootView`,
   which exist solely to keep the message list the leftmost tile. This
   returns genuine Apple sidebar chrome, which the hand-built panel could
   only approximate. **Assumed, not yet measured** in the real app —
   validated in reduction only.
2. **Re-test the background watchdog gate.** Rows currently collapse to
   `placeholderRow` while `scenePhase == .background` because a stack of
   UICollectionView-backed per-row `List`s was expensive enough to lay
   out that the background scene-update snapshot exceeded the 10-second
   watchdog (`0x8BADF00D`, PR #528). With the embedded `List` gone, that
   cost should be gone too. **Verification must be on device — the
   simulator cannot fire the watchdog**, and watchdog crashes do not
   appear in TestFlight's Crashes organizer; pull the device's Analytics
   Data `.ips` or use the MetricKit collector. Do not remove the gate on
   simulator evidence.
3. **Simplify the drag composition.** `.draggable` currently has to sit
   *outside* `SwipeActionRow` because the embedded `List` swallows a drag
   placed inside its row. On plain rows both drag and scroll survived in
   reduction, so the wrapper dance may be removable.

## Optional — DEBUG-only sign-in shortcut

**A judgment call for the maintainer, not a recommendation.**

MFA is what makes a fresh simulator expensive: simulator keychains do not
transfer between devices or runtimes, so every new simulator costs a full
manual sign-in, and this box alone carries iOS 18.6, 26.0, and 27.0
runtimes.

The obvious shape is accepting a session or refresh token via launch
environment. The tradeoff is real: that is an authentication bypass
surface in a security-sensitive mail app. If adopted, it must be
structurally impossible to compile into a Release or TestFlight binary
(`#if DEBUG`), must read from the keychain rather than embed anything,
and must never accept a password.

The cheaper mitigation, requiring no code: keep one designated
signed-in simulator per runtime and record which, since signed-in state
does persist across reinstalls of the same bundle ID on the same
simulator.

## Sequencing summary

| Phase | Depends on | Blocked by toolchain |
| --- | --- | --- |
| 1 — Identifiers and grouping | — | No |
| 2 — Auth form defects | — | No |
| 3 — Simulator tooling | — | No |
| 4 — Container swipe | 1, 3 (to verify it) | **Yes** |
| 5 — Simplifications | 4 | **Yes** |

Phases 1–3 are parallelisable across sessions. Phase 1 is the best first
move: it unblocks the automated verification that Phases 2 and 4 need,
and it is the phase whose accessibility dividend is entirely unclaimed
today.

## Reference

- Reduction harness measurements and repro commands:
  `~/swipe-repro/FINDINGS-os27.md` (untracked scratch project).
- Prototype: branch `claude/os27-swipe-proto`, commit `ed0d58ca`.
- A wider survey of OS 27 features relevant to Cabalmail (App Intents for
  address create/revoke, Core Spotlight indexing plus on-device
  retrieval-augmented search, Foundation Models, reorderable containers,
  new toolbar APIs, automatic `AsyncImage` HTTP caching) was drafted on
  branch `claude/os27-adoption-notes`; its PR (#864) was closed unmerged.
  Those items are additive feature work, out of scope here.
