# Bulk Actions Plan (query-driven selection and action pipelines)

## Progress

| Phase | Status |
|---|---|
| — | Design proposal. First review 2026-09-02; revised in response (scope safety, UID semantics, queue concurrency, plan durability, client reconciliation). Phases are drafted at the bottom as input to the implementation plan, not as commitments. |

## Context

Every native Cabalmail client selects messages the same way: enter a selection mode, then click rows one at a time. The React app added shift-click range extension ([`react/admin/src/hooks/useEnvelopeSelection.js`](../../react/admin/src/hooks/useEnvelopeSelection.js)) and the Apple clients added `selectAllVisible()` ([`apple/Cabalmail/ViewModels/MessageListViewModel+Bulk.swift`](../../apple/Cabalmail/ViewModels/MessageListViewModel+Bulk.swift)), but both operate over envelopes already rendered. The selection then travels to the server as a literal UID array, capped at `MAX_IDS_PER_REQUEST = 5000` ([`lambda/api/_shared/helper.py:342`](../../lambda/api/_shared/helper.py)).

That model has no answer for "archive the 30,000 messages I no longer want in my inbox." The user cannot click 30,000 rows, the client cannot hold 30,000 rendered envelopes, and the wire contract refuses more than 5,000 ids per call. The nearest thing that exists is `/search_envelopes`, which finds messages by a structured query but returns pages of envelopes for a human to read — it is a reading surface, not an acting one.

[`docs/0.11.x/multi-select-bulk-operations.md`](../0.11.x/multi-select-bulk-operations.md) named "server-side search-based bulk actions (flag all from sender X)" as an explicit non-goal, on the grounds that bulk actions operate on the user's explicit selection. That non-goal stands for that plan. This document picks it up as its own initiative, the same way the search plan picked up the index that the large-mailbox hardening plan had carved out.

The proposal: a **selection wizard** in the native clients that composes a query and an ordered list of actions, previews the match count, confirms, and hands the whole thing to the server as a **bulk job**. The client never enumerates UIDs. The server resolves the match set, applies the actions in batches, and reports progress.

## Goals

- Act on an arbitrarily large match set — 30,000 messages and beyond — without the user clicking rows and without the client holding the match set in memory.
- Compose conditions with AND and OR, and negate any of them. "Older than a month AND read AND (from any of these five senders)" is expressible in one query.
- Compose outcomes in order: mark read, then tag, then archive. One job, one pass.
- Show the user what they are about to do before it happens: a match count and a sample of matched messages, then an explicit confirmation naming the count and warning that it may take a few minutes.
- Make the destructive default safe. A job the user did not think carefully about must not move their Sent mail, their drafts, or the destination folder's own contents.
- Never let a bulk job storm the mail tier. The IMAP tier is a single ECS task ([`terraform/infra/modules/ecs/services.tf`](../../terraform/infra/modules/ecs/services.tf), `desired_count = 1`) backed by EFS; a bulk job is the largest sustained load any user can generate, and it must stay bounded and behind the interactive API in priority.
- Serialize a user's jobs strictly in submission order, so two overlapping submissions resolve deterministically: the later one runs after the earlier one finishes, sees the state the earlier one left, and wins.
- Keep the mailbox usable while a job runs, and leave every client's caches correct when it ends.
- One contract, three clients. Apple, Android, and Linux render the same wizard model natively.

## Non-goals

- **The React webmail.** React does not get the wizard. It is a second-class surface that new features are not required to reach, and building the wizard three times is already the cost of this plan. React keeps manual selection unchanged; a React user who needs a bulk job runs it from a native client.
- **Undo.** A job is not reversible. Move is reversible by the user filing the mail back; purge is not reversible at all. The `COPYUID` responses the engine already reads for counting (D3) would make a mechanical undo possible; that is a plausible follow-on, not part of this plan.
- **Saved queries, scheduled jobs, recurring cleanups.** A bulk job runs once, on demand. Standing behavior on *incoming* mail is what [mail rules](../mail-rules.md) already are; a scheduled sweep over existing mail is a different feature with a different risk profile.
- **A second query language.** The grammar defined here is the *one* structured query grammar. `/search_envelopes`'s current flat parameters become a legacy surface over the same compiler, not a parallel dialect.
- **Regular expressions, substring matching, arbitrary header matching, attachment content, or semantic search.** The condition vocabulary is bounded by what IMAP SEARCH and Dovecot's flatcurve index can answer cheaply — see D2.1 for what that costs the user.
- **Cross-user or admin-initiated bulk actions.** A job runs as its owner, over its owner's mailbox, and nothing else.
- **Sending, composing, or forwarding as a bulk action.** Actions are confined to flags and message placement. Nothing in a bulk job puts mail on the wire.
- **Replacing manual selection.** Row-by-row selection stays exactly as it is. The wizard is an additional surface for the case manual selection cannot serve.

