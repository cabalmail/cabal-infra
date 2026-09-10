# RSS Reader — Implementation Plan

## Context

This plan implements the RSS reader for Cabalmail 1.x based on the
decisions recorded in [`rss-requirements.md`](./rss-requirements.md).
It is the companion build plan to that requirements pass; whenever this
document says "per Dx," it refers to a decision in that file. The RSS
API is purely additive, which `docs/compatibility.md` classifies as a
minor release, so the work ships as 1.x minor releases (this
directory), each phase under its own release.

## Progress

The plan is still at the **Planning** stage on the roadmap wiki. No
phase has started. This table and the `**Status:**` line under each
phase are updated in the same PR as the work, per the docs convention.

| Phase | Work item                                         | Status      |
| ----- | ------------------------------------------------- | ----------- |
| 1     | DynamoDB tables + supporting infra                | Shipped 1.12.2 (2026-09-09) |
| 2     | Scheduler + fetcher Lambdas                       | On stage (2026-09-09) |
| 3     | Subscription + reader API                         | On stage (2026-09-09) |
| 4     | OPML import/export (API)                          | On stage (2026-09-10) |
| 5     | Apple clients (offline + FTS + cookie scoping)    | 5a on stage; 5b in review (2026-09-10) |
| 6     | Android client (offline + FTS + profile scoping)  | Not started |
| 7     | Image proxy + cache                               | Not started |
| 8     | Push notification integration                     | Not started |
| 9     | Credentialed feeds                                | Not started |
| 10    | Adaptive cadence + health surface polish          | Not started |

## Revisions (2026-09-09)

The plan was first written in May 2026 and revised in place on
2026-09-09 to reflect what shipped in the 0.11.x and 1.x releases and
to fix design defects found on re-read. This is an in-flight plan, so
the corrections are folded into the text rather than recorded as
errata; this section is the summary of what moved and why.

- **Public IMAP is closed and the API Lambdas are inside the VPC.**
  The prerequisite the original "Lambda networking policy" section
  waited on shipped in 0.11.x ([`private-imap-smtp-plan.md`](../1.x/private-imap-smtp-plan.md)).
  Every API Lambda is VPC-attached through
  `terraform/infra/modules/app/modules/call`, and the VPC has free
  gateway endpoints for S3 and DynamoDB. The plan's argument for
  running RSS Lambdas *outside* the VPC is withdrawn: it conflicted
  with D9's egress-IP-stability requirement (a non-VPC Lambda egresses
  from a shared, rotating AWS pool; the NAT Elastic IPs are the stack's
  only stable outbound identity) and it would have made RSS the one
  Lambda family with a different network posture. RSS Lambdas follow
  the existing pattern. See "Networking".
- **The React admin app receives no new features.** Every 1.x plan
  since mail rules records the React app as second-class; RSS has no
  React UI at all. The "React client v1" phase, the React
  known-limitations banner, and the React half of the per-feed
  cookie-scoping analysis are gone. The first reader UI is Apple, the
  second is Android.
- **Android is a first-class native client.** The May plan treated
  Android as "later" on the 1.1.x roadmap. It shipped: a UI-free `kit`
  module mirroring `CabalmailKit`, a Room-backed cache, FCM push with
  `/push_envelope` enrichment, and full coverage by the tester/fixer
  lifecycle. Android gets its own phase with offline reading, per-feed
  FTS, and per-feed web-view profile scoping, at parity with Apple.
- **The push pipeline's real shape is now known.** `push_dispatch`
  consumes content-free wake signals from `cabal-push-queue`
  (`batch_size = 1`), filters tokens by per-folder opt-in, sends silent
  background pushes to the macOS bundle ids, and the Apple Notification
  Service Extension deliberately does **not** link `CabalmailKit`. Each
  of those changes something in the notification and Apple-sync design;
  see "Notification path" and "Apple-side item cache".
- **Preferences sync exists.** `cabal-user-preferences` carries an
  `app` map validated against `APP_ALLOWED` in `set_preferences`, and
  the native clients already sync it. The separate
  `cabal-rss-user-settings` table is dropped in favour of `rss_*` keys
  in that map.
- **Conventions the plan had wrong.** Tables use AWS-owned encryption
  keys (with the standing `tfsec` ignore), not a customer KMS key;
  Cognito **username**, not `sub`, keys every per-user row; scheduled
  Lambdas use EventBridge Scheduler and live under `lambda/api/`; the
  API Gateway is flat (one Lambda per `path_part`, no path parameters);
  Lambda dependencies are hash-pinned; the runtime is Python 3.13. The
  plan now follows all of these.
- **Design defects fixed.** The sparse `unread_by_feed` index could
  never have worked with lazily-created state rows (a never-touched
  item has no row and so is absent from the index). The since-cursor
  keyed on `published_at` would miss backdated items. The
  `pending_notification` table plus a 60-second cron is replaced by a
  DynamoDB Stream on the item table. The single fetcher loop is split
  into a scheduler and a queue-fed per-feed worker so the 15-minute
  Lambda ceiling and per-feed retries stop being a concern. DynamoDB's
  400 KB item limit needs an S3 spill for oversized bodies. Details
  under "Data model" and "Data flow".
- **Requirements challenges were raised and ruled on the same day.**
  The operator's decisions (apex form canonical; `http://` upgraded to
  https or refused; Readability.js satisfies "reader view"; mark-as-read
  is manual or immediate-on-open under its own `rss_mark_as_read` key;
  a feed's content is deleted when its last subscriber leaves; the
  release is 1.x and the docs moved from `docs/2.x/` to `docs/1.x/`)
  are recorded as **Revised decision (2026-09-09)** annotations in the
  requirements doc and applied throughout this plan. Two follow-up
  rulings the same day dropped the reading-time estimate from v1
  (kept as future work) and confirmed the client order: Apple first,
  Android second, Linux once its mail client has caught up.

Three decisions shape the architecture more than the rest:

- **D6 = C: no server-side article extraction.** The server fetches
  feed XML/JSON, parses it, stores items as the feed delivered them,
  and serves them. When the user opens "the article," the client loads
  the publisher's page in an embedded web view (`WKWebView` on Apple,
  `WebView` on Android) and provides reader-mode styling on top. The
  server is never in the article-rendering business. This removes a
  whole subsystem and a whole class of operational risk (publisher
  anti-bot defenses, MIME oddities), at the cost of pushing some
  complexity into the clients (cookie scoping for paywalled content;
  see below).
- **D11: per-feed scoping of cookies and web-view local storage.**
  Each subscription gets its own credential and storage partition; a
  user with three Substack feeds authenticates each separately and
  keeps three Substack sessions side by side. On Apple this lands on
  `WKWebsiteDataStore(forIdentifier:)` (iOS 17+/macOS 14+; the Kit
  floor is iOS 18/macOS 15, so it is available unconditionally). On
  Android it lands on the `androidx.webkit` multi-profile API
  (`ProfileStore`), which is feature-gated at runtime on the installed
  WebView; see "Per-feed cookie scoping".
- **Revised D14 / Q2: DynamoDB primary store; per-feed FTS and offline
  reading on the native clients via a local SQLite cache.** The data
  layer is DynamoDB end-to-end — no relational store, no joins, no
  `tsvector`. Full-text search is per-feed only and lives client-side:
  SQLite FTS5 on Apple, Room FTS on Android. The same local cache
  supports offline reading (**Decision 18**), which is a first-class
  requirement on both native platforms.

Per open Q3 the **fetcher is Lambda-based**, not an ECS service (as a
scheduler plus a queue-fed worker; see "Data flow"). Per open Q5,
user-level customization (display preferences, ordering) is **stored**
server-side and **applied** client-side, so the shared canonical-feed
records hold no per-user data and the multi-tenancy boundary is
enforced by storage layout, not by access logic.

The plan is structured as ten independently-shippable phases. Each
phase ends in a state that can be deployed to prod without the next
phase being present.

## Goals

- A Cabalmail user can subscribe to RSS, Atom, and JSON feeds from the
  Apple and Android clients; read state and per-feed display
  preferences sync across devices.
- Public feeds are fetched once per cadence regardless of how many
  users subscribe; credentialed feeds are fetched per-user.
- The fetcher adapts its cadence per feed within operator-set bounds,
  with no user-exposed cadence control.
- Items are kept indefinitely server-side; image references in item
  bodies are proxied and cached for an operator-tunable TTL (default
  7 days, per D13).
- New items in subscribed feeds with notifications enabled produce
  APNs and FCM push within ~6 minutes of publication, reusing the
  0.11.x push path.
- A user can import an OPML file and export one at any time.
- Paywalled feeds with per-feed cookie scoping work on both native
  clients.
- **Both native clients support offline reading** of cached items
  (D18) — in-feed content (summary + any `content_html`) is fully
  available without network. Mark-read and favorite mutations
  performed offline queue locally and dispatch on reconnect.
- **Both native clients support per-feed full-text search** over the
  local cache.

## Non-goals (v1, all per the requirements doc)

- Server-side full-text article extraction (D6).
- **Server-side full-text search of any kind** (revised D14). No
  Postgres `tsvector`, no OpenSearch, no Lambda-scanning of items.
- **Cross-feed search**, on any client (revised D14; operator
  confirmed no real-world use case).
- **Any RSS surface in the React admin app.** The React app is
  second-class and receives no new features; the RSS API is
  client-neutral and nothing prevents a later React port, but none is
  planned.
- **RSS in the Linux client or the browser extension.** The Linux
  client waits until its mail client has caught up with Apple and
  Android (operator decision 2026-09-09); the extension is an
  address-management tool. A "subscribe to this page's feed"
  affordance in the extension (it already scans pages for
  `<link rel="alternate">`-style hooks) is a natural follow-on,
  not v1.
- Third-party API compatibility — no Fever, no Google Reader (D3).
- Email-to-feed (D7, deferred).
- Feed-to-email digests (D8, declined).
- Tagging, save-for-later, snooze, keep-unread pin, auto-mark-read on
  scroll, cross-feed dedup (D14, D15 — declined or deferred).
- Reading-time estimate (D15, revised 2026-09-09). Dropped from v1
  because D6 = C leaves no extracted text to estimate from; kept as
  future work, computed client-side from cached `content_html` and
  hidden for summary-only items, if it returns.
- OAuth-flow credentialed feeds (D11, deferred).
- Proactive notification of feed-health problems (D10 — visibility
  only in v1).
