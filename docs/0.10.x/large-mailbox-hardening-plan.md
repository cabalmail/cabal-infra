# Large Mailbox Hardening Plan

## Context

The React webmail and the iOS/macOS clients both talk to the same `/list_messages`, `/list_envelopes`, `/move_messages`, `/set_flag`, and `/search` Lambda endpoints. The behavior was acceptable on a 0.1.x personal mailbox of a few hundred messages, but it falls over quickly as the mailbox grows: bulk operations on large selections fail visibly, the UI freezes while envelopes load, and every poll re-walks the entire folder. As people start using Cabalmail as a primary mailbox — instead of a forwarding target — these failure modes will start showing up regularly.

This document is an audit-then-recommendation pass. It catalogs how the current implementation breaks under large folders and large bulk operations, then proposes a staged set of changes that shrink the blast radius without rewriting either client. Concrete ticket-sized steps live at the bottom; the prose in the middle is the "why" the operator will want when reading those tickets a quarter from now.

The roadmap parks this under `0.10.x` because the changes are additive at every layer — no schema migrations, no IMAP semantic changes, no breaking API revisions. Each phase can ship independently and be rolled back by reverting one PR.

## Goals

- A 50,000-message folder opens within the same time budget as a 500-message folder. Add another zero by the same factor of slowdown.
- Bulk operations (Archive / Move / Delete / Mark read on a multi-thousand-message selection) either finish or fail cleanly. They never leave the server and the client disagreeing about what moved.
- The IMAP master-user session count against Dovecot stays bounded as a folder grows; today it scales with the number of pages the client renders.
- Pagination work that the Lambda already does is not redone by the client (and vice versa).
- The React webmail no longer renders every loaded envelope into the DOM. Memory and frame time scale with the visible viewport, not with the folder size.
- The clients remain interchangeable — the React behavior and the Apple behavior continue to agree on counts, ordering, and what "archive" means.

## Non-goals

- Building a server-side search index. Dovecot's `SORT`/`SEARCH` is the source of truth for ordering and matching; we are not introducing OpenSearch or a SQLite mirror in front of IMAP. (If a future workload demands it, that becomes its own plan.)
- Push notifications / IDLE-over-the-API. The Apple client already polls `/folder_status` and the React client polls `/list_messages`; neither needs to become event-driven for the bulk-ops problem. A separate `0.x` proposal can revisit push.
- A unified envelope cache shared across clients. The Apple client has `EnvelopeCache` on disk; the React client uses in-memory state plus `localStorage` for a few small lists. Reconciling those is out of scope here — each client's cache is fine for the load this plan targets.
- Conversation/thread grouping. Same answer: separate concern, separate plan.
- Apple-client bulk selection. The iOS/macOS UI today is single-select with swipe actions; adding a multi-select mode is a feature, not a hardening step. The Lambda changes here pave the way for it but the UI work is out of scope.

## Current state (audit)

### React webmail

The `Messages` middle pane polls `/list_messages` every 10 seconds and replaces `messageIds` with the full sorted UID list returned by the Lambda. `Envelopes` then turns that flat list into pages of `PAGE_SIZE = 30` (see [`react/admin/src/constants.js`](../../react/admin/src/constants.js)) and renders them inside a single `SwipeableList`.

Concrete failure modes:

1. **Unbounded message-ID list.** [`list_messages/function.py`](../../lambda/api/list_messages/function.py) runs `IMAPClient.sort(...)` and returns every UID in the body. On a 100,000-message folder the JSON payload is on the order of 700 KB - 1 MB. It fits under API Gateway's 10 MB ceiling but the polling cadence (`10 s` in [`Messages/index.jsx`](../../react/admin/src/Email/Messages/index.jsx)) means we pull that down six times a minute. The React `ApiClient.getMessages` is bounded by a 10-second axios timeout (`TIMEOUT = ONE_SECOND * 10` in [`ApiClient.js`](../../react/admin/src/ApiClient.js)), which the Lambda often exceeds on cold-IMAP sessions over big folders. The request appears to "fail" while the server is still working, leaving the IMAP session orphaned.

