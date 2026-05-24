# RSS Reader — Implementation Plan

## Context

This plan implements the RSS reader for Cabalmail 2.0 based on the decisions
recorded in [`rss-requirements.md`](./rss-requirements.md). It is the
companion build plan to that requirements pass; whenever this document says
"per Dx," it refers to a decision in that file. The reader is the only
substantive feature in 2.0; the version cut is `2.0.x` with each phase
below shipping under a separate patch tag.

Three decisions shape the architecture more than the rest and are worth
restating up front:

- **D6 = C: no server-side article extraction.** The server fetches the
  feed XML/JSON, parses it, stores the items as the feed delivered them,
  and serves them. When the user opens "the article," the client loads
  the publisher's page in an embedded `WKWebView` (Apple) or sandboxed
  iframe (React) and relies on the embedded engine's reader mode for
  styling. The server is never in the article-rendering business. This
  removes a whole subsystem (Trafilatura/Mercury/Readability and its
  Lambda packaging) and removes a whole class of operational risk
  (publisher anti-bot defenses, MIME oddities, scripts running in the
  server context). It also pushes complexity into the clients, mainly
  around cookie scoping for paywalled content.
- **D11: per-feed scoping of cookies and web-view local storage.** Each
  subscription gets its own credential and storage partition; a user with
  three Substack feeds authenticates each one separately and keeps three
  Substack sessions side by side. On Apple this lands on
  `WKWebsiteDataStore(forIdentifier:)` (iOS 17+/macOS 14+; we target
  iOS 18/macOS 15). In a browser the equivalent doesn't exist cleanly
  and the React client gets a documented limitation.
- **D14 + open Q2: Aurora Postgres with `tsvector`.** The stack has no
  RDBMS today; everything is DynamoDB, EFS, S3, SSM. Adding Aurora is a
  meaningful infra step that influences how Lambdas talk to the data
  plane and the per-environment cost shape. We use Aurora Serverless v2
  with the **RDS Data API**, which lets the API Lambdas remain
  non-VPC-attached (matching the existing `lambda/api/` pattern, which
  reaches Dovecot through the public NLB rather than the private VPC
  surface).

Per open Q3 the **fetcher is a scheduled Lambda**, not an ECS service.
Per open Q5, user-level customization (display preferences, ordering)
is **stored** server-side and **applied** client-side, so the shared
canonical-feed records hold no per-user data and the multi-tenancy
boundary is enforced by storage layout, not by access logic.

The plan is structured as ten independently-shippable phases. Each phase
ends in a state that can be deployed to prod without the next phase being
present.

## Goals

- A Cabalmail user can subscribe to RSS, Atom, and JSON feeds from any
  Cabalmail client; read state and per-feed display preferences sync
  across devices.
- Public feeds are fetched once per cadence regardless of how many users
  subscribe; credentialed feeds are fetched per-user.
- The fetcher adapts its cadence per feed within operator-set bounds,
  with no user-exposed cadence control.
- Items are kept indefinitely; image references in item bodies are
  proxied and cached for an operator-tunable TTL (default 7 days, per
  D13).
- New items in subscribed feeds with notifications enabled produce APNs
  push (and eventually FCM, when Android lands) within ~5 minutes of
  publication, reusing the 1.0.x push path.
- A user can import an OPML file at signup and export one at any time.
- Paywalled feeds with per-feed cookie scoping work on Apple clients;
  the React client renders public feeds and reports the limitation for
  credentialed ones.

## Non-goals (v1, all per the requirements doc)

- Server-side full-text extraction (D6).
- Third-party API compatibility — no Fever, no Google Reader (D3).
- Email-to-feed (D7, deferred).
- Feed-to-email digests (D8, declined).
- Tagging, save-for-later, snooze, keep-unread pin, auto-mark-read on
  scroll, cross-feed dedup (D14, D15 — declined or deferred).
- OAuth-flow credentialed feeds (D11, deferred).
- Reader UI in the Android client (Android is on the 1.1.x roadmap; the
  RSS API will be Android-ready but no Android UI ships in 2.0).
- Proactive notification of *feed health* problems (D10 — visibility only
  in v1).
- A user-exposed fetch-cadence control (D17).
- Per-feed keyword muting (D14, declined).

## Architecture overview

### Component diagram

