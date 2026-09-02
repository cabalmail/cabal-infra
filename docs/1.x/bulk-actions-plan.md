# Bulk Actions Plan (query-driven selection and action pipelines)

## Progress

| Phase | Status |
|---|---|
| — | Design proposal, not yet reviewed. Phases are drafted at the bottom as input to the implementation plan, not as commitments. |

## Context

Every Cabalmail client selects messages the same way: enter a selection mode, then click rows one at a time. The React app added shift-click range extension ([`react/admin/src/hooks/useEnvelopeSelection.js`](../../react/admin/src/hooks/useEnvelopeSelection.js)) and the Apple clients added `selectAllVisible()` ([`apple/Cabalmail/ViewModels/MessageListViewModel+Bulk.swift`](../../apple/Cabalmail/ViewModels/MessageListViewModel+Bulk.swift)), but both operate over envelopes already rendered. The selection then travels to the server as a literal UID array, capped at `MAX_IDS_PER_REQUEST = 5000` ([`lambda/api/_shared/helper.py:342`](../../lambda/api/_shared/helper.py)).

That model has no answer for "archive the 30,000 messages I no longer want in my inbox." The user cannot click 30,000 rows, the client cannot hold 30,000 rendered envelopes, and the wire contract refuses more than 5,000 ids per call. The nearest thing that exists is `/search_envelopes`, which finds messages by a structured query but returns pages of envelopes for a human to read — it is a reading surface, not an acting one.

[`docs/0.11.x/multi-select-bulk-operations.md`](../0.11.x/multi-select-bulk-operations.md) named "server-side search-based bulk actions (flag all from sender X)" as an explicit non-goal, on the grounds that bulk actions operate on the user's explicit selection. That non-goal stands for that plan. This document picks it up as its own initiative, the same way the search plan picked up the index that the large-mailbox hardening plan had carved out.

The proposal: a **selection wizard** in every client that composes a query and an ordered list of actions, previews the match count, confirms, and hands the whole thing to the server as a **bulk job**. The client never enumerates UIDs. The server resolves the match set, applies the actions in batches, and reports progress.

## Goals

- Act on an arbitrarily large match set — 30,000 messages and beyond — without the user clicking rows and without the client holding the match set in memory.
- Compose conditions with AND and OR, and negate any of them. "Older than a month AND read AND (from any of these five senders)" is expressible in one query.
- Compose outcomes in order: mark read, then tag, then archive. One job, one pass.
- Show the user what they are about to do before it happens: a match count and a sample of matched messages, then an explicit confirmation naming the count and warning that it may take a few minutes.
- Never let a bulk job storm the mail tier. The IMAP tier is a single ECS task ([`terraform/infra/modules/ecs/services.tf`](../../terraform/infra/modules/ecs/services.tf), `desired_count = 1`) backed by EFS; a bulk job is the largest sustained load any user can generate, and it must stay bounded and behind the interactive API in priority.
- Serialize a user's jobs strictly in submission order, so two overlapping submissions resolve deterministically: the later one runs after the earlier one finishes, sees the state the earlier one left, and wins.
- Keep the mailbox usable while a job runs. The user can read, file, and send; a job is a background activity with a visible progress indicator, not a modal freeze.
- One contract, five clients. React, Apple, Android, Linux, and (if it ever needs it) the extension render the same wizard model natively.

## Non-goals

- **Undo.** A job is not reversible. Move is reversible by the user filing the mail back; purge is not reversible at all. Recording the destination UIDs a MOVE produced (Dovecot returns them via UIDPLUS `COPYUID`) would make a mechanical undo possible; that is a plausible follow-on, not part of this plan.
- **Saved queries, scheduled jobs, recurring cleanups.** A bulk job runs once, on demand. Standing behavior on *incoming* mail is what [mail rules](../mail-rules.md) already are; a scheduled sweep over existing mail is a different feature with a different risk profile.
- **A second query language.** The grammar defined here is the *one* structured query grammar. `/search_envelopes`'s current flat parameters become a legacy surface over the same compiler, not a parallel dialect.
- **Regular expressions, arbitrary header matching, attachment content, or semantic search.** The condition vocabulary is bounded by what IMAP SEARCH and Dovecot's FTS index can answer cheaply.
- **Cross-user or admin-initiated bulk actions.** A job runs as its owner, over its owner's mailbox, and nothing else.
- **Sending, composing, or forwarding as a bulk action.** Actions are confined to flags and message placement. Nothing in a bulk job puts mail on the wire.
- **Replacing manual selection.** Row-by-row selection stays exactly as it is. The wizard is an additional surface for the case manual selection cannot serve.