2. **Up-front parallel fan-out of envelope pages.** [`Envelopes.jsx`](../../react/admin/src/Email/Messages/Envelopes.jsx) loops over the full message-ID list and fires one `/list_envelopes` request *per page* synchronously inside `useEffect`:

   ```js
   for (let i = 0; i < numIds; i += PAGE_SIZE) {
     const ids = message_ids.slice(i, i + PAGE_SIZE);
     const page = Math.floor(i / PAGE_SIZE);
     api.getEnvelopes(folder, ids).then((data) => { ... });
   }
   ```

   A 10,000-message folder produces 334 concurrent in-flight requests. Each one opens a fresh IMAP session in `_shared/helper.py::get_imap_client` (LOGIN + SELECT + LOGOUT), so a single folder open burns through hundreds of Dovecot connections in a thundering herd. Only the first 4 pages are added to `envelopes` state for rendering, but all 334 fetches still race the network.

3. **No list virtualization.** Every envelope that lands in the `envelopes` state map renders as a `<SwipeableListItem>` with its own gesture recognizer. Once the user has scrolled past a few thousand messages, the DOM has thousands of swipe-enabled list items mounted; scrolling jank and memory pressure scale linearly. The `Observer` component fires "load page N+2 when the start-of-page-N row enters the viewport," which is good for *fetching*, but does nothing about *rendering*.

4. **Bulk operations are a single big-fan-in request.** `archiveSelected`, `deleteSelected`, `moveSelected`, and `runFlagOp` post the entire `selectedIdsArray` to `/move_messages` or `/set_flag` (see [`Messages/index.jsx`](../../react/admin/src/Email/Messages/index.jsx) around the bulk handlers). The Lambda then issues one IMAP `UID MOVE` or `UID STORE`. With a few thousand IDs:
   - The Lambda comfortably exceeds API Gateway's hard 29-second integration timeout while Dovecot is still processing. The client's 10-second axios timeout has already fired, the user sees an error, but the server keeps moving messages.
   - On retry the operation runs again, potentially against the same UIDs that just moved (now in the new folder), so failure is not idempotent.
   - There is no per-batch progress feedback. The UI freezes the bulk toolbar with no indication of how much remains.

5. **`set_flag` does a redundant full `SORT`.** [`set_flag/function.py`](../../lambda/api/set_flag/function.py) issues the flag mutation, then runs `client.sort(...)` over the entire folder and returns the result. The React client ignores the returned IDs — it calls `refreshAfterMutation()` which re-runs `/list_messages` and re-fetches the sorted IDs anyway. Two full `SORT` operations per flag change on large folders, when one would do (or zero, if the client trusted its in-memory ordering).

6. **`refreshAfterMutation` repeats step 1 + step 2.** Every bulk action triggers a fresh `/list_messages` poll AND a re-fan-out of every envelope page. On a folder with thousands of messages this is the most expensive moment in the lifecycle, and we trigger it after every bulk button press.

7. **`/list_envelopes` query-string carries IDs.** `ApiClient.getEnvelopes` encodes IDs as `?ids=[1,2,3,...]`. At PAGE_SIZE=30 this is fine. If a follow-on change raises the page size or moves to bulk-fetch, the URL silently exceeds API Gateway's per-request line limit before the body limit ever bites. This is a latent footgun, not a current bug.

8. **`counts` undercounts until the folder is fully loaded.** The header pill that says "12 of 100,000" and the `Unread (47)` filter are computed from the loaded envelopes only (see the `counts` `useMemo` in `Messages/index.jsx`). Until every page has been fetched — which today is "all of them, in parallel, eventually" — the user is reading inaccurate numbers. Once we virtualize and stop loading every page, this becomes a permanent inaccuracy unless we get the counts from the server.

9. **Stale `localStorage.removeItem("INBOX")` call.** `ApiClient.moveMessages` clears a localStorage entry called `"INBOX"` that is never written. Harmless, but a hint that the cache layer has drifted from its original intent.

### Apple client (CabalmailKit + Cabalmail/CabalmailMac)

The Apple client routes through [`ApiBackedImapClient`](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift), which adapts the React-shaped Lambda surface onto the `ImapClient` protocol. `MessageListViewModel` calls `topEnvelopes(folder:limit:50, totalMessages:)` on first load and `envelopes(folder:range:)` for pagination.

