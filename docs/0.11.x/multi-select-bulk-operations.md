# Multi-select and bulk operations (Apple clients)

## Context

The Apple clients (iOS, iPadOS, macOS, visionOS) currently let the user act on
one message at a time. The React admin app has supported multi-select with
bulk archive / move / flag / mark-read for several releases, so this is a
parity gap that becomes more painful as users move larger amounts of mail.

Most of the foundation is already in place:

- The `ImapClient` protocol at
  [apple/CabalmailKit/Sources/CabalmailKit/IMAP/ImapClient.swift:14](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ImapClient.swift)
  already takes `uids: [UInt32]` on `setFlags(folder:uids:flags:operation:)`
  and `move(folder:uids:destination:)`. No protocol change needed.
- `ApiBackedImapClient` at
  [apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift:163](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift)
  already bundles all UIDs into one Lambda call per flag (for `setFlags`) and
  one call total (for `move`).
- The Lambda endpoints
  [lambda/api/set_flag/function.py](../../lambda/api/set_flag/function.py) and
  [lambda/api/move_messages/function.py](../../lambda/api/move_messages/function.py)
  already accept `ids: [...]` lists. No backend change needed.

What is missing is the client-side state model, gesture model, action surface,
and large-batch hardening. This plan addresses those in five
independently-shippable phases.

## Goals

- Select multiple messages in a folder list and apply a single bulk action
  (mark read/unread, flag/unflag, move, archive, delete) to all of them.
- Match each platform's idiomatic multi-select UX: cmd/shift-click on macOS
  and iPadOS-with-keyboard, an explicit Select / Edit mode on iPhone.
- Optimistic UI: selected rows reflect the action immediately, then reconcile
  if the server rejects.
- Predictable behavior on selections of any size, including thousands of
  messages, with clear feedback when some operations fail partway through.
- Take the opportunity, while the bulk-op Lambda endpoints are under
  development for the Apple clients, to harden the response shape so the
  React admin app also benefits — replacing its current swallow-the-error
  behavior with real partial-success reporting.

## Non-goals

- Cross-folder selection. Selection clears when the user changes folder, as
  it does in the React app.
- Server-side search-based bulk actions ("flag all from sender X"). Bulk
  actions operate on the user's explicit selection only.
- A new permanent-delete (`UID EXPUNGE`) endpoint. Delete remains
  move-to-Deleted, matching the rest of the system.
- New IMAP protocol methods. The protocol already supports the operations
  we need.
- Apple-client-only design changes that diverge from React behavior. Where
  React has established UX, mirror it.

## Current state

- [apple/Cabalmail/Views/MessageListView.swift:8](../../apple/Cabalmail/Views/MessageListView.swift)
  declares `@Binding var selection: Envelope?` (a single optional).
- Selection state is lifted to
  [apple/Cabalmail/Views/MailRootView.swift:26](../../apple/Cabalmail/Views/MailRootView.swift)
  as `@State private var selectedEnvelope: Envelope?`.
- Per-message actions live in `MessageListView` swipe actions
  ([MessageListView.swift:226](../../apple/Cabalmail/Views/MessageListView.swift))
  and a row context menu
  ([MessageListView.swift:248](../../apple/Cabalmail/Views/MessageListView.swift)),
  and in the detail toolbar at
  [MessageDetailView+Toolbar.swift](../../apple/Cabalmail/Views/MessageDetailView+Toolbar.swift).
- `MessageListViewModel` holds an existing `pendingDisposeUIDs: Set<UInt32>`
  (around line 52) to deduplicate in-flight single-message ops. This is the
  precedent for tracking in-flight bulk ops.
- macOS app shell is in [apple/CabalmailMac/](../../apple/CabalmailMac/) and
  reuses the shared views; there are no macOS-only message-list views.

## Reference UX (React admin app)

The React app's behavior is the reference. Key file paths for reviewers:

- [react/admin/src/Email/Messages/index.jsx](../../react/admin/src/Email/Messages/index.jsx) -
  `selected: Set`, `bulkMode`, `lastSelectedRef` for the shift-click anchor,
  the action toolbar, and the Select button.
- [react/admin/src/Email/Messages/Envelopes.jsx](../../react/admin/src/Email/Messages/Envelopes.jsx) -
  shift-click range, meta-click toggle.
- [react/admin/src/Email/Messages/Envelope.jsx](../../react/admin/src/Email/Messages/Envelope.jsx) -
  per-row checkbox surfaced only in bulk mode.