## Current state (audit)

### Wire contract

`/move_messages`, `/set_flag`, `/purge_messages`, and `/empty_trash` all take an explicit `ids` array. `parse_bulk_request` rejects more than `MAX_IDS_PER_REQUEST` (5,000) with a 413 carrying the cap; `apply_in_batches` then splits the accepted list into `MAX_IDS_PER_IMAP_CMD` (500) slices, running each as one IMAP command and recording per-batch success or failure so `batch_result_response` can answer `partial` with both lists. That batching machinery is exactly what a bulk job needs internally — the job engine reuses it rather than reinventing it.

Every one of those endpoints runs inside API Gateway's 29-second ceiling, and every one carries `@maintenance_guard`, which turns a planned IMAP roll into a 503 rather than a connection error.

### Query surface

`/search_envelopes` ([`lambda/api/search_envelopes/function.py`](../../lambda/api/search_envelopes/function.py)) is the only structured query surface. It accepts flat query-string parameters — `text`, `from`, `to`, `subject`, `since`, `before`, `unread`, `flagged`, `has_attachment` — and ANDs them all. There is no OR, no NOT, no keyword (custom flag) predicate, and no size predicate. It caps the merged match set at `MAX_RESULTS = 5000` and pages envelopes out at up to 200 per request.

Its internals are the right starting point for the job planner: `search_folders` (per-folder SELECT + SEARCH with skip-and-log on failure, self-healing stale LSUB entries) and the truncation accounting. Its `enumerate_cross_folder` is *not* — see D2.2. The expensive part of that function is not the SEARCH — it is the per-UID `INTERNALDATE` fetch used for merge ordering, and the `BODYSTRUCTURE` fetch used for the attachment predicate. A count-only pass skips both.

### IMAP tier and index

`docker/imap/configs/dovecot/90-fts.conf` configures fts_flatcurve with `fts_enforced = yes`, `fts_flatcurve_substring_search = no`, `fts_filters = lowercase`, an `email-address` tokenizer, `fts_flatcurve_min_term_size = 2`, and `fts_autoindex_exclude = \Trash`. `15-mailboxes.conf` assigns special-use attributes to Drafts (`\Drafts`), Junk (`\Junk`), Trash (`\Trash`), Sent (`\Sent`), and Archive (`\Archive`), with Archive and INBOX auto-subscribed and Trash auto-created.

`_shared/imap_session.py` applies a socket timeout (`POOL_SOCKET_TIMEOUT = SocketTimeout(connect=10, read=27)`) **only on the pooled path**; the comment at line 43 is explicit that the flag-off path "keeps the original no-timeout client, byte-for-byte unchanged."

### Client selection surfaces

| Client | Selection | Search | Wizard target |
|---|---|---|---|
| Apple (`apple/Cabalmail`) | `MessageListViewModel+Bulk` — edit mode, `selectAllVisible()`, cross-folder results grouped by source mailbox before the wire call | `Views/SearchView.swift` | yes, first |
| Android (`android/app`) | `MessageListViewModel` selection state | `ui/mail/SearchViewModel.kt` | yes |
| Linux (`linux/`) | in progress | in progress | yes |
| React (`react/admin`) | `useEnvelopeSelection` — click toggles, shift extends over shown order | `Email/Search/index.jsx`, structured | no |

Client-side caches that a completed job invalidates: `apple/CabalmailKit/Sources/CabalmailKit/Cache/EnvelopeCache.swift`, `android/kit/src/main/kotlin/com/cabalmail/kit/cache/RoomEnvelopeCache.kt` (which already tracks per-folder `uidValidity`), plus `apple/Cabalmail/NavStateCoordinator.swift` and `apple/Cabalmail/SpotlightRouting.swift`. See D10.

### Async job infrastructure

Two SQS-consumer Lambdas already exist and set the pattern this plan follows: `append_sent` ([`terraform/infra/modules/app/append_sent.tf`](../../terraform/infra/modules/app/append_sent.tf)) and `push_dispatch`. Both use `batch_size = 1`, a DLQ with `maxReceiveCount`, a visibility timeout comfortably above the function timeout, and the deliberate choice to let `get_imap_client` raise during an IMAP roll so SQS redelivers until the tier is back. `append_sent` additionally stages a payload in the cache bucket (`sent-pending/<user>/<uuid>`) and deletes it on success.

