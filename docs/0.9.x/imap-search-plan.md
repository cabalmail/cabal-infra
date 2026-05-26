# IMAP Search Plan

## Context

Cabalmail has a "search" surface today, but only the Apple client wires it to a server. The React webmail has no message search at all — the search-ish controls in the message list are in-memory filters over the envelopes that happen to be loaded ([`react/admin/src/Email/Messages/Envelopes.jsx`](../../react/admin/src/Email/Messages/Envelopes.jsx)). The Apple client *does* hit a `/search` Lambda ([`lambda/api/search/function.py`](../../lambda/api/search/function.py)), but that endpoint is a thin passthrough that accepts a raw IMAP SEARCH criteria string and forwards it to Dovecot, which has no full-text-search plugin installed — so a body search is a sequential scan of every message in the selected folder, reading `Maildir` files over EFS. The contract is also single-folder: there is no "search my whole mailbox" call, no envelope-rich response, and the raw-IMAP-syntax wire shape leaks server semantics into clients.

This document audits the current state, lays out a server-first plan to turn IMAP search into a first-class feature, and stages the work so each phase is independently shippable.

This work lands in `0.9.x` alongside the lambda-layer-removal, sinkhole-test-harness, and SMTP-out queue-persistence plans. It is a deliberate scope expansion beyond the `0.10.x` [large-mailbox-hardening plan](../0.10.x/large-mailbox-hardening-plan.md), which explicitly carved out "building a server-side search index" as a non-goal. That non-goal stands for the hardening work; this plan picks it up as its own initiative.

## Goals

- A header- or body-text search across a folder returns within ~1 s on a 50,000-message mailbox after the index is warm. Across all folders, within a small multiple of that.
- The React webmail gains a real search bar that finds messages anywhere in the user's mailbox — not just in whatever envelopes are currently loaded.
- The Apple client keeps its existing UX but moves off raw IMAP-SEARCH syntax onto the structured Lambda contract.
- Search supports the common filters a user would expect: `from`, `to`, `subject`, free-text, date range, `unread`, `flagged`, `has-attachment`.
- Search runs against the user's full subscribed mailbox by default, with a "this folder only" affordance. Trash and Spam are excluded from "all mail" search unless explicitly opted in.
- The clients converge on a single contract. Raw IMAP-SEARCH passthrough is removed once both clients have migrated.
- Search is private. The system does not log query terms, result identifiers, or result counts. Observability is limited to operational signals (success/failure, server-side latency, whether Dovecot served from the FTS index or fell back to sequential scan) that reveal no information about what the user searched for or what came back.

## Non-goals

- Threading / conversation grouping. Out of scope here, separate plan if/when it lands.
- Saved searches and recent-search history. Plausible follow-on; not part of this plan.
- Search across multiple users' mailboxes. Per-user is the only mode.
- Semantic / vector search. The index is lexical only — Dovecot FTS or equivalent. ML-flavored search is a different conversation and a different cost profile.
- Real-time search-while-typing with character-by-character results. Debounced submit is the bar; the cost profile of typeahead against IMAP SEARCH (even with FTS) is not worth it at the scale Cabalmail runs.
- Indexing the text content of attachments (PDFs, Office docs, etc.). Body and headers only. The decode-pipeline cost (Tika or similar) is large for a personal mailbox and the user value is marginal at this scale. Not on the roadmap — if user demand ever changes the calculus, it becomes its own plan, not a follow-on phase of this one.
- A separate search service (OpenSearch / Solr / Elasticsearch). The plan keeps the index inside Dovecot — both because per-user mailboxes on EFS already fit Dovecot's per-user FTS model and because adding a managed search cluster doubles the infra surface for a single-tenant system.
- Content-revealing logs or metrics. Query text, the user's filter selections, result UIDs, result counts, "did this query hit the truncation cap" — none of these are recorded. The trade-off: some operational questions (most-common query shapes, distribution of result-set sizes, retry patterns) become unanswerable from telemetry, by design. If we ever need a specific operational signal that isn't covered by success/failure + latency + index-path, we add it then with an explicit content-free design — we do not loosen the default.