- [react/admin/src/ApiClient.js](../../react/admin/src/ApiClient.js) -
  `moveMessages` and `setFlag` send `ids` as arrays; the same shape Apple's
  `ApiBackedImapClient` already uses.

## Phases

Each phase is independently shippable behind no flag. Earlier phases are
useful on their own even if later phases never land.

### Phase 1: selection-state foundation

Goal: hold a set of selected message ids and let the user manipulate that
set with platform-native gestures. No bulk actions yet; selection is visible
but inert.

- In `apple/Cabalmail/Views/MailRootView.swift`, change `selectedEnvelope:
  Envelope?` to `selectedEnvelopeIDs: Set<Envelope.ID>` (and a derived
  computed `selectedEnvelope` for the detail pane, defined as: if
  `selectedEnvelopeIDs.count == 1`, the matching envelope; else `nil`).
- In `apple/Cabalmail/Views/MessageListView.swift`, change the binding to
  `@Binding var selection: Set<Envelope.ID>` and pass it to
  `List(selection:)`. SwiftUI's `List(selection:)` natively supports
  `Set<Hashable>` and unlocks cmd-click / shift-click on macOS and on
  iPadOS-with-keyboard for free.
- Add an `@Environment(\.editMode)`-backed bulk-mode toggle visible in the
  list's principal toolbar on compact (iPhone) layouts. On macOS and
  regular-width iPad, no explicit toggle: the modifier-key gestures and
  multi-cell selection already cover it.
- Selection clears on folder change (mirror `MessageListViewModel`'s existing
  reset hooks).
- When `selectedEnvelopeIDs.count != 1`, the detail pane shows an
  empty/placeholder state with a count ("N messages selected").

Acceptance criteria:

- On macOS, cmd-click toggles a row's selection; shift-click selects a
  contiguous range; click without modifier collapses selection to that row.
- On iPad with a keyboard attached, the same gestures work.
- On iPhone, tapping a "Select" button enters bulk mode; rows show
  leading checkmarks; tapping a row toggles its checkbox; tapping "Done"
  exits and clears selection.
- Detail pane shows a "N messages selected" placeholder when more than one
  is selected; shows the message when exactly one is selected.
- Existing single-selection flows (tap a row to read) still work in
  non-bulk mode.

### Phase 2: bulk action surface

Goal: act on the current selection.

- Add a `BulkActionBar` view shown above the list (iOS) or in the list
  toolbar (macOS / iPad regular) whenever `selection.count > 0`. The bar
  exposes:
  - Mark read / mark unread (toggles based on majority state, like the
    detail toolbar already does for single messages).
  - Flag / unflag (same majority-state toggle).
  - Move... (presents the existing folder picker used by
    `MessageDetailView+Toolbar.swift`; on confirm calls
    `client.imapClient.move(folder:uids:destination:)` once with all UIDs).
  - Dispose (archive or trash per user preference, mirroring the existing
    `dispose(_:)` swipe action).
- All actions call existing `ImapClient` methods with the full UID array.
  No new protocol surface.
- Apply optimistic updates by extending the same model
  `MessageListViewModel` uses for single-message ops. Add a
  `pendingBulkOpUIDs: Set<UInt32>` to prevent rows from being targeted by a
  second bulk op while one is in flight.
- After a successful bulk op, clear the selection. After a failure, keep
  the selection so the user can retry.

Acceptance criteria:

- With multiple messages selected, the bulk action bar appears.
- Each action applies to every selected message in one user gesture.
- Optimistic flag/read state appears immediately; on server error the rows
  revert and an error toast/banner explains what failed.
- Move targets the existing folder picker; selection clears on success.

### Phase 3: polish and platform conventions

Goal: round out the affordances power users expect.

- Select-all / deselect-all: cmd-A on macOS and iPad; "Select All" button
  in the iPhone bulk-mode toolbar. "Select all" means all currently-loaded
  envelopes in the list, not the entire server-side folder (mirror React's
  scope - it does not back-fetch).
- Selection-count badge in the list header.
- Destructive-action confirmations once the selection crosses a threshold
  (e.g. 25 messages): a confirmation alert before dispose/delete on large
  selections. No confirmation for non-destructive bulk ops.