1. **Every refresh pulls the entire UID list.** `topEnvelopes` and `envelopes(range:)` both call `api.listMessageIds(...)` to grab the full sorted UID array, then either `prefix(50)` for the top page or filter by UID range for older pages. Each refresh therefore does *one round trip whose response size scales with folder cardinality*, just to derive a window the Lambda could have computed server-side. On a 100k-message folder this dominates the refresh budget end-to-end.

2. **Search range expansion.** `runSearch` runs `imapClient.search(...)` to get matching UIDs, then calls `envelopes(folder, range: minMatch...maxMatch)`. If the search hits both a recent message (UID 99,000) and an old one (UID 100), the range is 99,000 wide. Inside `ApiBackedImapClient.envelopes(range:)` that filters the *full UID list* by range and posts every windowed UID to `/list_envelopes` in a single request. For a sparse-but-wide match set, this is both wasteful and prone to API Gateway URL-length issues.

3. **`setFlags(uids:flags:operation:)` serializes by flag.** `/set_flag` accepts only one flag per call, so `setFlags(folder:, uids:, flags: [.seen, .flagged], operation: .add)` does one HTTP round trip per flag. Today the UI only ever sets one flag at a time, so this is latent — the structural issue is that a multi-flag toggle is N round trips, each of which carries the full UID set.

4. **No native bulk operations exposed yet.** The iOS/macOS UI today is single-select; `dispose(_:)` operates on one envelope at a time. The Lambda-level limits don't bite the Apple client *yet*, but they will the moment someone wires a multi-select toolbar in. We should fix the API contract before then so we never ship a UI on top of a broken bulk endpoint.

5. **Sparse-folder pagination dead-ends prematurely.** `loadMoreIfNeeded` decrements `lowestUID - pageSize` to form the next window. If the folder is sparse (many UIDs deleted/expunged), an empty fetch from a low band sets `hasMore = false` and the client stops paginating, even though there may be older messages further down. The current heuristic optimizes for the common case but stops too early on heavy-archival mailboxes.

### Lambda surface

1. **One IMAP session per request.** `_shared/helper.py::get_imap_client` does a fresh `LOGIN ... SELECT folder` on every invocation and the call site `logout()`s at the end. There is no connection reuse across warm invocations of the same Lambda — the module-level `import` runs once, but the client object is constructed inside the handler. A burst of 300+ envelope fetches in a folder open thrashes Dovecot's session pool.

2. **`/list_messages` has no server-side pagination.** It returns every UID. There's no `?offset=` / `?limit=` / `?since_uid=` mechanism. Either the entire mailbox lives in one response or it doesn't fit at all.

3. **`/list_envelopes` accepts arbitrary `ids` set with no upper bound.** Fine when the React client caps at PAGE_SIZE=30; brittle as soon as either client decides to batch larger.

4. **`/move_messages` ships a single IMAP `UID MOVE <set>`** regardless of size. The IMAP server segments this internally on some implementations and not others. Dovecot handles large UID sets, but the API Gateway 29-second integration timeout is the binding constraint and `client.move(...)` blocks the Lambda for the entire IMAP round trip.

5. **`/set_flag` re-runs `SORT` after every store** (`response = client.sort(...)`) and returns the result. The clients ignore the result; on a 100k-message folder this doubles the Lambda's wall-clock cost.

6. **`/move_messages` always tries to create the "Deleted Messages" folder** when destination matches that string, even though Dovecot already auto-creates standard folders. Wasted round trip on every delete.

7. **Lambda timeout (30 s) > API Gateway integration timeout (29 s).** The Lambda keeps billing past the visible client failure. This is a small money leak rather than a correctness bug, but it makes the failure invisible to CloudWatch alarms that watch for Lambda timeouts.

## Recommendations

The recommendations stack: cheap-and-broad changes first (move the contract toward bounded payloads), then narrower client-side work that depends on the contract being in place.

### Layer 1 — API contract (Lambda)

These are additive: every change here adds a parameter or a new endpoint that defaults to the current behavior when omitted. No client has to upgrade in lockstep.

