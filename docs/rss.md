# RSS reader

Cabalmail fetches the RSS, Atom, and JSON feeds its users subscribe to,
stores their items, tracks each user's read and favorite state, and serves
all of it through the same Cognito-authorized API the mail clients use.
This page is the as-implemented reference for what has shipped so far:
the data layer, the fetcher and its politeness policy, and the HTTP API.
The plan and its progress live in
[`1.x/rss-implementation-plan.md`](./1.x/rss-implementation-plan.md); the
requirements and the decisions behind them in
[`1.x/rss-requirements.md`](./1.x/rss-requirements.md).

## Shape

- **Shared feeds, per-user everything else.** A public feed is one row in
  `cabal-rss-feed` and one set of items in `cabal-rss-item` no matter how
  many users subscribe. Subscriptions, folders, and read/favorite state
  are per user, keyed by Cognito username.
- **Feeds are deduplicated by canonical URL.** `http://` is upgraded to
  https (a feed that is not served over https is refused), the host is
  lower-cased and a leading `www.` is dropped when the rest is a
  registrable apex (Public Suffix List), query parameters are sorted,
  fragments are dropped. `/` is canonical only right after the host; the
  rest of the path is kept exactly as given, since only the server knows
  whether `/dir` and `/dir/` are one object. A publisher that treats them
  as one redirects, and the subscribe probe follows the permanent
  redirect before looking the feed up, so both forms still share a row.
- **Items are kept while a feed has subscribers.** When the last
  subscriber leaves, the feed, its items, and any spilled bodies are
  deleted; subscribing again starts it fresh.
- **Read state is computed.** An item is read when the user's state row
  says so, or, absent a row, when it was published at or before the
  subscription's `read_watermark` (what mark-all-read writes). A
  never-touched item has no row and is unread. Favorites are explicit and
  indexed.

## Fetcher

`rss_schedule` runs every five minutes (EventBridge Scheduler, paused by
quiesce) and claims due feeds from the `by_due` index; `rss_fetch`
consumes `cabal-rss-fetch-queue` one feed per invocation, at most five at
once. Both are VPC-attached, so publishers see the NAT Elastic IPs (the
same addresses that deliver outbound mail).

What publishers can expect, and what `front-door/feedbot.html` tells them:

| Behaviour | Detail |
|---|---|
| User-Agent | `Cabalmail-Feedbot/1 (+https://www.<control-domain>/feedbot.html)` |
| Conditional GET | Always. The strong form of the ETag alone when one is known (weak `W/` prefixes are stripped, since Cloudflare-fronted origins compare literally); `If-Modified-Since` only when no ETag is known. |
| Cadence | Adaptive: an EWMA of items per day aiming at one new item per fetch, clamped to `/cabal/rss/cadence_min_minutes` and `/cabal/rss/cadence_max_minutes` (SSM SecureString; defaults 15 and 1440). `Cache-Control: max-age`, `Retry-After`, RSS `<ttl>`, and `sy:updatePeriod` are honoured as floors. |
| Failures | Exponential backoff from the minimum cadence; dead-lettered (removed from `by_due`) after twenty consecutive failures or on `410 Gone`. Subscribing revives a dead-lettered feed. |
| Redirects | Up to five hops, https only, every hop checked. A first-hop `301`/`308` moves the stored URL unless another feed already owns the target (`redirect_conflict_url` is recorded instead). |
| Limits | 5 MB response cap before and after gzip; 20 s per operation, 60 s overall; 500 items per fetch. |
| Safety | The host is resolved before connecting and any non-global address (loopback, private, link-local, IPv4-mapped) is refused, on every hop. Plain http is never fetched. |

Item HTML is stored as feedparser sanitizes it; clients still render it in
the same sandboxed body view they use for mail. Bodies over 300 KB spill
to the `rss-cache` bucket's `items/` prefix and are inlined by the API.

Metrics are CloudWatch EMF under `Cabal/Rss` (`FeedsDue`, `FeedsClaimed`,
`FeedsEnqueued`, `Fetched`, `NotModified`, `Failed`, `DeadLettered`,
`ItemsNew`, `ItemsUpdated`, `BytesFetched`); logs at
`/cabal/lambda/rss_schedule` and `/cabal/lambda/rss_fetch`, prefixed
`[rss-schedule]` / `[rss-fetch]`. Undeliverable fetches land in
`cabal-rss-fetch-dlq`.

## API

Flat endpoints on the existing gateway, Cognito-authorized like the rest.
Reads are `GET` with query parameters; writes carry a JSON body. Errors
are `{"Error": "<message>", "code": "<token>"}`; the codes below are the
stable part. Every response field listed here is part of the
compatibility contract ([`compatibility.md`](./compatibility.md)); new
fields may appear and clients must ignore unknown ones.

### Objects

**subscription**: `subscription_id`, `feed_id`, `folder_id` (empty =
root), `custom_title`, `ordering_mode` (`newest_first` | `oldest_first` |
`newest_day_oldest_within` | `oldest_day_newest_within`),
`default_open_mode` (`summary` | `article`), `default_styling` (`reader`
| `native`), `notifications_enabled`, `credentials_scheme`,
`read_watermark`, `data_store_uuid` (the per-subscription identifier the
clients key their isolated web-view storage on), `created_at`, and
`feed`.