- A user-exposed fetch-cadence control (D17).
- Per-feed keyword muting (D14, declined).
- WebSub (PubSubHubbub) subscriptions. Feeds that advertise a hub
  could push to us instead of being polled; that needs a public,
  unauthenticated callback endpoint and its own verification story.
  Polling is fine at hobby scale; revisit if a high-velocity feed
  ever makes the min cadence feel slow.
- Aggressive pre-caching of image bytes onto devices for offline image
  rendering. The embedded web view's cache captures what it captures
  from prior online viewing; explicit image pre-fetch is a v1.x
  candidate.
- RSS on Apple Watch. The watch app is address-management only.

## Architecture overview

### Component diagram

```
                          +----------------------------+
                          |  DynamoDB tables           |
                          |    cabal-rss-feed          |
                          |    cabal-rss-item  --------+--- stream (INSERT) --+
                          |    cabal-rss-subscription  |                      |
                          |    cabal-rss-folder        |                      |
                          |    cabal-rss-user-item-    |                      |
                          |      state                 |                      |
                          +-------------+--------------+                      |
                                        ^                                     v
   +-----------+   Scheduler   +--------+-------+   SQS    +----------+  +----+-----+
   | EventBridge| every 5 min  | rss_schedule   | -------> | rss_fetch|  | rss_     |
   | Scheduler  | -----------> | (claims due    | feed ids | (one feed|  | notify   |
   +-----------+               |  feeds)        |          |  per msg)|  | (fan-out |
                               +----------------+          +----+-----+  |  to      |
                                                                |        |  users)  |
                                                 HTTPS + CGET   |        +----+-----+
                                                 via NAT EIPs   v             |
                                                           +---------+        | cabal-push-
                                                           |  feeds  |        | queue (SQS)
                                                           |  (any)  |        v
                                                           +---------+  +-----------+
                                                                        |  push_    |
                                                                        |  dispatch |
                                                                        | (0.11.x)  |
                                                                        +-----+-----+
                                                                              |
                                                                          APNs / FCM
                                                                              v
                    +-----------------+                  +-----------------+
                    |  iOS / macOS    |                  |  Android        |
                    |  (CabalmailKit) |                  |  (kit)          |
                    |  reader UI      |                  |  reader UI      |
                    |  WKWebView per  |                  |  WebView profile|
                    |  feed (WKWDS    |                  |  per feed       |
                    |  per identifier)|                  |                 |
                    |  +-----------+  |                  |  +-----------+  |
                    |  | ItemCache |  |                  |  | Room +    |  |
                    |  | SQLite    |  |                  |  | FTS       |  |
                    |  | + FTS5    |  |                  |  | offline + |  |
                    |  | offline + |  |                  |  | per-feed  |  |
                    |  | per-feed  |  |                  |  | search    |  |
                    |  | search    |  |                  |  +-----------+  |
                    |  +-----------+  |                  +--------+--------+
                    +--------+--------+                           |
                             +--------------+---------------------+
                                            |
                                            v
                              +-------------+---------+     +-------------------+
                              |  API Gateway          | --> |  rss_* Lambdas    |
                              |  (Cognito auth, flat  |     |  (lambda/api/,    |
                              |   path_part per fn)   |     |   VPC-attached)   |
                              +-----------------------+     +---------+---------+
                                                                      |
                                                                      v
                                                            +---------+---------+
                                                            |  rss_image Lambda |
                                                            |  + S3 cache (7d)  |
                                                            |  -> presigned URL |
                                                            +-------------------+
```

### Data flow

**Fetch path.** EventBridge Scheduler fires `rss_schedule` every 5
minutes. It queries `cabal-rss-feed`'s `by_due` GSI (`PK = "active"`,
`SK <= now`), claims each due feed with a conditional update that
advances `next_fetch_at` (so a slow or duplicated tick cannot fetch the
same feed twice), and enqueues one message per feed id on a new
`cabal-rss-fetch-queue` SQS queue (with a dead-letter queue, like
`cabal-push-queue`). `rss_fetch` consumes that queue one feed per
invocation with a small reserved concurrency (start at 5) so outbound
traffic stays polite and bounded. For each feed it issues a
conditional GET against the publisher with the prior
`ETag`/`Last-Modified`, parses the response, upserts items via the
`by_guid` GSI lookup + `PutItem`, updates the feed's health fields and
`observed_items_per_day`, and sets a new `next_fetch_at` from the
adaptive-cadence formula. A worker failure lands the message back on
the queue (visibility timeout) and eventually in the DLQ, which is the
operator's signal that a feed is misbehaving in a way the health
fields did not capture.

The split replaces the single "loop over every due feed" Lambda of the
original plan. It removes the 15-minute Lambda ceiling as a failure
mode, gives per-feed retries for free, mirrors the `push_dispatch`
queue-consumer pattern the project already runs, and costs nothing
extra at hobby scale.

Credentialed feeds run on the same worker in a per-user track: the
`cabal-rss-feed` row has `is_shared = false` and `owner_user` set to
the subscriber. The worker pulls credentials from SSM at
`/cabal/rss/credentials/<user>/<feed_id>`.

**Notification path.** `cabal-rss-item` has a DynamoDB Stream
(`NEW_IMAGE`); `rss_notify` is its Lambda trigger, filtered to
`INSERT` events so item updates (re-publishes) never notify. For each
new item it queries the sparse GSI `subscription.by_feed_notify` for
subscribers with notifications on and enqueues one wake signal per
(user, item) onto the existing `cabal-push-queue` with `kind = "rss"`.
This replaces the original `pending_notification` table, the
`TransactWriteItems` coupling in the fetcher, the 60-second cron, and
its TTL sweep: the stream *is* the durable pending queue, Lambda
stream triggers have no read charge, and retries come from the stream
retry policy. `push_dispatch` gains a `kind = "rss"` branch (the
existing mail signal is `{user, folder, uid, msg_id}` with no `kind`;
absence of the field means mail). See "Push notification integration"
for what changes inside `push_dispatch` and the clients.

**Read path.** Clients call API Gateway endpoints. Following the
existing gateway shape — one Lambda per flat `path_part`, JSON bodies,
no path parameters — the endpoints are `rss_*` functions under
`lambda/api/` (e.g. `/rss_subscribe`, `/rss_list_items`,
`/rss_set_item_state`), not a REST-style `/rss/items/{id}` tree. This
keeps them on the existing build (`build-api-one.sh`), lint, CI filter
(`lambda/api/**`), and Terraform (`modules/app/modules/call`) paths
with no new plumbing. Lambdas execute DynamoDB Query/BatchGet calls
directly. The endpoint that returns an item body rewrites
`<img src="...">` to image-proxy URLs (phase 7).

For folder-spanning item lists, the API runs N parallel Queries
against the item table (one per feed in the folder), merge-sorts the
streams by `published_at` in the Lambda, and overlays per-user state
from `user-item-state`. See "Data model" for how unread and favorite
filtering work.

**Native sync path.** When online, a client polls
`/rss_list_items` with `since=<fetched_at cursor>` per subscribed feed
to pull new items into its local cache. The cursor is the server's
`fetched_at` (ingest time), **not** `published_at`: publishers backdate
and re-date items, and a cursor over `published_at` silently misses
them. Foreground sync and background refresh handle the rest; the push
path assists on Apple through an App Group handoff (not by the NSE
writing the cache directly — see "Apple-side item cache").

### Shared vs. per-user data

| Concept              | Shared / per-user                                |
| -------------------- | ------------------------------------------------ |
| `cabal-rss-feed`     | Shared (public feeds) **or** per-user            |
|                      | (credentialed feeds, `is_shared = false`)        |
| `cabal-rss-item`     | Shared with the feed it belongs to               |
| `subscription`       | Per-user (links user to feed_id)                 |
| `folder`             | Per-user                                         |
| `user-item-state`    | Per-user (read, favorite, read_at)               |
| Credentials          | Per-user SSM parameters; credentialed feeds      |
|                      | bypass sharing                                   |
| User settings        | Per-user `rss_*` keys in the existing            |
|                      | `cabal-user-preferences` `app` map               |
| Display preferences  | Per-user attrs on `subscription`, applied        |
|                      | client-side (per open Q5)                        |

Credentialed feeds get a *per-user* `cabal-rss-feed` row (same
canonical URL, different `owner_user`). This trades schema purity for
explicit isolation — there is no code path where a credentialed fetch
lands content into a row that another user can read.

## Data model (DynamoDB)

All tables follow `terraform/infra/modules/table/main.tf`:
**on-demand** capacity, **server-side encryption with the AWS-owned
key** (the standing `#tfsec:ignore:aws-dynamodb-table-customer-key`
directive; there is no project KMS key for tables and the plan no
longer introduces one), **point-in-time recovery** enabled, and
**deletion protection** on every table that holds user data. The
per-user key is the Cognito **username** (the `cognito:username`
claim, as extracted by `_shared/helper.py` and used by every other
per-user table), named `user` below. The schema:

```
cabal-rss-feed
  PK: feed_id (UUID v4 string)
  attrs: canonical_url, is_shared (bool), owner_user (null when shared),
         feed_type ('rss'|'atom'|'json'), display_name, description,
         site_url, next_fetch_at_iso, last_fetched_at_iso,
         last_etag, last_modified, last_status_code, last_error,
         consecutive_failure_count, cadence_minutes,
         observed_items_per_day, item_count, subscriber_count,
         created_at
  GSI by_canonical:  PK = canonical_url
                     SK = owner_user_or_NULL_SENTINEL
                     (dedup on subscribe; sentinel string for nulls
                      since DynamoDB GSIs reject null SK)
  GSI by_due (sparse): PK = due_shard ("active" while fetchable;
                            attribute removed when dead-lettered; the
                            whole row is deleted when subscriber_count
                            reaches 0)
                       SK = next_fetch_at_iso

cabal-rss-item
  PK: feed_id
  SK: published_at_iso#item_id  (sortable + unique; published_at is
                                 fixed at first sight — a re-publish
                                 updates attrs, never the SK)
  attrs: item_id (UUID), guid, title, author, url,
         summary_html, content_html | content_s3_key,
         published_at, updated_at, fetched_at
  GSI by_guid:    PK = feed_id, SK = guid
                  (upsert dedup lookup on fetch; guid falls back to
                   the item link, then to a hash of title+content,
                   when the feed omits one)
  GSI by_fetched: PK = feed_id, SK = fetched_at_iso#item_id
                  (the since-cursor for client sync)
  Stream: NEW_IMAGE (drives rss_notify)

cabal-rss-subscription
  PK: user
  SK: subscription_id (UUID)
  attrs: feed_id, folder_id, custom_title, ordering_mode,
         default_open_mode, default_styling,
         notifications_enabled, credentials_scheme (null | 'basic' |
         'url_key' | 'cookie'), read_watermark_iso,
         data_store_uuid, created_at
  GSI by_user_folder: PK = user
                      SK = folder_id#subscription_id
                      (list subscriptions in folder)
  GSI by_feed_notify (sparse): PK = feed_id
                               SK = user
                               (present only when
                                notifications_enabled = true)

cabal-rss-folder
  PK: user
  SK: folder_id (UUID)
  attrs: parent_folder_id (null = root), name, display_order

cabal-rss-user-item-state
  PK: user#feed_id
  SK: published_at_iso#item_id    (matches item SK shape)
  attrs: item_id, is_read, is_favorite, read_at, updated_at
  GSI favorite_by_feed (sparse): PK = user#feed_id
                                 SK = published_at_iso#item_id
                                 (present when is_favorite = true)
```