Neither has a DLQ consumer or a DLQ-depth alarm. Nothing in the repo uses an SQS FIFO queue, a Lambda `scaling_config`, or reserved concurrency today.

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
    { "field": "date",  "op": "older_than",    "value": { "days": 30 } },
    { "field": "seen",  "op": "is",            "value": true },
    { "match": "any", "clauses": [
      { "field": "from", "op": "contains_word", "value": "newsletter@example.com" },
      { "field": "from", "op": "contains_word", "value": "noreply@example.net" }
    ]}
  ]
}
```

Fields and operators:

| Field | Operators | Compiles to |
|---|---|---|
| `from`, `to`, `cc`, `subject` | `contains_word` | `FROM` / `TO` / `CC` / `SUBJECT` |
| `text` | `contains_word` | `TEXT` (headers + body) |
| `body` | `contains_word` | `BODY` |
| `header` (with `name`) | `contains_word` | `HEADER <name> <value>` |
| `date` | `older_than` / `newer_than` (relative), `before` / `since` (absolute) | `BEFORE` / `SINCE` |
| `seen`, `flagged`, `answered`, `draft` | `is` (true/false) | `SEEN` / `UNSEEN`, `FLAGGED` / `UNFLAGGED`, … |
| `keyword` | `is` (slot atom) | `KEYWORD cabal-flag-NN` |
| `size` | `larger_than` / `smaller_than` (bytes) | `LARGER` / `SMALLER` |
| `has_attachment` | `is` | post-filter on `BODYSTRUCTURE` (see D9) |

`all` compiles to concatenation (IMAP SEARCH's implicit AND). `any` folds right into IMAP's binary prefix `OR`: `OR a (OR b c)`. `negate` prefixes `NOT`. The compiler lives in `lambda/api/_shared/query_compiler.py` and is the single place any client-supplied query becomes IMAP syntax — the same posture the search plan established when it removed the raw-syntax `/search` endpoint.

Relative dates are resolved to absolute dates **at submission time**, not at execution time, and the absolute dates are what the job stores. A job that sits in the queue for an hour still means what the user meant when they clicked Confirm.

Bounds: at most `MAX_CLAUSES` (32) condition nodes, at most `MAX_DEPTH` (3) levels of nesting, `header` restricted to an allowlist of header names. The wire format permits nesting so the grammar can outgrow the UI; the initial wizard UI exposes the two-level form (a top-level `all`/`any` with condition rows, each row optionally an inline `any` list of values), which is the Thunderbird/Apple Mail shape users already know and which covers every motivating case.

#### D2.1. `contains_word` means what flatcurve means

The operator is named `contains_word`, not `contains`, because `fts_flatcurve_substring_search = no`. Every text and header predicate is served by the index, and the index stores tokens:

- **No substring matching.** `example` does not match `example.com`; `news` does not match `newsletter`. What matches is a whole indexed term.
- **Addresses are one term.** The `email-address` tokenizer keeps `user@example.com` intact, so an address predicate matches the whole address and not its parts.
- **Case is folded both ways** (`fts_filters = lowercase`), so query casing is irrelevant.
- **Terms shorter than two characters are not indexed** (`fts_flatcurve_min_term_size = 2`).

A wizard that says "contains" in front of an irreversible action invites the user to expect substring semantics and get something else, on 30,000 messages. So the UI labels the operator "contains the word", the value field's help text gives the address example, and the preview's sample list is the check the user actually performs. `/search_envelopes` has these semantics today under friendlier parameter names; converging its vocabulary on this one is part of the follow-on in Open Question 2.

**Trash has no index.** `fts_autoindex_exclude = \Trash` plus `fts_enforced = yes` means a text or header predicate scoped to Trash either fails that folder's SEARCH outright (which `search_folders` swallows as a skip) or triggers a full index build inside the request. Neither is acceptable in a preview, so a text/header predicate combined with a Trash-inclusive scope is **rejected at preview** with a message naming the reason, rather than silently returning nothing or blowing the budget.

#### D2.2. Scope is a safety control, not a folder list

The first review caught the sharpest edge in the original draft: scope inherited `enumerate_cross_folder`, which is *every subscribed folder minus Trash*. "Older than 30 days → archive" over that scope moves the user's Sent mail and their drafts into Archive. That is data loss from a reasonable-sounding query, so scope gets its own rules.

Three scope modes:

| Mode | Resolves to |
|---|---|
| `this_folder` | the named folder only |
| `folders` | an explicit list, exactly as given |
| `all_mail` | subscribed, selectable folders **minus** `\Trash`, `\Junk`, `\Drafts`, `\Sent`, minus the pipeline's destination folder, and minus any folder the user has not subscribed |

Rules that apply to every mode:

1. **`all_mail` is labelled with its exclusions.** The UI reads "All mail (excludes Sent, Drafts, Junk, Trash)", with four checkboxes to add any of them back deliberately. A label that says "all" while quietly skipping unsubscribed folders is its own trap, so the picker says that too, and offers the unsubscribed folders as explicit additions.
2. **The destination folder is never in the resolved plan.** All-mail plus `archive` otherwise puts Archive in the match set and MOVEs those messages into the folder they already live in — depending on the server that either errors on every chunk or duplicates mail. The planner drops the destination folder from the plan after the SEARCH, in every mode, and reports how many matches that removed. The same rule covers `trash` with Trash in scope.
3. **`purge` requires an explicit trash-only scope.** Under the `all_mail` rules Trash is excluded by default, so a purge job with the default scope would resolve to zero folders. Rather than let that read as "nothing matched", `purge` accepts only a scope whose every folder passes `validate_trash_folder`, and preview rejects anything else by name.

Special-use attributes come from the server, not from folder names: `15-mailboxes.conf` assigns `\Sent`, `\Drafts`, `\Junk`, `\Trash`, and `\Archive`. **Implementation note:** LSUB responses do not carry special-use attributes, so the planner cannot reuse `list_sub_folders()` the way `enumerate_cross_folder` does — it needs `LIST (SUBSCRIBED) RETURN (SPECIAL-USE)` (or a plain LIST intersected with the subscription list). Where the attribute is genuinely absent the planner falls back to matching the conventional names, and says in the response which mechanism it used.

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

The ordering constraint is not a style choice, but the reason is not the one the original draft gave. **RFC 3501 §6.4.8 is explicit that a UID command ignores a non-existent UID without generating an error.** A STORE issued after the MOVE therefore does not fail — it silently succeeds having done nothing. Silence is worse than an error here, because the job would report the flag step as applied. So the API rejects a pipeline with more than one destination, or with a destination anywhere but last, and the engine never has to discover the problem at runtime. (`_move_batch`'s existing comment in [`lambda/api/move_messages/function.py`](../../lambda/api/move_messages/function.py) asserts the opposite — "a STORE would reject them" — and should be corrected when this work lands; its `mark_seen` behavior is right, only the stated reason is wrong.)

The same RFC rule sets what the engine can honestly report:

- A **flag step** cannot be counted. UID STORE returns OK whether it touched 500 messages or none of them, so `processed` for a flag step is *UIDs attempted*, and the job record labels it that way.
- A **move step** can be counted. Dovecot supports UIDPLUS, so `UID MOVE` returns a `COPYUID` response whose source-UID set names exactly the messages that moved. The engine counts from that and reports `moved` as an actual.

The consequence the user sees: a message the user filed elsewhere between Confirm and execution silently drops out of the move count, and out of the flag count not at all. The completion summary reads "31,482 attempted, 31,340 moved" rather than one confident number. That is the honest reading of what IMAP tells us.

`purge` is accepted only under the trash-only scope rule in D2.2. Custom-flag extras are validated against the user's palette the way `/set_flag` does — setting a slot requires it to be enabled in the palette, unsetting only requires a well-formed slot atom.

### D4. Preview and confirmation

`POST /bulk_preview` takes a query, a scope, and the pipeline (it needs the destination to apply the D2.2 exclusion) and returns:

```json
{
  "count": 31482,
  "exact": true,
  "sample": [ /* up to 20 envelopes, newest first, with source folder */ ],
  "folders_searched": ["INBOX", "Lists"],
  "folders_excluded": [
    { "folder": "Sent",    "reason": "special_use" },
    { "folder": "Archive", "reason": "destination", "dropped_matches": 812 }
  ],
  "folders_incomplete": [],
  "refusal": null,
  "warnings": []
}
```

Counting is cheap where the search is: `SEARCH` returns a UID list, and `len()` of it is the count. The preview does **not** fetch `INTERNALDATE` for the match set — only for the 20 sampled UIDs — which is what makes an exact count over a 100,000-message mailbox affordable inside API Gateway's 29 seconds.

Four honesty rules:

- The preview carries a wall-clock budget (~20 s). Folders it did not reach are listed in `folders_incomplete` and `exact` goes false; the count is then a lower bound and the UI says "at least N".
- `has_attachment` forces a `BODYSTRUCTURE` fetch over the match set, which is not cheap. When that predicate is present the preview reports a capped estimate and `exact: false`.
- **Every refusal happens here, not at plan time.** Over `MAX_JOB_MESSAGES`, a purge outside trash, a text predicate over Trash — all of them come back as a populated `refusal` with a reason the UI can render. By plan time the user has already confirmed, and a job that refuses after confirmation is a job that looked like it was running and then was not.
- Because the world moves between Confirm and completion, the confirmation says **about**, and the completion summary reports actuals (D3). If the match set has grown past `MAX_JOB_MESSAGES` by the time the planner runs, the job fails cleanly as `too_large` without applying anything — never a partial sweep of an over-cap set.

The confirmation dialog is built from this response and states the count, the actions in order, the folders in and out of scope, and the duration expectation:

> This will mark **about 31,482 messages** as read and move them to **Archive**, across 2 folders.
> Not included: Sent, Drafts, Junk, Trash, Archive.
> This may take a few minutes. You can keep using Cabalmail while it runs.

A `purge` destination replaces "may take a few minutes" with an unambiguous irreversibility line and takes a distinct destructive-confirm treatment in each client.

### D5. Execution: one job per user at a time, in submission order

Submission (`POST /new_bulk_job`) does three things and returns: allocates a per-user sequence number, writes a job record, and enqueues a wake signal. It performs no IMAP work, so it always answers well inside the gateway timeout.

The engine is an SQS **FIFO** queue whose `MessageGroupId` is the Cognito username, consumed by a `bulk_apply` Lambda. FIFO gives the property this feature needs and a standard queue does not: **at most one message per group is in flight at a time**. That is the per-user mutex, for free, with no lease table and no lock TTL to get wrong.

The queue message is a *wake signal*, not the job. On wake, the worker queries the job table for that user's oldest unfinished job by sequence and works on that one. Ordering therefore comes from the sequence number in DynamoDB, not from queue position — which matters, because a continuation re-enqueued mid-job would otherwise land *behind* a job submitted in the meantime and interleave the two.

A worker invocation:

1. Claims the oldest unfinished job for the user (conditional update `queued` → `running`, or resumes one already `running`).
2. **Plans**, resumably (D6): resolves the scope, runs the compiled SEARCH folder by folder, applies the D2.2 destination exclusion, and records each folder's UID list and `UIDVALIDITY`.
3. **Applies**, resuming from the record's `(step_index, folder_index, chunk_index)` cursor: for each pipeline step, for each folder, `SELECT` and check `UIDVALIDITY` against the plan, then for each 500-UID chunk one IMAP command via the existing `apply_in_batches` accounting.
4. Checkpoints the cursor and the running attempted/moved/failed counts to DynamoDB after each chunk.
5. Yields at a 9-minute time slice (function timeout 15 min): re-enqueues a wake for the same group and returns cleanly. SQS releases the group, the next wake picks the same job back up at its cursor.
6. On the final chunk, marks the job `completed` (or `partial` when any chunk failed or any folder was skipped), deletes the plan artifacts, and — if the user has another queued job — enqueues one more wake.

The plan is resolved **once** and persisted. Re-running the SEARCH on each continuation would be wrong for exactly the composed case this feature exists for: after the "mark as read" step, an `unread` predicate matches nothing, and the archive step would find an empty set.

Failure posture follows `append_sent`: an IMAP roll makes `get_imap_client` raise, the record stays on the queue, SQS redelivers after the visibility timeout, and the job resumes from its checkpoint. Two additions, because nothing in this repo consumes a DLQ:

- The worker reads `ApproximateReceiveCount` from the SQS record. On the **last permitted receive** it writes `status: failed` with the last error onto the job record *before* raising, so a job that lands in the DLQ has already told the user it died. A DLQ with no consumer is then an operator artifact, not the only record of the failure.
- A CloudWatch alarm on DLQ depth. (`append_sent` and `push_dispatch` lack one too; adding theirs is a small separate change, not scope here.)

#### D5.1. Concurrency: `maximum_concurrency`, not reserved concurrency

The original draft proposed reserved concurrency on the worker to bound total IMAP load. That is the wrong lever on an SQS event source: when the poller is throttled, the message is returned unprocessed but `ApproximateReceiveCount` **still increments**. With a 960-second visibility timeout, a busy queue can walk a job to `maxReceiveCount` and DLQ it having done no work at all — blocking that user's FIFO group for 16 minutes per wasted attempt on the way there.

The event source mapping's `scaling_config { maximum_concurrency = 3 }` is the correct control: it limits how many concurrent invocations the poller *starts*, so a job that cannot run yet is simply not received. (The minimum accepted value is 2.)

#### D5.2. The worker sets its own socket timeout

`imap_session` applies `POOL_SOCKET_TIMEOUT` only when pooling is enabled; the unpooled client is deliberately left with no timeout, sized for a request that dies at the 29-second gateway ceiling anyway. A worker has no such ceiling: a MOVE that hangs on EFS would hold the invocation to the 15-minute Lambda limit, consume a receive, and block the group for the visibility timeout.

So the worker dials with an explicit `SocketTimeout` regardless of the pool flag — connect 10 s, read 60 s, comfortably above a 500-UID MOVE and far below the time slice. A read timeout surfaces as a failed chunk, which the existing accounting already handles.

### D6. The plan pass is itself resumable

A plan pass over a large scope is not free, and with `has_attachment` — which forces a `BODYSTRUCTURE` fetch across the match set — it can exceed one time slice on its own. A planner that cannot checkpoint would restart from folder one on every continuation and never finish.

So the plan is per-folder and incremental:

- One artifact per folder: `s3://cache.<control-domain>/bulk-plans/<user>/<job_id>/<n>.json.gz`, holding `{"folder": …, "uidvalidity": …, "uids": [...]}`.
- The job record holds `planned_folders` (the resolved scope in order) and `plan_cursor` (how many are done). The worker writes one artifact, advances the cursor, and checks its time slice before starting the next folder.
- The status is `planning` until the cursor reaches the end, at which point `total` is final and the apply phase begins.