**feed** (summary): `feed_id`, `canonical_url`, `feed_type` (`rss` |
`atom` | `json`), `title`, `description`, `site_url`, `item_count`,
`last_fetched_at`, `last_attempt_at`, `last_status_code`, `last_error`,
`consecutive_failure_count`, `cadence_minutes`, `next_fetch_at`,
`dead_lettered`.

**folder**: `folder_id`, `parent_folder_id` (empty = root), `name`,
`display_order`.

**item**: `feed_id`, `subscription_id`, `item_id`, `sort_key` (the item's
key; opaque, pass it back), `guid`, `title`, `author`, `url`,
`published_at`, `updated_at`, `fetched_at`, `fetched_key` (the sync
cursor), `summary_html`, `content_html` (spilled bodies inlined),
`is_read`, `is_favorite`.

Display preferences on a subscription are stored by the server and
applied by the client; the server never reorders or filters items by
them except as documented under `/rss_list_items`.

### Endpoints

| Endpoint | Method | Request | Response |
|---|---|---|---|
| `/rss_subscribe` | POST | `{url, folder_id?}` | `{subscription, existing}`. Reuses the shared feed for a known canonical URL; otherwise fetches the document once (autodiscovering the feed a web page advertises), creates the feed, and hands it to the fetcher immediately. Idempotent per user and feed. Codes: `invalid_url`, `not_https`, `unreachable`, `not_a_feed`, `needs_credentials`, `feed_gone`, `publisher_error`, `unknown_folder` (404). |
| `/rss_unsubscribe` | POST | `{subscription_id}` | `{subscription_id, feed_id, feed_purged}`. Deletes the caller's state for the feed; purges the feed when no subscribers remain. |
| `/rss_update_subscription` | PUT | `{subscription_id, custom_title?, folder_id?, ordering_mode?, default_open_mode?, default_styling?, notifications_enabled?}` | `{subscription}`. Codes: `invalid_<field>`, `unknown_folder`, `nothing_to_update`. |
| `/rss_list_subscriptions` | GET | | `{folders, subscriptions}`, each subscription with its `feed` summary. |
| `/rss_new_folder` | POST | `{name, parent_folder_id?, display_order?}` | `{folder}` |
| `/rss_update_folder` | PUT | `{folder_id, name?, parent_folder_id? ("" = root), display_order?}` | `{folder}`. Code `cyclic_folder` when moved under itself. |
| `/rss_delete_folder` | POST | `{folder_id}` | `{folder_id, moved_subscriptions, moved_folders, parent_folder_id}`. Contents move to the parent, never deleted. |
| `/rss_list_items` | GET | `subscription_id` \| `folder_id` \| neither (all); `filter=all\|unread\|favorite`; `order=newest\|oldest`; `limit` (1–100, default 50); `cursor` | `{items, next_cursor}`. Folder scope includes nested folders. Pages of several feeds are merged by sort key; `next_cursor` is opaque. |
| `/rss_list_items` (sync) | GET | `subscription_id`, `since=<fetched_key or empty>`, `limit` | `{items, next_since, has_more}`: items ingested after `since`, oldest-ingested first. This is the cursor client caches sync on; it is keyed on ingest time, so backdated items are never missed. |
| `/rss_get_item` | GET | `feed_id`, `sort_key` | `{item}` with the body inlined. Codes: `not_subscribed`, `unknown_item`. |
| `/rss_set_item_state` | POST | `{items: [{feed_id, sort_key, is_read?, is_favorite?}]}` (≤100) | `{updated}`. An explicit `is_read` overrides the watermark in either direction. |
| `/rss_mark_all_read` | POST | `{subscription_id}` \| `{folder_id}` \| `{}` | `{subscriptions, flipped, read_watermark}`. Writes the watermark and flips items explicitly marked unread. |
| `/rss_opml_import` | POST | `{opml: "<xml>", folder_id?}` | `{created, existing, folders_created, failed: [{url, code, Error}]}`. Additive: folders from the outline tree (reusing same-named folders under the same parent, rooted at `folder_id` when given); unknown feeds are created from the OPML's title without a probe and handed to the fetcher, so bad entries surface as feed health. Codes: `invalid_opml`, `unknown_folder` (404). 2 MB, 1000 feeds. |
| `/rss_opml_export` | GET | | `{opml, filename}`: OPML 2.0 with the folder tree as nested outlines and one `type="rss"` outline per subscription, titled with the custom title when set. |

The two day-grouped ordering modes are applied client-side from the
`published_at` values; the server orders strictly by sort key. Unread
counts are not served; clients count from their local cache using the
watermark and per-item state above.

## Operator notes

- **Seeding or reviving a feed by hand**: a feed row needs `feed_id`,
  `canonical_url`, `is_shared`, `owner_key` (`~shared` for a public
  feed), `due_shard` = `active`, a past `next_fetch_at`, and
  `subscriber_count`. Removing `due_shard` idles a feed; setting it back
  revives it.
- **Forcing a fetch**: set the row's `next_fetch_at` to a past time; the
  next tick claims it.
- **Cadence bounds**: `aws ssm put-parameter --overwrite` on the two
  `/cabal/rss/cadence_*` parameters; the worker re-reads them within five
  minutes.
- **Stuck feed**: read `last_error`, `last_status_code`, and
  `consecutive_failure_count` on the row (or the `feed` summary in
  `/rss_list_subscriptions`), then the worker log. A dead-lettered feed
  revives on the next subscribe.
- **Quiesce** pauses the schedule; nothing else RSS-specific is needed.
