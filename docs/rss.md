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
  registrable apex (Public Suffix List) - unless the apex turns out not to
  serve the feed: when the fetcher or the subscribe probe gets a 404, a
  non-feed body, or a redirect to the front page from an apex host, it
  tries the `www.` form once and, if that parses as a feed, makes it the
  canonical URL (`rss_url.www_variant`, `rss_fetch.www_fallback`,
  `rss_subscribe_core.fetch_probe`); query parameters are sorted,
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
  indexed. Every state write also sets `updated_key`
  (`<updated_at>#<item_id>`), and the `by_updated` index over it is what
  carries a mark made on one device to the others (the state-sync form of
  `/rss_list_items` below); item ingest time does not move when state
  does, so the item sync alone never re-delivers a changed item.

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

### Feed rules at ingest

When a fetch inserts at least one item, the worker applies the
subscribers' feed rules to the new items (the rules themselves are
described in [mail-rules.md](mail-rules.md), "Feed rules"). A fetch that
inserts nothing, which is most of them, does none of this.

1. One query on the subscription table's plain `by_feed` index
   (`feed_id`, then `user`; keys only) lists the feed's subscribers.
2. Their rules rows are read from `cabal-user-rules` in batches of 100,
   asking only for `feedRules`.
3. For each subscriber who has enabled feed rules, each new item is
   evaluated. A subscriber's flag palette is read from
   `cabal-user-preferences` once, and only if a matching rule of theirs
   sets a custom flag.
4. Each outcome is one `UpdateItem` on the subscriber's state row for
   the item, in the shape `/rss_set_item_state` writes (`is_read`,
   `is_favorite` with `favorite_key`, `flags` by `ADD`, and the
   `updated_key` stamp), so the state sync carries it to every device.
   The stamp is the time of the write, not of the fetch, so it cannot
   land behind a device's sync cursor. `is_read` is written only where
   the row has none, so a mark the user made by hand stands.

This runs after the fetch has recorded its success on the feed row, and
it is best effort throughout: a refused or failed lookup is logged and
counted and the fetch still succeeds, one subscriber's failed write does
not stop the next subscriber's, and nothing here can back a feed off or
dead-letter it. It also has a time budget (`RULES_BUDGET_SECONDS`,
default 45, and never past fifteen seconds before the function's
timeout), and its DynamoDB calls use short timeouts and two attempts, so
one stalled request cannot outlast that reserve. Evaluations the budget
cuts off are logged and not retried, because on the next fetch those
items are no longer new; for the same reason, items inserted by a fetch
that then failed before recording its success get no rules.

Two races are accepted. A feed's very first fetch is queued as its
first subscriber subscribes, and can list subscribers before that row
is visible, in which case the backlog gets no rules. And a subscriber
who unsubscribes while the pass is running can be left with state rows
for the feed, which they would see again only by re-subscribing while
the feed still has another subscriber.

A fetch that had subscribers to consider logs one extra line:

```
[rss-fetch] <feed_id> feed-rules rule_subscribers=3 rule_read_calls=2 rules_evaluated=6 rule_matches=2 rule_writes=2 rule_skips=0 rule_failures=0 rule_unfinished=0 rule_ms=41
```

`rule_read_calls` counts DynamoDB read requests (the index query's
pages, the rules batches and any palette reads), `rule_skips` rules that
matched but named a custom flag no longer in the palette, and
`rule_unfinished` rule evaluations the time budget cut off (or, when
there was no time even to list subscribers, the number of new items). No
line names a subscriber.

Metrics are CloudWatch EMF under `Cabal/Rss` (`FeedsDue`, `FeedsClaimed`,
`FeedsEnqueued`, `Fetched`, `NotModified`, `Failed`, `DeadLettered`,
`ItemsNew`, `ItemsUpdated`, `BytesFetched`, and for feed rules
`RulesEvaluated`, `RuleMatches`, `RuleFailures`); logs at
`/cabal/lambda/rss_schedule` and `/cabal/lambda/rss_fetch`, prefixed
`[rss-schedule]` / `[rss-fetch]`. Undeliverable fetches land in
`cabal-rss-fetch-dlq`.

## API

Flat endpoints on the existing gateway, Cognito-authorized like the rest.
Reads are `GET` with query parameters; writes carry a JSON body. Errors
are `{"Error": "<message>", "code": "<token>"}`, with a further field
where a code below names one; the codes below are the stable part. Every response field listed here is part of the
compatibility contract ([`compatibility.md`](./compatibility.md)); new
fields may appear and clients must ignore unknown ones.

### Objects