## Current state (audit)

### Wire contract

`/move_messages`, `/set_flag`, `/purge_messages`, and `/empty_trash` all take an explicit `ids` array. `parse_bulk_request` rejects more than `MAX_IDS_PER_REQUEST` (5,000) with a 413 carrying the cap; `apply_in_batches` then splits the accepted list into `MAX_IDS_PER_IMAP_CMD` (500) slices, running each as one IMAP command and recording per-batch success or failure so `batch_result_response` can answer `partial` with both lists. That batching machinery is exactly what a bulk job needs internally — the job engine reuses it rather than reinventing it.

Every one of those endpoints runs inside API Gateway's 29-second ceiling, and every one carries `@maintenance_guard`, which turns a planned IMAP roll into a 503 rather than a connection error.

### Query surface

`/search_envelopes` ([`lambda/api/search_envelopes/function.py`](../../lambda/api/search_envelopes/function.py)) is the only structured query surface. It accepts flat query-string parameters — `text`, `from`, `to`, `subject`, `since`, `before`, `unread`, `flagged`, `has_attachment` — and ANDs them all. There is no OR, no NOT, no keyword (custom flag) predicate, and no size predicate. It caps the merged match set at `MAX_RESULTS = 5000` and pages envelopes out at up to 200 per request.

Its internals are the right starting point for the job planner: `enumerate_cross_folder` (subscribed folders, `\Noselect` and Trash excluded, INBOX hoisted), `search_folders` (per-folder SELECT + SEARCH with skip-and-log on failure, self-healing stale LSUB entries), and the truncation accounting. The expensive part of that function is not the SEARCH — it is the per-UID `INTERNALDATE` fetch used for merge ordering, and the `BODYSTRUCTURE` fetch used for the attachment predicate. A count-only pass skips both.

### Client selection surfaces

| Client | Selection | Search |
|---|---|---|
| React (`react/admin`) | `useEnvelopeSelection` — click toggles, shift extends over shown order | `Email/Search/index.jsx`, structured |
| Apple (`apple/Cabalmail`) | `MessageListViewModel+Bulk` — edit mode, `selectAllVisible()`, cross-folder results grouped by source mailbox before the wire call | `Views/SearchView.swift` |
| Android (`android/app`) | `MessageListViewModel` selection state | `ui/mail/SearchViewModel.kt` |
| Linux (`linux/`) | in progress | in progress |

Every client already has both halves of what the wizard needs — a query editor and a bulk-action bar. What none of them has is a way to connect the two.

### Async job infrastructure

Two SQS-consumer Lambdas already exist and set the pattern this plan follows: `append_sent` ([`terraform/infra/modules/app/append_sent.tf`](../../terraform/infra/modules/app/append_sent.tf)) and `push_dispatch`. Both use `batch_size = 1`, a DLQ with `maxReceiveCount`, a visibility timeout comfortably above the function timeout, and the deliberate choice to let `get_imap_client` raise during an IMAP roll so SQS redelivers until the tier is back. `append_sent` additionally stages a payload in the cache bucket (`sent-pending/<user>/<uuid>`) and deletes it on success — the same shape a job's resolved UID set wants.

There is no FIFO queue, no job table, and no notion of job progress anywhere in the system today.

## Design

### D1. The match set never crosses the wire

This is the decision the rest of the design follows from. The client submits a *query*; the server resolves it to UIDs and acts on them. No endpoint in this feature accepts or returns a large UID array.

Consequences, all of them wanted:

