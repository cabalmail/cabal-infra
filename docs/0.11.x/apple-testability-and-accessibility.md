# Apple Client Testability and Accessibility Plan

## Context

The Apple clients expose no machine-readable interface: there are **zero**
`accessibilityIdentifier` calls anywhere in `apple/` (verify with
`rg -c accessibilityIdentifier apple`). Every automated interaction has
to fall back to matching visible label text or tapping raw screen
coordinates. Label matching breaks the moment copy changes and would
break entirely under localization; coordinates break on rotation, on
layout changes, and have to be transformed by hand in landscape, where
the simulator framebuffer stays portrait-shaped.

This surfaced concretely on 2026-08-01: a session attempting to drive the
real app on an iPadOS simulator could not get past sign-in at all, and
every workaround it reached for was a substitute for the missing semantic
layer — tapping coordinates like `xy:417,343` because the button had no
name to ask for, matching on visible label text, and reading screenshots
to determine state because the accessibility tree would not report it.

**The same absence that blocks automation blocks assistive technology.**
An automated tester and a screen reader both need the interface to expose
*what things are* rather than *where they are*, so an interface that
communicates only through pixel position and rendered text is opaque to
both. The clearest evidence is the symptom that blocked sign-in:
`hittable=false` is XCUITest reporting that an accessibility hit-test does
not resolve to the element, which is the same query VoiceOver
direct-touch and Switch Control use. Where automation degraded to a
slower path, a VoiceOver user would simply be stuck.

The overlap is a strong correlation rather than a guarantee, and it is
worth being precise about which side of it each change lands on.
`accessibilityIdentifier` is deliberately **never announced to users** —
it is machine-facing only, so adding identifiers is pure automation
benefit with no user-facing improvement. The user-facing dividend comes
from the neighbouring work: meaningful labels, correct traits, sensible
grouping, and real focus order. Conversely, accessibility-driven testing
is blind to what the tree cannot express — visual regressions, contrast,
animation, and layout that is technically reachable but unusable.

**Everything in this plan is native to OS 26.x.** It needs no beta
toolchain and no OS 27 SDK, so it builds and verifies on the Mac mini and
in CI ([.github/workflows/apple.yml](../../.github/workflows/apple.yml))
exactly as the tree does today. The separate, toolchain-gated OS 27 swipe
work is in
[os27-swipe-actions-container.md](os27-swipe-actions-container.md); the
two plans share one prerequisite, noted there.

## Goals

- Give the Apple clients a stable, machine-readable control surface:
  identifiers on the controls automation and assistive technology need to
  address by name, with correct grouping so revealed affordances stay
  reachable.
- Remove the auth-form defects that make automated sign-in impossible on
  any simulator or runtime.
- Make full-app simulator testing reproducible from a clean checkout,
  without tribal knowledge about build flags or hand-patched harnesses.
- Determine whether the Verify-button unreachability found on iPadOS 27
  also affects real users of assistive technology.

## Non-goals

- A full accessibility audit — VoiceOver rotor order, Dynamic Type at
  every size, contrast, reduce-motion. This plan covers identity,
  grouping, and hit-testing, the parts that overlap with testability. A
  broader audit deserves its own plan.
- Any OS 27-only API. See
  [os27-swipe-actions-container.md](os27-swipe-actions-container.md).
- Android or React admin testability.
- Replacing the `~/swipe-repro` reduction harness, which stays a
  standalone scratch project. Only the *full-app* drive harness is
  proposed for in-repo adoption.

## Phase 1 — Accessibility identifiers and grouping

Independently shippable, splittable across sessions by view area, and the
largest single unblocker for everything else.

Add `accessibilityIdentifier` to the controls automation and assistive
technology need to address by name, and fix grouping where it currently
hides children. Suggested naming convention: `area.control`, e.g.
`signin.username`, `signin.submit`, `mfa.code`, `mfa.verify`,
`message.row.<uid>`, `folder.row.<path>`, `compose.subject`.

Work items, each a reasonable single session:

1. **Auth surface** —
   [SignInView.swift](../../apple/Cabalmail/Views/SignInView.swift):
   control domain, username, password, Sign In, MFA code, Verify, Back to
   sign in.
2. **Message list** —
   [MessageListView+Rows.swift](../../apple/Cabalmail/Views/MessageListView+Rows.swift),
   [MessageListView+Selection.swift](../../apple/Cabalmail/Views/MessageListView+Selection.swift):
   rows keyed by UID, swipe action buttons, bulk-mode checkboxes, filter
   pills.
3. **Folder and address lists** —
   [FolderListView.swift](../../apple/Cabalmail/Views/FolderListView.swift),
   [AddressListView.swift](../../apple/Cabalmail/Views/AddressListView.swift).
4. **Reader and compose toolbars** —
   [MessageDetailView+Toolbar.swift](../../apple/Cabalmail/Views/MessageDetailView+Toolbar.swift),
   [ComposeView.swift](../../apple/Cabalmail/Views/ComposeView.swift).

### The subtree-merge trap

**Measured, and it cost two full measurement runs.** A row-level
`accessibilityIdentifier` **merges its whole subtree into one
accessibility element**. Revealed leading/trailing swipe buttons then
become invisible to XCUITest *while plainly visible on screen* — two runs
reported `revealed=false` against attached screenshots showing the
buttons sitting right there.

Any row that takes an identifier must also take
`.accessibilityElement(children: .contain)`. This is not a test hook: a
merged row announces itself to VoiceOver as one undifferentiated blob and
its swipe actions are unreachable. Same fix, two beneficiaries — and the
automation failure is what surfaced it.

**Acceptance:** an XCUITest can complete sign-in, select a folder, select
a message, and reveal both swipe edges using only identifiers, with no
coordinate taps and no visible-label matching. VoiceOver reaches a
revealed swipe button on a message row.