**subscription**: `subscription_id`, `feed_id`, `folder_id` (empty =
root), `custom_title`, `ordering_mode` (`newest_first` | `oldest_first` |
`newest_day_oldest_within` | `oldest_day_newest_within`),
`default_open_mode` (`summary` | `article`), `default_styling` (`reader`
| `native`), `default_remote_content` (`inherit` | `show` | `hide`; `inherit`
defers to the client's global remote-content preference, the others
override it for this feed), `default_filter` (`all` | `unread` |
`favorite`; the filter pill the feed's list opens on, `unread` until the
user picks another), `notifications_enabled`, `credentials_scheme`,
`read_watermark`, `data_store_uuid` (the per-subscription identifier the
clients key their isolated web-view storage on), `created_at`, and
`feed`.

**feed** (summary): `feed_id`, `canonical_url`, `feed_type` (`rss` |
`atom` | `json`), `title`, `description`, `site_url`, `item_count`,
`last_fetched_at`, `last_attempt_at`, `last_status_code`, `last_error`,
`consecutive_failure_count`, `cadence_minutes`, `next_fetch_at`,
`dead_lettered`.

**folder**: `folder_id`, `parent_folder_id` (empty = root), `name`,
`display_order`, `default_filter` (the pill the folder's list opens on;
same values and default as a subscription's), `ordering_mode` (the order
the folder's own merged list opens in; same values and default as a
subscription's, and it does not change the order of the feeds inside).

**item**: `feed_id`, `subscription_id`, `item_id`, `sort_key` (the item's
key; opaque, pass it back), `guid`, `title`, `author`, `url`,
`published_at`, `updated_at`, `fetched_at`, `fetched_key` (the sync
cursor), `summary_html`, `content_html` (spilled bodies inlined),
`is_read`, `is_read_explicit` (whether `is_read` is the user's own mark
rather than the watermark rule; a client applying its own watermark must
exempt explicit marks), `is_favorite`, `flags`.

**state** (state sync only): `feed_id`, `sort_key`, `item_id`,
`is_read`, `is_read_explicit`, `is_favorite`, `flags`, `updated_at`.

`flags` is the item's custom flags: a sorted list of the keyword slots
of the user's flag palette (`cabal-flag-01` .. `cabal-flag-20`, the
`flag_palette` synced preference), empty when it has none. It is the
same vocabulary mail keywords use, so one palette entry names and
colours a flag on both. The system flag is never in the list: on a feed
item it is `is_favorite`. A slot stays in the list when its palette
entry is deleted. The Apple apps then show it by its slot id until it
is taken off, as they do a mail keyword whose flag was deleted.

Display preferences on a subscription or folder are stored by the
server and applied by the client; the server never reorders or filters
items by them except as documented under `/rss_list_items`. The
all-feeds list has no row of its own, so its sticky pill is the
`filter:feeds:all` key of the synced preferences `app` map
(`/set_preferences`), and its sticky order is the `order:feeds:all` key
(one of the `ordering_mode` values).

### Endpoints