1.1 **Paginate `/list_messages`.** Add optional `?offset=N&limit=M` (or `?after_uid=N&limit=M` — `after_uid` is friendlier to clients that already have a window). The Lambda still runs `SORT` against Dovecot (we are not building a separate index), but it returns only the requested slice. The response shape gains `total` so the client can show "12 of 100,000" without fetching the whole list. Behavior when neither parameter is set: unchanged — return the full sorted UID array, so existing clients keep working.

1.2 **Drop the redundant `SORT` from `/set_flag`.** Stop calling `client.sort(...)` after `add_flags`/`remove_flags`. Return `{"status": "submitted"}` matching `/move_messages`. The React client ignores the IDs today and re-polls; the Apple client decodes them optionally and discards them. This is a one-line change but it halves the cost of every flag toggle on large folders.

1.3 **Cap `/move_messages` and `/set_flag` server-side by chunking.** Inside the Lambda, batch the incoming `ids` list into chunks of `MAX_IDS_PER_IMAP_CMD` (start at 500 — a value that fits well inside `client.move` performance on Dovecot and inside the 29 s envelope) and issue sequential IMAP commands. If the total list exceeds `MAX_IDS_PER_REQUEST` (start at 5,000), return `413 Payload Too Large` with `{"max_ids": 5000}` so the client knows to chunk. The chunking inside the Lambda is the cheap save; the 413 is the guardrail.

1.4 **Add `/move_messages_chunked` (or a `chunked: true` flag) that runs asynchronously.** For truly large selections (10k+), do the IMAP work from a Step Function or from the Lambda backgrounded via SNS, return a job ID immediately, and expose `/job_status?id=`. Out of scope for the first ship; in scope as a fast follow if bulk-moves on large selections turn out to be a regular operation. Start with chunking; promote to async only if the synchronous path's 29 s ceiling is a real constraint.

1.5 **Reuse IMAP connections inside the Lambda execution environment.** Hoist `IMAPClient` construction out of the handler and into module scope, keyed by user. Use an idle-timeout in the helper module so warm invocations of the same Lambda for the same user reuse the same authenticated session. Today's `get_imap_client(...)`-then-`logout()` pattern can be turned into a context manager that returns a pooled client. The win is significant for the per-envelope-page fetches the React client fans out, and even bigger for the post-pagination world where each Lambda invocation may now serve several IMAP commands per request.

1.6 **Skip the "Deleted Messages" auto-create when the folder already exists.** One STATUS call, or just trust Dovecot's autocreate. Trivial.

1.7 **Tighten the Lambda timeout to 29 s** (`terraform/infra/modules/app/modules/call/lambda.tf` — currently `timeout = 30`). Aligns billing with the visible failure boundary. Out of scope: per-endpoint timeouts. The call module's single 30 s value applies to everything; one second back to the user is the right default.

1.8 **(Optional) Add `/list_messages_with_envelopes`.** A single endpoint that returns the first page of envelopes alongside the windowed UID list, so a folder-open round trip drops from 2 (list_messages -> list_envelopes) to 1. Defer until the per-call IMAP-reuse work (1.5) is in place; once sessions are reused, the bundled endpoint is straightforward and the savings are real.

### Layer 2 — React webmail

2.1 **Stop fanning out every page on folder open.** Replace the current `for (let i = 0; i < numIds; i += PAGE_SIZE)` loop with a queue that fetches the visible page plus a small look-ahead (one page above, one below). Use the `Observer` already in place to drive subsequent fetches as the user scrolls. Once Layer 1.1 ships, drop the local "compute the page from the full ID list" logic entirely and call `/list_messages?after_uid=&limit=` per page.

2.2 **Virtualize the envelope list.** Wrap the `SwipeableList` in a virtualized container (`react-window` or `@tanstack/react-virtual`). Render ~30-50 envelopes in the DOM regardless of how many are loaded in state. The `SwipeableList` library's current full-render assumption is the main blocker; investigate whether it supports a windowed mode or whether we need to swap the swipe implementation.

2.3 **Move the polling source of truth to `/folder_status`.** Replace the 10-second `/list_messages` poll with a 10-second `/folder_status` poll. Only re-fetch IDs when `UIDNEXT` advances or message count drops (matching what the Apple client already does in `ApiBackedImapClient.idle(folder:)`). Cuts the steady-state poll cost from O(folder) to O(1).