Five tables, down from eight. What went, and why:

- **`cabal-rss-pending-notification`** — replaced by the item
  table's stream (see "Notification path").
- **`cabal-rss-user-settings`** — replaced by `rss_*` keys in the
  `app` map of `cabal-user-preferences`, validated in `APP_ALLOWED`
  like the mail keys: `rss_mark_as_read` (`manual | on_open`, the same
  two modes the mail clients offer, under its own key so mail and feed
  habits can differ) and `rss_last_ordering_mode`. The map is
  `{string: string}`
  by contract with the shipped clients, which enum values satisfy. The
  Linux `xtask` drift test asserts client keys against `APP_ALLOWED`;
  new keys land in both.
- **`cabal-rss-credentials`** — the SSM path is derivable from
  `(user, feed_id)`, so the table only ever held the scheme, which now
  sits on the subscription row.

A few notes on the model:

- **No tombstones.** Per D4, items live forever; tombstones were only
  needed if items could be dropped. Image-cache objects age out (D4
  "linked content"); item rows do not.
- **Oversized bodies spill to S3.** DynamoDB caps an item at 400 KB and
  some feeds deliver full-article `content_html` (occasionally with
  inline base64 images) well past that. Bodies over ~300 KB are written
  to the `rss-cache` bucket's `items/<feed_id>/<item_id>` prefix
  and the row carries `content_s3_key` instead of `content_html`; the
  read endpoint inlines it. Same pattern as the mail message cache.
- **`is_shared` + `owner_user`** disambiguates shared from per-user
  canonical-feed records. The `by_canonical` GSI uses an owner sentinel
  for shared rows so the (canonical_url, owner_user) lookup works
  uniformly.
- **Missing user-item-state rows mean default state** (unread, not
  favorite). This avoids writing a row for every (user, item) pair at
  fetch time on shared feeds. A row is created the first time the user
  marks-read or favorites an item.
- **Unread is computed, not indexed.** The original plan's sparse
  `unread_by_feed` GSI is gone: with lazy rows, an item nobody has
  touched has no row and so would never appear in an "unread" index.
  Unread for a feed is *items minus read rows*: Query the item table
  (SK order gives the ordering), BatchGet the matching state rows, and
  drop the ones with `is_read = true`. Per-feed item counts are in the
  hundreds to low thousands, so this is a page or two of reads.
- **Mark-all-as-read is a watermark.** `read_watermark_iso` on the
  subscription means "everything published at or before this instant
  is read." Mark-all-read (per feed, per folder, global — D15) writes
  one attribute per subscription instead of one row per item; the
  unread computation treats items at or below the watermark as read
  unless a state row explicitly says `is_read = false` (the user
  re-marked one unread afterwards). Unread counts follow the same
  rule: count items above the watermark, subtract read rows above it.
- **Favorites keep a sparse GSI.** Favorite is opt-in and explicit, so
  the sparse-index pattern works for it: `favorite_by_feed` contains
  exactly the rows with `is_favorite = true`.
- **A feed with no subscribers is deleted** (D4, revised
  2026-09-09). When the last subscription to a shared feed is removed,
  `/rss_unsubscribe` deletes the feed row, its items, any spilled
  bodies under `items/<feed_id>/`, and the departing user's state rows
  for it. Unsubscribing while other subscribers remain deletes only the
  user's own state rows; a per-user credentialed feed is deleted with
  its single subscription. Re-subscribing starts the feed fresh. D4's
  "kept forever" therefore applies while at least one subscription
  exists; a cold-storage tier for departed feeds is a possible later
  release, and the S3 spill prefix is where it would live.
- **The four ordering modes** (D17 confirmed scope): modes 1 and 2
  (oldest/newest first) fall out of the SK shape. Modes 3 and 4
  (day-grouped) don't encode naturally in a DynamoDB SK; the API
  fetches a chunk in `published_at` order and re-sorts in the Lambda.
  Pagination uses a fixed over-fetch multiplier (e.g. 2x page size) to
  handle the reorder correctly. Since the native clients read from a
  local cache, the day-grouped modes can equally be applied
  client-side; the server implementation exists so the first page a
  fresh install sees is already in the right order.

## Apple-side design (phase 5, as decided 2026-09-10)

This section is the phase 5 design note: what `CabalmailKit` and the two
app targets gain, in the order the PRs land. It supersedes the May
sketch below it in spirit; the May schema is kept as the record of where
the design started. The one server-side change phase 5 needs is the
`rss_mark_as_read` key in `set_preferences`'s `APP_ALLOWED` (and the
Linux `xtask` drift test's mirror of it).

### Storage: a thin actor over the system SQLite

`CabalmailKit` has no third-party Swift dependencies and keeps it that
way (operator decision 2026-09-10): `RssStore` is an actor over the
`SQLite3` module that ships with every Apple OS, a few hundred lines
wrapping `sqlite3_prepare_v2` / bind / step for the dozen statements this
cache needs. WAL mode, one file per account scope
(`Application Support/<scope>/rss.sqlite`, the same account hashing
`Preferences.scopeIdentifier` uses), forward-only migrations by
`PRAGMA user_version`; downgrade is delete-and-repopulate from the
server. The store mirrors the *whole* RSS catalog, not just items, so
the sidebar renders offline:

```sql
folders        (folder_id PK, parent_folder_id, name, display_order)
subscriptions  (subscription_id PK, feed_id, folder_id, custom_title,
                ordering_mode, default_open_mode, default_styling,
                notifications_enabled, read_watermark, data_store_uuid,
                feed_title, feed_site_url, feed_type, feed_health_json)
items          (feed_id, sort_key, item_id, guid, title, author, url,
                published_at, fetched_key, summary_html, content_html,
                is_read, is_favorite, state_is_explicit,   -- server state
                cached_at,  PRIMARY KEY (feed_id, sort_key))
items_fts      fts5(title, body_text, content='items', content_rowid=id,
                    tokenize='unicode61')  -- kept by triggers; no stemmer,
                                           -- so typed prefixes match
feed_sync      (feed_id PK, since_cursor, oldest_sort_key, last_synced_at)
pending        (id PK, kind, feed_id, sort_key, value, created_at)
               -- kind: read | favorite | mark_all_read(subscription)
```

`body_text` for the FTS table is the stripped HTML of summary +
content; stripping reuses the Kit's existing `HTMLText` plain-text path
(the mail snippet code), not `NSAttributedString`'s WebKit-backed parser.
Read state is computed locally by the same rule the server uses (an
explicit row wins, else `published_at <= read_watermark`), so the list,
the unread counts (`SELECT COUNT` per subscription/folder), and the
filters never need a network round trip.

### Kit API surface

- `RssClient` protocol with `ApiBackedRssClient` as the only production
  implementation (there is no direct-protocol alternative to keep alive,
  unlike IMAP), wire types in `Models/Rss.swift` mirroring `docs/rss.md`
  field for field, and `URLSessionApiClient+Rss.swift` for the thirteen
  endpoints. Tested with `RecordingHTTPTransport` like the other
  endpoint groups.
- `RssStore` (above) and `RssSyncEngine`, an actor that owns the sync
  loop and is the only writer to the store besides the UI's optimistic
  local mutations.
- `CabalmailClient` gains `rss: RssClient`, `rssStore`, `rssSync`, wired
  in `make(...)`; nil-safe under the memberwise initializer for tests.

### Sync loop

1. **Catalog refresh** (`/rss_list_subscriptions`) on sign-in, on
   foreground, on pull-to-refresh, and after every management mutation:
   folders and subscriptions upserted, departed ones deleted along with
   their items and their `WKWebsiteDataStore`.
2. **Per-feed item sync** via `/rss_list_items?since=` from the stored
   cursor, pages of 100 until `has_more` is false (bounded per run).
   A **new** subscription is populated instead from
   `/rss_list_items?order=newest&limit=100` and its cursor set to the
   largest `fetched_key` seen; "Load older" pages the same call with its
   cursor and appends. Subscribed feeds sync with the same concurrency
   cap the mail sidebar uses for folder counts (4).
3. **Mutation queue**: mark read/unread, favorite, and mark-all-read
   apply to the store immediately and enqueue; the engine drains the
   queue in `/rss_set_item_state` batches (≤100) and
   `/rss_mark_all_read` calls whenever online, on reconnect
   (`Reachability`), and before each item sync. Last write wins; a
   server row that disagrees after a drain is taken as truth.
4. **Triggers**: selecting a feed or folder syncs the visible feeds;
   foreground syncs everything subscribed; iOS `BGAppRefreshTask`
   (system-scheduled, at least hourly requested) and a 15-minute timer
   on macOS while the app runs; the push-assisted path arrives with
   phase 8 through the App Group handoff described there.

### Screens

- **Sidebar.** On macOS and regular-width iPad the existing mail
  sidebar gains a collapsible **Feeds** section under the folder
  sections: the RSS folder tree with feeds as leaves, unread counts in
  the style of `folderCountDisplay`, drag-to-reorder into folders, a
  `+` for subscribe and a context menu (rename, move, settings, mark all
  read, unsubscribe). Selecting a feed or folder swaps the content
  column to the item list and the detail column to the item reader;
  selecting a mail folder swaps back. One sidebar, two content types,
  the way Reeder and Mail-plus-NetNewsWire users already think.
- **iPhone (compact)** gets a **Feeds** tab beside Mail, hosting its own
  `NavigationSplitView` that collapses to a stack (folders/feeds → items
  → reader), mirroring `MailRootView`. **visionOS** gets a Feeds tab in
  its ornament bar.