- The 5,000-id cap stops being the ceiling on what a user can do. The new ceiling is `MAX_JOB_MESSAGES`, set by how much work the engine will accept, not by how much JSON fits in a request.
- The client needs no pagination logic, no chunking, no partial-failure reconciliation over 60 requests.
- The query is re-evaluated server-side at execution time, so a job submitted behind another job sees the state the earlier one left.

### D2. Query grammar

A query is a tree of clause nodes. A **group** node has `match` (`all` or `any`) and a list of children; a **condition** node has a field, an operator, and a value. Any node may carry `negate: true`.

```json
{
  "match": "all",
  "clauses": [
    { "field": "date",  "op": "older_than", "value": { "days": 30 } },
    { "field": "seen",  "op": "is",         "value": true },
    { "match": "any", "clauses": [
      { "field": "from", "op": "contains", "value": "newsletter@example.com" },
      { "field": "from", "op": "contains", "value": "noreply@example.net" }
    ]}
  ]
}
```

Fields and operators:

| Field | Operators | Compiles to |
|---|---|---|
| `from`, `to`, `cc`, `subject` | `contains` | `FROM` / `TO` / `CC` / `SUBJECT` |
| `text` | `contains` | `TEXT` (headers + body, FTS-served) |
| `body` | `contains` | `BODY` |
| `header` (with `name`) | `contains` | `HEADER <name> <value>` |
| `date` | `older_than` / `newer_than` (relative), `before` / `since` (absolute) | `BEFORE` / `SINCE` |
| `seen`, `flagged`, `answered`, `draft` | `is` (true/false) | `SEEN` / `UNSEEN`, `FLAGGED` / `UNFLAGGED`, … |
| `keyword` | `is` (slot atom) | `KEYWORD cabal-flag-NN` |
| `size` | `larger_than` / `smaller_than` (bytes) | `LARGER` / `SMALLER` |
| `has_attachment` | `is` | post-filter on `BODYSTRUCTURE` (see D8) |