- Keyboard shortcuts on macOS, declared via
  `apple/CabalmailMac/CabalmailCommands.swift` (or whichever Commands struct
  the macOS app uses):
  - Delete / Backspace -> dispose
  - F -> flag toggle
  - U -> mark unread
  - cmd-shift-M -> move...
  Shortcuts apply to either the current single-message selection or the
  full bulk selection, whichever is non-empty.
- VoiceOver: row labels announce checked/unchecked when in bulk mode;
  bulk action bar buttons have explicit accessibility labels including the
  selection count ("Archive 12 messages").

Acceptance criteria:

- Select-all works on each platform and respects the loaded-envelope scope.
- A 50-message dispose triggers a confirmation; a 5-message dispose does
  not.
- All keyboard shortcuts work on macOS and on iPad with a keyboard.
- VoiceOver speaks the count when a bulk action button is focused.

### Phase 4: cross-client API hardening

Goal: tighten the bulk-op Lambda endpoints so both clients can report
partial success honestly, and add client-side chunking as a Lambda-timeout
safety net for very large selections.

This is the only phase that touches code outside the Apple targets. It is
worth doing now because (a) the Apple side genuinely needs richer error
information to ship Phases 1–3 with confidence, and (b) the React admin
app's existing bulk-operation surface has known shakiness rooted in the
same response shape — fixing it once benefits both clients. The Lambda
change is purely additive, so the three layers (Lambda, Apple, React) can
adopt on independent schedules.

**Lambda** — [lambda/api/set_flag/function.py](../../lambda/api/set_flag/function.py)
and [lambda/api/move_messages/function.py](../../lambda/api/move_messages/function.py):

- Replace the current opaque response (`{"status": "submitted"}` /
  `{"message_ids": [...]}` / `{"status": "unable"}`) with a uniform shape:

  ```json
  {
    "status": "ok" | "partial" | "failed",
    "succeeded": [uid, ...],
    "failed": [{"uid": uid, "reason": "string"}, ...],
    "message_ids": [...]   // optional, see below
  }
  ```

- In `move_messages`, replace the bare `except:` that currently masks every
  failure as `{"status": "unable"}` with a per-call try/except that captures
  the imapclient error message and partitions UIDs into succeeded/failed
  buckets. `imapclient.move` does not return per-UID results directly, so on
  failure fall back to a `UID COPY` + `UID STORE +FLAGS \Deleted` +
  `UID EXPUNGE` sequence that can report per-UID success, *or* (simpler)
  re-`UID FETCH` the source folder for the requested UIDs after the attempt
  and treat any UID still present as failed.
- In `set_flag`, wrap the `add_flags` / `remove_flags` call in try/except so
  IMAP errors do not silently 500. On partial failure (rare for STORE, but
  possible if some UIDs no longer exist), report which UIDs were not
  present.
- Make the post-mutation `client.sort(...)` call in `set_flag` opt-in via a
  new request field `refresh_list: bool` (default `false`). Right now it
  runs unconditionally and is the dominant latency cost for flag toggles;
  the React UI uses it on bulk flag/read changes that re-render the list,
  but most single-message toggles do not need a fresh list. When omitted,
  return the existing folder's `message_ids` only when the caller asks.
- Backward compatibility: the additive fields are forward-compatible. A
  client that ignores `succeeded` / `failed` and looks only at HTTP status
  will continue to work. Keep returning HTTP 200 even on `status:
  "partial"` so partial-failure flows are surfaced through the body, not
  through HTTP errors.

**Apple** — [apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift):

- Decode the new response shape. When `status == "partial"`, throw a new
  error `CabalmailError.bulkPartialFailure(succeededUIDs: Set<UInt32>,
  failedUIDs: Set<UInt32>, underlying: Error)` defined in the file that
  holds `CabalmailError` (search for the existing declaration; do not
  guess the path). When `status == "failed"`, throw an error containing
  the server's reason.
- Introduce a private constant `bulkChunkSize` (start at 1000; tune
  later) and split any call where `uids.count > bulkChunkSize` into
  sequential chunked calls inside `setFlags` and `move`. This is a
  Lambda-timeout safety net; the Lambda itself should still handle
  reasonably large batches in one call. Sequential, not parallel — both
  to avoid stampeding the IMAP server and to keep per-chunk error
  attribution simple.
- Aggregate per-chunk succeeded / failed UID sets and throw a single
  `bulkPartialFailure` with the union if any chunk reports partial or
  full failure.