```
                          +----------------------------+
                          |  Aurora Serverless v2      |
                          |  (Postgres, Data API)      |
                          |                            |
                          |  canonical_feed            |
                          |  item (tsvector)           |
                          |  subscription              |
                          |  folder                    |
                          |  user_item_state           |
                          |  credentials (refs SSM)    |
                          |  user_settings             |
                          +-------------+--------------+
                                        ^
                                        |
   +-----------+    EventBridge    +----+-----+    HTTPS+CGET     +--------+
   |   cron    |  every 5 minutes  | fetcher  | ----------------> | feeds  |
   +-----------+ ----------------> | Lambda   | <---------------- |  (any) |
                                   +----+-----+                   +--------+
                                        |
                                        | (new items in
                                        |  notify-on feeds)
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
   +--------+-------+         +--------+--------+         +-----+-----+
            |                          |                        |
            +--------+-----------------+------------------------+
                     |
                     v
            +--------+--------+        +-----------------+
            |  API Gateway    | -----> |  rss-api        |
            |  (Cognito auth) |        |  Lambdas        |
            +-----------------+        | (read/write)    |
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
fetcher selects `canonical_feed` rows whose `next_fetch_at` is in the
past, with `SELECT ... FOR UPDATE SKIP LOCKED` so concurrent invocations
don't double-pick. For each, it issues a conditional GET (`If-None-Match`
+ `If-Modified-Since` from the prior fetch), parses the response into
items, upserts items by `(canonical_feed_id, guid)`, updates the feed's
health fields and `observed_item_rate`, computes a new `next_fetch_at`
from the adaptive-cadence formula, commits, and releases the row lock.

Credentialed feeds run on the same Lambda but in a per-user track:
`subscription` rows where `credentials_id IS NOT NULL` have their own
`next_fetch_at` and `last_etag`/`last_modified` on the subscription row
itself, and the fetch issues credentials pulled from SSM SecureString.

**Read path.** Clients call API Gateway endpoints (`/rss/folders`,
`/rss/subscriptions`, `/rss/items`, `/rss/item/{id}`, `/rss/search`).
The API Lambdas execute SQL via the Data API. List endpoints honor the
filter dimensions of D14 (read/favorite/all) by joining
`user_item_state`. The endpoint that returns an item body rewrites
`<img src="...">` to the image-proxy URL with the user's Cognito JWT
required to dereference (so image cache is shared but the public read
surface is auth'd; see "Image proxy" below).

**Notification path.** When the fetcher upserts a new item (not a
re-publish — first time the GUID has appeared in that feed), it writes
the item_id to an "unnotified items" queue keyed by canonical_feed_id.
A second Lambda (the `rss-notify` Lambda, separate so notification
slowness can't slow fetching) drains the queue: for each new item it
looks up subscribers with notifications enabled on that feed (via
subscription OR folder, per D12 — but in v1, subscription only) and
enqueues an SNS message per (user, item) onto the existing push topic
provisioned by the 1.0.x push-notifications work. The push-sender
Lambda from 1.0.x handles APNs delivery; on-device NSE enriches the
notification by calling the RSS API to fetch the item.

### Shared vs. per-user data

| Concept              | Shared / per-user                                |
| -------------------- | ------------------------------------------------ |
| `canonical_feed`     | Shared (public feeds only — see D1 sub-decision) |
| `item`               | Shared (immutable across users)                  |
| `subscription`       | Per-user (links user to canonical feed)          |
| `folder`             | Per-user                                         |
| `user_item_state`    | Per-user (read, favorite, read_at)               |
| `credentials`        | Per-user; credentialed feeds bypass sharing      |
| `user_settings`      | Per-user (auto_mark_read, reading_time_visible)  |
| Display preferences  | Per-user, applied client-side from               |
|                      | `subscription` columns                           |

Credentialed feeds get a *per-user* `canonical_feed` row (i.e. the row's
URL is the same but the row exists per subscriber). This trades schema
purity for explicit isolation — there is no path where a credentialed
fetch lands content into a row that another user can see. The
`canonical_feed.is_shared` boolean disambiguates.

## Data model

The full schema in DDL form:

```sql
CREATE TABLE canonical_feed (
  id                            BIGSERIAL PRIMARY KEY,
  canonical_url                 TEXT NOT NULL,
  is_shared                     BOOLEAN NOT NULL DEFAULT TRUE,
  owner_user                    TEXT NULL,        -- non-null iff is_shared = FALSE
  feed_type                     TEXT NOT NULL,    -- 'rss' | 'atom' | 'json'
  display_name                  TEXT,
  description                   TEXT,
  site_url                      TEXT,
  last_fetched_at               TIMESTAMPTZ,
  next_fetch_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_etag                     TEXT,
  last_modified                 TEXT,
  last_status_code              INTEGER,
  last_error                    TEXT,
  consecutive_failure_count     INTEGER NOT NULL DEFAULT 0,
  cadence_minutes               INTEGER NOT NULL DEFAULT 60,
  observed_items_per_day        DOUBLE PRECISION NOT NULL DEFAULT 1.0,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT canonical_feed_shared_uniq
    UNIQUE NULLS NOT DISTINCT (canonical_url, owner_user)
);
CREATE INDEX canonical_feed_due_idx
  ON canonical_feed (next_fetch_at) WHERE consecutive_failure_count < 20;