A job whose planning is interrupted resumes at the next unplanned folder, and the folders already planned keep the UID sets and `UIDVALIDITY` values captured when they were first walked.

### D7. UIDVALIDITY is part of the plan

A persisted UID list is only meaningful against the `UIDVALIDITY` it was captured under; a bump renumbers the mailbox, so the same integers name different messages. Rare with maildir, but the failure is acting on the wrong mail, which is exactly what this feature must never do at 30,000-message scale.

Each per-folder artifact records the `UIDVALIDITY` returned by the `SELECT` that produced it. Every subsequent `SELECT` of that folder — each continuation, each pipeline step — compares. On a mismatch the folder is **skipped for the rest of the job**, recorded in `folders_skipped` with the reason, and the job finishes `partial` with that fact in its summary. It is never re-planned mid-job: the user confirmed a count, and silently re-resolving the set underneath them is a different job than the one they approved.

The clients already carry this concept — `RoomEnvelopeCache` tracks per-folder `uidValidity`, and the draft lifecycle keys on `(uid, uidvalidity)` pairs — so the vocabulary is not new to the system.

### D8. Overlap semantics

The user's stated hazard: submit a 30,000-message job, then submit an overlapping one while the first is still running.

Strict per-user serialization answers it. The second job does not start until the first finishes; its query is resolved *after* the first job's effects have landed, so the second job's plan reflects them. Last submitted is last applied, and therefore wins.