- **Item list.** Filter pills all / unread / favorite, the four ordering
  modes applied locally (two by SQL order, two day-grouped in Swift),
  swipe read/unread and favorite, per-feed search field backed by FTS5
  with a "Search older items" affordance that pulls another page first,
  and the mail list's index-addressed virtualization pattern for long
  feeds.
- **Reader.** Header (feed, title, author, date), then the in-feed body
  through the existing `HTMLBodyView` with the subscription's
  `default_styling` choosing reader or original styling (the mail
  reader's stylesheet approach, per the standing A/B posture), remote
  content gated by the existing `loadRemoteContent` preference until
  phase 7's proxy exists, and an **Open article** action. A subscription
  whose `default_open_mode` is `article` opens the article view
  directly.
- **Article view.** `WKWebView` with
  `WKWebsiteDataStore(forIdentifier: data_store_uuid)`, JavaScript on
  (publisher pages need it), back/forward, Share, Open in Safari, and a
  reader toggle that injects Mozilla's Readability.js and restyles the
  result with the reader stylesheet. Readability is vendored like
  marked/turndown: pinned in `react/admin/package.json`, materialized by
  `sync-vendored.sh`, credited in `Acknowledgements` (Apache-2.0).
  Unsubscribing removes the data store.
- **Management.** Subscribe sheet (URL, folder picker, the API's error
  codes rendered as sentences), subscription settings sheet (title,
  folder, ordering, open mode, styling, notifications toggle — stored
  now, effective with phase 8), folder create/rename/move/delete, OPML
  import through `fileImporter` and export through the share sheet /
  `fileExporter`.
- **Settings.** A **Feeds** category: mark-as-read (manual / on open,
  the `rss_mark_as_read` synced key, mirroring the mail picker) and the
  OPML actions. macOS adds menu commands and shortcuts for mark read,
  favorite, mark all read, next/previous unread, and open article,
  window-scoped like the mail commands.
- **Offline.** The existing offline banner covers status; items carry a
  small "queued" mark while a mutation is pending, and the article
  action shows "needs a connection" when unreachable.

### Delivery order

Four PRs, each green and shippable on its own: **5a** Kit (models,
client, store, sync engine, tests) plus the `APP_ALLOWED` key; **5b**
the read path on iOS and macOS (sidebar section and tab, list, reader,
article view); **5c** management (subscribe, settings, folders, OPML,
the Settings category, macOS commands); **5d** search, offline
indicators, and polish from dogfooding. The Feeds section and tab
appear with 5b.

## Apple-side item cache, FTS, and offline reading (May 2026 sketch)

*Kept as the planning record; the design above is the one being built.*

This lives entirely in `CabalmailKit` and the iOS/macOS apps; no
server-side change beyond the `since` cursor on `/rss_list_items`
(phase 3).

### Storage

SQLite with FTS5 (Apple's bundled SQLite ships with FTS5). **Library
choice is a phase-5 decision to make deliberately:** `CabalmailKit`
currently has *no* third-party Swift package dependencies (its
`Package.swift` declares none; the only vendored code is the
marked/turndown JS, materialized by `scripts/sync-vendored.sh` and
pinned via `react/admin/package.json`). GRDB.swift is the obvious
choice and would be the Kit's first SPM dependency, with the
supply-chain and pinning obligations that implies under the
supply-chain hardening work. The alternative is a thin actor over the
system `sqlite3` C API — a few hundred lines for the handful of
statements this cache needs. Either is fine; the point is to choose,
not to drift into a dependency. The cache schema:

```sql
CREATE TABLE items_cache (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  feed_id             TEXT NOT NULL,
  item_id             TEXT NOT NULL,       -- server-side item_id
  guid                TEXT NOT NULL,
  title               TEXT,
  author              TEXT,
  url                 TEXT,
  summary_html        TEXT,
  content_html        TEXT,
  published_at        INTEGER,             -- unix epoch
  fetched_at          INTEGER,             -- server ingest time (sync cursor)
  is_read             INTEGER DEFAULT 0,   -- mirrors server state
  is_favorite         INTEGER DEFAULT 0,
  fetched_locally_at  INTEGER,
  UNIQUE (feed_id, item_id)
);
CREATE INDEX items_cache_feed_pub
  ON items_cache (feed_id, published_at DESC);

CREATE VIRTUAL TABLE items_fts USING fts5(
  title,
  body_text,                                -- stripped HTML
  content='items_cache',
  content_rowid='id',
  tokenize='porter unicode61'
);
-- triggers keep items_fts in sync with items_cache

CREATE TABLE feed_sync_state (
  feed_id                          TEXT PRIMARY KEY,
  last_synced_at                   INTEGER,
  since_cursor                     TEXT,     -- server fetched_at#item_id
  oldest_cached_published_at       INTEGER,
  read_watermark                   INTEGER
);

CREATE TABLE pending_mutations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id      TEXT NOT NULL,
  feed_id      TEXT NOT NULL,
  mutation     TEXT NOT NULL,    -- 'mark_read' | 'mark_unread'
                                 -- | 'favorite' | 'unfavorite'
                                 -- | 'mark_all_read'
  created_at   INTEGER NOT NULL
);
```

`items_fts` mirrors stripped-HTML text of `summary_html` and
`content_html` for indexing. HTML stripping uses Apple's
`NSAttributedString(data:options:documentAttributes:)` with
`.html` document type — adequate for plaintext extraction, ships
with the OS, no third-party dependency. (The Kit's MIME layer already
has HTML-to-text plumbing for mail snippets; reuse it if it fits.)

`pending_mutations` is the offline-write queue. When the user marks
an item read or favorites it while offline, the cache is updated
immediately and a row lands in `pending_mutations`; the next time
the client has connectivity, a sync job drains the queue against the
server with last-write-wins semantics.

### Sync strategy

Three sync paths cooperate:

- **Push-assisted (notification-on feeds).** The original plan had the
  Notification Service Extension write the enriched item straight into
  the local cache. It cannot: the NSE deliberately does **not** link
  `CabalmailKit` (it stays tiny and reads the API URL and a mirrored
  Cognito token from the App Group via `PushEnrichmentStore`), so it
  has no access to the cache code, and a second process writing the
  SQLite file would need its own locking story anyway. Instead the NSE
  writes the enriched item JSON it already fetched into an App Group
  **handoff directory**; the main app drains that directory into
  `ItemCache` on next launch or foreground. Same shared-container
  contract as today, in the other direction. On macOS the app itself
  receives the (silent) push while running and can write the cache
  directly.
- **Background refresh (notification-off feeds).** Registered iOS
  `BGTaskScheduler` task runs at the system's discretion (typically
  once per hour at the system's whim); pulls new items for all
  subscribed notification-off feeds via the `since` cursor.
- **Foreground sync.** When the user opens a feed or folder, the
  client fires a sync for the visible feeds immediately and shows
  newly-arrived items inline.

**Initial population.** On first launch (or first subscription), the
client eagerly fetches the most recent ~100 items per subscribed feed
in the background. This makes search useful from day one without
hammering the server. A "load older" UI affordance on each feed
triggers a one-shot pull of older items into the cache (and re-indexes
FTS).

### Cache retention

Default: keep items from the last 365 days per feed, plus all
favorites unconditionally. User-configurable per-feed override. The
eviction job runs on app launch (low priority, batched). The server
keeps items forever (per D4), so re-fetching evicted items via
"load older" always works.

Storage estimate at default retention: 50 active feeds × ~365
items/year × ~5 KB/item ≈ 90 MB. Comfortable on any current device.

### Offline reading

The client's reader UI reads exclusively from the local cache.
"Online vs. offline" is transparent to the user — what's cached is
what's shown. Articles opened via the web view still require network
(per D6); the UI signals this distinction with a small "article
requires connection" indicator when offline.

Images inside cached in-feed content rely on whatever the web view's
`URLCache` happened to fetch on previous online viewing. Explicit
pre-cache of image bytes is deferred (could be a v1.x addition).

In-feed content renders through the **existing message-body
renderer** on each platform, including its reader-mode toggle. The two
platforms currently implement reader mode differently (Android strips
author CSS; Apple overrides it) as a deliberate side-by-side
comparison the operator is still running; RSS inherits whichever
approach each client has and does not pick a winner.

### Per-feed FTS

Search is a feed-scoped FTS5 query against `items_fts` joined to
`items_cache`:

```sql
SELECT items_cache.*
FROM items_cache
JOIN items_fts ON items_fts.rowid = items_cache.id
WHERE items_fts MATCH ? AND items_cache.feed_id = ?
ORDER BY rank;
```

BM25 ranking is built into FTS5. The UI surfaces a per-feed search
field; results show what's in the cache. A "search older items"
affordance triggers a deeper pull from the server before re-running
the query.

### Cross-device inconsistency

Different devices maintain independent caches; search results scale
with each cache. This is acceptable for per-feed search (you search
where you are) and is consistent with how every other multi-device
RSS reader behaves.

## Android-side item cache, FTS, and offline reading

The Android `kit` module already has a Room database
(`RoomEnvelopeCache`, storing envelopes as wire JSON keyed by folder
and uid, exercised on-device rather than under Robolectric). The RSS
cache is a sibling in the same module:

- **Tables** mirror the Apple schema: `rss_items`, `rss_feed_sync`,
  `rss_pending_mutations`. Unlike the envelope cache, items are
  exploded into columns, because search needs real text columns.
- **FTS** uses Room's `@Fts4` entity (Room has first-class FTS3/FTS4
  support; FTS5 is not annotated and would need raw SQL plus a check
  that the platform SQLite on API 31+ devices enables it). FTS4 with
  the `unicode61` tokenizer is adequate for per-feed search; BM25
  ranking is not built in, so ranking is by recency, which for
  per-feed search over a few hundred items is what users expect
  anyway.
- **Sync, retention, and the offline mutation queue** follow the Apple
  design exactly; the `kit` contract tests cover the in-memory
  implementation and the Room DAO is exercised on-device, matching the
  envelope cache's existing test posture.
- **Push-assisted sync** is simpler than on Apple: the
  `FirebaseMessagingService` runs inside the app process, already
  calls the API for enrichment, and can write the cache directly.

## Networking

Every API Lambda has been VPC-attached since the private-IMAP replumb
(0.11.x): `modules/app/modules/call` sets `vpc_config` for all of
them, the VPC has free **gateway endpoints for S3 and DynamoDB**, and
the remaining AWS-service calls (SSM, SQS, Cognito, Logs) ride the NAT
path by deliberate choice (interface endpoints cost per AZ-hour and
those flows are thin). The RSS Lambdas follow the same pattern, for
three reasons:

- **D9 requires stable egress IPs**, and the NAT Elastic IPs are the
  stack's only stable outbound identity (`docs/nat.md`; they already
  carry `smtp.<control-domain>` forward DNS and validated reverse DNS,
  and survive quiesce and NAT-mode switches). A Lambda outside the VPC
  egresses from AWS's shared regional pool: publishers that
  rate-limit or block by IP would see Cabalmail's fetches arriving
  from addresses shared with every other tenant, and there would be
  nothing to put on a feedbot info page.