2.4 **Cap bulk selection and chunk bulk operations client-side.** Until Layer 1.4 ships:
- Show "Select all loaded" and "Select all in folder" as distinct actions. Most users want the former.
- Cap a single bulk action at the per-request limit (1.3) — refuse to issue a `/move_messages` with more than `MAX_IDS_PER_REQUEST` and surface a clear message instead.
- Inside the cap, chunk client-side anyway (say, 250 per request). Show progress (`Archiving 1,400 of 3,200...`). Stop on the first error and offer retry-from-where-we-left-off.

2.5 **Optimistic UI for bulk ops.** Remove rows from the in-memory envelope state immediately on submit; reconcile on `/folder_status` change rather than re-polling `/list_messages` after every mutation. Matches what the Apple client already does for single-row dispose.

2.6 **Trust the server for `Unread (N)` / `Flagged (N)` pill counts.** Have `/folder_status` return `unseen` and `flagged` (it already exposes `unseen`). Stop computing pill counts from loaded envelopes. The "all" count comes from `total` in the paginated list_messages.

2.7 **Per-call timeouts proportional to operation size.** The 10-second axios `TIMEOUT` is fine for `/list_envelopes` on 30 UIDs but wrong for `/move_messages` on 500 UIDs. Switch to per-method timeouts (`getMessages`: 20 s, `moveMessages`/`setFlag`: 25 s, etc.) and align with the new Lambda 29 s ceiling.

2.8 **Delete `localStorage.removeItem("INBOX")`.** Dead code.

### Layer 3 — Apple client

3.1 **Use paginated `/list_messages` directly from `ApiBackedImapClient`.** Replace the "fetch all UIDs, then prefix/window in-memory" pattern in `topEnvelopes` and `envelopes(folder:range:)` with a single call to the paginated endpoint. The protocol already exposes a `limit` to `topEnvelopes`, so the wire change is local to `ApiBackedImapClient`.

3.2 **Bound the envelope fetch on `runSearch`.** When the match set is wide-but-sparse, post UIDs to `/list_envelopes` in chunks of `MAX_IDS_PER_REQUEST / 10` (matching the same per-request limit as bulk ops) rather than as one huge `ids=[]` query string. Even at the matching-set ceiling this keeps the URL well inside API Gateway's request-line limit.

3.3 **Stop sparse-pagination from giving up early.** Replace the "empty page -> `hasMore = false`" branch with "keep walking until the lowest UID returned by `/folder_status` (UID 1)." Cheap once Layer 1.1 lets us request "page below this UID" directly.

3.4 **Lay the groundwork for multi-select (UI work, separate ticket).** Once Layer 1.3 caps bulk ops on the server side, exposing a multi-select toolbar in `MessageListView` is straightforward: `Set<UInt32>` of selected UIDs, the existing `setFlags`/`move` methods on `ImapClient`, and a confirmation sheet for large selections. Not part of this hardening plan, but the API constraints land in the right place to make it safe.

3.5 **Batch `setFlags(flags:operation:)` better.** Today the loop is `for flag in flags { setFlag(...) }`. If/when we ever toggle two flags at once (e.g. "mark read + unflag"), pipeline them concurrently with `async let` rather than serially. Trivial.

### Layer 4 — Observability

4.1 **CloudWatch dimensions per endpoint.** Tag Lambda invocations with `endpoint` (already implicit in function name) plus `folder_size_bucket` (`<1k`, `1k-10k`, `10k-100k`, `>100k`) so we can see whether tail latency tracks folder cardinality. Easiest path: emit a structured log line at handler end and aggregate in CloudWatch Insights — no Terraform changes.

4.2 **Synthetic large-mailbox tests.** Add a sinkhole-style harness (similar to `docs/0.9.x/sinkhole-test-harness-plan.md`) that pre-populates a test mailbox with 50k messages and runs through the open/scroll/bulk-archive flow on each release. Lives alongside the existing test suite; runs in `development`.

4.3 **Alarm on Lambda timeouts for the message-list endpoints.** Once the Lambda timeout drops to 29 s (1.7), an actual timeout becomes signal rather than noise. Wire a CloudWatch alarm on `Duration` p99 > 25 s for `list_messages` and `list_envelopes` and a separate one on the timeout `Errors` metric.