Two supporting behaviors:

- A queued job (not yet planned) can be cancelled outright. A running job can be cancelled between chunks; the work already applied stands, and the job records `cancelled` with its partial counts. Nothing rolls back.
- The wizard tells the user when a job is already queued or running, shows its progress, and says the new one will start after it.

The alternative — freezing the UID set at submission for every queued job — was rejected. A frozen set is stale by construction (the earlier job invalidates the UIDs it moved), it would need the plan resolved during the submission request, and it turns the gateway timeout into the real cap on job size.

### D9. Performance budget and backpressure

Every knob here exists because the IMAP tier is one task on EFS.

| Control | Value | Why |
|---|---|---|
| Jobs in flight per user | 1 | SQS FIFO group = username |
| Worker concurrency | ESM `maximum_concurrency = 3` | Bounds bulk load on Dovecot without burning receive counts (D5.1) |
| ESM `batch_size` | 1 | One wake per invocation, matching `append_sent` / `push_dispatch` |
| UIDs per IMAP command | 500 (`MAX_IDS_PER_IMAP_CMD`) | Already the tuned value for the interactive bulk endpoints |
| IMAP socket timeout | connect 10 s, read 60 s | Set by the worker itself; the unpooled default is no timeout (D5.2) |
| Inter-chunk pause | configurable, default 25 ms | Leaves headroom for interactive traffic between commands; a knob, so it can be tuned from telemetry rather than guessed twice |
| Worker time slice | 540 s (timeout 900 s, visibility 960 s) | Yields the FIFO group well before the Lambda ceiling |
| `MAX_JOB_MESSAGES` | 100,000 | Refuse at preview rather than plan a job whose artifacts and runtime are unbounded |
| Active jobs per user | 5 queued + running | Keeps the queue legible and the table small |
| Submission rate | via `cabal-rate-limits` | Reuses the existing per-caller window table |