| Endpoint | Method | Request | Response |
|---|---|---|---|
| `/rss_subscribe` | POST | `{url, folder_id?}` | `{subscription, existing}`. Reuses the shared feed for a known canonical URL; otherwise fetches the document once (autodiscovering the feed a web page advertises), creates the feed, and hands it to the fetcher immediately. Idempotent per user and feed. Codes: `invalid_url`, `not_https`, `unreachable`, `not_a_feed`, `needs_credentials`, `feed_gone`, `publisher_error`, `unknown_folder` (404). |
| `/rss_unsubscribe` | POST | `{subscription_id}` | `{subscription_id, feed_id, feed_purged}`. Deletes the caller's state for the feed; purges the feed when no subscribers remain. The subscription's delete is conditional: of two overlapping calls for one subscription, one succeeds and the other answers like a repeat. Code: `unknown_subscription` (404). |
| `/rss_update_subscription` | PUT | `{subscription_id, custom_title?, folder_id?, ordering_mode?, default_open_mode?, default_styling?, default_remote_content?, default_filter?, notifications_enabled?}` | `{subscription}`. Codes: `invalid_<field>`, `unknown_folder`, `nothing_to_update`. |
| `/rss_list_subscriptions` | GET | | `{folders, subscriptions}`, each subscription with its `feed` summary. |
| `/rss_new_folder` | POST | `{name, parent_folder_id?, display_order?}` | `{folder}` |
| `/rss_update_folder` | PUT | `{folder_id, name?, parent_folder_id? ("" = root), display_order?, default_filter?, ordering_mode?}` | `{folder}`. Codes: `cyclic_folder` when moved under itself, `invalid_<field>`, `nothing_to_update`. |
| `/rss_delete_folder` | POST | `{folder_id}` | `{folder_id, moved_subscriptions, moved_folders, parent_folder_id}`. Contents move to the parent, never deleted. |
| `/rss_list_items` | GET | `subscription_id` \| `folder_id` \| neither (all); `filter=all\|unread\|favorite`; `order=newest\|oldest`; `limit` (1–100, default 50); `cursor` | `{items, next_cursor}`. Folder scope includes nested folders. Pages of several feeds are merged by sort key; `next_cursor` is opaque. |
| `/rss_list_items` (sync) | GET | `subscription_id`, `since=<fetched_key or empty>`, `limit` | `{items, next_since, has_more}`: items ingested after `since`, oldest-ingested first. This is the cursor client caches sync on; it is keyed on ingest time, so backdated items are never missed. |
| `/rss_list_items` (state sync) | GET | `subscription_id`, `state_since=<opaque or empty>`, `limit` | `{states, next_state_since, has_more}`: the caller's state rows for the feed changed since the cursor. An empty cursor first pulls the whole partition in `sort_key` order (a fresh or pre-existing cache catching up), then the cursor moves to the `by_updated` index and each call returns only what changed. The cursor trails "now" by a few seconds so a late commit is not stepped past; a row on a boundary is delivered twice, and applying state is idempotent. |
| `/rss_get_item` | GET | `feed_id`, `sort_key` | `{item}` with the body inlined. Codes: `not_subscribed`, `unknown_item`. |
| `/rss_set_item_state` | POST | `{items: [{feed_id, sort_key, is_read?, is_favorite?, add_flags?, remove_flags?}]}` (≤100) | `{updated}`: how many entries changed something. An explicit `is_read` overrides the watermark in either direction. `add_flags` and `remove_flags` are lists of palette slots, added to and removed from the item's `flags` one slot at a time, so two devices changing different flags of one item both take effect; an empty or absent list changes nothing. Adding needs a slot that is in the caller's palette; an entry's `enabled` is deprecated and not read. Removing needs only a well-formed slot, so a flag whose entry is gone can still be cleared. Every entry's flags are checked before anything is written, so a call refused with one of the flag codes has changed nothing. Codes: `invalid_flags` (not a list of slots; the system flag is `is_favorite`, not a slot), `flag_conflict` (a slot in both lists of one entry), `flag_not_in_palette` (adding a slot that is not in the palette); the last two carry `flags`, the sorted slots refused. `palette_unavailable` (500) when the palette cannot be read while adding. Also `missing_items`, `too_many_items`, `invalid_item`, `not_subscribed` (404), which stop the call at that entry with the earlier entries already written. |
| `/rss_mark_all_read` | POST | `{subscription_id}` \| `{folder_id}` \| `{}`, each with an optional `watermark` (ISO 8601) | `{subscriptions, flipped, read_watermark}`. Writes the watermark (the client's tap time when sent, clamped to now; otherwise now; never moved backwards) and flips items published up to it that were explicitly marked unread. A client replaying a queued mark-all-read sends the tap time so items that arrived in between stay unread. Code: `invalid_watermark`. |
| `/rss_opml_import` | POST | `{opml: "<xml>", folder_id?}` | `{created, existing, folders_created, failed: [{url, code, Error}]}`. Additive: folders from the outline tree (reusing same-named folders under the same parent, rooted at `folder_id` when given); unknown feeds are created from the OPML's title without a probe and handed to the fetcher, so bad entries surface as feed health. Codes: `invalid_opml`, `unknown_folder` (404). 2 MB, 1000 feeds. |
| `/rss_opml_export` | GET | | `{opml, filename}`: OPML 2.0 with the folder tree as nested outlines and one `type="rss"` outline per subscription, titled with the custom title when set. |

The two day-grouped ordering modes are applied client-side from the
`published_at` values; the server orders strictly by sort key. Unread
counts are not served; clients count from their local cache using the
watermark and per-item state above.

`/rss_update_subscription`, `/rss_mark_all_read` and `/rss_delete_folder`
change a subscription only if it still exists when they write. When the
write finds it gone, `/rss_update_subscription` answers 404
`unknown_subscription`, as it does for any subscription the caller does
not have, and the other two skip it and leave it out of their counts.
Mark-all-read likewise flips only the explicit unread marks that still
exist when it writes.

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
- **A feed rule did not fire**: find the fetch that inserted the item in
  the worker log and read its `feed-rules` line. `rule_failures` above
  zero means a lookup or a write failed (the line before it has the
  error); `rule_skips` means a matching rule named a custom flag that is
  no longer in the subscriber's palette; `rule_unfinished` means the
  time budget ran out. No `feed-rules` line at all means the fetch found
  no subscriber, or inserted nothing: rules never apply to an item the
  feed already held.
- **Quiesce** pauses the schedule; nothing else RSS-specific is needed.