## Phase 2 — Auth form defects

Small, but gates automated sign-in on every simulator and runtime.

1. **Return does not submit.** Neither the sign-in form nor the MFA form
   submits on Return. *Owner: the maintainer has taken this one.* Add
   `.submitLabel` plus `.onSubmit` to both forms.
2. **Auto-submit the one-time code.** Submit as soon as six digits are
   present in the MFA field, rather than requiring the Verify button.
   This is the standard OTP pattern, better for humans, and it routes
   around item 3 entirely.
3. **Verify button unreachability — investigate.** On iPadOS 27,
   `Button("Verify")` inside the `mfaForm` `Form` in
   [SignInView.swift](../../apple/Cabalmail/Views/SignInView.swift)
   reports `hittable=false` and ignores a coordinate tap at its own frame
   centre *and* Return, with no error text appearing — so the action never
   fires rather than the code being rejected.

   **Status: unconfirmed as user-facing.** XCUITest hittability is not the
   same as human tappability; a finger may work fine. Not filed as a bug
   for that reason. What makes it suspicious: iPadOS 27 shows a new
   floating numeric keypad popover for `.oneTimeCode` +
   `.keyboardType(.numberPad)` fields, and it sits directly over the
   button's region. Dismissing the *visible* popover did not restore
   hittability, which hints at a window lingering in the hit-test chain.

   Investigate in this order: (a) does VoiceOver direct-touch reach the
   button on a real device; (b) does moving the primary action to a
   toolbar or keyboard accessory make it reachable; (c) is the `Form`
   `Section` wrapping implicated. If (a) fails on device, this is a real
   accessibility bug and should be filed and fixed, not merely worked
   around.

   Note this was observed on iPadOS 27, but the fix belongs here rather
   than in the OS 27 plan: items 1 and 2 are version-independent
   improvements, and if (a) fails the defect is in our view code.

**Acceptance:** MFA can be completed by keyboard alone and by automation,
on both a 26.x and a 27.x simulator. A definite answer, either way, on
whether Verify is reachable by assistive technology on device.

## Phase 3 — Simulator tooling in-repo

Turns per-session rediscovery into checked-in tooling.

1. **Signed-simulator build script** (`apple/scripts/build-sim.sh`). The
   working invocation is non-obvious and currently survives only in
   session notes. It must **omit** `CODE_SIGNING_ALLOWED=NO` — the CI
   recipe strips entitlements and sign-in then fails with keychain error
   `-34018` — and **add** `ENABLE_DEBUG_DYLIB=NO`, or the notification
   service extension's preview-dylib link step fails.
   `ONLY_ACTIVE_ARCH=YES` keeps it quick. Simulator ad-hoc signing is
   sufficient; do not try to hand-sign an unsigned build with
   `codesign --entitlements`, which produces launch denials.
2. **Full-app drive harness** (`apple/Tools/SimDrive/`). A small XCUITest
   command REPL: the host writes a command line to a file in the runner's
   container, the test executes it against the installed app and writes
   the result back. It currently lives outside the repo and was
   hand-extended in `/tmp` during the session. Verbs worth having from
   the start: `launch`/`activate`, `env` (launch environment, for
   flag-gated experiments), `dump`/`focus`, `tap` (by query or
   coordinate), `type`, `cmdv`, `orient`, `drag` with a configurable
   **hold**, `swiperow`, `exists`, `wait`.

   The hold-during-drag verb is what makes gesture work possible at all:
   a swipe reveal cannot be observed without holding the drag and
   screenshotting from *outside* the runner, since gestures occupy the
   main thread — query and screenshot from a background thread during the
   hold.
3. **Secure-field entry note.** A SwiftUI `SecureField` does not accept
   the keyboard assistant bar's Paste button, but does accept hardware
   **Cmd-V** (`app.typeKey("v", modifierFlags: .command)`) against a
   pasteboard seeded host-side with `simctl pbcopy`. This keeps secrets
   out of the harness and its logs, which is the required handling.
4. **First-run overlay pre-flight.** Two system interruptions ate cycles:
   an iPadOS "Copy and Paste" keyboard education overlay covering the
   form, and a "Save Password?" alert (dismiss: `Not Now`) after sign-in.
   Either script the dismissal sequence or seed the relevant simulator
   defaults before launch.
5. **Documentation** — fold the above into [docs/apple.md](../apple.md)
   so it is discoverable from a clean checkout rather than inferred.

**Acceptance:** from a fresh clone, one documented command builds and
installs a sign-in-capable simulator build, and a second drives it
through a scripted scenario.

## Optional — DEBUG-only sign-in shortcut

**A judgment call for the maintainer, not a recommendation.**

MFA is what makes a fresh simulator expensive: simulator keychains do not
transfer between devices or runtimes, so every new simulator costs a full
manual sign-in, and a single machine may carry several runtimes at once.

The obvious shape is accepting a session or refresh token via launch
environment. The tradeoff is real: that is an authentication bypass
surface in a security-sensitive mail app. If adopted, it must be
structurally impossible to compile into a Release or TestFlight binary
(`#if DEBUG`), must read from the keychain rather than embed anything,
and must never accept a password.

The cheaper mitigation, requiring no code: keep one designated signed-in
simulator per runtime and record which, since signed-in state does
persist across reinstalls of the same bundle ID on the same simulator.

## Sequencing

All three phases are parallelisable across sessions and none blocks
another. **Phase 1 is the best first move:** it unblocks the automated
verification Phase 2 needs, it is the prerequisite for verifying the
OS 27 swipe work in the real app, and it is the phase whose accessibility
dividend is entirely unclaimed today.