Order-of-magnitude for the motivating case: 30,000 messages, mark-read then archive, is 60 STOREs and 60 MOVEs. In maildir both are filename operations — flags live in the filename, and a same-store move is a rename — so the job is bound by round-trips, not by bytes moved. That is why "a few minutes" is an honest upper bound rather than a hedge.

`has_attachment` is the one predicate that scales with match-set size rather than index lookups, since it needs a `BODYSTRUCTURE` fetch per candidate. It is supported, the preview reports an estimate rather than an exact count when it is present, the planner applies it as a post-filter, and both the preview and the wizard warn when it is the only predicate over a large scope.

What this design does *not* do is give bulk work lower priority inside Dovecot; there is no such lever. Bounded concurrency plus the inter-chunk pause is the whole mitigation, and a CloudWatch alarm on interactive-endpoint latency during job execution is how we find out if it is enough.

### D10. Telling the clients what happened

The largest client-side gap in the original draft: nothing invalidated client caches when a server-side job finished. The Apple envelope cache prunes stale rows on pull-to-refresh and the Android Room cache has a reconcile pass, but neither has any reason to fire because a job the user started ten minutes ago has just moved 30,000 messages. Left alone, the user returns to a client showing folders that no longer hold what it thinks they hold.

So reconciliation is part of the wire contract, not per-client polish. The job record carries everything a client needs to invalidate precisely:

