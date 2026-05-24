# RSS Reader — Implementation Plan

## Context

This plan implements the RSS reader for Cabalmail 2.0 based on the
decisions recorded in [`rss-requirements.md`](./rss-requirements.md).
It is the companion build plan to that requirements pass; whenever this
document says "per Dx," it refers to a decision in that file. The
reader is the only substantive feature in 2.0; the version cut is
`2.0.x` with each phase below shipping under a separate patch tag.

Three decisions shape the architecture more than the rest:

- **D6 = C: no server-side article extraction.** The server fetches
  feed XML/JSON, parses it, stores items as the feed delivered them,
  and serves them. When the user opens "the article," the client loads
  the publisher's page in an embedded `WKWebView` (Apple) or sandboxed
  iframe (React) and relies on the embedded engine's reader mode for
  styling. The server is never in the article-rendering business. This
  removes a whole subsystem and a whole class of operational risk
  (publisher anti-bot defenses, MIME oddities), at the cost of pushing
  some complexity into the Apple clients (cookie scoping for paywalled
  content; see below).
- **D11: per-feed scoping of cookies and web-view local storage.**
  Each subscription gets its own credential and storage partition; a
  user with three Substack feeds authenticates each separately and
  keeps three Substack sessions side by side. On Apple this lands on
  `WKWebsiteDataStore(forIdentifier:)` (iOS 17+/macOS 14+; we target
  iOS 18/macOS 15, so it's available unconditionally). In a browser
  the equivalent doesn't exist cleanly and the React client gets a
  documented limitation.
- **Revised D14 / Q2: DynamoDB primary store; per-feed FTS and offline
  reading on Apple clients via SQLite/FTS5.** The data layer is
  DynamoDB end-to-end — no relational store, no joins, no `tsvector`.
  The per-feed view that JOINs would have produced is materialized at
  write time in the `user-item-state` table with sparse GSIs (the
  "personal inbox" pattern). Full-text search is per-feed only, lives
  client-side on Apple via a local item cache backed by SQLite FTS5,
  and is absent from the React client. The same local cache supports
  offline reading on Apple (**Decision 18**), which is a first-class
  requirement.

Per open Q3 the **fetcher is a scheduled Lambda**, not an ECS service.
Per open Q5, user-level customization (display preferences, ordering)
is **stored** server-side and **applied** client-side, so the shared
canonical-feed records hold no per-user data and the multi-tenancy
boundary is enforced by storage layout, not by access logic.

The plan is structured as ten independently-shippable phases. Each
phase ends in a state that can be deployed to prod without the next
phase being present.

## Goals

- A Cabalmail user can subscribe to RSS, Atom, and JSON feeds from any
  Cabalmail client; read state and per-feed display preferences sync
  across devices.
- Public feeds are fetched once per cadence regardless of how many
  users subscribe; credentialed feeds are fetched per-user.
- The fetcher adapts its cadence per feed within operator-set bounds,
  with no user-exposed cadence control.
- Items are kept indefinitely server-side; image references in item
  bodies are proxied and cached for an operator-tunable TTL (default
  7 days, per D13).
- New items in subscribed feeds with notifications enabled produce
  APNs push (and eventually FCM, when Android lands) within ~6 minutes
  of publication, reusing the 1.0.x push path.
- A user can import an OPML file at signup and export one at any time.
- Paywalled feeds with per-feed cookie scoping work on Apple clients;
  the React client renders public feeds and reports the limitation for
  credentialed ones.
- **Apple clients support offline reading** of cached items (D18) —
  in-feed content (summary + any `content_html`) is fully available
  without network. Mark-read and favorite mutations performed offline
  queue locally and dispatch on reconnect.
- **Apple clients support per-feed full-text search** over the local
  cache using SQLite FTS5.

## Non-goals (v1, all per the requirements doc)

- Server-side full-text article extraction (D6).
- **Server-side full-text search of any kind** (revised D14). No
  Postgres `tsvector`, no OpenSearch, no Lambda-scanning of items.
- **Cross-feed search**, on Apple or anywhere (revised D14; operator
  confirmed no real-world use case).
- **FTS, offline reading, or per-feed cookie/storage partitioning in
  the React client.** React renders the current network state with
  the browser's default cookie behavior; full-feature offline,
  search, and per-feed credential scoping live on Apple. Mitigations
  for the cookie-partitioning gap were considered and deferred past
  v1; see "Per-feed cookie scoping > Mitigations considered".
- Third-party API compatibility — no Fever, no Google Reader (D3).
- Email-to-feed (D7, deferred).
- Feed-to-email digests (D8, declined).
- Tagging, save-for-later, snooze, keep-unread pin, auto-mark-read on
  scroll, cross-feed dedup (D14, D15 — declined or deferred).
- OAuth-flow credentialed feeds (D11, deferred).
- Reader UI in the Android client (Android is on the 1.1.x roadmap;
  the RSS API will be Android-ready but no Android UI ships in 2.0).
- Proactive notification of feed-health problems (D10 — visibility
  only in v1).
- A user-exposed fetch-cadence control (D17).
- Per-feed keyword muting (D14, declined).
- Aggressive pre-caching of image bytes onto Apple devices for
  offline image rendering. The embedded `URLCache` captures what it
  captures from prior online viewing; explicit image pre-fetch is a
  v1.x candidate.

## Architecture overview

### Component diagram

```
                          +----------------------------+
                          |  DynamoDB tables           |
                          |    cabal-rss-feed          |
                          |    cabal-rss-item          |
                          |    cabal-rss-subscription  |
                          |    cabal-rss-folder        |
                          |    cabal-rss-user-item-    |
                          |      state                 |
                          |    cabal-rss-credentials   |
                          |    cabal-rss-user-settings |
                          |    cabal-rss-pending-      |
                          |      notification          |
                          +-------------+--------------+
                                        ^
                                        |
   +-----------+    EventBridge    +----+-----+    HTTPS+CGET     +--------+
   |   cron    |  every 5 minutes  | fetcher  | ----------------> | feeds  |
   +-----------+ ----------------> | Lambda   | <---------------- |  (any) |
                                   +----+-----+                   +--------+
                                        |
                                        | (writes pending_notification
                                        |  rows in TransactWriteItems
                                        |  alongside item upsert)
                                        v
                                   +----+-----+    SNS / SQS    +-----------+
                                   |  rss-    | --------------> |  push-    |
                                   |  notify  |                 |  sender   |
                                   |  Lambda  |                 |  Lambda   |
                                   +----------+                 |  (1.0.x)  |
                                                                +-----+-----+
                                                                      |
                                                                  APNs / FCM
                                                                      v
   +----------------+         +-----------------+         +-----------+
   |  React client  |         |  iOS / macOS    |         |  Android  |
   |                |         |  (CabalmailKit) |         |  (later)  |
   |  reader UI     |         |  reader UI      |         |           |
   |  iframe for    |         |  WKWebView per  |         |           |
   |  articles      |         |  feed (WKWDS    |         |           |
   |                |         |  per identifier)|         |           |
   |  online-only   |         |                 |         |           |
   |  no search     |         |  +-----------+  |         |           |
   |                |         |  | ItemCache |  |         |           |
   |                |         |  | + FTS5    |  |         |           |
   |                |         |  | (SQLite,  |  |         |           |
   |                |         |  |  GRDB)    |  |         |           |
   |                |         |  | offline + |  |         |           |
   |                |         |  | per-feed  |  |         |           |
   |                |         |  | search    |  |         |           |
   |                |         |  +-----------+  |         |           |
   +--------+-------+         +--------+--------+         +-----+-----+
            |                          |                        |
            +--------+-----------------+------------------------+
                     |
                     v
            +--------+--------+        +-----------------+
            |  API Gateway    | -----> |  rss-api        |
            |  (Cognito auth) |        |  Lambdas        |
            +-----------------+        | (read/write,    |
                                       |  since-cursor   |
                                       |  sync endpoint) |
                                       +--------+--------+
                                                |
                                                v
                                       +--------+--------+
                                       |  image-proxy    |
                                       |  Lambda + S3    |
                                       |  cache (7d TTL) |
                                       +-----------------+
```

### Data flow

**Fetch path.** EventBridge fires the fetcher every 5 minutes. The
fetcher queries `cabal-rss-feed`'s `by_due` GSI (`PK = "active"`,
`SK <= now`) for due feeds, processes each (with a conditional update
to claim it for this run), issues a conditional GET against the
publisher with the prior `ETag`/`Last-Modified`, parses the response,
upserts items via `cabal-rss-item` `by_guid` GSI lookup + `PutItem`,
updates the feed's health fields and `observed_items_per_day`, and
sets a new `next_fetch_at` from the adaptive-cadence formula. New
items (i.e. items whose GUID wasn't previously seen in that feed) are
written together with a `pending_notification` row in a single
`TransactWriteItems` call so notification work is not lost if the
Lambda dies mid-feed.

Credentialed feeds run on the same Lambda but in a per-user track:
the `cabal-rss-feed` row has `is_shared = false` and `owner_user`
set to the subscriber. The fetcher pulls credentials from SSM via
the `credentials` table reference.

**Read path.** Clients call API Gateway endpoints (`/rss/folders`,
`/rss/subscriptions`, `/rss/items`, `/rss/item/{id}`, `/rss/feed/{id}/
health`). Lambdas execute DynamoDB Query/BatchGet calls directly
(no Data API, no RDS, no VPC attachment — the API Lambdas remain
non-VPC like the existing `lambda/api/` functions). The endpoint
that returns an item body rewrites `<img src="...">` to the image-
proxy URL with a Cognito-derived signed token.

For folder-spanning item lists, the API runs N parallel Queries
against `user-item-state`'s sparse GSIs (one per feed in the folder),
merge-sorts the streams by `published_at` in the Lambda, and
`BatchGet`s the actual item bodies for the page. See "Data model"
below for the sparse-GSI design that makes filtered queries cheap.

**Notification path.** A scheduled Lambda (`rss-notify`) fires every
60 seconds, scans `pending_notification` (small table, drains quickly),
queries the sparse GSI `subscription.by_feed_notify` for each
pending item to find subscribers with notifications-on, and enqueues
one SNS message per (user, item) onto the existing push topic with a
`type=rss` attribute. The push-sender Lambda from 1.0.x handles
APNs/FCM delivery; on-device NSE enriches the notification by calling
`/rss/items/{id}`.

**Apple sync path.** When online, the Apple client polls
`GET /rss/items?subscription_id=X&since=<cursor>` (or one call per
folder member) to pull new items into its local `ItemCache`. The
APNs NSE extension also writes incoming items into the cache as it
enriches notifications, so notification-on feeds stay current
without explicit sync. Background refresh (iOS `BGTaskScheduler`)
handles the rest. See "Apple-side item cache, FTS, and offline
reading" below for the full design.

### Shared vs. per-user data

| Concept              | Shared / per-user                                |
| -------------------- | ------------------------------------------------ |
| `cabal-rss-feed`     | Shared (public feeds) **or** per-user            |
|                      | (credentialed feeds, `is_shared = false`)        |
| `cabal-rss-item`     | Shared with the feed it belongs to               |
| `subscription`       | Per-user (links user to feed_id)                 |
| `folder`             | Per-user                                         |
| `user-item-state`    | Per-user (read, favorite, read_at)               |
| `credentials`        | Per-user; credentialed feeds bypass sharing      |
| `user-settings`      | Per-user (auto_mark_read, reading_time_visible)  |
| Display preferences  | Per-user attrs on `subscription`, applied        |
|                      | client-side (per open Q5)                        |

Credentialed feeds get a *per-user* `cabal-rss-feed` row (same
canonical URL, different `owner_user`). This trades schema purity for
explicit isolation — there is no code path where a credentialed fetch
lands content into a row that another user can read.

## Data model (DynamoDB)

All tables use **on-demand** capacity (no provisioned read/write
units), **KMS encryption at rest** with the project-standard key,
and **point-in-time recovery** enabled. The schema:

```
cabal-rss-feed
  PK: feed_id (UUID v4 string)
  attrs: canonical_url, is_shared (bool), owner_user (null when shared),
         feed_type ('rss'|'atom'|'json'), display_name, description,
         site_url, next_fetch_at_iso, last_fetched_at_iso,
         last_etag, last_modified, last_status_code, last_error,
         consecutive_failure_count, cadence_minutes,
         observed_items_per_day, created_at
  GSI by_canonical:  PK = canonical_url
                     SK = owner_user_or_NULL_SENTINEL
                     (dedup on subscribe; sentinel string for nulls
                      since DynamoDB GSIs reject null SK)
  GSI by_due (sparse): PK = "active" (constant)
                       SK = next_fetch_at_iso
                       (row removed from index when
                        consecutive_failure_count >= 20)

cabal-rss-item
  PK: feed_id
  SK: published_at_iso#item_id  (sortable + unique)
  attrs: item_id (UUID), guid, title, author, url,
         summary_html, content_html, published_at, updated_at,
         fetched_at
  GSI by_guid: PK = feed_id, SK = guid
               (upsert dedup lookup on fetch)

cabal-rss-subscription
  PK: user_sub
  SK: subscription_id (UUID)
  attrs: feed_id, folder_id, custom_title, ordering_mode,
         default_open_mode, default_styling,
         notifications_enabled, credentials_ref,
         per_user_last_etag, per_user_last_modified,
         per_user_next_fetch_at_iso, created_at
  GSI by_user_folder: PK = user_sub
                      SK = folder_id#subscription_id
                      (list subscriptions in folder)
  GSI by_feed_notify (sparse): PK = feed_id
                               SK = user_sub
                               (present only when
                                notifications_enabled = true)

cabal-rss-folder
  PK: user_sub
  SK: folder_id (UUID)
  attrs: parent_folder_id (null = root), name, display_order

cabal-rss-user-item-state
  PK: user_sub#feed_id
  SK: published_at_iso#item_id    (matches item SK shape)
  attrs: item_id, is_read, is_favorite, read_at
  GSI unread_by_feed (sparse):  PK = user_sub#feed_id
                                SK = published_at_iso#item_id
                                (present when is_read = false)
  GSI favorite_by_feed (sparse): PK = user_sub#feed_id
                                 SK = published_at_iso#item_id
                                 (present when is_favorite = true)

cabal-rss-credentials
  PK: user_sub
  SK: feed_id
  attrs: scheme ('basic'|'url_key'|'cookie'),
         ssm_parameter_path, created_at

cabal-rss-user-settings
  PK: user_sub
  attrs: auto_mark_read, reading_time_visible,
         last_ordering_mode, updated_at

cabal-rss-pending-notification
  PK: item_id
  attrs: feed_id, created_at, ttl
```

A few notes on the model:

- **No tombstones.** Per D4, items live forever; tombstones were only
  needed if items could be dropped. Image-cache rows can age out (D4
  "linked content"); item rows cannot.
- **`is_shared` + `owner_user`** disambiguates shared from per-user
  canonical-feed records. The `by_canonical` GSI uses an owner sentinel
  for shared rows so the (canonical_url, owner_user) lookup works
  uniformly.
- **The "personal inbox" pattern** is the load-bearing piece. The
  `user-item-state` table holds one row per user per item the user has
  interacted with, sortable by `published_at` via the SK shape, with
  sparse GSIs `unread_by_feed` and `favorite_by_feed` that contain
  rows only when the corresponding flag is set. Filtered queries then
  Query the sparse GSI directly rather than scanning items and
  filtering — and the indexes are small because they only carry items
  in the relevant state.
- **Missing user-item-state rows mean default state** (unread, not
  favorite). This avoids writing a row for every (user, item) pair at
  fetch time. The first time a user views an item it stays in the
  default; the first time the user marks-read or favorites it, a row
  is created.
- **`pending_notification`** is a small queue table written in the
  same `TransactWriteItems` call as a new item insert, so notifications
  can't be lost if the fetcher dies between the two writes. A TTL
  attribute (e.g. 24 hours) catches anything `rss-notify` fails to
  drain.
- **The four ordering modes** (D17): modes 1 and 2 (oldest/newest
  first) fall out of the SK shape. Modes 3 and 4 (day-grouped) don't
  encode naturally in a DynamoDB SK; the API fetches a chunk in
  `published_at` order and re-sorts in the Lambda. Pagination uses a
  fixed over-fetch multiplier (e.g. 2x page size) to handle the
  reorder correctly.

## Apple-side item cache, FTS, and offline reading

This is the new architectural addition relative to the original plan.
It lives entirely in `CabalmailKit` and the iOS/macOS apps; no
server-side change beyond the `since=<cursor>` parameter on
`GET /rss/items` (added in phase 3).

### Storage

GRDB.swift wrapping SQLite, with FTS5 enabled (Apple's bundled SQLite
ships with FTS5). The cache schema:

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
  oldest_cached_published_at       INTEGER,
  most_recent_cached_published_at  INTEGER
);