CREATE TABLE item (
  id                BIGSERIAL PRIMARY KEY,
  canonical_feed_id BIGINT NOT NULL REFERENCES canonical_feed(id) ON DELETE CASCADE,
  guid              TEXT NOT NULL,
  title             TEXT,
  author            TEXT,
  url               TEXT,
  summary_html      TEXT,
  content_html      TEXT,
  published_at      TIMESTAMPTZ,
  updated_at        TIMESTAMPTZ,
  fetched_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  content_search    tsvector,
  CONSTRAINT item_feed_guid_uniq UNIQUE (canonical_feed_id, guid)
);
CREATE INDEX item_feed_published_idx
  ON item (canonical_feed_id, published_at DESC);
CREATE INDEX item_content_search_idx
  ON item USING GIN (content_search);

CREATE TABLE folder (
  id                BIGSERIAL PRIMARY KEY,
  user_sub          TEXT NOT NULL,
  parent_folder_id  BIGINT NULL REFERENCES folder(id) ON DELETE CASCADE,
  name              TEXT NOT NULL,
  display_order     INTEGER NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX folder_user_idx ON folder (user_sub);

CREATE TABLE subscription (
  id                              BIGSERIAL PRIMARY KEY,
  user_sub                        TEXT NOT NULL,
  canonical_feed_id               BIGINT NOT NULL REFERENCES canonical_feed(id),
  folder_id                       BIGINT NULL REFERENCES folder(id) ON DELETE SET NULL,
  custom_title                    TEXT,
  ordering_mode                   TEXT NOT NULL DEFAULT 'newest_first',
                                       -- 'oldest_first' | 'newest_first'
                                       -- | 'oldest_day_newest_within'
                                       -- | 'newest_day_oldest_within'
  default_open_mode               TEXT NOT NULL DEFAULT 'summary',
                                       -- 'summary' | 'article'
  default_styling                 TEXT NOT NULL DEFAULT 'reader',
                                       -- 'reader' | 'native'
  notifications_enabled           BOOLEAN NOT NULL DEFAULT FALSE,
  credentials_id                  BIGINT NULL REFERENCES credentials(id) ON DELETE SET NULL,
  -- per-user fetch state, populated only when canonical_feed.is_shared = FALSE
  per_user_last_etag              TEXT,
  per_user_last_modified          TEXT,
  per_user_next_fetch_at          TIMESTAMPTZ,
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT subscription_user_feed_uniq UNIQUE (user_sub, canonical_feed_id)
);
CREATE INDEX subscription_user_folder_idx ON subscription (user_sub, folder_id);
CREATE INDEX subscription_notify_idx
  ON subscription (canonical_feed_id) WHERE notifications_enabled;

CREATE TABLE user_item_state (
  user_sub     TEXT NOT NULL,
  item_id      BIGINT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
  is_read      BOOLEAN NOT NULL DEFAULT FALSE,
  is_favorite  BOOLEAN NOT NULL DEFAULT FALSE,
  read_at      TIMESTAMPTZ,
  PRIMARY KEY (user_sub, item_id)
);
CREATE INDEX uis_user_unread_idx
  ON user_item_state (user_sub, item_id) WHERE NOT is_read;
CREATE INDEX uis_user_favorite_idx
  ON user_item_state (user_sub, item_id) WHERE is_favorite;

CREATE TABLE credentials (
  id                  BIGSERIAL PRIMARY KEY,
  user_sub            TEXT NOT NULL,
  canonical_feed_id   BIGINT NOT NULL REFERENCES canonical_feed(id) ON DELETE CASCADE,
  scheme              TEXT NOT NULL,    -- 'basic' | 'url_key' | 'cookie'
  ssm_parameter_path  TEXT NOT NULL,    -- SecureString location of secret material
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT credentials_user_feed_uniq UNIQUE (user_sub, canonical_feed_id)
);

CREATE TABLE user_settings (
  user_sub               TEXT PRIMARY KEY,
  auto_mark_read         BOOLEAN NOT NULL DEFAULT FALSE,
  reading_time_visible   BOOLEAN NOT NULL DEFAULT FALSE,
  last_ordering_mode     TEXT,
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Items pending notification dispatch. Drained by rss-notify Lambda.
CREATE TABLE pending_notification (
  item_id      BIGINT PRIMARY KEY REFERENCES item(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

A few notes on the model:

- **No tombstones.** Per D4, items live forever; tombstones were only
  needed if items could be dropped. They are not in v1. Image-cache
  rows can age out (D4 "linked content"); item rows cannot.
- **`canonical_feed.is_shared`** is the only mechanism that disambiguates
  shared from per-user canonical-feed records. The `UNIQUE NULLS NOT
  DISTINCT (canonical_url, owner_user)` constraint allows multiple shared
  rows with the same URL only if there's a bug; the intended state is
  exactly one shared row per canonical URL, plus N per-user rows for the
  same URL when those subscribers are using credentials.
- **`content_search`** is populated by a trigger on `item` insert/update:
  `content_search := to_tsvector('english', coalesce(title,'') || ' ' ||
  coalesce(summary_html,'') || ' ' || coalesce(content_html,''))`.
  The HTML strip can stay in the trigger if we use the
  `unaccent + strip_tags` pattern, or move to the application layer if
  trigger performance hurts.
- **`pending_notification`** is a Postgres table not an SQS queue
  intentionally: it lets the fetcher commit notification work in the
  same transaction as the item insert, so notifications can't be lost
  if the fetcher dies between writing the item and emitting the SQS
  message.

## Infrastructure additions

A new Terraform module `terraform/infra/modules/rss/` owns the new
resources:

- **Aurora Serverless v2 cluster** (Postgres 16), single-AZ in
  non-prod, multi-AZ in prod. ACU range 0.5 - 4 in non-prod, 1 - 8 in
  prod. **Data API enabled** so Lambdas access it over HTTPS without
  VPC attachment.
- **A KMS key** for `cabal-rss-postgres`, separate from the existing
  email-side keys.
- **An S3 bucket** `cabal-rss-image-cache-<env>` with a 7-day
  lifecycle rule (TTL per D13). Bucket policy allows the
  `image-proxy` Lambda only.
- **SSM SecureString hierarchy** `/cabal/rss/credentials/<user>/<feed>`
  for per-(user, feed) credentials, encrypted with the same KMS key.
- **EventBridge schedule** firing the `rss-fetcher` Lambda every
  5 minutes. The 5-minute floor caps the worst-case fetch lag and is
  well under any operator-configurable min cadence.
- **Lambda functions** (zip-deployed, alongside `lambda/api/`):
  - `lambda/rss/fetcher/` (Python 3.12, libraries: `feedparser`,
    `requests`, `boto3`)
  - `lambda/rss/notify/` (Python, drains `pending_notification`)
  - `lambda/rss/image_proxy/` (Python, S3 cache + transparent fetch)
  - `lambda/rss/api/*` (the read/write endpoints; structured the same
    way as `lambda/api/` with a per-endpoint directory)
- **API Gateway routes** under `/rss/*`, Cognito-authorized identically
  to the existing email API.
- **SNS topic + SQS queue** reusing the 1.0.x push fanout, with a new
  topic-attribute filter for RSS payloads so a subscriber on email push
  doesn't also get RSS push and vice versa.

What this does **not** add:

- No new ECS service. The fetcher is a Lambda.
- No RDS Proxy. Data API replaces connection pooling.
- No VPC attachment on the RSS Lambdas. Data API + S3 + SSM + SNS are
  all reachable over public endpoints with IAM auth.
- No new Cognito user pool, no auth changes. RSS API endpoints sit
  under the existing pool.

## Per-feed cookie scoping

### Apple clients

`WKWebView` supports per-instance website data stores since
iOS 17/macOS 14 via `WKWebsiteDataStore(forIdentifier: UUID)`. We
target iOS 18/macOS 15, so this is available unconditionally. The
client maps each `subscription.id` to a stable `UUID` and persists the
mapping in the client-side store. When the user opens an article in a
web view, the view's configuration uses the per-feed data store; cookies
and `localStorage` set on the publisher's site survive across launches
and stay isolated from other feeds' data stores.

Removal: when the user unsubscribes from a feed, the client calls
`WKWebsiteDataStore.remove(forIdentifier:)` to delete all stored
cookies and `localStorage` for that feed. The mapping row is also
removed.

### React client

Browsers don't expose per-iframe cookie partitioning to web apps. The
React client renders article web views with a sandboxed iframe pointed
at the publisher's URL; the browser uses its single cookie jar per
origin. The implications:

- A user who's logged into Substack feed A in one tab gets the same
  Substack session when they open Substack feed B in another. This
  defeats the per-feed scoping intent for users who maintain multiple
  identities per publisher.
- We can't fix this without proxying article rendering server-side,
  which contradicts D6.

This is documented as a known limitation: the React client is the right
tool for public feeds and for credentialed feeds where the user uses one
identity per publisher; users who want full per-feed scoping should use
the Apple client. A future-version mitigation is a server-side
cookie-rewriting proxy, but it's out of scope for 2.0.

## Phased implementation

Each phase is independently shippable. Phases 1-3 are sequential and
purely backend; from phase 4 onward, work can parallelize.

### Phase 1: Aurora Postgres + schema

**Goal.** Aurora cluster running in all three environments, schema
applied, Data API tested from a Lambda. No application code.

**Work.**

- New module `terraform/infra/modules/rss/postgres.tf` with the cluster,
  KMS key, secret, IAM policies for Lambdas, and an operator-only
  bastion role for ad hoc psql access. (We can run psql via the Data
  API for ops; no bastion EC2 needed.)
- Schema management via Flyway-style migrations checked into
  `lambda/rss/_migrations/` and applied by a one-shot Lambda invoked
  from CI on Terraform apply. (Simpler than a sidecar; we already run
  one-shot Lambdas for `lambda/counter` and similar.)
- Minimal `lambda/rss/_shared/db.py` with a `Data API` wrapper that
  takes parameterized SQL and returns rows as dicts. Tested locally
  against a Postgres in Docker and remotely via Data API in stage.
- CHANGELOG: "Added Aurora Serverless v2 Postgres for the RSS feature
  set (cluster only; no application traffic yet)."

**Rollback.** Destroy the module. No reference from elsewhere.

### Phase 2: Fetcher Lambda

**Goal.** The fetcher fetches public feeds on its cadence, parses
RSS/Atom/JSON, upserts items, tracks health. No user-facing surface yet
— validate by seeding a few `canonical_feed` rows by hand and inspecting
the result.

**Work.**

- `lambda/rss/fetcher/function.py` selects due feeds, runs conditional
  GET with `feedparser`, normalizes content, upserts items, recomputes
  `next_fetch_at`. Concurrency-safe via row-level `SELECT FOR UPDATE
  SKIP LOCKED`.
- User-Agent set to
  `Cabalmail/2.0 (+https://<control-domain>/feedbot)`. The control
  domain serves a small static page explaining the bot — wire that into
  the React app's static assets in this phase.
- Adaptive cadence: simple EWMA on `observed_items_per_day` with a
  conservative initial cadence (60 minutes), recomputed on every fetch.
  Bounds are SSM parameters
  `/cabal/rss/cadence_min_minutes` (default 15) and
  `/cabal/rss/cadence_max_minutes` (default 1440). User-invisible per
  D17.
- Canonical URL normalizer per D1 sub-decision (https only, www-vs-apex
  collapse, trailing-slash rules, alphabetized query params, `<guid>`
  exempt). Lives in `lambda/rss/_shared/url.py` with unit tests covering
  every example in the requirements doc.
- Per-feed dead-letter after 20 consecutive failures (column
  `consecutive_failure_count`). The `WHERE consecutive_failure_count <
  20` clause in the `canonical_feed_due_idx` prevents dead feeds from
  ever being selected; a manual reset is required to revive them.
- Notification rows: writes to `pending_notification` in the same
  transaction as item insert, but no notify Lambda yet — phase 7 picks
  this up.

**Rollback.** Disable the EventBridge schedule; rows are append-only,
no destructive change.

### Phase 3: Subscription + reader API

**Goal.** Authenticated clients can subscribe to a feed, organize feeds
into folders, list items with filtering, and mark items read/favorite.
No image proxy yet (image `<img>` tags pass through verbatim).

**Work.**

- API Gateway routes under `/rss/*`:
  - `POST /rss/subscriptions` (autodiscovery: if the body URL is a
    webpage, scrape `<link rel="alternate">` tags for the feed URL)
  - `DELETE /rss/subscriptions/{id}`
  - `PATCH /rss/subscriptions/{id}` (display preferences,
    notifications toggle, folder move)
  - `GET /rss/subscriptions` (the user's list)
  - `GET|POST|PATCH|DELETE /rss/folders[/{id}]`
  - `GET /rss/items` with `?folder_id|subscription_id` +
    `?filter=read|favorite|all` + `?order=...` + pagination
  - `GET /rss/items/{id}` (returns item + per-user state)
  - `POST /rss/items/{id}/read` and `/unread`, `/favorite`,
    `/unfavorite`
  - `GET /rss/search?q=...` (Postgres `tsvector` query)
  - `GET /rss/feed/{id}/health` (per D10)
- API Lambdas share a `lambda/rss/_shared/auth.py` to extract the user
  sub from the Cognito authorizer claims, the same pattern as
  `lambda/api/_shared/helper.py`.
- When the user subscribes to a public feed for the first time
  Cabalmail-wide, the API creates the `canonical_feed` row with
  `next_fetch_at = NOW()` so the fetcher picks it up on its next tick
  (worst-case 5-minute lag to first content).
- `user_settings` defaults are created on first read.

**Rollback.** Remove the API routes. Data rows are inert without the
fetcher (still running) and the routes (removed).

### Phase 4: React client v1

**Goal.** The React admin app has an "RSS" section with subscription
management, folder hierarchy, item list (with filtering), and an
article viewer. Public feeds only. Iframe-based article view; no
per-feed cookie scoping (documented limitation).

**Work.**

- New top-level route in `react/admin/src/`, sibling to Email and
  Addresses.
- Components: `FeedList`, `FolderTree` (drag-and-drop folder ops),
  `ItemList` (virtualized — feed item lists get long fast),
  `ItemDetail` (renders summary HTML with DOMPurify, "open article"
  button switches to an iframe view of `item.url`).
- Per-feed settings UI (ordering, default open mode, default styling,
  notifications) — these write to the `subscription` row but apply
  client-side (per Q5).
- Filter UI for read/favorite/all.
- Reuse the existing `AuthContext`/`AppMessageContext` patterns.
- The known-limitation banner on the article view explaining
  shared-cookie behavior for credentialed feeds.

**Rollback.** Remove the route. The API endpoints continue to function
for other clients.

### Phase 5: OPML import/export

**Goal.** A user can upload an OPML file and have its feeds and folders
imported; a user can download an OPML file of their current state.

**Work.**

- `POST /rss/opml/import` (multipart upload, Lambda parses with
  `defusedxml`, additive merge per D5 sub-decision, returns a summary
  of created/skipped/failed items).
- `GET /rss/opml/export` (Lambda emits OPML 2.0).
- React UI under the RSS section's settings.
- Apple-side equivalents in phase 8.
- Test: round-trip a Feedly export, a NetNewsWire export, and a
  Reeder export.

**Rollback.** Remove the routes. Existing imported data stays.

### Phase 6: Image proxy + cache

**Goal.** All `<img>` references in served item content are rewritten
to the image-proxy URL, which fetches the publisher's image on first
request and caches in S3 for 7 days.

**Work.**

- `lambda/rss/image_proxy/function.py`: on `GET /rss/img/{hash}`,
  looks up `image_cache` row by hash (SHA-256 of source URL), serves
  from S3 if present and not expired, otherwise fetches from the
  publisher, stores in S3, writes the row, serves bytes.
- API Gateway proxy integration with binary support enabled.
- Image-URL rewriting in `GET /rss/items/{id}`: parse `summary_html`
  and `content_html` with `lxml`, replace `src` and `srcset`
  attributes, hand back the rewritten body.
- Image cache TTL is the S3 bucket lifecycle rule (7 days, operator
  override in SSM); the DB row also has an expiry column for cache
  invalidation independent of S3 (e.g. on `Cache-Control: no-store`).
- IAM: the image-proxy Lambda is the only writer to the bucket; API
  Lambdas don't touch it.
- Authentication: image-proxy validates a short-lived signed token
  derived from the user's Cognito JWT (so cached images aren't a
  world-readable surface).

**Rollback.** Stop rewriting `<img>` tags in the read endpoints;
let-through behavior resumes. The bucket can stay or be destroyed
independently.

### Phase 7: Push notification integration

**Goal.** New items in subscribed feeds with notifications enabled
produce APNs (and FCM-when-ready) notifications via the existing
1.0.x push path.

**Work.**

- `lambda/rss/notify/function.py`: EventBridge-triggered every 60
  seconds, drains `pending_notification` rows. For each item: find
  subscribers with `notifications_enabled` on that
  `canonical_feed_id`, enqueue one SNS message per (user, item) onto
  the existing push topic with a `type=rss` attribute. Delete the
  pending row on success.
- Extend the push-sender Lambda (from 1.0.x) to handle `type=rss`
  payloads: lookup device tokens for the user, build an APNs payload
  with `feed_id` and `item_id` (no content — NSE enriches on device),
  send.
- iOS/macOS NSE extension (lives in CabalmailKit per the 1.0.x design)
  gets an enrichment branch for `type=rss` that calls
  `GET /rss/items/{id}` and populates the notification body with feed
  name + item title.
- Notification tap-throughs: open the item in the reader UI.
- v1 is per-subscription notifications-on, default false (per D12).
  Folder-level toggle (D12 option B) is wired up but disabled in v1
  UI; it ships when 2.1 lands.

**Rollback.** Stop the notify Lambda's schedule; pending rows stay in
the table and resume on re-enable.

### Phase 8: Apple clients

**Goal.** The iOS, iPadOS, visionOS, and macOS clients have RSS in
parity with the React app, plus per-feed `WKWebsiteDataStore`
isolation.

**Work.**

- `CabalmailKit` gains an `RssClient` protocol with the same shape as
  `ImapClient`, and a `live(...)` constructor wrapping the
  `/rss/*` Lambda endpoints in `ApiBackedRssClient`. The pattern
  mirrors the `ApiBackedImapClient` work from issue #371 —
  Lambda-backed from day one, no native parsing.
- Reader views on each platform: folder tree, item list, item detail.
- `WKWebView` configuration uses
  `WKWebsiteDataStore(forIdentifier: subscription_uuid)`. The UUID
  is generated client-side on first article view and persisted in
  Keychain.
- Reader-vs-native styling: when the user picks reader, invoke
  WebKit's reader mode via the `WKWebpagePreferences` interface
  (iOS 18+ supports this directly).
- OPML import/export via the share sheet.
- Push handling already in place from the 1.0.x work; the NSE branch
  from phase 7 makes RSS notifications work.

**Rollback.** Hide the RSS tab behind a build flag.

### Phase 9: Credentialed feeds

**Goal.** Users can subscribe to private feeds using HTTP Basic,
URL-key, or cookie auth. Credentials are stored per-user, per-feed.

**Work.**

- `POST /rss/subscriptions` accepts a `credentials` block:
  - `{"scheme": "basic", "username": "...", "password": "..."}`
  - `{"scheme": "url_key", "url": "...?key=..."}` — no separate
    credential storage; the URL is the secret and lives in
    `canonical_feed.canonical_url`.
  - `{"scheme": "cookie", "cookie_header": "..."}` (rarely used
    directly; usually the Apple client will copy the cookie out of
    its `WKWebsiteDataStore` after user login)
- Credentials write to `credentials` table + SSM SecureString
  parameter. SSM path is the source of truth for the secret value;
  Postgres only holds the path.
- The fetcher's per-user track activates: subscriptions with
  `credentials_id IS NOT NULL` get their own `canonical_feed` row
  (`is_shared = false, owner_user = subscriber`).
- Apple client UI for "feed requires login": opens a `WKWebView` to
  the feed/site URL using the subscription's `WKWebsiteDataStore`;
  after the user authenticates, the client extracts cookies from the
  data store and posts them to the API.
- React client UI for Basic + URL-key only; cookie auth is
  Apple-only in v1 because of the React cookie-scoping limitation.

**Rollback.** Drop the credential endpoints; existing credentialed
subscriptions sit dormant (fetcher returns 401, marks feed unhealthy).

### Phase 10: Adaptive cadence + health surface polish

**Goal.** Tune the adaptive cadence formula based on observed
production behavior, and surface feed health visibly enough that
operator and users can spot problems.

**Work.**

- Per-feed `/rss/feed/{id}/health` returns full health history
  (last 30 fetches: timestamp, status, error).
- React + Apple UI surfaces a small health badge on feeds that have
  failed 3+ times in a row (yellow) or 20+ in a row / 410 Gone (red).
- Adaptive-cadence formula gets a feedback loop: if `observed_items_
  per_day` is high but the polling-tier cadence keeps us catching the
  same items repeatedly, slow down. Lives in
  `lambda/rss/_shared/cadence.py` with unit tests on simulated feeds.
- Operator runbook entry in `docs/operations/` for "RSS feed is
  stuck": health endpoint, cadence reset, dead-letter revival.

**Rollback.** Revert the formula change; the health UI can stay or
go independently.

## Operational concerns

### Cost shape

The new infrastructure budget per environment:

| Item                                  | Cost (USD/month, ballpark)     |
| ------------------------------------- | ------------------------------ |
| Aurora Serverless v2 (0.5 - 4 ACU)    | ~$45 idle, scales with load    |
| RDS Data API requests                 | $0.35 per million requests     |
| Image cache S3 (with 7d TTL)          | <$5 for first 1k users         |
| Fetcher Lambda invocations            | <$1 (288 invocations/day)      |
| API Lambda invocations                | scales with reader use         |
| EventBridge schedule                  | negligible                     |
| SNS/SQS                               | negligible (reuses 1.0.x)      |

Non-prod environments use the lower ACU range; prod the higher.
Development is quiesced by default per the project's standing
practice, so dev incurs Aurora's idle floor only when explicitly
de-quiesced for a test.

### Quiesce

`docs/quiesce.md` covers ECS + NAT + ASG. The RSS additions extend
it: when quiescing a non-prod environment, scale Aurora to its
minimum ACU (0.5) and disable the EventBridge schedule. When
restoring, reverse both. The `quiesce.yml` workflow gains the two
new steps in this phase's deploy.

### Backup

Aurora has automated backups (35-day retention by default; we'll set
14 days non-prod, 35 prod). The image-cache S3 bucket has no backup
— it's regenerable on demand. SSM credential parameters are
KMS-encrypted; the existing `terraform/infra/modules/backup/` module
is extended to cover the new resources where appropriate.

### Multi-environment story

Branches/environments per the project's existing model: development /
stage / main. The new module follows the same pattern; nothing
RSS-specific routes around the existing per-environment AWS account
boundary. Cognito users in stage do not see feeds added in prod and
vice versa.

### Rollback per phase

Every phase has its own rollback note above. The dependency chain is
1 -> 2 -> {3 -> {4, 5, 6, 7}} -> 8 -> 9 -> 10. Phases 4-7 can ship
in any order after 3 is live; phase 9 needs phase 8 (the Apple client
is the primary UX for credentialed feeds); phase 10 is polish on top
of everything.

## Open questions and risks

The decisions in `rss-requirements.md` settled the v1 scope; what
remains are implementation-time judgment calls. These don't block the
plan but should be revisited before the corresponding phase ships.

1. **Data API vs. RDS Proxy.** Choosing Data API keeps the API
   Lambdas out of the VPC, but Data API has a 1 MB response limit and
   higher per-request latency. If the reader API endpoints start
   hitting size or latency walls (large item lists, big content_html
   bodies), switching individual high-traffic endpoints to RDS Proxy
   + VPC-attached Lambda is reasonable. The first stress test in
   stage will tell.
2. **Aurora minimum ACU and idle cost.** Aurora Serverless v2's
   minimum is 0.5 ACU = ~$45/month per environment. If dev is
   quiesced 95% of the time and stage 50%, the actual cost is lower.
   If the bill is uncomfortable, evaluate Aurora Serverless v2
   scale-to-zero (now GA on Postgres 16) — adds cold-start latency
   on first request but eliminates idle cost.
3. **Tsvector index growth.** Item rows live forever; the GIN index
   on `content_search` grows monotonically. At scale (1M+ items),
   index size becomes noticeable. Bounded by reality of feed
   volumes (typical user: ~50 feeds x ~3 items/day x 5 years =
   ~270k items per user; 1k users = 270M items, which is a real
   number). Plan for partition-by-date if it becomes a problem.
4. **Notification timing accuracy.** The fetcher tick is 5 minutes
   and the notify Lambda tick is 60 seconds, so worst-case time
   from publication to push notification is ~6 minutes. Comparable
   to other readers; acceptable for v1.
5. **Per-feed cookie scoping in React.** Documented limitation, but
   if users complain, a server-side cookie-rewriting proxy is a
   sizeable v1.1 project.
6. **Adaptive cadence pathologies.** A feed that posts in burstst
   (e.g. weekday-only) will look slow on weekends and the cadence
   will widen, then the burst on Monday is delayed by up to
   max_cadence. Mitigations exist (time-of-day-aware cadence) but
   are out of scope for v1; phase 10 monitors whether it matters.
7. **OPML import edge cases.** Real-world OPML files from Feedly,
   NetNewsWire, Reeder all encode folder hierarchy slightly
   differently. The phase 5 test plan should pin down all three
   explicitly.

## Documentation

When the RSS feature ships, operator-facing documentation lives at
`docs/rss.md` (top-level, per the docs convention) covering:

- What RSS in Cabalmail does (link to user-facing UI tour)
- The fetcher's politeness policy (User-Agent, conditional GET, rate
  limits) — what publishers should expect
- The image-proxy's behavior — privacy implications, cache TTL
- The credential storage model — what's in SSM, what's in Postgres,
  how rotation works
- Operator runbook for stuck feeds, OPML imports, schema migrations

The `docs/2.0.x/` directory keeps this plan and the requirements doc
as the historical planning record.

## Next steps

1. Operator review of this plan — particularly the per-phase
   sequencing and the Aurora cost shape.
2. If approved, phase 1 is the first PR: Terraform-only, Aurora
   cluster + KMS + Data API + an initial migration that creates
   the schema above. CI deploys it to stage; smoke-test Data API
   connectivity from a throwaway Lambda before tearing down the
   test.
3. Each subsequent phase opens its own PR, against `stage`, with the
   `claude` label per the project's automation conventions.