- **Uniformity.** One network posture for every Lambda in the account
  is easier to reason about, secure, and quiesce than a special case.
- **Reuse.** The `call` module, its security group, and its IAM
  template already exist. The DynamoDB and S3 flows use the gateway
  endpoints; the fetcher's feed traffic and the thin SSM/SQS calls use
  NAT like everything else.

Consequences worth naming:

- **Fetcher traffic shares the NAT.** At hobby scale (a few hundred
  conditional GETs per hour, mostly 304s) this is noise next to mail
  and log traffic. In NAT Gateway mode it is metered per GB; the
  budget below allows for it.
- **RSS joins the NAT failure blast radius.** Mail delivery, `/send`,
  and log shipping already do; RSS adds nothing new in kind. The
  `docs/nat.md` diagnosis applies unchanged.
- **Quiesce must also pause the schedule.** Quiesce removes the
  private subnets' default route, so a still-scheduled `rss_schedule`
  in a quiesced environment would enqueue feeds that `rss_fetch` then
  fails on until the DLQ fills. The schedule resource reads
  `var.quiesced` and sets its own state to `DISABLED`, the same
  variable that scales the rest of the compute to zero.
- **Cold starts** are not a reason to stay outside the VPC; Lambda has
  pre-provisioned VPC networking (Hyperplane) since 2019 and the
  existing API Lambdas already pay whatever residual cost exists.

The May plan's "Lambda networking policy" (in the VPC only if the
function needs an internal-only resource) is superseded: the working
rule is that Lambdas in this account are VPC-attached, and a function
that wants to be outside must argue for it.

## Per-feed cookie scoping

### Apple clients

`WKWebView` supports per-instance website data stores since
iOS 17/macOS 14 via `WKWebsiteDataStore(forIdentifier: UUID)`. The Kit
floor is iOS 18/macOS 15, so this is available unconditionally. The
identifier is the subscription's `data_store_uuid`, generated
server-side on subscribe and returned with the subscription, so every
Apple device of the same user shares one identifier per subscription
(the stores themselves are still per-device). When the user opens an
article in a web view, the view's configuration uses the per-feed data
store; cookies and `localStorage` set on the publisher's site survive
across launches and stay isolated from other feeds' data stores.

Removal: when the user unsubscribes from a feed, the client calls
`WKWebsiteDataStore.remove(forIdentifier:)` to delete all stored
cookies and `localStorage` for that feed.

### Android client

The `androidx.webkit` multi-profile API (`ProfileStore` /
`Profile`, applied with `WebViewCompat.setProfile`) gives each
`WebView` its own cookie jar, storage, and cache, keyed by a profile
name — the direct analog of `WKWebsiteDataStore(forIdentifier:)`. It
is gated on the installed WebView build via
`WebViewFeature.isFeatureSupported(MULTI_PROFILE)`; on API 31+ devices
with a current system WebView it is present. Where it is not, the
client falls back to the default profile and surfaces the same
"sessions are shared across feeds on this device" notice the React
analysis once described. Profile name is the subscription's
`data_store_uuid`; unsubscribing deletes the profile.

### What the React analysis established

The May plan spent a section on why a browser cannot partition cookies
per app-controlled identity (CHIPS partitions by top-level site;
service workers cannot touch `Cookie` headers; `<iframe sandbox>` has
no cookie flag). With no React RSS UI that analysis is moot for v1; it
remains correct if a browser client is ever revisited, and the
remedies it listed (open in a new tab; hide credentialed feeds; a
server-side cookie-rewriting proxy, not recommended) are still the
menu.

## Phased implementation

Each phase is independently shippable. Phase 1 is foundational; from
phase 3 onward, work can parallelize across the OPML, Apple, Android,
image-proxy, and push tracks. Phases are cut along **verification**
boundaries — what can be exercised end to end on stage (by script,
by the daily client tester, or by the operator dogfooding) before the
next phase lands — rather than by authoring effort, which is no longer
the constraint on this project.

### Phase 1: DynamoDB tables + supporting infra

**Status:** Shipped in 1.12.2 (2026-09-09, PR #1488). The per-function IAM grants
and the quiesce hook moved to phase 2, where their consumers exist (see
the notes in the work list).

**Goal.** All DynamoDB tables, the item-table stream, the fetch queue
and its DLQ, and the `rss-cache` S3 bucket in place in all three
environments. No application code. (The SSM credential hierarchy needs
no Terraform until phase 9 writes to it; parameters are created at
runtime.)

**Work.**

- Five tables in `terraform/infra/modules/table/main.tf`, following
  the sibling tables' shape (on-demand, AWS-owned SSE with the
  standing `tfsec` ignore, PITR, deletion protection), indexes per the
  data model, `stream_enabled` + `NEW_IMAGE` on `cabal-rss-item`. The
  tables join the AWS Backup selection through a new `extra_tables`
  input on the backup module.
- `cabal-rss-fetch-queue` + `cabal-rss-fetch-dlq` in a new
  `modules/app/rss.tf` (both producer and consumer are app-module
  Lambdas; the push queue sits in the ecs module only because its
  producer is a container).
- `rss-cache.<control-domain>` bucket in the same file, next to the
  message-cache bucket's conventions (private, access-logged): versioned,
  a 7-day expiry on the `img/` prefix, no expiry on the `items/` spill
  prefix, and a bucket-wide 7-day retirement of noncurrent versions and
  abandoned multipart parts. Two inline, justified Checkov skips
  (cross-region replication, event notifications) match the other
  buckets' baseline entries.
- Concrete attribute names, where the schema above uses descriptions:
  feed `owner_key`, `due_shard`, `next_fetch_at`; item `sort_key`
  (`published_at_iso#item_id`), `fetched_key`
  (`fetched_at_iso#item_id`); subscription `folder_key`
  (`folder_id#subscription_id`), `notify_feed_id` (sparse);
  user-item-state `user_feed` (`user#feed_id`), `sort_key`,
  `favorite_key` (sparse). Every GSI projects `KEYS_ONLY` except
  `by_user_folder` (`ALL`; subscription rows are small).