CREATE TABLE pending_mutations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id      TEXT NOT NULL,
  feed_id      TEXT NOT NULL,
  mutation     TEXT NOT NULL,    -- 'mark_read' | 'mark_unread'
                                 -- | 'favorite' | 'unfavorite'
  created_at   INTEGER NOT NULL
);
```

`items_fts` mirrors stripped-HTML text of `summary_html` and
`content_html` for indexing. HTML stripping uses Apple's
`NSAttributedString(data:options:documentAttributes:)` with
`.html` document type — adequate for plaintext extraction, ships
with the OS, no third-party dependency.

`pending_mutations` is the offline-write queue. When the user marks
an item read or favorites it while offline, the cache is updated
immediately and a row lands in `pending_mutations`; the next time
the client has connectivity, a sync job drains the queue against the
server with last-write-wins semantics.

### Sync strategy

Three sync paths cooperate:

- **APNs-assisted (notification-on feeds).** The notification service
  extension that enriches push payloads (already in CabalmailKit per
  the 1.0.x design) gets an `RssEnrichment` branch that, in addition
  to enriching the notification body, writes the fetched item into
  the local cache and updates `feed_sync_state`.
- **Background refresh (notification-off feeds).** Registered iOS
  `BGTaskScheduler` task runs at the system's discretion (typically
  once per hour at the system's whim); pulls new items for all
  subscribed notification-off feeds via the `since=<cursor>` endpoint.
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
what's shown. Articles opened via the WKWebView still require network
(per D6); the UI signals this distinction with a small "article
requires connection" indicator when offline.

Images inside cached in-feed content rely on whatever
`WKWebView`/`URLCache` happened to fetch on previous online viewing.
Explicit pre-cache of image bytes is deferred (could be a v1.x
addition).

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

Different Apple devices (iPhone, iPad, Mac) maintain independent
caches; search results scale with each cache. This is acceptable for
per-feed search (you search where you are) and is consistent with how
every other multi-device RSS reader behaves.

## Infrastructure additions

A new Terraform module `terraform/infra/modules/rss/` owns the new
resources. Compared to the original Aurora-based plan, this is much
smaller:

- **DynamoDB tables** (8 of them; see "Data model"), all on-demand,
  PITR enabled, KMS-encrypted with the project-standard key.
- **An S3 bucket** `cabal-rss-image-cache-<env>` with a 7-day
  lifecycle rule (TTL per D13). Bucket policy allows the
  `image-proxy` Lambda only.
- **SSM SecureString hierarchy** `/cabal/rss/credentials/<user>/<feed>`
  for per-(user, feed) credentials, encrypted with the same KMS key.
- **EventBridge schedules:**
  - `rss-fetcher` every 5 minutes
  - `rss-notify` every 60 seconds
- **Lambda functions** (zip-deployed, alongside `lambda/api/`):
  - `lambda/rss/fetcher/` (Python 3.12; libraries: `feedparser`,
    `requests`, `boto3`)
  - `lambda/rss/notify/` (Python; `boto3` only)
  - `lambda/rss/image_proxy/` (Python; `boto3`, `requests`,
    response streaming)
  - `lambda/rss/api/*` (per-endpoint directory, same pattern as
    `lambda/api/`; `boto3` only)
- **API Gateway routes** under `/rss/*`, Cognito-authorized identically
  to the existing email API.
- **SNS topic + SQS queue** reusing the 1.0.x push fanout, with a new
  topic-attribute filter for RSS payloads.

What this does **not** add:

- No RDS, no Aurora, no Postgres.
- No Data API, no RDS Proxy, no connection-pooling layer.
- No VPC attachment on any RSS Lambda. See "Lambda networking policy"
  below for the rule. DynamoDB, S3, SSM, SNS are all reachable over
  public AWS endpoints with IAM auth; the fetcher's outbound
  feed-fetching is intentionally public-internet.
- No new ECS service. The fetcher and notify components are Lambdas.
- No new Cognito user pool, no auth changes.

## Lambda networking policy

Cabalmail follows a written rule for Lambda VPC attachment:

> A Lambda joins the VPC if and only if it needs to reach
> internal-only resources. Otherwise it runs outside the VPC.

The rule was settled during the design of this feature in
conjunction with a separate decision to eventually close public IMAP
access (planned for a later hardening release, with first-party
client parity as the gating prerequisite). The companion VPC-
migration project for the existing `lambda/api/` functions is out of
scope for this document; it's tracked separately.

Under the rule:

- **Existing `lambda/api/` functions** need internal access to
  Dovecot (today through the public IMAP NLB; eventually through an
  internal endpoint as part of the IMAP-closure work). They are in
  scope for VPC migration in their own release.
- **RSS Lambdas** (`lambda/rss/fetcher/`, `lambda/rss/notify/`,
  `lambda/rss/image_proxy/`, `lambda/rss/api/*`) do not need
  internal access. DynamoDB, S3, SSM, SNS, and SQS are reachable
  over public AWS endpoints with IAM auth; the fetcher's
  feed-fetching is intentionally outbound to the public internet.
  None of these Lambdas has any reason to be in the VPC.

So the RSS Lambdas run outside the VPC — **not as a deferral, but
as the policy outcome.** If a future RSS-adjacent Lambda needs to
reach an internal-only resource (a hypothetical per-user Postgres,
say, if the data-layer cost shape ever changes), the rule applies
to it specifically: that Lambda joins the VPC; its peers do not.

Concrete benefits of keeping RSS Lambdas out:

- The fetcher's external traffic does not traverse NAT, so it does
  not load the NAT instances or expose RSS to a NAT-instance-
  failure blast radius.
- No VPC endpoint configuration for AWS-service access. The free
  gateway endpoints (S3, DynamoDB) would suffice for the API
  Lambdas, but interface endpoints for SNS/SQS/SSM cost ~$7/AZ/
  month each and add deployment complexity that the policy avoids
  here.
- Slightly faster cold starts on the API Lambdas (no Hyperplane
  ENI initialisation), which matters for the first user-facing
  read after an idle window.

The policy is also forward-protective: future RSS-related Lambdas
inherit "out of VPC" by default. If a maintainer later argues a
Lambda should be in-VPC, the rule forces them to identify the
specific internal-only resource it needs to reach.

## Per-feed cookie scoping

### Apple clients

`WKWebView` supports per-instance website data stores since
iOS 17/macOS 14 via `WKWebsiteDataStore(forIdentifier: UUID)`. We
target iOS 18/macOS 15, so this is available unconditionally. The
client maps each `subscription.id` to a stable `UUID` stored in
Keychain. When the user opens an article in a web view, the view's
configuration uses the per-feed data store; cookies and `localStorage`
set on the publisher's site survive across launches and stay isolated
from other feeds' data stores.

Removal: when the user unsubscribes from a feed, the client calls
`WKWebsiteDataStore.remove(forIdentifier:)` to delete all stored
cookies and `localStorage` for that feed.

### React client

Browsers don't expose per-iframe cookie partitioning to web apps. The
React client renders article views with a sandboxed iframe pointed at
the publisher's URL; the browser uses its single cookie jar per
origin. The implications:

- A user logged into Substack feed A in one tab gets the same Substack
  session when they open Substack feed B in another. This defeats the
  per-feed scoping intent for users who maintain multiple identities
  per publisher.
- We can't fix this without proxying article rendering server-side,
  which contradicts D6.

Documented as a known limitation: the React client is the right tool
for public feeds and for credentialed feeds where the user uses one
identity per publisher; users who want full per-feed scoping should
use the Apple client.

### Mitigations considered (deferred past v1)

A short menu was reviewed during planning. None ships in v1; the
React limitation is documented and the cost of fixing it is recorded
here for future reference. If hobbyist usage proves the limitation
is a real friction point, revisit and pick from below.

**Non-options** (ruled out as architecturally impossible from a web
app):

- **CHIPS / partitioned cookies** partition by top-level site, not by
  app-controlled identity. Both Substack iframes inside `cabalmail.com`
  share the same partition.
- **Service workers** can intercept requests but can't read or modify
  `Cookie` / `Set-Cookie` headers; those live in the browser's network
  stack outside the SW boundary.
- **`<iframe sandbox>`** restricts capabilities but has no
  isolated-cookies flag.
- **Storage Access API** governs cross-origin storage *permission*,
  not per-app partitioning.

**Viable options when the time comes:**

- **A. Open articles in a new browser tab instead of an iframe.**
  Effort: trivial (single-line UI change). Doesn't fix scoping but
  reframes it — user gets browser-default behavior identical to
  visiting the publisher directly and can apply any browser-level
  mitigations they already use (separate profiles, container tabs).
  Loses the embedded-reader feel; for paywalled sites that may
  actually be preferable since the publisher's full UI loads.
- **B. Hide credentialed-feed subscription in the React UI entirely.**
  Effort: trivial. React handles public feeds; the credentials form
  is Apple-only. Sidesteps the problem by removing the surface area
  where it bites. Already partially aligned with the v1 documented-
  limitation banner.
- **C. Document Firefox Multi-Account Containers** for users who want
  per-domain scoping in the browser. Effort: documentation only.
  Firefox-only; manual per-domain setup; not turnkey but free
  guidance.
- **D. Server-side cookie-rewriting proxy.** Effort: high —
  approximately a quarter-long project. A Lambda or container
  intercepts article requests, strips and stores `Set-Cookie` headers
  per (user, subscription), rewrites all URLs in the HTML to route
  back through itself, injects the right cookie on outbound requests,
  and handles JavaScript-built URL construction in publisher SPAs
  (this last is the hardest part and the most likely failure mode).
  Works on static publisher pages; breaks on most modern sites with
  OAuth flows, complex SPA navigation, or heavy client-side
  rendering. Ongoing maintenance burden whenever publishers redesign.
  Not recommended unless usage data justifies it.

If the limitation ever needs fixing, the likely sequence is **B + A
+ C** in a single small release (cheap, honest, helpful for Firefox
users); **D** stays on the shelf unless real demand emerges.

## Phased implementation

Each phase is independently shippable. Phase 1 is foundational; from
phase 3 onward, work can parallelize across React, OPML, image proxy,
push, and Apple tracks.

### Phase 1: DynamoDB tables + supporting infra

**Goal.** All DynamoDB tables, the image-cache S3 bucket, the SSM
hierarchy, and the KMS key in place in all three environments. No
application code.

**Work.**

- New module `terraform/infra/modules/rss/` with:
  - `dynamodb.tf` — 8 tables, on-demand, PITR enabled, KMS-encrypted,
    indexes per the data model.
  - `s3.tf` — `cabal-rss-image-cache-<env>` with 7-day lifecycle.
  - `kms.tf` — `cabal-rss` KMS key.
  - `ssm.tf` — credential parameter hierarchy (no values, just the
    path structure and IAM policy template).
- IAM policies for the (not-yet-existing) Lambda functions, scoped to
  the specific tables and indexes they'll need.
- A small one-shot Lambda + GHA step that verifies all tables exist
  and respond to a smoke-test `DescribeTable` call after apply.
- CHANGELOG: "Added DynamoDB tables, S3 image-cache bucket, KMS key,
  and SSM hierarchy for the RSS feature set. No application traffic
  yet."

**Rollback.** Destroy the module. Nothing references it.

### Phase 2: Fetcher Lambda

**Goal.** The fetcher fetches public feeds on its cadence, parses
RSS/Atom/JSON, upserts items, tracks health. Validate by seeding a
few `cabal-rss-feed` rows and inspecting `cabal-rss-item` after a
tick.

**Work.**

- `lambda/rss/fetcher/function.py`:
  - Query `by_due` GSI for due feeds.
  - Conditional GET via `feedparser` with the prior `ETag`/`Last-
    Modified` from the feed row.
  - Parse, normalize, upsert items via `by_guid` GSI lookup +
    `PutItem` (or `UpdateItem` for re-publishes).
  - `TransactWriteItems` to write a new item + matching
    `pending_notification` row atomically.
  - Update `cabal-rss-feed` health fields and `next_fetch_at` via the
    adaptive-cadence formula.
- User-Agent set to
  `Cabalmail/2.0 (+https://<control-domain>/feedbot)`. The control
  domain serves a small static page explaining the bot.
- Adaptive cadence: EWMA on `observed_items_per_day` with a
  conservative initial cadence (60 minutes), recomputed on every
  fetch. Bounds are SSM parameters
  `/cabal/rss/cadence_min_minutes` (default 15) and
  `/cabal/rss/cadence_max_minutes` (default 1440). User-invisible
  per D17.
- Canonical URL normalizer per D1 sub-decision (https only, www-vs-
  apex collapse, trailing-slash rules, alphabetized query params,
  `<guid>` exempt). Lives in `lambda/rss/_shared/url.py` with unit
  tests covering every example in the requirements doc.
- Per-feed dead-letter after 20 consecutive failures: when the
  threshold is crossed, the fetcher does an `UpdateItem` that removes
  the row from the `by_due` GSI (by setting its index PK to a
  non-"active" value). Manual reset reverts it.
- `pending_notification` rows accumulate but are not yet drained —
  phase 7 picks that up.

**Rollback.** Disable the EventBridge schedule; data is append-only,
no destructive change.

### Phase 3: Subscription + reader API

**Goal.** Authenticated clients can subscribe to a feed, organize
feeds into folders, list items with filtering, mark items read/
favorite, and pull incremental updates via the `since=<cursor>`
parameter that the Apple cache will rely on. No image proxy yet
(image `<img>` tags pass through verbatim).

**Work.**

- API Gateway routes under `/rss/*`:
  - `POST /rss/subscriptions` (autodiscovery: if the body URL is a
    webpage, scrape `<link rel="alternate">` tags for the feed URL)
  - `DELETE /rss/subscriptions/{id}`
  - `PATCH /rss/subscriptions/{id}` (display preferences,
    notifications toggle, folder move)
  - `GET /rss/subscriptions` (the user's list)
  - `GET|POST|PATCH|DELETE /rss/folders[/{id}]`
  - `GET /rss/items?subscription_id|folder_id&filter=read|favorite|
    all&since=<iso>&order=...&limit=...`
  - `GET /rss/items/{id}` (returns item + per-user state)
  - `POST /rss/items/{id}/read` / `/unread` / `/favorite` /
    `/unfavorite`
  - `GET /rss/feed/{id}/health` (per D10)
- The single-feed list endpoint Queries `cabal-rss-item` directly
  (PK = feed_id) with the SK shape giving order; filter via
  `BatchGet` on `user-item-state`. The filtered single-feed list
  endpoint Queries `user-item-state`'s sparse GSI (`unread_by_feed`
  or `favorite_by_feed`) and `BatchGet`s the items.
- The folder list endpoint follows the multi-Query + merge-sort +
  `BatchGet` pattern described in "Data flow." Pagination cursor is
  a JSON blob carrying per-feed `LastEvaluatedKey` plus a global
  merge position.
- API Lambdas share a `lambda/rss/_shared/auth.py` to extract the user
  sub from the Cognito authorizer claims, the same pattern as
  `lambda/api/_shared/helper.py`.
- When a user subscribes to a public feed for the first time
  Cabalmail-wide, the API creates the `cabal-rss-feed` row with
  `next_fetch_at = NOW()` so the fetcher picks it up on its next
  tick (worst-case 5-minute lag to first content).
- `user-settings` defaults are created on first read.

**Rollback.** Remove the API routes. Data rows are inert without the
fetcher (still running) and the routes (removed).

### Phase 4: React client v1

**Goal.** The React admin app has an "RSS" section with subscription
management, folder hierarchy, item list (with filtering), and an
article viewer. Public feeds only. **No FTS, no offline.** Iframe-
based article view.

**Work.**

- New top-level route in `react/admin/src/`, sibling to Email and
  Addresses.
- Components: `FeedList`, `FolderTree` (drag-and-drop folder ops),
  `ItemList` (virtualized), `ItemDetail` (renders summary HTML with
  DOMPurify, "open article" button switches to an iframe view of
  `item.url`).
- Per-feed settings UI (ordering, default open mode, default styling,
  notifications) — these write to the `subscription` row but apply
  client-side (per open Q5).
- Filter UI for read/favorite/all.
- Reuse existing `AuthContext`/`AppMessageContext` patterns.
- Known-limitations banner on the RSS section landing screen that
  enumerates the React client's reduced feature set vs. the Apple
  clients: **no per-feed cookie/storage partitioning** (multiple
  identities at the same publisher share a session — see "Per-feed
  cookie scoping" above), no full-text search, no offline reading.
  Each item links to documentation pointing users to the Apple
  clients if the missing feature is important to them. The cookie-
  partitioning bullet is the most important one to call out
  prominently — it's the one where a user could inadvertently
  cross-contaminate accounts without realising it.

**Rollback.** Remove the route. The API endpoints continue to function
for other clients.

### Phase 5: OPML import/export

**Goal.** A user can upload an OPML file and have its feeds and
folders imported; a user can download an OPML file of their current
state.

**Work.**

- `POST /rss/opml/import` (multipart upload, Lambda parses with
  `defusedxml`, additive merge per D5 sub-decision, returns a summary
  of created/skipped/failed items).
- `GET /rss/opml/export` (Lambda emits OPML 2.0).
- React UI under the RSS section's settings.
- Apple-side equivalents arrive in phase 8 (share-sheet integration).
- Test: round-trip a Feedly export, a NetNewsWire export, and a
  Reeder export.

**Rollback.** Remove the routes. Existing imported data stays.

### Phase 6: Image proxy + cache

**Goal.** All `<img>` references in served item content are rewritten
to the image-proxy URL, which fetches the publisher's image on first
request and caches in S3 for 7 days.

**Work.**

- `lambda/rss/image_proxy/function.py`: on `GET /rss/img/{hash}`,
  looks up the S3 object by hash (SHA-256 of source URL), serves it
  if present, otherwise fetches from the publisher, stores in S3,
  serves bytes.
- API Gateway proxy integration with binary support enabled.
- Image-URL rewriting in `GET /rss/items/{id}`: parse `summary_html`
  and `content_html` with `lxml`, replace `src` and `srcset`
  attributes, hand back the rewritten body.
- Image-cache TTL is the S3 bucket lifecycle rule (7 days, operator
  override in SSM).
- IAM: the image-proxy Lambda is the only writer to the bucket; API
  Lambdas don't touch it.
- Authentication: image-proxy validates a short-lived signed token
  derived from the user's Cognito JWT (so cached images aren't a
  world-readable surface).

**Rollback.** Stop rewriting `<img>` tags in the read endpoints; let-
through behavior resumes. The bucket can stay or be destroyed
independently.

### Phase 7: Push notification integration

**Goal.** New items in subscribed feeds with notifications enabled
produce APNs (and FCM-when-ready) notifications via the existing
1.0.x push path.

**Work.**

- `lambda/rss/notify/function.py`: EventBridge-triggered every 60
  seconds. Scans `pending_notification` (small table), for each item:
  Query `subscription.by_feed_notify` for subscribers with
  notifications-on, enqueue one SNS message per (user, item) onto the
  existing push topic with a `type=rss` attribute. Delete the
  pending row on success.
- Extend the push-sender Lambda (from 1.0.x) to handle `type=rss`
  payloads: lookup device tokens for the user, build an APNs payload
  with `feed_id` and `item_id` (no content — NSE enriches on device),
  send.
- iOS/macOS NSE in CabalmailKit gets a `type=rss` enrichment branch
  that calls `GET /rss/items/{id}` and populates the notification
  body with feed name + item title. The NSE also writes the fetched
  item into the local `ItemCache` (phase 8 dependency: ItemCache
  must exist; sequence accordingly).
- Notification tap-throughs open the item in the reader UI.
- v1 is per-subscription notifications-on, default false (per D12).
  Folder-level toggle (D12 option B) is wired up but the UI exposes
  per-feed only; folder default lands in 2.1.

**Rollback.** Stop the notify Lambda's schedule; pending rows stay in
the table (TTL eventually drains them) and resume on re-enable.

### Phase 8: Apple clients (with offline + FTS)

**Goal.** The iOS, iPadOS, visionOS, and macOS clients have RSS in
parity with the React app, plus per-feed `WKWebsiteDataStore`
isolation, offline reading, and per-feed FTS.

**Work.**

- `CabalmailKit` gains:
  - `RssClient` protocol with the same shape as `ImapClient`, and
    `ApiBackedRssClient` wrapping the `/rss/*` Lambda endpoints. The
    pattern mirrors `ApiBackedImapClient` from #371.
  - `ItemCache` actor backed by GRDB + SQLite (FTS5). Schema, sync
    logic, mutation queue per the "Apple-side item cache, FTS, and
    offline reading" section above.
  - `RssSync` actor coordinating the three sync paths (APNs-assisted,
    background-refresh, foreground).
- Reader views on each platform: folder tree, item list (read from
  ItemCache, not the API), item detail.
- `WKWebView` configuration uses `WKWebsiteDataStore(forIdentifier:
  subscription_uuid)`. The UUID lives in Keychain, generated on
  first article view per subscription.
- Reader-vs-native styling: when the user picks reader, invoke
  WebKit's reader mode via the `WKWebpagePreferences` interface
  (iOS 18+ exposes this directly).
- Per-feed search UI: a search field in the feed view, results from
  `ItemCache.search(query:, feedId:)`. "Search older items" affordance
  pulls more from the server and re-indexes.
- Offline indicators: small badge on the article-view button when the
  network is unavailable; "queued" indicator on items with pending
  mutations.
- OPML import/export via the share sheet.
- Background refresh registered with `BGTaskScheduler` (iOS) or
  scheduled timer (macOS).
- Push handling already in place from 1.0.x; the `type=rss` NSE
  branch from phase 7 makes RSS notifications work and feeds the
  ItemCache.

**Rollback.** Hide the RSS tab behind a build flag. ItemCache schema
migrations are forward-only; downgrade strategy is "delete and re-
populate from server."

### Phase 9: Credentialed feeds

**Goal.** Users can subscribe to private feeds using HTTP Basic,
URL-key, or cookie auth. Credentials stored per-user, per-feed.

**Work.**

- `POST /rss/subscriptions` accepts a `credentials` block:
  - `{"scheme": "basic", "username": "...", "password": "..."}`
  - `{"scheme": "url_key", "url": "...?key=..."}` — no separate
    credential storage; the URL is the secret and lives in
    `cabal-rss-feed.canonical_url`.
  - `{"scheme": "cookie", "cookie_header": "..."}` (rarely used
    directly; usually the Apple client copies the cookie out of its
    `WKWebsiteDataStore` after user login)
- Credentials write to `cabal-rss-credentials` table + SSM
  SecureString parameter. SSM path is the source of truth for the
  secret value; DynamoDB only holds the path.
- The fetcher's per-user track activates: subscriptions with a
  `credentials_ref` get their own `cabal-rss-feed` row
  (`is_shared = false`, `owner_user = subscriber`).
- Apple client UI for "feed requires login": opens a `WKWebView` to
  the feed/site URL using the subscription's `WKWebsiteDataStore`;
  after the user authenticates, the client extracts cookies from
  the data store and posts them to the API.
- React client UI for Basic + URL-key only; cookie auth is Apple-
  only in v1 because of the React cookie-scoping limitation.

**Rollback.** Drop the credential endpoints; existing credentialed
subscriptions sit dormant (fetcher returns 401, marks feed
unhealthy).

### Phase 10: Adaptive cadence + health surface polish

**Goal.** Tune the adaptive cadence formula based on observed
production behavior, and surface feed health visibly enough that
operator and users can spot problems.

**Work.**

- Per-feed `/rss/feed/{id}/health` returns the last N fetches'
  history.
- React + Apple UI surfaces a small health badge on feeds with 3+
  consecutive failures (yellow) or 20+ consecutive / 410 Gone (red).
- Adaptive-cadence formula gets a feedback loop: if
  `observed_items_per_day` is high but the polling tier keeps us
  catching the same items repeatedly, slow down. Lives in
  `lambda/rss/_shared/cadence.py` with unit tests on simulated feeds.
- Operator runbook entry in `docs/operations/` for "RSS feed is
  stuck": health endpoint, cadence reset, dead-letter revival.

**Rollback.** Revert the formula change; the health UI can stay or
go independently.

## Operational concerns

### Cost shape

The new infrastructure budget per environment at hobby scale (one
operator + a handful of beta users, ~100 feeds total, ~5000 items/
month):

| Item                              | Cost (USD/month)              |
| --------------------------------- | ----------------------------- |
| DynamoDB on-demand (8 tables)     | ~$0.50 (read+write+storage)   |
| GSI storage (sparse, small)       | negligible                    |
| Image cache S3 (with 7d TTL)      | <$2                           |
| Fetcher Lambda invocations        | <$1 (288 invocations/day)     |
| Notify Lambda invocations         | <$1 (1440 invocations/day)    |
| API Lambda invocations            | scales with reader use, <$1   |
| EventBridge schedules             | negligible                    |
| SNS/SQS                           | negligible (reuses 1.0.x)     |
| KMS                               | <$1                           |
| **Total per environment**         | **~$5/month**                 |

Dev is quiesced by default per the project's standing practice and
incurs negligible cost when off. Stage + prod together: **~$10/month**
data-layer cost, down from ~$90/month under the original Aurora plan.

DynamoDB scales smoothly upward: at substantially higher use the
per-million-request fees start to add up, but the data layer would
still be in the low tens of dollars per month at, say, 100 users with
typical reader activity.

### Quiesce

`docs/quiesce.md` covers ECS + NAT + ASG. The RSS additions to the
quiesce path are minimal:

- Disable the `rss-fetcher` and `rss-notify` EventBridge schedules.
- Optionally disable the `/rss/*` API Gateway routes (they're free
  while idle, so this is more about preventing accidental writes).
- DynamoDB tables on-demand have no cost while idle and need no
  scale-down step.

### Backup

DynamoDB PITR (35-day retention by default; we use 14 days non-prod,
35 prod) covers all RSS tables. The image-cache S3 bucket has no
backup — regenerable on demand. SSM credential parameters are
KMS-encrypted; the existing `terraform/infra/modules/backup/` module
is extended to cover the new resources where appropriate (mainly the
KMS key for emergency restore).

The Apple-side `ItemCache` lives on each device and is not backed up
by Cabalmail — it's a derived cache, rebuilt from the server on
demand. iOS device backups include it as a side-effect via NSURL-
ProtectionCompleteUnlessOpen attributes on the SQLite file.

### Multi-environment story

Branches/environments per the project's existing model: development /
stage / main. The new module follows the same pattern; nothing RSS-
specific routes around the existing per-environment AWS account
boundary.

### Rollback per phase

Every phase has its own rollback note above. The dependency chain is
1 -> 2 -> 3 -> {4, 5, 6, 7 -> 8} -> 9 -> 10. Phase 7's NSE branch
that writes to ItemCache requires phase 8's ItemCache to exist on
device, but the server side of phase 7 can ship before phase 8 — the
NSE branch just gracefully handles the absent cache.

## Open questions and risks

The decisions in `rss-requirements.md` (with the post-design-
exploration revisions) settled v1 scope. Open implementation-time
items, scoped per phase:

1. **Pagination cursor format for folder-spanning Queries.** A JSON
   blob carrying per-feed `LastEvaluatedKey` plus a merge position
   is workable but ugly. Worth designing the cursor format
   deliberately in phase 3 so it's a stable contract clients can
   rely on.
2. **GSI hot-partition risk on `by_due`.** The fixed `PK = "active"`
   sends all due-feed reads to a single partition. At hobby scale
   this is fine (a few hundred items in the index, queried twice an
   hour). If the feed count grows materially, shard by
   `hash(feed_id) % N` and Query in parallel across N constant PK
   values.
3. **Sync strategy tuning on Apple.** The lazy/eager/APNs-assisted
   mix is a hypothesis; real-world battery and bandwidth behavior
   determines whether to bias more toward eager prefetch or lean
   harder on background-refresh. Tune in phase 8.
4. **Cache retention defaults.** 365 days + favorites-exempt is a
   guess. Watch device storage usage in phase 8 beta and adjust the
   default before GA.
5. **HTML stripping for FTS.** `NSAttributedString`'s HTML parser is
   adequate for plaintext extraction but slow on large bodies
   (it spins up a full WebKit parser internally). If indexing
   throughput becomes an issue, swap to a lightweight Swift HTML
   tokenizer like `SwiftSoup`.
6. **Adaptive cadence pathologies.** A feed that posts in bursts
   (weekday-only, say) will look slow on weekends and cadence will
   widen, then Monday's burst is delayed by up to max_cadence. Time-
   of-day-aware cadence is out of scope for v1; phase 10 monitors
   whether it matters.
7. **OPML import edge cases.** Real-world OPML files from Feedly,
   NetNewsWire, and Reeder encode folder hierarchy slightly
   differently. Phase 5 test plan should pin down all three
   explicitly.
8. **Pending-mutation conflict resolution on Apple.** Last-write-
   wins is the v1 strategy but breaks down if the user marks an
   item favorite on iPhone offline, then unfavorites on Mac online,
   then the iPhone reconnects. Acceptable in v1 (the iPhone wins
   because its mutation timestamp is later); revisit if it bites.

## Documentation

When the RSS feature ships, operator-facing documentation lives at
`docs/rss.md` (top-level, per the docs convention) covering:

- What RSS in Cabalmail does (link to user-facing UI tour).
- The fetcher's politeness policy (User-Agent, conditional GET, rate
  limits) — what publishers should expect.
- The image-proxy's behavior — privacy implications, cache TTL.
- The credential storage model — what's in SSM, what's in DynamoDB,
  how rotation works.
- The Apple client's offline-reading semantics and FTS scope, plus
  the React client's known limitations.
- Operator runbook for stuck feeds, OPML imports, ItemCache rebuilds.

The `docs/2.0.x/` directory keeps this plan and the requirements doc
as the historical planning record.

## Next steps

1. Operator review of this revised plan — particularly the DynamoDB
   schema, the Apple-cache design, and the per-phase sequencing.
2. If approved, phase 1 is the first PR: Terraform-only, the new
   `rss` module with DynamoDB tables, S3 bucket, KMS key, and SSM
   hierarchy. CI deploys it to stage; the smoke-test step verifies
   table existence and KMS encryption.
3. Each subsequent phase opens its own PR against `stage`, with the
   `claude` label per the project's automation conventions.