## Current state (audit)

### React webmail

The "search" affordances in the Messages middle pane are not search. `Envelopes.jsx` defines two in-memory filters:

```js
function matchesFilter(envelope, filter) { /* unread | flagged checks */ }
function matchesAddress(envelope, address) { /* recipient-name contains */ }
```

Both apply only to envelopes already loaded into component state. There is no API call, no input field that submits to a backend, and no concept of "find messages not currently in view." The "From" picker in the compose overlay ([`react/admin/src/Email/ComposeOverlay/FromPicker/index.jsx`](../../react/admin/src/Email/ComposeOverlay/FromPicker/index.jsx)) does have a search box, but it filters the user's *own addresses* — not messages.

### Apple clients

The iOS/macOS UI exposes a search field bound to `MessageListViewModel.searchQuery`. On submit, [`MessageListViewModel.runSearch()`](../../apple/Cabalmail/ViewModels/MessageListViewModel.swift) does:

```swift
let query = "TEXT \"\(searchQuery.replacingOccurrences(of: "\"", with: "\\\""))\""
let matches = try await client.imapClient.search(folder: folder.path, query: query)
```

That call lands in `ApiBackedImapClient.search(folder:query:)` ([`apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift`](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift)), which POSTs the literal `TEXT "..."` string to `/search` and gets back a UID list. The view-model then takes the `min...max` UID range and asks `/list_envelopes` for that range, filtering client-side. Concrete problems:

1. **Raw IMAP-SEARCH syntax on the wire.** Clients are responsible for IMAP quoting, CHARSET handling, and protocol-aware escaping. The current quoting (`\"` for `"`, nothing else) is brittle; a query containing backslashes, parentheses, or non-ASCII characters will round-trip wrong.
2. **UID-only response, envelope fan-out client-side.** A search that matches UID 10 and UID 99,000 makes the Apple client ask for `envelopes(range: 10...99000)` and filter, which is exactly the wasteful range expansion called out in [`large-mailbox-hardening-plan.md`](../0.10.x/large-mailbox-hardening-plan.md) (current state, Apple client, item 2). The hardening plan paper-fixes it by chunking; the real fix is to have the search endpoint return envelopes directly.
3. **Single-folder scope only.** There is no "search across all folders" affordance in the protocol or the UI.
4. **`TEXT` searches scan bodies sequentially.** Dovecot has no FTS plugin configured (see below). Every body search becomes a per-message disk read on EFS. On large folders this is the most expensive operation in the system.

### Lambda `/search`

[`lambda/api/search/function.py`](../../lambda/api/search/function.py) accepts `folder`, `host`, optional `charset`, and a `query` string that is passed verbatim to `IMAPClient.search(...)`. Concrete problems:

1. **No input validation.** The Lambda passes whatever the client sends through to Dovecot. The IMAP server enforces folder/user scoping via the master login, so this is not a security bug, but it means there is no contract: any change to the query language is a client-server lockstep change with no schema to negotiate.
2. **UIDs only.** Response is `{"message_ids": [...]}`. The clients then have to round-trip back to `/list_envelopes` to render anything. Two requests per search by construction, and the second one is the wide-range fan-out described above.
3. **Single folder.** The handler does `client.select_folder(folder, ...)` and runs `search(...)` inside it. There is no per-call multi-folder iteration.
4. **No pagination, no ordering.** The full match set is returned, in whatever order Dovecot supplied. For a query that matches 10k messages, that's a 10k-element array, the client picks the range, and the rest is discarded.
5. **No connection reuse.** Inherits the `get_imap_client(...)` -> `logout()` pattern. Same per-request session cost as the rest of the API surface.

### Dovecot