## Risks and trade-offs

- **Pagination changes the "select all" semantics.** Today the React client *does* eventually have every envelope loaded after the up-front fan-out, so "select all" really does select everything. Once we stop loading the whole folder, "select all loaded" becomes the more honest UI; "select all in folder" needs server-side affordance (Layer 1.3/1.4). We need to land both before promising the latter.
- **Trusting `/folder_status` for unread counts requires the Lambda to be correct about subscriptions.** Today `unseen` comes straight from IMAP STATUS, which is fine for the current folder, but the per-folder navigation badge in the React app currently relies on the (incidentally-loaded) envelope flags. Switching to STATUS for all unread counts means each folder change requires its own STATUS call; cheap individually, but worth batching if we ever add a sidebar with badges for every folder.
- **Pooled IMAP sessions in the Lambda module scope** require careful eviction. If a user changes their password the pooled session becomes invalid and the next request fails until the pool entry is evicted. Mitigation: short idle timeout (say 60 s — Lambdas live ~15 minutes warm but the session pool inside one execution environment doesn't have to), plus a "kill on auth-failure" branch.
- **Chunking inside `/move_messages` changes the failure mode.** Today a single `UID MOVE` either succeeds for all UIDs or fails for all. Chunked, we can succeed for the first N chunks and fail on the (N+1)th, leaving the user with a partial move. Return `{ "moved_ids": [...], "failed_ids": [...] }` so the client can re-issue only the failed chunk.
- **Virtualization on top of `react-swipeable-list` may not be free.** The current library renders everything; if it doesn't support windowing we'll either need to swap libraries (touchpoint: every row in `Envelope.jsx`) or vendor a lightweight swipe wrapper. Scope this before committing to 2.2.

## Phased rollout

Each phase is a candidate PR or small set of PRs. Phases are ordered for cost/risk; later phases assume earlier ones.

**Phase 1 — Server-side cleanup (Layer 1.2, 1.6, 1.7).** Drop the redundant `SORT` in `/set_flag`, skip the "Deleted Messages" autocreate, tighten the Lambda timeout to 29 s. Three small changes. No client impact. Ships through `stage` -> `main` standard PR flow.

**Phase 2 — Bulk-op safety net (Layer 1.3).** Server-side chunking inside `/move_messages` and `/set_flag` with a 5,000-ID per-request cap. React client refuses to submit more than that, surfaces a clear message. No new endpoint, no new contract.

**Phase 3 — Pagination contract (Layer 1.1).** Add `?offset=&limit=` (or `?after_uid=&limit=`) and `total` to `/list_messages`. Default behavior unchanged so old clients keep working. Both clients ship in lockstep but the server is backward-compatible, so we can land the server first and the clients in follow-up PRs.

**Phase 4 — React client adopts pagination + virtualization (Layer 2.1, 2.2, 2.7).** Stop the parallel fan-out, virtualize the list, switch to per-method timeouts. This is the most user-visible improvement and should land as a single coordinated PR with a manual test pass.

**Phase 5 — Apple client adopts pagination (Layer 3.1, 3.2, 3.3).** Mirror the React work inside `ApiBackedImapClient`. Smaller change because the view-model already paginates conceptually — only the wire path needs to change.

**Phase 6 — `/folder_status`-driven polling (Layer 2.3, 2.6, 4.3).** Replace the 10 s `/list_messages` poll with a 10 s `/folder_status` poll; surface unread/total counts from STATUS. Wire CloudWatch alarms once Phase 1's timeout change is in place.

**Phase 7 — IMAP session pooling in the Lambda (Layer 1.5).** Module-scope pool with idle-timeout and kill-on-auth-failure. Ship behind a feature flag, then enable per-environment. Phase 7 is the highest-risk change in the plan; it goes last so the rest of the work is already paying off when we touch the connection layer.

**Phase 8 — Async bulk endpoint, if needed (Layer 1.4).** Only if the synchronous chunked path (Phase 2) shows up as a real ceiling. Otherwise close this thread.

Layer 4 observability (4.1, 4.2) sits alongside Phases 1-3 — small, independent, useful as soon as it lands.