`all` compiles to concatenation (IMAP SEARCH's implicit AND). `any` folds right into IMAP's binary prefix `OR`: `OR a (OR b c)`. `negate` prefixes `NOT`. The compiler lives in `lambda/api/_shared/query_compiler.py` and is the single place any client-supplied query becomes IMAP syntax — the same posture the search plan established when it removed the raw-syntax `/search` endpoint.

Relative dates are resolved to absolute dates **at submission time**, not at execution time, and the absolute dates are what the job stores. A job that sits in the queue for an hour still means what the user meant when they clicked Confirm.

Bounds: at most `MAX_CLAUSES` (32) condition nodes, at most `MAX_DEPTH` (3) levels of nesting, `header` restricted to an allowlist of header names. The wire format permits nesting so the grammar can outgrow the UI; the initial wizard UI exposes the two-level form (a top-level `all`/`any` with condition rows, each row optionally an inline `any` list of values), which is the Thunderbird/Apple Mail shape users already know and which covers every motivating case.

**Scope** is separate from the query: either an explicit folder list, or all subscribed folders with the same Trash exclusion `enumerate_cross_folder` applies today.

### D3. Action pipeline

An action set is **extras then one destination**, deliberately the same vocabulary as [mail rules](../mail-rules.md) so a user who has written a rule already understands it:

```json
{
  "extras": [
    { "type": "add_flag",    "flag": "\\Seen" },
    { "type": "add_flag",    "flag": "cabal-flag-03" },
    { "type": "remove_flag", "flag": "\\Flagged" }
  ],
  "destination": { "type": "move", "folder": "Archive" }
}
```

Extras run in the listed order, then the destination. Destination is one of `none`, `move` (to a named folder), `archive` (move to `Archive`), `trash` (move to the configured trash folder), or `purge` (`\Deleted` + UID EXPUNGE).

The ordering constraint is not a style choice: after a MOVE the source UIDs no longer exist, so a STORE against them fails. `_move_batch`'s existing `mark_seen` flag is the one-step-before-move case of exactly this rule. The API rejects a pipeline with more than one destination, or with a destination anywhere but last.

`purge` is accepted only when every folder in scope passes `validate_trash_folder`, matching `/purge_messages`. Nothing else in the system can expunge outside trash, and the wizard does not become the exception.

Custom-flag extras are validated against the user's palette the way `/set_flag` does — setting a slot requires it to be enabled in the palette, unsetting only requires a well-formed slot atom.

### D4. Preview and confirmation

`POST /bulk_preview` takes a query and a scope and returns:

```json
{
  "count": 31482,
  "exact": true,
  "sample": [ /* up to 20 envelopes, newest first, with source folder */ ],
  "folders_searched": ["INBOX", "Archive", "Lists"],
  "folders_incomplete": [],
  "warnings": []
}
```

Counting is cheap where the search is: `SEARCH` returns a UID list, and `len()` of it is the count. The preview does **not** fetch `INTERNALDATE` for the match set — only for the 20 sampled UIDs — which is what makes an exact count over a 100,000-message mailbox affordable inside API Gateway's 29 seconds.

Two honesty rules:

- The preview carries a wall-clock budget (~20 s). Folders it did not reach are listed in `folders_incomplete` and `exact` goes false; the count is then a lower bound and the UI says "at least N".
- `has_attachment` forces a `BODYSTRUCTURE` fetch over the match set, which is not cheap. When that predicate is present the preview reports a capped estimate and `exact: false`.

The confirmation dialog is built from this response and states the count, the actions in order, and the duration expectation:

> This will mark **about 31,482 messages** as read and move them to **Archive**, across 3 folders. This may take a few minutes. You can keep using Cabalmail while it runs.

A `purge` destination replaces "may take a few minutes" with an unambiguous irreversibility line and takes a distinct destructive-confirm treatment in each client.

### D5. Execution: one job per user at a time, in submission order

Submission (`POST /new_bulk_job`) does three things and returns: allocates a per-user sequence number, writes a job record, and enqueues a wake signal. It performs no IMAP work, so it always answers well inside the gateway timeout.

The engine is an SQS **FIFO** queue whose `MessageGroupId` is the Cognito username, consumed by a `bulk_apply` Lambda. FIFO gives the property this feature needs and a standard queue does not: **at most one message per group is in flight at a time**. That is the per-user mutex, for free, with no lease table and no lock TTL to get wrong.

The queue message is a *wake signal*, not the job. On wake, the worker queries the job table for that user's oldest unfinished job by sequence and works on that one. Ordering therefore comes from the sequence number in DynamoDB, not from queue position — which matters, because a continuation re-enqueued mid-job would otherwise land *behind* a job submitted in the meantime and interleave the two.

A worker invocation:

1. Claims the oldest unfinished job for the user (conditional update `queued` → `running`, or resumes one already `running`).
2. **Plans**, if the job has no plan yet: runs the compiled SEARCH across the scope, writes the resolved `{folder: [uid, …]}` map to `s3://cache.<control-domain>/bulk-plans/<user>/<job_id>.json.gz`, and records `total`.
3. **Applies**, resuming from the record's `(step_index, folder_index, chunk_index)` cursor: for each pipeline step, for each folder, for each 500-UID chunk, one IMAP command via the existing `apply_in_batches` accounting.
4. Checkpoints the cursor and the running succeeded/failed counts to DynamoDB after each chunk.
5. Yields at a 9-minute time slice (function timeout 15 min): re-enqueues a wake for the same group and returns cleanly. SQS releases the group, the next wake picks the same job back up at its cursor.
6. On the final chunk, marks the job `completed` (or `partial` when any chunk failed), deletes the plan object, and — if the user has another queued job — enqueues one more wake.

The plan is resolved **once**, at job start, and persisted. Re-running the SEARCH on each continuation would be wrong for exactly the composed case this feature exists for: after the "mark as read" step, an `unread` predicate matches nothing, and the archive step would find an empty set.

Failure posture matches `append_sent`: an IMAP roll makes `get_imap_client` raise, the record stays on the queue, SQS redelivers after the visibility timeout, and the job resumes from its checkpoint. After `maxReceiveCount` the wake lands in the DLQ and the job record is marked `failed` with the last error.

### D6. Overlap semantics

The user's stated hazard: submit a 30,000-message job, then submit an overlapping one while the first is still running.

Strict per-user serialization answers it. The second job does not start until the first finishes; its query is resolved *after* the first job's effects have landed, so the second job's plan reflects them. Last submitted is last applied, and therefore wins.

Two supporting behaviors:

- A queued job (not yet planned) can be cancelled outright. A running job can be cancelled between chunks; the work already applied stands, and the job records `cancelled` with its partial counts. Nothing rolls back.
- The wizard tells the user when a job is already queued or running, shows its progress, and says the new one will start after it.

The alternative — freezing the UID set at submission for every queued job — was rejected. A frozen set is stale by construction (the earlier job invalidates the UIDs it moved), it would need the plan resolved during the submission request, and it turns the gateway timeout into the real cap on job size.

### D7. Performance budget and backpressure

Every knob here exists because the IMAP tier is one task on EFS.

| Control | Value | Why |
|---|---|---|
| Jobs in flight per user | 1 | SQS FIFO group = username |
| Worker reserved concurrency | 3 | Bounds total bulk load on Dovecot regardless of user count |
| ESM `batch_size` | 1 | One wake per invocation, matching `append_sent` / `push_dispatch` |
| UIDs per IMAP command | 500 (`MAX_IDS_PER_IMAP_CMD`) | Already the tuned value for the interactive bulk endpoints |
| Inter-chunk pause | configurable, default 25 ms | Leaves headroom for interactive traffic between commands; a knob, so it can be tuned from telemetry rather than guessed twice |
| Worker time slice | 540 s (timeout 900 s, visibility 960 s) | Yields the FIFO group well before the Lambda ceiling |
| `MAX_JOB_MESSAGES` | 100,000 | Refuse rather than plan a job whose plan object and runtime are unbounded |
| Active jobs per user | 5 queued + running | Keeps the queue legible and the table small |
| Submission rate | via `cabal-rate-limits` | Reuses the existing per-caller window table |

Order-of-magnitude for the motivating case: 30,000 messages, mark-read then archive, is 60 STOREs and 60 MOVEs. A maildir MOVE within one mailstore is a rename, so the dominant cost is round-trips, not bytes — well inside one or two time slices. The confirmation's "a few minutes" is an honest upper bound rather than a hedge.

What this design does *not* do is give bulk work lower priority inside Dovecot; there is no such lever. Bounded concurrency plus the inter-chunk pause is the whole mitigation, and a CloudWatch alarm on interactive-endpoint latency during job execution is how we find out if it is enough.

### D8. `has_attachment`

The existing `bodystructure_has_attachment` heuristic requires a `BODYSTRUCTURE` fetch per candidate UID, which is the one predicate that scales with match-set size rather than with index lookups. It is supported in the grammar, but: the preview reports an estimate rather than an exact count when it is present, and the *plan* pass applies it as a post-filter over the SEARCH result. A job whose only predicate is `has_attachment` over a whole mailbox is legal and slow; the wizard warns.

### D9. Privacy and logging

The search plan set the rule and this feature inherits it: **no query content in logs or metrics**. Job records hold the query (the user's own data, in the user's own row, encrypted at rest); logs and CloudWatch metrics carry job id, user, status transitions, counts, action *kinds*, and durations — never field values, never matched UIDs, never subjects.

Job records carry a 30-day TTL. Plan objects are deleted on completion and additionally covered by a short lifecycle rule on the `bulk-plans/` prefix, so an abandoned plan cannot outlive its job.

## Data model

**DynamoDB `cabal-bulk-jobs`** — hash `user`, range `job_id`, PAY_PER_REQUEST, SSE, PITR, TTL on `expires_at`.

- `job_id` = `f"{sequence:012d}-{uuid4().hex[:8]}"`, so a Query with `ScanIndexForward=true` returns a user's jobs in submission order.
- `sequence` comes from an atomic `UpdateItem ADD` on the sentinel item `job_id = "#seq"` for that user. A timestamp would be one write cheaper but ties on a fast double-submit; the counter is exact, which is the property the whole ordering argument rests on.
- Attributes: `status` (`queued` | `planning` | `running` | `completed` | `partial` | `failed` | `cancelled`), `query`, `actions`, `scope`, `total`, `processed`, `failed_count`, `cursor` (`step_index`, `folder_index`, `chunk_index`), `plan_key`, `created_at`, `started_at`, `finished_at`, `error`, `cancel_requested`, `expires_at`.

**S3 plan artifact** — `s3://cache.<control-domain>/bulk-plans/<user>/<job_id>.json.gz`, `{"folders": {"INBOX": [uid, …], …}}`. 100,000 UIDs compress to well under a megabyte; the object is read once per continuation and deleted on completion.

**SQS** — `cabal-bulk-jobs.fifo` (content-based deduplication off; explicit `MessageDeduplicationId` per wake, since a continuation wake is otherwise byte-identical to the one that spawned it and would be swallowed by the 5-minute dedup window) plus `cabal-bulk-jobs-dlq.fifo`.

## API surface

| Endpoint | Method | Purpose |
|---|---|---|
| `/bulk_preview` | POST | Match count, exactness, sample envelopes, incomplete folders |
| `/new_bulk_job` | POST | Validate, allocate sequence, write record, enqueue wake. Returns `job_id` and queue position |
| `/list_bulk_jobs` | GET | Active and recent jobs with status and counts; clients poll this while a job is live |
| `/cancel_bulk_job` | POST | Sets `cancel_requested`; the worker honors it between chunks |

All four follow the existing `local.lambdas` / `modules/call` wiring, Cognito-authorized, uncached. `bulk_apply` is not gateway-fronted and gets its own Terraform file alongside `append_sent.tf`.

## Client experience

Three steps, identical in model across clients, rendered natively in each:

1. **Conditions** — a match-all/match-any selector and a list of condition rows (field, operator, value), each row negatable, plus the scope picker (this folder / selected folders / all mail). Live "about N matches" as the query settles, debounced.
2. **Actions** — extras (mark read/unread, flag/unflag, add/remove custom flags) and one destination (nothing / move to folder / archive / trash / permanently delete). Order shown explicitly, destination pinned last.
3. **Review** — count, the sentence-form summary of the pipeline, the sample list, and Confirm.

While a job is live, each client shows a compact progress affordance (`Archiving 12,400 of 31,482…`) fed by polling `/list_bulk_jobs`, with a cancel control. The React app's existing "select all" affordance gains an escape hatch into the wizard with the current folder and filter prefilled.

Rollout order: React first (the largest editing surface and the fastest iteration), then Apple, then Android, then Linux. The wire contract lands once and does not change per client.

## Open questions

1. **Completion notification.** The push pipeline exists (`push_dispatch`, APNs + FCM) but carries one payload shape today, fed by procmail. Should a finished job wake the device, or is an in-app progress indicator enough for the first release?
2. **Purge confirmation strength.** A count and a destructive-styled dialog, or a typed confirmation for irreversible jobs above some size?
3. **`/search_envelopes` convergence.** Does the search endpoint gain the tree grammar in this plan (one grammar everywhere, immediately) or in a follow-on (smaller blast radius now, two shapes in the tree for a while)?
4. **`MAX_JOB_MESSAGES` at 100,000.** Is refusing above that the right answer, or should the wizard offer to split by folder or date range?
5. **Inter-chunk pause default.** 25 ms is a guess. Worth measuring against stage before it becomes a number people trust.
6. **Job history retention.** 30 days of records, or trim to the last N per user?

## Likely phase boundaries

Sketch only — the phased implementation plan comes after this design is reviewed.

1. Shared query compiler in `_shared/`, with unit tests over the grammar and the IMAP folding rules. No user-visible change.
2. `/bulk_preview` — the query grammar becomes reachable and testable end to end, with no way to mutate anything.
3. Job engine: table, FIFO queue, `bulk_apply` worker, `/new_bulk_job`, `/list_bulk_jobs`, `/cancel_bulk_job`. Verified on stage against a synthetic large mailbox.
4. React wizard.
5. Apple wizard.
6. Android and Linux wizards.
7. Telemetry, alarms, and the tuning pass on the pacing knobs.