- `MessageListViewModel` catches `bulkPartialFailure`, applies the
  successful changes to its local state, restores the failed rows, and
  surfaces a user-visible message ("Moved 387 of 412 messages. 25 could
  not be moved.").

**React admin app** — [react/admin/src/ApiClient.js](../../react/admin/src/ApiClient.js)
and [react/admin/src/Email/Messages/index.jsx](../../react/admin/src/Email/Messages/index.jsx):

- `ApiClient.moveMessages` and `ApiClient.setFlag` parse the new
  `{status, succeeded, failed}` body and return it (or a typed wrapper)
  instead of the raw axios response. Existing call sites that only need
  to know "did it work" continue to work via the `status` field.
- The bulk-action handlers in `Messages/index.jsx` (around lines 131–176
  for `setFlag`, `moveMessages`-to-Archive, `moveMessages`-to-Deleted,
  and the move-to-arbitrary-folder dispatch) consume `succeeded` /
  `failed` and surface a `AppMessageContext` toast on partial failure
  ("Moved 387 of 412 messages — 25 could not be moved."). The
  optimistic-update reconciliation in `refreshAfterMutation` continues
  to handle the bulk case, but the partial-failure toast prevents the
  user from silently losing 25 messages from view.
- Per-row single-message flag toggles in `Messages/index.jsx` (lines
  ~195–215) pass `refresh_list: false` to skip the post-mutation
  `sort()` call. Bulk flag changes from the multi-select bar continue
  to request `refresh_list: true` so the list re-renders against the
  new state.

Acceptance criteria:

- Both Lambda endpoints return the new uniform body shape; a synthetic
  test confirms `status == "partial"` is reported when at least one UID
  fails and at least one succeeds.
- Apple `ApiBackedImapClient` chunked path: a bulk move of 3,000
  messages issues 3 chunked Lambda calls (with `bulkChunkSize == 1000`),
  and a mid-chunk partial failure surfaces a `bulkPartialFailure` error
  with precise succeeded/failed UID sets.
- React: a forced server-side partial failure surfaces a toast naming the
  succeeded and failed counts; the failed rows remain in the list.
- React: single-message flag toggle latency drops measurably with
  `refresh_list: false` (eyeball test; no specific number required).

### React app: concrete benefits

The Lambda response-shape change addresses these existing problems in the
React app's bulk-operation surface, independent of the Apple work:

- **Honest error reporting.** The bare `except: return {"status":
  "unable"}` in `move_messages` currently hides the real IMAP error from
  the user and from logs. After Phase 4, the failure reason flows back to
  the toast and to CloudWatch.
- **Partial-success visibility.** Today, a bulk move where some UIDs
  succeed and some fail is indistinguishable from total failure (the
  caller sees only an exception), so the user has no way to know which
  messages still need attention. After Phase 4, the React bulk-action
  handlers can show "Moved X of Y" and leave the failed rows highlighted.
- **Faster single-message flag toggles.** The `client.sort()` call in
  `set_flag` runs on every request, including per-row mark-read/unread
  taps. Making it opt-in cuts a server round-trip out of the most common
  bulk-action gesture in the inbox.
- **Set the stage for retryable bulk ops.** Once the failed-UID list is
  available client-side, a future "Retry failed" affordance in the
  React bulk action bar becomes trivial. Out of scope for this plan but
  worth noting.

### Phase 5: tests and a11y verification

Goal: lock in behavior and confirm the feature is usable for accessibility
users, across both clients.

- [apple/CabalmailKit/Tests/CabalmailKitTests/ApiBackedImapClientTests.swift](../../apple/CabalmailKit/Tests/CabalmailKitTests/ApiBackedImapClientTests.swift):
  add tests for chunked `setFlags` and `move`, including a happy-path
  multi-chunk case, a Lambda partial-failure case (`status: "partial"`),
  and a mid-chunk failure when chunking is engaged.
- New `apple/CabalmailKit/Tests/CabalmailKitTests/BulkSelectionTests.swift`
  (or extend `MessageListViewModelTests` if it exists) covering: selection
  set mutations, optimistic state on success, rollback on failure,
  partial-failure rollback granularity.
- React: extend
  [react/admin/src/Email/Messages/Messages.test.jsx](../../react/admin/src/Email/Messages/Messages.test.jsx)
  (and `Envelopes.test.jsx`) with cases that mock the Lambda returning
  `status: "partial"` and assert the toast text and that failed rows
  remain selected.
- Lambda: unit tests for `set_flag` and `move_messages` covering the
  three statuses (`ok`, `partial`, `failed`) and the `refresh_list`
  toggle behavior.
- Manual a11y pass with VoiceOver on iOS and macOS: bulk-mode entry,
  selection toggles, action bar, confirmation alerts. Record findings in
  the PR description and address regressions before merge.

Acceptance criteria:

- New Swift tests pass under `cd apple/CabalmailKit && swift test`.
- New React tests pass under `cd react/admin && npm run test`.
- New Lambda tests pass under `cd lambda/api && pylint --rcfile
  .pylintrc */function.py` (lint clean) plus the per-function local
  invocation path.
- VoiceOver pass documented in the implementing PR.

## Platform UX summary

| Platform                         | Enter bulk mode               | Range / multi gesture              | Exit / clear                            |
| -------------------------------- | ----------------------------- | ---------------------------------- | --------------------------------------- |
| macOS                            | Implicit (any cmd/shift click)| cmd-click toggle, shift-click range| Click empty row, Esc, or cmd-A then Esc |
| iPadOS regular w/ keyboard       | Implicit (cmd/shift click)    | Same as macOS                      | Same as macOS                           |
| iPadOS regular touch-only        | "Select" toolbar button       | Tap rows to toggle                 | "Done" button                           |
| iPadOS compact / iPhone          | "Select" toolbar button       | Tap rows to toggle                 | "Done" button                           |
| visionOS                         | "Select" toolbar button       | Tap rows to toggle (treat as iPad) | "Done" button                           |

## Risks and open questions

- **Latent SwiftUI selection bugs.** `List(selection: Set<...>)` has had
  rough edges on older OS versions, particularly around split-view
  detail-pane sync. Mitigation: keep the derived single-selection computed
  property simple and verify on the minimum OS targets declared in
  `apple/project.yml` early in Phase 1.
- **Optimistic state on partial failure.** Phase 4's per-UID rollback is
  more complex than the current single-message rollback. If implementation
  proves fiddly, fall back to "refresh the envelope list from the server"
  rather than per-UID surgery, at the cost of a visible flicker.
- **Bulk-mode discoverability on touch.** A single "Select" button can hide
  among the existing toolbar buttons. Watch for confusion and consider an
  onboarding tooltip if usage data (or user feedback) shows people aren't
  finding it.
- **Chunk size.** 200 is a guess. Validate against real Lambda timing
  during Phase 4; adjust before shipping.
- **Selection persistence across app suspend.** Out of scope; selection
  clears when the app is backgrounded long enough for the view to be torn
  down. Document as a non-goal if it surfaces during review.

## Out-of-scope follow-ups

- Cross-folder selection (e.g. "select all flagged across all folders").
- Server-side search-then-act ("flag all from sender X without scrolling").
- Saved selections / smart selections.
- Drag-and-drop bulk move on iPadOS and macOS (selection foundation makes
  this much easier; tracked separately).

## Verification end-to-end

The implementing PRs (one per phase, or grouped where it makes sense)
should each include:

1. `cd apple && xcodegen generate && xcodebuild -workspace
   Cabalmail.xcworkspace -scheme Cabalmail -destination
   'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` succeeds.
2. `cd apple/CabalmailKit && swift test` passes, including the new tests
   added in Phase 5.
3. Manual smoke on at least one Apple platform (iPhone simulator at
   minimum; macOS native app preferred for Phase 3 keyboard shortcuts).
4. For Phase 4:
   - `cd lambda/api && pylint --rcfile .pylintrc */function.py` is clean.
   - `cd react/admin && npm run test` is green.
   - A synthetic test (or a script that hits a stage account) bulk-moves
     > 1500 messages and confirms client-side chunking engages and the
     final folder state matches the request.
   - A forced partial failure (e.g. include one UID that has since been
     expunged) surfaces `status: "partial"` from the Lambda, a
     `bulkPartialFailure` on the Apple side, and a "Moved X of Y" toast
     on the React side.
5. CHANGELOG entry under an Unreleased 1.1.x section once any phase ships.

## CHANGELOG note

When the first phase ships, open an Unreleased section for 1.1.x in
[CHANGELOG.md](../../CHANGELOG.md) if one is not already present, and add
the user-visible behavior under "Added". Subsequent phases append to the
same Unreleased section until the release cuts. Per project convention, do
not record intermediate iteration or bug fixes within a phase - only what
ships.