```json
{
  "folders_touched": ["INBOX", "Lists"],
  "destination": "Archive",
  "folders_skipped": [{ "folder": "Receipts", "reason": "uidvalidity_changed" }],
  "moved": 31340,
  "attempted": 31482
}
```

On observing a job reach a terminal status, every client must:

1. Drop cached envelopes for each folder in `folders_touched` and for `destination`, rather than diffing — the set is too large to reconcile row by row.
2. Refresh folder status (unread and total counts) for the same folders.
3. Repair navigation state: if the selected message or the list cursor points into a folder that was touched, re-resolve it and fall back to the folder root when the message is gone (`NavStateCoordinator.swift` on Apple).
4. Re-index or evict affected Spotlight entries on Apple (`SpotlightRouting.swift`).
5. Surface the `partial` / `folders_skipped` detail to the user, since a silently skipped folder is the one outcome they most need to know about.

Steps 1–3 are common to all three clients and belong in each kit (`CabalmailKit`, `android/kit`, `cabalmail-kit`), driven by the same job-status poll that feeds the progress indicator.

### D11. Privacy and logging

The search plan's rule is that result-set size is user information: it records success/failure, latency, and index path, but never query terms, result identifiers, or result counts. The original draft inherited half of that and then logged counts anyway. Resolved in favor of the stricter reading, because a bulk job's size says as much about a mailbox as a search's does — "this user has 31,482 messages older than a month from these senders" is exactly the kind of fact the search plan declined to write down.

- **Job records** hold the query, the counts, and the folder lists. They are the user's own data in the user's own row, encrypted at rest, TTL'd at 30 days, and read back by that user's clients.
- **Logs and metrics** carry job id, user, status transitions, durations, action *kinds*, and error classes. No counts, no folder names, no field values, no matched UIDs. Job-duration histograms and status-transition counts are the operational signal; "how big was that job" is not available from telemetry, deliberately.

The cost is real: we cannot answer "what size are jobs in practice" from CloudWatch, which is exactly the question D9's pacing knobs would like answered. The tuning pass reads it from job records on a stage mailbox instead.

Plan artifacts are deleted on completion and additionally covered by a short lifecycle rule on the `bulk-plans/` prefix, so an abandoned plan cannot outlive its job.

## Data model

**DynamoDB `cabal-bulk-jobs`** — hash `user`, range `job_id`, PAY_PER_REQUEST, SSE, PITR, TTL on `expires_at`.

- `job_id` = `f"{sequence:012d}-{uuid4().hex[:8]}"`, so a Query with `ScanIndexForward=true` returns a user's jobs in submission order.
- `sequence` comes from an atomic `UpdateItem ADD` on the sentinel item `job_id = "#seq"` for that user. A timestamp would be one write cheaper but ties on a fast double-submit; the counter is exact, which is the property the whole ordering argument rests on.
- Attributes: `status` (`queued` | `planning` | `running` | `completed` | `partial` | `failed` | `cancelled`), `query`, `actions`, `scope`, `planned_folders`, `plan_cursor`, `folders_touched`, `folders_skipped`, `destination`, `total`, `attempted`, `moved`, `failed_count`, `cursor` (`step_index`, `folder_index`, `chunk_index`), `created_at`, `started_at`, `finished_at`, `error`, `cancel_requested`, `expires_at`.