`docker/imap/configs/dovecot/` has no `plugin { fts ... }` block, no `fts_xapian` or `fts_flatcurve` config, no `mail_plugins = ... fts ...` setting. The image installs stock Dovecot from `amazonlinux:2023`. Two consequences:

1. **`SEARCH BODY`/`SEARCH TEXT` is O(folder).** Every body search reads every message file from `Maildir` over EFS. On a small mailbox this is acceptable; on a primary mailbox it is the slowest user-visible operation in the system.
2. **No header pre-indexing either.** Even `FROM`/`TO`/`SUBJECT` searches require Dovecot to read message headers from disk (mediated by Dovecot's own caches, but not by a search index). It's faster than body search but still scales with folder size.

### Lambda surface (broader)

There is no `/search_envelopes`, `/search_all`, or `/find` endpoint. There is no notion of search jobs, search progress, or paginated search results in the API contract. There is no SSM parameter, no Terraform variable, no DynamoDB table related to search. The search story is what's in `lambda/api/search/function.py` plus what the clients improvise around it.

## Recommendations

The recommendations stack: cheap-and-broad first (rebuild the contract), then the index work that the new contract makes worthwhile, then client adoption.

### Layer 1 — API contract (Lambda)

These additions deprecate the raw-syntax wire shape and stand up a structured replacement. The original `/search` endpoint stays in place during the migration; new endpoints land alongside.

1.1 **New endpoint: `/search_envelopes`.** Accepts a structured query, returns envelopes plus a continuation cursor. Wire shape:

```
GET /search_envelopes
  ?host=imap.cabalmail.com
  &folder=INBOX                     // optional; omit for cross-folder search
  &text=hello%20world               // tokenized, AND-of-terms; matches body+headers
  &from=alice@example.com           // optional
  &to=bob@example.com               // optional
  &subject=invoice                  // optional
  &since=2026-01-01                 // ISO date, optional
  &before=2026-04-01                // ISO date, optional
  &unread=1                         // optional flag predicate
  &flagged=1                        // optional flag predicate
  &has_attachment=1                 // optional; see 1.2
  &limit=50                         // default 50, max 200
  &cursor=<opaque>                  // pagination

Response:
  { "envelopes": [...],            // envelope shape matches /list_envelopes
    "total_estimate": 137,         // approximate; exact when match set fits in one page
    "next_cursor": "...",          // null when last page
    "folders_searched": ["INBOX", "Archive", ...] }
```

The Lambda translates structured params into an IMAP SEARCH criteria list server-side. Clients never write IMAP syntax. UTF-8 is the only accepted charset; the Lambda sets `CHARSET UTF-8` on every call so non-ASCII queries are unambiguous.

1.2 **`has_attachment` predicate.** Implemented in two phases: until FTS lands (Layer 2), the Lambda computes it from envelope `BODYSTRUCTURE` for matched UIDs and filters post-hoc. Once FTS lands, it can be expressed as a header predicate (`HEADER Content-Type multipart/mixed` plus tighter shape checks) or via a dedicated FTS field if the indexer supports it.

1.3 **Cross-folder mode.** When `folder` is omitted, the Lambda enumerates the user's subscribed folders (via `client.list_sub_folders()`), excludes `Trash` (the one folder users genuinely don't want search results from — Spam / Junk stay searchable because misclassified mail is a real use case for "search everything"), and runs the SEARCH against each. Implementation options:

- **Sequential SELECT/SEARCH per folder, merge results, sort newest-first.** Simplest; latency scales with folder count. Acceptable on typical mailboxes (handful to dozens of folders).
- **Dovecot virtual folders.** Configure a virtual `Virtual/AllMail` namespace at the server side; the Lambda SELECTs that one folder and runs SEARCH once. Faster but requires Dovecot config changes (`mail_plugins = ... virtual`) and a per-user namespace declaration synced from the user list.
- **Lambda-side fan-out with asyncio.** Open multiple IMAP sessions and SEARCH folders in parallel. Most performant; most session pressure.