- The `rss_table_arns` and `rss_item_stream_arn` outputs on the table
  module. The per-function IAM grants land with the first consumer in
  phase 2: the `call` module's uniform DynamoDB grant is **not** widened
  to the RSS tables; RSS functions get a per-function table list
  instead. (Plumbing an unused variable through the app module now
  would trip tflint's unused-declaration rule.)
- Quiesce is Terraform-variable driven (`var.quiesced`), so the pause
  hook is a property of the schedule resource itself —
  `state = var.quiesced ? "DISABLED" : "ENABLED"` on the EventBridge
  Scheduler schedule — and lands with the schedule in phase 2, together
  with the `docs/quiesce.md` row.
- CHANGELOG fragment: tables, queue, bucket, and SSM hierarchy for the
  RSS feature set; no application traffic yet.

The one-shot table-verification Lambda in the May plan is dropped:
`terraform apply` failing is the verification, and the IaC gates
(Checkov, tflint, tfsec) already run on every plan.

**Rollback.** Destroy the resources. Nothing references them.

### Phase 2: Scheduler + fetcher Lambdas

**Status:** On stage (2026-09-09, PR #1489), validated with three seeded
public feeds (Atom, RSS, JSON Feed): first fetch stored 78 items, the
forced second cycle returned 304 where the publisher honours validators.
That soak found one publisher (Cloudflare-fronted) that never 304s when
sent the weak ETag Cloudflare substitutes on compressed responses, or any
stale `If-Modified-Since`; the client now sends the strong form of the
ETag alone, and the date only when no ETag is known. `rss_schedule` and `rss_fetch` under
`lambda/api/`, the shared `rss_url` / `rss_http` / `rss_parse` /
`rss_cadence` modules with unit tests, `modules/app/rss_fetcher.tf`
(roles, log groups, SSM cadence bounds, the five-minute schedule gated
on `var.quiesced`, the queue event source mapping), the
`front-door/feedbot.html` bot page, and the `docs/quiesce.md` row. As
built, two details differ from the text below: the User-Agent is the
constant `Cabalmail-Feedbot/1 (+https://www.<control-domain>/feedbot.html)`
rather than carrying the release version (the fetcher zip is built
without knowledge of the release), and a permanent redirect whose target
already belongs to another feed row is **recorded** (`redirect_conflict_url`)
rather than merged, because merging needs to re-point every subscriber
and that is API-side work for phase 3.

**Goal.** Public feeds are fetched on their cadence, RSS/Atom/JSON
parsed, items upserted, health tracked. Validate by seeding a few
`cabal-rss-feed` rows and inspecting `cabal-rss-item` after a tick.

**Work.**

- `lambda/api/rss_schedule/function.py` (EventBridge Scheduler, every
  5 minutes, following `reap_pending_addresses.tf`): Query `by_due`,
  claim each due feed with a conditional `UpdateItem`, enqueue feed
  ids.
- `lambda/api/rss_fetch/function.py` (SQS event source mapping,
  `batch_size = 1`, reserved concurrency 5):
  - Conditional GET with the prior `ETag`/`Last-Modified`. Use the
    stdlib `urllib` with a hard timeout, a response-size cap (5 MB),
    gzip, and a redirect limit — the same shape as `fetch_bimi`'s
    logo fetch — rather than adding `requests` and its four transitive
    packages to the hash-pinned tree. Parse the bytes with
    `feedparser` (hash-pinned with `sgmllib3k`; its built-in HTML
    sanitizer stays on). Verify `feedparser`'s JSON Feed handling for
    the pinned version; if it is absent, JSON Feed is small enough to
    parse with `json` directly.
  - **SSRF guard**: https only (D1), resolve the host and refuse
    loopback, link-local, RFC 1918, and other non-global addresses
    before connecting, re-check on every redirect hop. The fetcher
    sits inside the VPC, so this is not optional.
  - Upsert via `by_guid` + `PutItem`/`UpdateItem` (re-publishes update
    attrs; the SK never changes). Bodies over ~300 KB spill to S3.
  - Update health fields, `observed_items_per_day`, `next_fetch_at`.
  - **Politeness signals beyond conditional GET**: honour
    `Cache-Control: max-age` and `Retry-After` as cadence floors; treat
    RSS `<ttl>` and `<sy:updatePeriod>` the same way; on a permanent
    redirect (301/308) re-normalize the target, and if a shared feed
    row already exists for it, re-point the subscriptions and retire
    the old row; 410 Gone dead-letters immediately; 429 backs off.
- User-Agent set to
  `Cabalmail-Feedbot/1 (+https://www.<control-domain>/feedbot.html)`. The
  front-door site (`front-door/`) serves the page, which explains the
  bot, which addresses it comes from (the NAT EIPs), and how to reach
  the operator.
- Adaptive cadence: EWMA on `observed_items_per_day` with a
  conservative initial cadence (60 minutes), recomputed on every
  fetch. Bounds are SSM parameters
  `/cabal/rss/cadence_min_minutes` (default 15) and
  `/cabal/rss/cadence_max_minutes` (default 1440), SecureString like
  the other `/cabal/` parameters, re-read every five minutes.
  User-invisible per D17. A feed with no history seeds its rate from
  the spread of its items' dates, falling back to a 60-minute cadence.
- Canonical URL normalizer per D1 sub-decision (https only, www-vs-
  apex collapse, trailing-slash rules, alphabetized query params,
  `<guid>` exempt). Lives in `lambda/api/_shared/rss_url.py` with unit
  tests covering every example in the requirements doc (the trailing-slash
  examples are satisfied by lookup-time equivalence, not by rewriting —
  see the phase 3 status note). The www/apex
  rule needs the **Public Suffix List** to tell an apex from a
  subdomain (`example.co.uk` is an apex; `web.example.com` is not);
  bundle `publicsuffix2` or ship a vendored snapshot of the list. The
  **apex form is canonical** in every case (operator decision
  2026-09-09, superseding the requirements doc's `www.example.com`
  example): `https://www.example.com/` normalizes to
  `https://example.com/`. An `http://` input is upgraded to `https://`
  before normalization; plain http is never fetched.
- Per-feed dead-letter after 20 consecutive failures: remove the
  `due_shard` attribute so the row leaves `by_due`. Manual reset
  restores it.

**Rollback.** Disable the Scheduler schedule; data is append-only, no
destructive change.

### Phase 3: Subscription + reader API

**Status:** In review (2026-09-09). Eleven `rss_*` endpoints under
`lambda/api/` with `_shared/rss_api.py` (envelope, keys, computed read
state, serialization) and `_shared/rss_discover.py` (autodiscovery);
reference in `docs/rss.md`. As built, versus the text below: health
rides on each subscription's `feed` summary in `/rss_list_subscriptions`
instead of a separate health endpoint; folders and subscriptions come
back from that one call; item state is set in batches through
`/rss_set_item_state`; the first fetch of a new feed is not done inline
but by handing the feed to the worker queue immediately (one ingest code
path, items within seconds); the day-grouped orderings are applied
client-side; unread counts are not served (clients count from their
cache); and the shared-feed owner sentinel is `~shared`. Stage validation
(2026-09-09) found two defects, both fixed in a follow-up: the RSS
endpoints lacked `dynamodb:BatchWriteItem` (unsubscribe's purge), so they
now carry their own IAM statement instead of riding the mail endpoints'
uniform one; and the normalizer's trailing-slash rule turned a real feed
URL (`/feeds/json`) into a 404 (`/feeds/json/`). The operator then ruled
that `/` is canonical only right after the host, and elsewhere the
server decides (D1, revised): **the normalizer neither adds nor removes
trailing slashes, and the feed lookup matches the canonical URL
exactly.** A publisher that treats `/feed` and `/feed/` as one object
says so with a 301, which the subscribe probe follows and canonicalizes
before looking up, so both forms still land on one shared row without
Cabalmail guessing. The subscribe path itself moved into
`_shared/rss_subscribe_core.py` so phase 4's OPML import shares it, and
unsubscribe now deletes state before the subscription row (a failure
between the two had stranded state that resurfaced on re-subscribe).

**Goal.** Authenticated clients can subscribe to a feed, organize
feeds into folders, list items with filtering, mark items read/
favorite, and pull incremental updates via the `since` cursor that the
native caches rely on. No image proxy yet (image `<img>` tags pass
through verbatim).

**Work.**

- `rss_*` functions under `lambda/api/`, one per endpoint, wired with
  the `call` module like every other API function:
  - `/rss_subscribe` (autodiscovery: if the body URL is a webpage,
    scrape `<link rel="alternate">` tags for the feed URL; same SSRF
    guard as the fetcher; an `http://` URL is tried as `https://` and,
    if the feed is not served over https, the call fails with a
    user-facing message and nothing is stored; returns the subscription
    including its `data_store_uuid`)
  - `/rss_unsubscribe` (deletes the user's state rows for the feed and,
    when `subscriber_count` reaches 0, the feed, its items, and any
    spilled bodies — see "Data model")
  - `/rss_update_subscription` (display preferences, notifications
    toggle, folder move)
  - `/rss_list_subscriptions`
  - `/rss_list_folders`, `/rss_new_folder`, `/rss_update_folder`,
    `/rss_delete_folder`
  - `/rss_list_items` (`subscription_id` or `folder_id`;
    `filter = read|unread|favorite|all`; `since`; `order`; `limit`)
  - `/rss_get_item` (item + per-user state; inlines an S3-spilled body)
  - `/rss_set_item_state` (read/unread/favorite/unfavorite, batched)
  - `/rss_mark_all_read` (per subscription, folder, or all — writes
    watermarks)
  - `/rss_feed_health` (per D10)
- The unread and favorite filters follow the "Data model" notes:
  favorite via the sparse GSI; unread via items-minus-read-rows above
  the watermark.
- The folder list endpoint follows the multi-Query + merge-sort
  pattern described in "Data flow." Pagination cursor is an opaque
  base64 JSON blob carrying per-feed `LastEvaluatedKey` plus a merge
  position; clients treat it as opaque.
- `/rss_subscribe` on a public feed nobody else has creates the
  `cabal-rss-feed` row with `next_fetch_at = now` so the scheduler
  picks it up on its next tick (worst-case 5-minute lag to first
  content). On the first subscribe, do a synchronous fetch inline so
  the user sees items immediately, then let the scheduler own it.
- `set_preferences` / `get_preferences` gain the `rss_*` keys in
  `APP_ALLOWED`.
- **Compatibility.** These endpoints join the stable HTTP API surface
  under `docs/compatibility.md` the moment they ship in a release, so
  request and response shapes should be reviewed for the
  ignore-unknown-fields / additive-only discipline before the first
  client depends on them.

**Rollback.** Remove the API routes. Data rows are inert without the
fetcher (still running) and the routes (removed).

### Phase 4: OPML import/export (API)

**Status:** In review (2026-09-09). `/rss_opml_import` and
`/rss_opml_export` with `_shared/rss_opml.py`. As built: the body carries
the OPML text in JSON (`{"opml": ...}`) rather than a multipart upload,
matching every other endpoint; import creates unknown feeds **without**
the interactive probe (from the OPML's own title) and hands them to the
worker, so a large export fits one request and a dead entry surfaces as
feed health rather than an import error; folders are reused by name under
the same parent and an optional `folder_id` roots the import; the
fixtures are Feedly-, NetNewsWire-, and Reeder-shaped documents (with
lower-case attribute variants) in the unit tests rather than real
exports, which would carry the operator's feed list.

**Goal.** A user can upload an OPML file and have its feeds and
folders imported; a user can download an OPML file of their current
state. This phase ships the API; the native UIs land with their
client phases. It comes before any client phase so the operator's own
feed list can be loaded on stage and dogfooded through the API before
a UI exists.

**Work.**

- `/rss_opml_import` (body carries the OPML text; Lambda parses with
  `defusedxml`, additive merge per D5 sub-decision, subscribes each
  feed through the same path as `/rss_subscribe`, returns a summary of
  created/skipped/failed items).
- `/rss_opml_export` (Lambda emits OPML 2.0 with the folder hierarchy
  as nested outlines).
- Test: round-trip a Feedly export, a NetNewsWire export, and a
  Reeder export, checked into the Lambda's tests as fixtures (with any
  personal feed lists replaced by public ones).

**Rollback.** Remove the routes. Existing imported data stays.

### Phase 5: Apple clients (with offline + FTS)

**Status:** 5a (Kit) in review (2026-09-10): `RssClient` + the
`URLSessionApiClient` conformance, wire models, `SQLiteDatabase` (the
thin `sqlite3` actor's backing type), `RssStore` with FTS5,
`RssSyncEngine`, the `rssMarkAsRead` preference (gated like
`flag_palette`), `CabalmailClient` wiring, 25 Kit tests, the
`APP_ALLOWED` key server-side, and the Linux drift test's exemption. Two
as-built notes: the FTS index uses the plain `unicode61` tokenizer, not
porter, because stemming stored tokens breaks the typed-prefix matching a
search field needs; and sign-out's `clearLocalData()` now clears the RSS
store too. **5b (read path) in review (2026-09-10):** `FeedSidebarViewModel`
/ `FeedItemListViewModel` / `FeedItemDetailViewModel`, the Feeds section
in the mail sidebar (macOS, iPad-regular) driving the split view's content
and detail columns, a Feeds tab with its own collapsing split on iPhone
and visionOS, `FeedItemListView` (filters, orderings, swipes, per-feed
FTS search, load older), `FeedItemDetailView` on the existing
`HTMLBodyView`, and `ArticleWebView` on the subscription's
`WKWebsiteDataStore(forIdentifier:)` with the vendored Readability.js
reader toggle (`@mozilla/readability` pinned in `react/admin/package.json`,
materialized by `sync-vendored.sh` into `RSS/ReaderAssets`, credited in
Acknowledgements). Session start and foreground trigger `syncAll`. Not in
5b: subscribe / folder / settings UI, OPML, the Settings category, macOS
menu commands (5c), and the list virtualization and offline indicators
(5d). Rows in multi-feed lists show the item URL's host as the feed label
until 5d resolves titles.

**Goal.** The iOS, iPadOS, visionOS, and macOS clients have a reader
UI with per-feed `WKWebsiteDataStore` isolation, offline reading, and
per-feed FTS. This is the first user-facing surface.

**Work.**

- `CabalmailKit` gains:
  - `RssClient` protocol and `ApiBackedRssClient` wrapping the `rss_*`
    endpoints. The pattern mirrors `ApiBackedImapClient` from #371.
  - `ItemCache` actor backed by SQLite (FTS5). Schema, sync logic,
    mutation queue per "Apple-side item cache". Library decision
    (GRDB vs. thin `sqlite3` wrapper) made and recorded here.
  - `RssSync` actor coordinating the three sync paths.
  - The App Group handoff directory the NSE will write into (phase 8
    fills it).
- Reader views on each platform: folder tree, item list (read from
  ItemCache, not the API), item detail through the existing body
  renderer with its reader-mode toggle. Design tokens come from the
  shared colour-token catalog.
- `WKWebView` for articles uses `WKWebsiteDataStore(forIdentifier:
  subscription.data_store_uuid)`.
- Reader-vs-native styling for the publisher's page: Safari's Reader
  is not exposed to `WKWebView`, so the reader path injects a
  Readability-style extractor (Mozilla's Readability.js) into the
  loaded page and renders the extracted content with the client's own
  styling. Vendor it the way marked/turndown are vendored: pinned in
  `react/admin/package.json` (still the pin source of truth even
  though the React app itself is frozen), materialized by
  `sync-vendored.sh`, credited in `Acknowledgements.swift`. Native
  styling = the publisher's page rendered as-is.
- Per-feed search UI: a search field in the feed view, results from
  `ItemCache.search(query:, feedId:)`. "Search older items" affordance
  pulls more from the server and re-indexes.
- Offline indicators: small badge on the article-view button when the
  network is unavailable; "queued" indicator on items with pending
  mutations.
- Mark-as-read follows `rss_mark_as_read`: manual, or immediately on
  opening an item — the same two modes as the mail client, no delayed
  variant.
- OPML import via the document picker / share sheet; export via the
  share sheet.
- Background refresh registered with `BGTaskScheduler` (iOS) or a
  scheduled timer (macOS).
- Remote-content policy: in-feed images honour the existing
  `load_remote_content` preference (`off | ask | always`) until phase
  7's proxy exists, after which "load via Cabalmail" becomes the
  privacy-preserving middle setting.
- Spotlight indexing of items is a possible follow-on (the Kit already
  indexes messages); not in this phase.
- Changelog fragment carries the `Apple:` prefix.

**Rollback.** Hide the RSS tab behind a build flag. ItemCache schema
migrations are forward-only; downgrade strategy is "delete and re-
populate from server."

### Phase 6: Android client (with offline + FTS)

**Status:** Not started.

**Goal.** The Android client reaches parity with phase 5: reader UI,
offline reading, per-feed FTS, per-feed WebView profile scoping.

**Work.**

- `kit` gains the `RssClient` interface and API-backed implementation
  (mirroring `ApiClient`'s existing shape), the Room RSS cache with
  `@Fts4` search, sync, and the offline mutation queue, per
  "Android-side item cache".
- Compose reader screens: folder tree, item list from the cache, item
  detail through the existing `MessageDetailScreen` body renderer and
  its reader-mode behaviour.
- Article `WebView` uses the `androidx.webkit` multi-profile API keyed
  on `data_store_uuid`, with the runtime feature check and fallback
  notice described under "Per-feed cookie scoping". Readability.js
  injection for reader styling, vendored from the same pin.
- OPML import via the system file picker; export via the share sheet.
- `WorkManager` periodic refresh for notification-off feeds.
- Changelog fragment carries the `Android:` prefix with a ~40-character
  headline, per the Play release-notes budget.

**Rollback.** Feature flag hides the RSS destination.

### Phase 7: Image proxy + cache

**Status:** Not started.

**Goal.** All `<img>` references in served item content are rewritten
to the image-proxy URL, which fetches the publisher's image on first
request and caches in S3 for 7 days.

**Work.**

- `lambda/api/rss_image/function.py`: given a signed image reference,
  looks up the S3 object by hash (SHA-256 of source URL); if absent,
  fetches from the publisher (same SSRF guard, https only,
  `Content-Type` must be `image/*`, size cap) and stores it. Returns a
  **presigned S3 URL** (the pattern `helper.py` already uses for
  attachments) rather than streaming bytes. This avoids enabling
  binary media types on the REST API, which is a gateway-wide setting
  that changes how existing JSON endpoints negotiate payloads, and it
  keeps large responses off the Lambda-through-API-Gateway path.
- Image-URL rewriting in `/rss_get_item` and `/rss_list_items`: parse
  `summary_html` and `content_html`, replace `src` and `srcset`, hand
  back the rewritten body. `lxml` is a large binary wheel; the stdlib
  `html.parser` is enough for attribute rewriting and keeps the
  hash-pinned tree small.
- Image-cache TTL is the S3 bucket lifecycle rule (7 days, operator
  override in SSM).
- Authentication: the rewritten reference carries a short-lived
  signature derived from the user's request, so cached images are not
  a world-readable surface.

**Rollback.** Stop rewriting `<img>` tags in the read endpoints;
pass-through resumes. The bucket can stay or be destroyed
independently.

### Phase 8: Push notification integration

**Status:** Not started.

**Goal.** New items in subscribed feeds with notifications enabled
produce APNs and FCM notifications via the existing 0.11.x push path.

**Work.**

- `lambda/api/rss_notify/function.py`: DynamoDB Stream trigger on
  `cabal-rss-item`, `INSERT` events only. For each new item: Query
  `subscription.by_feed_notify`, enqueue one wake signal per (user,
  item) onto `cabal-push-queue`:
  `{"kind": "rss", "user": ..., "feed_id": ..., "item_id": ...}`.
- Extend `push_dispatch` to branch on `kind`:
  - **Opt-in filter.** The mail path filters token rows by per-folder
    opt-in (`_wants_folder`). RSS opt-in is per subscription and lives
    on the subscription row, so `rss_notify` has already applied it;
    `push_dispatch` must not run the folder filter on RSS signals.
    Whether a token row needs a separate "RSS notifications on this
    device" switch is a UI question for phase 5/6; the plan assumes
    subscription-level opt-in is enough for v1.
  - **APNs payload.** Content-free like mail (`"New item"`,
    `mutable-content`, a distinct `category` such as `RSS_ITEM`, and
    an `itemRef` with `feed_id`/`item_id`); collapse id derived from
    `item_id`. The macOS bundle ids keep receiving **silent**
    background pushes, so, exactly as for mail, a quit Mac app gets no
    RSS notification — documented, not fixed.
  - **FCM data map.** String-valued `kind`, `feed_id`, `item_id`.
- Apple NSE gets an `RSS_ITEM` branch that calls `/rss_get_item`,
  rewrites the alert with feed name + item title, and drops the item
  JSON into the App Group handoff directory for the app to ingest.
- Android `FirebaseMessagingService` gets a `kind == "rss"` branch that
  enriches via `/rss_get_item`, posts the local notification, and
  writes the cache directly.
- Notification tap-throughs open the item in the reader UI.
- v1 is per-subscription notifications-on, default false (per D12).
  Folder-level toggle (D12 option B) is wired up but the UI exposes
  per-feed only; folder default lands in a later minor release.

**Rollback.** Disable the stream event source mapping; the stream
retains 24 hours of records, so re-enabling within a day replays
missed notifications (or trims them, if that is preferable after an
outage).

### Phase 9: Credentialed feeds

**Status:** Not started.

**Goal.** Users can subscribe to private feeds using HTTP Basic,
URL-key, or cookie auth. Credentials stored per-user, per-feed.

**Work.**

- `/rss_subscribe` accepts a `credentials` block:
  - `{"scheme": "basic", "username": "...", "password": "..."}`
  - `{"scheme": "url_key", "url": "...?key=..."}` — no separate
    credential storage; the URL is the secret and lives in the
    per-user `cabal-rss-feed.canonical_url`.
  - `{"scheme": "cookie", "cookie_header": "..."}` (the client copies
    the cookie out of its per-feed web-view store after user login)
- Secrets write to SSM SecureString at
  `/cabal/rss/credentials/<user>/<feed_id>`; the subscription row holds
  only `credentials_scheme`. Consistent with the project's standing
  rule that runtime secrets live in SSM and never in Terraform state.
- The fetcher's per-user track activates: subscriptions with a
  scheme get their own `cabal-rss-feed` row (`is_shared = false`,
  `owner_user = subscriber`).
- Native client UI for "feed requires login": opens the article web
  view with the subscription's data store / profile to the feed's site
  URL; after the user authenticates, the client extracts cookies from
  the store and posts them to the API. Both platforms expose the
  cookie store for their scoped web views (`WKHTTPCookieStore` and
  `CookieManager` per profile).
- A feed that 401s while shared surfaces as a credential prompt (D1
  sub-decision) rather than being quarantined.

**Rollback.** Drop the credential endpoints; existing credentialed
subscriptions sit dormant (fetcher returns 401, marks feed
unhealthy).

### Phase 10: Adaptive cadence + health surface polish

**Status:** Not started.

**Goal.** Tune the adaptive cadence formula based on observed
production behavior, and surface feed health visibly enough that
operator and users can spot problems.

**Work.**

- `/rss_feed_health` returns the last N fetches' history (kept as a
  bounded list attribute on the feed row).
- Native UI surfaces a small health badge on feeds with 3+ consecutive
  failures (yellow) or 20+ consecutive / 410 Gone (red).
- Adaptive-cadence formula gets a feedback loop: if
  `observed_items_per_day` is high but the polling tier keeps
  returning 304s, slow down. Lives in `lambda/api/_shared/rss_cadence.py`
  with unit tests on simulated feeds.
- Operator visibility uses CloudWatch, not the (disabled) monitoring
  stack: `rss_fetch` emits metrics the way `push_dispatch` does
  (fetches, 304s, failures, dead-letters), and the fetch DLQ depth
  gets an alarm alongside the push DLQ's.
- Runbook in `docs/operations/runbooks/` for "RSS feed is stuck":
  health endpoint, cadence reset, dead-letter revival, DLQ redrive.

**Rollback.** Revert the formula change; the health UI can stay or
go independently.

## Operational concerns

### Cost shape

The new infrastructure budget per environment at hobby scale (one
operator + a handful of beta users, ~100 feeds total, ~5000 items/
month):

| Item                              | Cost (USD/month)              |
| --------------------------------- | ----------------------------- |
| DynamoDB on-demand (5 tables)     | ~$0.50 (read+write+storage)   |
| GSI storage (sparse, small)       | negligible                    |
| DynamoDB Stream → Lambda          | free (trigger reads)          |
| Image cache + spill S3 (7d TTL)   | <$2                           |
| Scheduler + fetch invocations     | <$1 (288 ticks + fetches/day) |
| API Lambda invocations            | scales with reader use, <$1   |
| SQS (fetch queue; push reused)    | negligible                    |
| NAT egress for feed traffic       | $0 (instances) / <$0.50 (GW)  |
| **Total per environment**         | **~$4/month**                 |

Dev is quiesced by default per the project's standing practice and
incurs negligible cost when off. Stage + prod together: **under
$10/month**, down from ~$90/month under the original Aurora plan.

DynamoDB scales smoothly upward: at substantially higher use the
per-million-request fees start to add up, but the data layer would
still be in the low tens of dollars per month at, say, 100 users with
typical reader activity.

### Quiesce

`docs/quiesce.md` covers ECS + NAT + ASG. The RSS additions to the
quiesce path:

- Disable the `rss_schedule` Scheduler schedule (mandatory: with the
  NAT route gone, a running schedule only fills the fetch DLQ).
- Leave the stream trigger alone; with no fetches there are no
  inserts.
- DynamoDB tables on-demand have no cost while idle and need no
  scale-down step.

### Backup

DynamoDB PITR (35-day retention by default; we use 14 days non-prod,
35 prod) covers all RSS tables, and the tables are in the AWS Backup
selection where backups are enabled. The `rss-cache` bucket is not in
AWS Backup: `img/` is regenerable on demand, and the `items/` spill
prefix, while authoritative for oversized bodies, is small and
write-once; bucket versioning with a 7-day noncurrent retention is its
recovery story for now. (AWS Backup for S3 needs its own service-role
policy and continuous-backup configuration; revisit if the spill prefix
grows.) SSM credential parameters are KMS-encrypted.

The device-side caches (Apple `ItemCache`, Android Room) are not
backed up by Cabalmail — they are derived caches, rebuilt from the
server on demand.

### Multi-environment story

Branches/environments per the project's existing model: development /
stage / main. Nothing RSS-specific routes around the existing
per-environment AWS account boundary. New infrastructure variables, if
any, go in both the plan and apply tfvars steps of `infra.yml`.

### Rollback per phase

Every phase has its own rollback note above. The dependency chain is
1 -> 2 -> 3 -> {4, 5, 6, 7, 8} -> 9 -> 10. Phase 8's notification
flow depends on phase 5/6 only for the on-device enrichment branches;
the server side ships independently.

## Requirements challenges (raised and decided 2026-09-09)

These are places where the requirements doc, read against what had
shipped since May, contradicted itself, rested on an assumption that no
longer held, or needed a decision the operator had not been asked for.
The operator ruled on them on 2026-09-09; each ruling is recorded as a
**Revised decision (2026-09-09)** annotation in `rss-requirements.md`
and applied above; two follow-up rulings closed the remaining items.

1. **D1 normalizer: which host form is canonical.** The examples
   disagreed (`www.example.com` canonical in one, `example.co.uk` apex
   canonical in another). **Decided: the apex form is canonical.** The
   rule needs the Public Suffix List to identify the apex.
2. **D1 "http is not supported."** **Decided:** an `http://` input is
   silently upgraded to `https://`; if the feed is not available over
   https, the user is told and nothing is fetched or stored.
3. **D3's parenthetical about exposing IMAP externally** is history:
   public IMAP and submission closed in 0.11.x. The decision (own API
   only) stands. No plan change.
4. **D6 "the embedded engine's reader mode."** Neither `WKWebView` nor
   Android `WebView` exposes the browser's reader mode to apps.
   **Confirmed:** a Readability.js-based reader view satisfies the
   requirement; the operator reserves the right to request tweaks
   after it ships.
5. **D15 reading-time estimate "from extracted text."** Under D6 = C
   there is no extracted text; for summary-only feeds an estimate would
   be wildly wrong. **Decided: dropped from v1, kept as future work**
   (client-side from cached `content_html`, hidden for summary-only
   items, if it returns).
6. **D15 auto-mark-read.** **Decided:** the mail clients no longer
   offer a time-delayed mark-as-read, only manual or
   immediate-on-open, and feeds offer the same two options under a
   separate `rss_mark_as_read` preference rather than the mail
   `mark_as_read` key.
7. **D9 egress stability vs. Q3 "scheduled Lambda."** Resolved in the
   plan by running the fetcher in the VPC behind the NAT EIPs; noted
   so the choice is explicit. No requirement change.
8. **D10 health visibility with monitoring off.** The plan uses
   CloudWatch metrics and a DLQ alarm because `TF_VAR_MONITORING` is
   false everywhere. No requirement change.
9. **D4 "forever" and feeds nobody subscribes to.** **Decided:** when
   the last user unsubscribes from a feed, its content is deleted; a
   cold-storage option may be considered in a future release.
10. **Version label vs. semver.** **Decided:** RSS is additive and ships
    as 1.x minor releases under `docs/compatibility.md`; the RSS docs
    moved from `docs/2.x/` to `docs/1.x/`; the roadmap wiki row was
    updated to match.
11. **Client cut (Q6).** The original "phased rollout is fine" answer
    predates Android shipping. **Decided: Apple first, Android second;
    Linux waits until its mail client has caught up.**

## Open questions and risks

Open implementation-time items, scoped per phase:

1. **Pagination cursor format for folder-spanning Queries.** An opaque
   base64 JSON blob carrying per-feed `LastEvaluatedKey` plus a merge
   position is workable. Design it deliberately in phase 3 so it is a
   stable contract clients can rely on under `docs/compatibility.md`.
2. **GSI hot-partition risk on `by_due`.** The fixed `PK = "active"`
   sends all due-feed reads to a single partition. At hobby scale
   this is fine (a few hundred items in the index, queried twelve
   times an hour). If the feed count grows materially, shard by
   `hash(feed_id) % N` and Query in parallel across N constant PK
   values — which is why the attribute is named `due_shard` from the
   start.
3. **Unread computation cost.** Items-minus-read-rows above a
   watermark is cheap per feed and fine for folder views at hobby
   scale, but "global unread count" touches every subscription. Cache
   it client-side and refresh on sync rather than asking the server on
   every badge redraw; if it ever matters server-side, a per-
   subscription counter maintained by `rss_notify`'s stream handler is
   the upgrade path.
4. **Sync strategy tuning on the native clients.** The
   lazy/eager/push-assisted mix is a hypothesis; real-world battery
   and bandwidth behavior determines whether to bias more toward eager
   prefetch or lean harder on background-refresh. Tune in phases 5–6.
5. **Cache retention defaults.** 365 days + favorites-exempt is a
   guess. Watch device storage usage in the phase 5/6 beta and adjust
   the default before GA.
6. **HTML stripping for FTS on Apple.** `NSAttributedString`'s HTML
   parser is adequate for plaintext extraction but slow on large
   bodies (it spins up a full WebKit parser internally). If indexing
   throughput becomes an issue, swap to a lightweight tokenizer.
7. **Adaptive cadence pathologies.** A feed that posts in bursts
   (weekday-only, say) will look slow on weekends and cadence will
   widen, then Monday's burst is delayed by up to max_cadence. Time-
   of-day-aware cadence is out of scope for v1; phase 10 monitors
   whether it matters.
8. **OPML import edge cases.** Real-world OPML files from Feedly,
   NetNewsWire, and Reeder encode folder hierarchy slightly
   differently. Phase 4's fixtures pin down all three explicitly.
9. **Pending-mutation conflict resolution.** Last-write-wins is the
   v1 strategy but breaks down if the user marks an item favorite on
   iPhone offline, then unfavorites on Mac online, then the iPhone
   reconnects. Acceptable in v1 (the iPhone wins because its mutation
   timestamp is later); revisit if it bites.
10. **Android multi-profile WebView availability.** The
    `androidx.webkit` multi-profile feature depends on the installed
    system WebView, not the OS version. Measure how often the fallback
    path is taken on the tester devices before deciding whether the
    fallback notice is enough.
11. **Feed-content trust.** `feedparser` sanitizes item HTML, and both
    clients render bodies through the same sandboxed renderer they use
    for mail, so a hostile feed has the same (small) surface as a
    hostile email. Confirm in phase 5/6 that the RSS body view does not
    grant anything the mail body view withholds (scripts, remote
    content policy, link handling).
12. **Agent access.** The tentative
    [`agent-mail-access-plan.md`](../tentative/agent-mail-access-plan.md)
    proposes scoped, token-based MCP access to a user's mailbox. Feeds
    are an obvious second scope for the same grant model ("read my
    feeds, never mark them read"). Nothing in this plan should make
    that harder: keep read endpoints free of side effects and keep the
    per-user state writes in explicitly named endpoints.

## Documentation

When the RSS feature ships, operator-facing documentation lives at
`docs/rss.md` (top-level, per the docs convention) covering:

- What RSS in Cabalmail does (link to user-facing UI tour in
  `docs/user_manual.md`).
- The fetcher's politeness policy (User-Agent, egress addresses,
  conditional GET, cadence bounds, rate limits) — what publishers
  should expect — and the `/feedbot` page that points at it.
- The image-proxy's behavior — privacy implications, cache TTL.
- The credential storage model — what's in SSM, what's in DynamoDB,
  how rotation works.
- The native clients' offline-reading semantics and FTS scope, and
  the per-feed session-scoping behaviour (including the Android
  fallback).
- Operator runbook for stuck feeds, DLQ redrive, OPML imports, cache
  rebuilds.

The `docs/1.x/` directory keeps this plan and the requirements doc
as the historical planning record.

## Next steps

1. Operator review of this revised plan — particularly the
   "Requirements challenges" section, the reduced data model, the
   in-VPC fetcher, and the Apple/Android phase ordering.
2. If approved, phase 1 is the first PR: Terraform-only — tables,
   stream, fetch queue, bucket, IAM, and the quiesce hook. CI deploys
   it to stage.
3. Each subsequent phase is a worktree branch merged to `stage` by PR
   and promoted to `main` with `make promote`, with a changelog
   fragment per change (`Apple:` / `Android:` prefixed where the
   client sources change) and this document's Progress table updated
   in the same PR.