**S3 plan artifacts** — `s3://cache.<control-domain>/bulk-plans/<user>/<job_id>/<n>.json.gz`, one per planned folder, each `{"folder": …, "uidvalidity": …, "uids": [...]}`. 100,000 UIDs across all folders compress to well under a megabyte; each object is read once per continuation that touches its folder, and the prefix is deleted on completion.

**SQS** — `cabal-bulk-jobs.fifo` (content-based deduplication off; explicit `MessageDeduplicationId` per wake, since a continuation wake is otherwise byte-identical to the one that spawned it and would be swallowed by the 5-minute dedup window) plus `cabal-bulk-jobs-dlq.fifo`, with a depth alarm.

## API surface

| Endpoint | Method | Purpose |
|---|---|---|
| `/bulk_preview` | POST | Match count, exactness, sample envelopes, excluded and incomplete folders, and every refusal |
| `/new_bulk_job` | POST | Validate, allocate sequence, write record, enqueue wake. Returns `job_id` and queue position |
| `/list_bulk_jobs` | GET | Active and recent jobs with status, counts, and the reconciliation fields of D10 |
| `/cancel_bulk_job` | POST | Sets `cancel_requested`; the worker honors it between chunks |

All four follow the existing `local.lambdas` / `modules/call` wiring, Cognito-authorized, uncached. `bulk_apply` is not gateway-fronted and gets its own Terraform file alongside `append_sent.tf`.

## Client experience

Three steps, identical in model across the native clients, rendered natively in each:

1. **Conditions** — a match-all/match-any selector and a list of condition rows (field, operator, value), each row negatable, plus the scope picker with its exclusions shown and individually overridable (D2.2). Live "about N matches" as the query settles, debounced.
2. **Actions** — extras (mark read/unread, flag/unflag, add/remove custom flags) and one destination (nothing / move to folder / archive / trash / permanently delete). Order shown explicitly, destination pinned last.
3. **Review** — count, the sentence-form summary of the pipeline, the in-and-out-of-scope folder list, the sample list, and Confirm.

While a job is live, each client shows a compact progress affordance (`Archiving 12,400 of 31,482…`) fed by polling `/list_bulk_jobs`, with a cancel control. On terminal status the client runs the D10 reconciliation and reports actuals, including any skipped folders.

Rollout order: **Apple first**, then Android, then Linux. The wire contract lands once and does not change per client. React is out of scope (see Non-goals).

## Open questions

1. **Completion notification.** The push pipeline exists (`push_dispatch`, APNs + FCM) but carries one payload shape today, fed by procmail. Should a finished job wake the device, or is an in-app progress indicator enough for the first release? A wake would also be the natural trigger for the D10 reconciliation on a client that was not running.
2. **`/search_envelopes` convergence.** Does the search endpoint gain the tree grammar and the `contains_word` vocabulary in this plan (one grammar everywhere, immediately) or in a follow-on (smaller blast radius now, two shapes in the tree for a while)?
3. **Purge confirmation strength.** A count and a destructive-styled dialog, or a typed confirmation for irreversible jobs above some size?
4. **`MAX_JOB_MESSAGES` at 100,000.** Is refusing above that the right answer, or should the preview offer to split by folder or date range?
5. **Inter-chunk pause default.** 25 ms is a guess, and D11 means telemetry will not answer it. Worth measuring against a stage mailbox before it becomes a number people trust.
6. **Job history retention.** 30 days of records, or trim to the last N per user?

## Likely phase boundaries

Sketch only — the phased implementation plan comes after this design is reviewed.

1. Shared query compiler in `_shared/`, with unit tests over the grammar, the IMAP folding rules, and the `contains_word` semantics. No user-visible change.
2. Scope resolver: special-use enumeration, the `all_mail` exclusion set, destination dropping, purge's trash-only rule. Unit-testable against a fake LIST response.
3. `/bulk_preview` — the grammar and the scope rules become reachable and testable end to end, with no way to mutate anything.
4. Job engine: table, FIFO queue, `bulk_apply` worker, resumable planning, UIDVALIDITY checks, `/new_bulk_job`, `/list_bulk_jobs`, `/cancel_bulk_job`. Verified on stage against a synthetic large mailbox.
5. Apple wizard, including the D10 reconciliation in `CabalmailKit`.
6. Android and Linux wizards.
7. Telemetry, alarms (including the DLQ depth alarm), and the tuning pass on the pacing knobs.