Start with sequential; if it bites, promote to the virtual-folder option (it's the architecturally clean path).

1.4 **Pagination via cursor, not offset.** The cursor encodes `(folders_remaining, last_internal_date, last_uid)`. UIDs are stable within a folder; combined with internal-date ordering we get a "next page" that survives modest mailbox churn. Offset would mean re-running the full SEARCH on every page, which we will not do.

1.5 **Server-side result cap.** Hard cap on total results per query: 5,000 (matching `MAX_IDS_PER_REQUEST` from the hardening plan). When the SEARCH hits the cap, return the first 5,000 + a flag saying "results truncated, refine your query." This bounds the wall-clock cost.

1.6 **Reuse the existing `helper.get_imap_client(...)` evolution.** This plan does not need to invent connection pooling — Phase 7 of the hardening plan covers it. The search endpoints benefit transparently from that work once it lands; in the meantime they pay the same per-request session cost as the rest of the surface.

1.7 **Retire `/search` (the raw-syntax endpoint).** Keep it for one release after both clients migrate, then delete. The Apple client is the only consumer; the cutover is bounded.

1.8 **Folder exclusion list is per-user-configurable, eventually.** Default in code; can be moved to a DynamoDB-stored preference later if users want per-account control. Out of scope for the initial ship.

### Layer 2 — Dovecot full-text search index

Without FTS, the new contract makes search ergonomically nicer but does not make it faster. Adding FTS is the work that turns body search from "sequential read every message file" into "consult an inverted index."

2.1 **Pick the indexer: `fts_flatcurve`.** Two real candidates:

- `fts_xapian` — file-per-mailbox index, well-trodden, but relies on Xapian's locking model which interacts badly with NFS. EFS is NFSv4 underneath. Has known issues on NFS-backed mail stores.
- `fts_flatcurve` — written by the maintainer of `fts_solr` specifically to be NFS-safe, embedded in Dovecot, file-per-mailbox-message index segments. Designed for the storage shape we already have. This is the right default for a Cabalmail-shaped deployment.

Either way, the index lives next to each user's `Maildir` on EFS (`~/Maildir/.fts/...` or similar). Index size is typically 10-20% of mail volume.

2.2 **Package fts_flatcurve into the `imap` container.** It is not in the default `amazonlinux:2023` Dovecot package. Two options:

- Build from source as part of `docker/imap/Dockerfile`, pinned to a known good revision. The build is small (a few hundred KB once compiled) and Cabalmail already builds dovecot configuration into the image; one more compile step is tolerable.
- Pull from a community RPM repo, if one tracks AL2023. Less control.

Default to building from source; revisit if a stable repo appears.

**License:** Upstream `dovecot-fts-flatcurve` (https://github.com/slusarz/dovecot-fts-flatcurve) is LGPL-2.1 (exactly version 2.1; no "or later" clause). LGPL-2.1 is compatible with our AGPL-3.0 infra by design — LGPL libraries are explicitly meant to be combinable with works under other licenses. Cabalmail-authored code stays AGPL-3.0, flatcurve stays LGPL-2.1, no relicensing required on either side. Obligations we pick up by shipping the binary in the imap container image:

- Preserve flatcurve's `COPYING` file and copyright notices inside the image, alongside the installed binary.
- Pin the build to a specific upstream commit or release tag so the corresponding source is identifiable.
- Make source available under LGPL-2.1 section 4(c) — pointing at the pinned upstream URL in the image's documentation or a `THIRD-PARTY-LICENSES` file is sufficient.
- If we ever patch flatcurve, the patch ships under LGPL-2.1 (preferably upstreamed). The plan assumes verbatim upstream; revisit if that changes.

2.3 **Configure plugin and triggers.** Sketch in `docker/imap/configs/dovecot/conf.d/90-fts.conf`:

```
mail_plugins = $mail_plugins fts fts_flatcurve

plugin {
  fts = flatcurve
  fts_autoindex = yes
  fts_autoindex_exclude = \Trash
  fts_enforced = yes
  fts_flatcurve_min_term_size = 2
  fts_flatcurve_substring_search = no    // exact-term first; substring is expensive
}
```

`fts_enforced = yes` makes Dovecot refuse to fall back to sequential scan when the index is unavailable — preferable to a silent slow path. The autoindex exclude list matches the cross-folder search's exclude list (Trash only).

2.4 **One-shot reindex for existing mailboxes.** When the FTS plugin first lights up, no mailbox has an index yet. Provide a manual reindex command (`doveadm fts rescan -u <user>`) and run it for every existing user during the rollout window. Document in the release notes. On a multi-gigabyte mailbox this is minutes-of-CPU work; acceptable as a one-time cost.

2.5 **EFS performance considerations.** FTS indexing is small-file-heavy. EFS throughput scales with provisioned capacity; if reindex throttles, bump `provisioned_throughput_in_mibps` in [`terraform/infra/modules/efs/main.tf`](../../terraform/infra/modules/efs/main.tf) for the duration of the reindex and back off afterward. Document the steady-state index size in `docs/operations.md` once measured.

2.6 **Trash is excluded from the index.** Trash is the one folder users don't want search results from, so indexing it would be wasted EFS throughput. Spam and Junk stay indexed: misclassified mail is a real use case for "search everything," and the cost of indexing them is small compared to the user-value of finding a legitimate message that ended up in Spam. The FTS exclude list matches the Lambda's cross-folder default — Trash only.

2.7 **No attachment-text indexing — not in this plan, not as a follow-on.** `fts_flatcurve` can be paired with a decoder pipeline (`tika` or similar) to index attachment text. Cabalmail is not adopting that. The decode CPU cost is large, the user value at our scale is marginal, and bringing it in would force decisions about decoder lifecycle, format support, and re-decode-on-failure that this plan should not pick up. Captured in the non-goals; if it ever comes back, it is a separate plan.

### Layer 3 — React webmail

3.1 **Add a search bar to the Email view.** Place it above the folder/message list, debounced on submit (Enter or button). Use the new `/search_envelopes` endpoint. When the search input is empty, behavior reverts to the current folder view.

3.2 **Search results panel.** Render the result envelopes in the existing `Envelopes` component (reused as-is, or wrapped in a "search results" header that shows `total_estimate`, the active query, and a "clear" button). Selection, archive, delete, flag — all the bulk operations from `Messages/index.jsx` — work on search results identically to folder views. The hardening plan's bulk-op caps apply.

3.3 **Filter sidebar.** Surface the structured-query parameters as form fields: `from`, `to`, `subject`, date range, unread/flagged/has-attachment checkboxes, and a "this folder only" toggle (default off — cross-folder is the right default for "search"). The free-text input maps to `text=`. Modeled on common webmail conventions; the underlying API is what makes this cheap.

3.4 **No client-side caching of search results.** Each query is a fresh round trip. The cursor-paginated response handles "load more"; navigating away from the result set and back re-runs the query. Avoids the cache-invalidation work that the existing `localStorage`-based envelope cache (such as it is) does not handle gracefully.

3.5 **Wire `ApiClient.searchEnvelopes(...)`.** Mirrors the shape of `getMessages`/`getEnvelopes`. Per-method timeout proportional to the operation: 25 s default, matching `/move_messages` from the hardening plan's Layer 2.7.

3.6 **Keep the existing in-memory filter chips.** The unread/flagged filter pills in `Envelopes.jsx` are useful for the *folder* view independent of search. They stay. The new search is additive, not a replacement for the existing filters.

### Layer 4 — Apple client migration

4.1 **`ApiBackedImapClient.search(folder:query:)` becomes `searchEnvelopes(...)`.** New protocol method on `ImapClient` that takes a structured query (Swift `SearchQuery` struct) and returns envelopes + cursor. The old `search(folder:query:) -> [UInt32]` method stays during the deprecation window; `LiveImapClient` continues to implement it for parity, but no production code calls `LiveImapClient` (per the existing CLAUDE.md note on `ApiBackedImapClient`).

4.2 **`MessageListViewModel.runSearch` switches to the new method.** Build a `SearchQuery` from the search field text — initially just `{ text: searchQuery }` — and call `searchEnvelopes`. Drop the `min...max` UID range expansion; drop the `replacingOccurrences` quote-escape hack; drop the post-fetch filter step. The wire path becomes one request that returns envelopes directly.

4.3 **Filter UI in the iOS/macOS clients.** Mirror the React filter sidebar — `from`, `to`, `subject`, date range, unread/flagged/has-attachment — via a search-options sheet or inline pickers. UI work is its own ticket; the protocol underneath is the shared piece. Treat the structured `SearchQuery` as the contract both clients build against.

4.4 **Search-all-folders affordance.** Once the cross-folder Lambda mode (1.3) is in place, default the Apple search to cross-folder, with a "this folder only" toggle. Matches the React default. Keeps both clients honest about what "search" means.

4.5 **Once both clients ship on `searchEnvelopes`, delete the raw-syntax path.** Remove `/search` from the Lambda, remove `search(folder:query:)` from `ImapClient`, remove the `LiveImapClient` and `ApiBackedImapClient` implementations. Tighten the surface area.

### Layer 5 — Observability (privacy-constrained)

The hard constraint here is: **no query terms, no filter selections, no result UIDs, no result counts, no per-search content-derived signal in any log or metric.** Operational telemetry sticks to outcome + latency + storage-path signals. This shapes Layer 5 considerably — several signals an unconstrained search service would normally emit are deliberately not collected.

5.1 **Per-search structured log — content-free.** Every `/search_envelopes` invocation emits a single structured log line with exactly these fields: `outcome` (`success`/`failure`), `latency_ms`, `error_class` (only set when `outcome=failure`; the IMAP/Dovecot exception class, never the message body or query text), `index_path` (`fts`/`sequential`/`unknown` — Dovecot-side signal about which code path served the search, derived from Dovecot's own logs rather than from the query). No `user`, no `folder`, no `result_count`, no `query_kind`, no `truncated` flag. The `user` field would be hashed-trivially-reversible against the Cognito user pool and we don't need per-user telemetry to answer the operational questions we actually have; the API Gateway access log already carries enough of that for incident response.

5.2 **No truncated-rate alarm.** We deliberately don't record whether a query hit the 5,000-result cap, so we can't alarm on it. Two consequences worth naming: (a) we will not be able to tell from telemetry whether the cap is "right" — feedback has to come from users hitting it in the UI, where the "Showing first 5,000 of many — refine your query" affordance is the only signal; (b) if the cap proves wrong in either direction we adjust by changing the number, not by adding telemetry that contradicts the privacy stance.

5.3 **Content-free aggregate counter for cap hits (optional).** If the lack of any truncation signal turns out to be operationally painful, the minimum acceptable addition is a single CloudWatch custom metric — call it `SearchTruncationCapHits` — that increments by 1 each time the cap is hit, with **no dimensions**: no user, no folder, no query attributes. It tells us how many searches per day hit the cap across the whole system and nothing else. Land 5.1 first; only add this if 5.2's blindness actually bites.

5.4 **CloudWatch alarm on FTS-index-miss rate.** Once Layer 2 ships, an unindexed search is a regression. The alarm reads `index_path=sequential` counts from log metric filters — no per-search content involved, just a count of "this many searches in the last 15 minutes went the slow path." Threshold tuned to the steady-state miss rate Dovecot produces for newly-arrived-but-not-yet-indexed messages.

5.5 **Synthetic search check.** Extend whatever `large-mailbox` test harness lands out of the `0.10.x` plan to include "search for a known phrase, assert one match, assert latency under threshold." The test harness *does* know its own query text and expected result count, because the test owns both ends. That stays inside the harness; no production code path logs the same.

5.6 **Dovecot-side logging hygiene.** Dovecot's own logs need to be checked for inadvertent search-content leakage. By default, `mail_debug = no` and `auth_debug = no` keep SEARCH bodies out of syslog, but `fts_flatcurve` and Dovecot debug toggles can change that. Bake the audit into the Phase 4 rollout: confirm no SEARCH arguments make it into CloudWatch Logs from the container, and document the relevant `log_*` settings in `docs/operations.md`.

## Risks and trade-offs

- **fts_flatcurve packaging is more work than enabling a flag.** Building from source in `docker/imap/Dockerfile` adds a build dependency (`make`, `gcc`, Xapian headers) to the image. The image grows by ~5 MB after stripping. If the upstream project goes quiet, we're maintaining a build pinned to a snapshot. Mitigation: pin a known-good commit, document it, and re-evaluate annually. Fallback: switch to `fts_xapian` and accept the NFS-locking caveat (operationally we are single-writer per mailbox, so the locking risk is mostly theoretical for this deployment).
- **One-shot reindex is a foot-gun if not scheduled.** Reindexing a 5 GB mailbox burns CPU and EFS throughput for several minutes. Run during off hours; alert the operator before kicking it off. Document the operation in `docs/operations.md`.
- **Cross-folder search multiplies session cost.** Until connection pooling (hardening plan Phase 7) lands, one cross-folder search = N IMAP LOGIN/SELECT/LOGOUT cycles where N is the subscribed folder count. Acceptable for typical folder counts (5-20); not acceptable for users with hundreds of folders. Mitigation: keep the cap on subscribed-folder count in mind when prioritizing the pool work; if cross-folder search ships first, monitor session counts and gate behind a feature flag if needed.
- **Truncating at 5,000 results changes search semantics from "all matches" to "the first page of matches plus a hint that there are more."** Users used to "Inbox search returns everything" may find that surprising. Mitigation: be loud about it in the UI ("Showing first 5,000 of approximately 12,000 matches — refine your query"). The cap exists for a reason; the alternative is unbounded server work.
- **Pagination by cursor doesn't survive mailbox-side reflows during a search session.** If a user runs a search, archives some messages, and clicks "next page," the cursor may reference UIDs that have moved. The result is "minor result-set drift," not corruption: a few results may repeat or be skipped. Document; do not engineer around. Stronger guarantees would require a server-side snapshot of the match set, which is more state than the use case warrants.
- **`has_attachment` heuristics are imprecise.** Computed from BODYSTRUCTURE or via header predicates, `has_attachment` will catch inline images, calendar invites, and signature attachments that the user wouldn't think of as "attachments." Document the heuristic. Refine if user feedback warrants.
- **Cutover lockstep with the Apple client.** The raw-syntax `/search` endpoint can only be deleted once the Apple client has shipped on `searchEnvelopes`. Until then, two parallel search paths exist and the Lambda code in `lambda/api/search/function.py` stays untouched. Plan accordingly: the deletion is a follow-up PR, not part of the cross-folder ship.
- **No attachment-text indexing means users will be surprised.** Searching for a phrase that lives only inside a PDF won't find it. Document the limitation alongside the search UI. Reevaluate as a follow-on once the lexical-search surface is solid.
- **EFS index files do not back up cleanly under AWS Backup.** Dovecot indexes are derived data; if the EFS backup omits or corrupts them, `doveadm fts rescan` rebuilds them. Confirm AWS Backup includes (or safely excludes) the `.fts` directories. If they're backed up, point-in-time restores carry the index with them, which is fine. If they're not, post-restore needs a reindex pass. Either way, document.
- **The privacy constraint on logging makes some failures harder to debug.** A user reporting "search doesn't work" cannot be triaged from production telemetry — we cannot see their query, their result count, or whether they hit the truncation cap. The path forward is the same as it would be for an end-to-end-encrypted system: reproduce in a dev/stage mailbox with synthetic data, lean on Dovecot-side operational logs (which we audit in 5.6 to ensure they don't contain query content either), and iterate against the test harness. This is a deliberate trade: the privacy floor is more valuable than the debugging convenience.

## Phased rollout

Each phase is a candidate PR or small set of PRs. Phases are ordered cost/risk-first; later phases assume earlier ones.

**Phase 1 — Structured `/search_envelopes` Lambda, single folder only.** Land the new endpoint alongside the existing `/search`. Accept the structured query params, translate to IMAP SEARCH server-side, return envelopes (not just UIDs) with cursor pagination and the 5,000-result cap. No FTS yet — performance is whatever Dovecot's sequential scan gives us. No cross-folder yet — `folder` is required. Tests against a small fixture mailbox in the existing test harness.

**Phase 2 — React webmail picks up search.** Search bar in the Email view; result envelopes rendered via the existing component; filter sidebar with the structured params; cross-folder default off (since the Lambda doesn't support it yet). This is the most user-visible change in the plan and the one that closes the biggest current gap (React has no search at all today).

**Phase 3 — Cross-folder search in the Lambda.** Add the "no folder specified -> enumerate subscribed folders" path. Sequential per-folder SEARCH, merge results newest-first, exclude Trash by default. React's "search all folders" toggle becomes the default; Apple's existing UI keeps single-folder semantics for now.

**Phase 4 — Dovecot fts_flatcurve.** Build into the `imap` container; configure the plugin; one-shot reindex of existing mailboxes. Document the operation in `docs/operations.md`. This is the phase that makes body search actually fast — Phases 1-3 stand without it but search latency on large folders is unsatisfying until it ships.

**Phase 5 — Apple client migration.** New `searchEnvelopes` protocol method on `ImapClient`; `ApiBackedImapClient` calls the new endpoint; `MessageListViewModel.runSearch` switches over. UI for the structured filters can land in this phase or a follow-up; the protocol change is the gate. Once both clients are on the new endpoint, the raw-syntax `/search` deprecation timer starts.

**Phase 6 — Retire raw `/search` and `LiveImapClient` search path.** Delete `lambda/api/search/function.py`, remove the SSM/Terraform registration for it, drop the `search(folder:query:) -> [UInt32]` shape from `ImapClient.swift`. Strictly cleanup; no behavior change.

**Deferred: Phase 7 — Content-free observability.** Emit the privacy-constrained per-search log (outcome, latency, error class, index path — no query, no counts, no user). Wire the FTS-index-miss alarm off the log-derived metric. Audit Dovecot-side logs for inadvertent SEARCH-argument leakage and document the relevant `mail_debug`/`auth_debug`/`log_*` settings in `docs/operations.md`. Extend the synthetic search check in the test harness. Can run alongside Phase 4 or after. Note: the truncated-result-rate alarm from the original draft is **dropped** — recording truncation events would leak result-set shape, which the privacy goal disallows. The optional `SearchTruncationCapHits` aggregate counter (5.3) is a follow-up only if 5.2's blindness becomes operationally painful.

**Deferred: Phase 8 — Virtual-folder all-mail (optional).** Replace the Lambda's sequential per-folder fan-out with a Dovecot `Virtual/AllMail` namespace. Only if Phase 3's sequential approach proves too slow on real mailboxes. The architecturally cleaner answer; the question is whether it's worth the per-user namespace plumbing.

Phases 1-2 ship search functionally for React, on top of slow scans. Phase 4 makes it fast. Phase 5 brings Apple onto the same contract. Phases 3 and 6-8 are independently valuable and can be reordered against operational realities once the first two phases are out.
