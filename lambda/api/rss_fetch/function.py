'''RSS fetch worker (docs/1.x/rss-implementation-plan.md, phase 2).

Consumes cabal-rss-fetch-queue one feed per invocation (rss_schedule is the
producer). For the feed: conditional GET against the publisher with the prior
ETag / Last-Modified through the SSRF-guarded rss_http.fetch, parse with
rss_parse, upsert items into cabal-rss-item keyed on the feed's item identity
(by_guid), then record health and the next adaptive cadence on the feed row.

Outcomes, and what they write on cabal-rss-feed:
  304            last_fetched_at, cadence widened for a quiet interval
  200            items upserted; title/site metadata refreshed; cadence
                 re-estimated from the EWMA of items/day; failures reset
  410 Gone       dead-lettered at once (due_shard removed; never fetched again
                 until an operator or a re-subscribe restores it)
  other 4xx/5xx, network, TLS, oversize, parse
                 consecutive_failure_count += 1, exponential backoff honouring
                 Retry-After; dead-lettered at DEAD_LETTER_FAILURES
  301/308 first hop
                 canonical_url follows the redirect unless another feed row
                 already owns the target, in which case redirect_conflict_url
                 is recorded for the API to merge (phase 3)

Politeness (D9): one User-Agent with a contact URL, conditional GET always,
Cache-Control max-age / Retry-After / <ttl> / sy:updatePeriod honoured as
cadence floors, one fetch per feed per claim, bounded concurrency at the
queue. Bodies over SPILL_BYTES go to the rss-cache bucket (items/ prefix) to
stay inside DynamoDB's 400 KB item limit.

Feed rules (docs/1.x/cross-media-ux-plan.md, Phase 4): after a fetch that
inserted items has recorded its success, each subscriber's feed rules are
evaluated against each new item and the outcome (flags, an explicit read
mark) is written to that subscriber's state row, so it is there before any
device opens the feed. This is best effort and comes last on purpose:
nothing in it can cost the feed its health record, fail the invocation, or
dead-letter the feed. A fetch that inserts nothing does none of it.

Not an API endpoint. See terraform/infra/modules/app/rss_fetcher.tf.
'''
import hashlib
import json
import os
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error
from rss_cadence import (backoff_minutes, next_cadence_minutes,  # pylint: disable=import-error
                         publisher_floor_minutes, update_items_per_day)
from rss_http import FetchError, fetch  # pylint: disable=import-error
from rss_parse import ParseError, parse_feed  # pylint: disable=import-error
from rss_rules import ItemText, evaluate, palette_slots, parse_rules  # pylint: disable=import-error
from rss_url import FeedUrlError, redirect_target, www_variant  # pylint: disable=import-error
from rss_www import try_www  # pylint: disable=import-error

FEED_TABLE = 'cabal-rss-feed'
ITEM_TABLE = 'cabal-rss-item'
SUBSCRIPTION_TABLE = 'cabal-rss-subscription'
STATE_TABLE = 'cabal-rss-user-item-state'
RULES_TABLE = os.environ.get('USER_RULES_TABLE_NAME', 'cabal-user-rules')
PREFERENCES_TABLE = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
CONTROL_DOMAIN = os.environ['CONTROL_DOMAIN']
CACHE_BUCKET = os.environ.get('RSS_CACHE_BUCKET', f'rss-cache.{CONTROL_DOMAIN}')
# The bot's calling card: publishers see this in their logs, and the page
# (front-door/feedbot.html) explains what it is, where it comes from, and
# how to reach the operator.
USER_AGENT = f'Cabalmail-Feedbot/1 (+https://www.{CONTROL_DOMAIN}/feedbot.html)'
DEAD_LETTER_FAILURES = int(os.environ.get('DEAD_LETTER_FAILURES', '20'))
SPILL_BYTES = int(os.environ.get('SPILL_BYTES', '300000'))
SUMMARY_CAP_BYTES = 65536
CADENCE_MIN_PARAM = '/cabal/rss/cadence_min_minutes'
CADENCE_MAX_PARAM = '/cabal/rss/cadence_max_minutes'
CADENCE_DEFAULTS = (15, 1440)
# A brand-new feed with no fetch history starts at this cadence unless its
# items' dates give a better estimate.
INITIAL_CADENCE_MINUTES = 60
MAX_ERROR_LENGTH = 500
# Feed rules run inside what is left of the invocation after the fetch and
# the upserts. They stop at whichever comes first: this many seconds of
# their own, or RULES_RESERVE_SECONDS before the Lambda's timeout, so the
# invocation always returns and the queue message is deleted. What a budget
# cuts off is logged and gets no rules; it is not retried, because on the
# next fetch those items are no longer new.
RULES_BUDGET_SECONDS = float(os.environ.get('RULES_BUDGET_SECONDS', '45'))
RULES_RESERVE_SECONDS = 15.0
RULES_BATCH = 100   # BatchGetItem's limit on keys per request
RULES_BATCH_RETRIES = 3
RULE_STATS = ('rule_subscribers', 'rule_read_calls', 'rules_evaluated', 'rule_matches',
              'rule_writes', 'rule_skips', 'rule_failures', 'rule_unfinished', 'rule_ms')

ddb = boto3.resource('dynamodb')
feeds = ddb.Table(FEED_TABLE)
items = ddb.Table(ITEM_TABLE)
# The feed rules' own DynamoDB handle. The deadline is only looked at
# between calls, so each call must be short on its own: with the SDK's
# defaults (a 60 s read timeout, ten attempts) one stalled request could
# outlast the reserve and time the invocation out. Two attempts of at most
# five seconds each stay inside RULES_RESERVE_SECONDS.
rules_ddb = boto3.resource('dynamodb', config=boto3.session.Config(
    connect_timeout=2, read_timeout=3, retries={'max_attempts': 2, 'mode': 'standard'}))
subscriptions = rules_ddb.Table(SUBSCRIPTION_TABLE)
state = rules_ddb.Table(STATE_TABLE)
preferences = rules_ddb.Table(PREFERENCES_TABLE)
s3 = boto3.client('s3')
ssm = boto3.client('ssm')


def handler(event, context):
    '''Processes each queued feed (batch_size = 1 in practice).'''
    outcomes = []
    for record in event.get('Records', []):
        feed_id = json.loads(record['body'])['feed_id']
        outcome = process_feed(feed_id, context)
        emit_metrics(outcome)
        print(f'[rss-fetch] {feed_id} {outcome["outcome"]} status={outcome.get("status")} '
              f'new={outcome.get("new", 0)} updated={outcome.get("updated", 0)} '
              f'next={outcome.get("next_fetch_at", "")} {outcome.get("error", "")}')
        if outcome.get('rule_subscribers') or outcome.get('rule_failures'):
            print(f'[rss-fetch] {feed_id} feed-rules '
                  + ' '.join(f'{name}={outcome.get(name, 0)}' for name in RULE_STATS))
        outcomes.append(outcome)
    return {'statusCode': 200, 'body': json.dumps(outcomes, default=str)}


def process_feed(feed_id, context=None):
    '''Fetches one feed and records the result; returns the outcome dict.
    `context` is the Lambda context, read only for the time left (the feed
    rules' budget); None gives the rules their own budget alone.'''
    feed = feeds.get_item(Key={'feed_id': feed_id}, ConsistentRead=True).get('Item')
    if not feed or 'due_shard' not in feed:
        return {'outcome': 'skipped', 'feed_id': feed_id}
    bounds = cadence_bounds()
    try:
        result = fetch(feed['canonical_url'], etag=feed.get('last_etag', ''),
                       last_modified=feed.get('last_modified', ''), user_agent=USER_AGENT)
    except FetchError as err:
        return (www_fallback(feed, bounds, context)
                or record_failure(feed, bounds, err.reason, str(err)))
    if result.status != 200:
        if result.status not in (304, 410):
            return www_fallback(feed, bounds, context) or record_non_200(feed, bounds, result)
        return record_non_200(feed, bounds, result)
    return ingest(feed, bounds, result, context)


def record_non_200(feed, bounds, result):
    '''Routes a non-200 answer: 304 is quiet, 410 is final, the rest back off.'''
    if result.status == 304:
        return record_not_modified(feed, bounds, result)
    if result.status == 410:
        return dead_letter(feed, '410 Gone', status=410)
    return record_failure(feed, bounds, f'http_{result.status}',
                          f'HTTP {result.status} from {result.url}',
                          status=result.status, retry_after=result.retry_after_seconds)


def ingest(feed, bounds, result, context=None):
    '''Parses a 200 body, upserts its items, records success, and then
    applies the subscribers' feed rules to what was inserted.'''
    try:
        parsed = parse_feed(result.body, result.content_type)
    except ParseError as err:
        return (www_fallback(feed, bounds, context)
                or record_failure(feed, bounds, 'parse', str(err), status=200))
    now = datetime.now(timezone.utc)
    counts, inserted = upsert_items(feed['feed_id'], parsed.items, now)
    follow_permanent_redirect(feed, result)
    outcome = record_success(feed, bounds, result, parsed, counts, now)
    outcome.update(apply_feed_rules(feed['feed_id'], inserted, context))
    return outcome


def www_fallback(feed, bounds, context=None):
    '''D1 keeps the apex host canonical, but some publishers serve the feed
    only on `www.` and either 404 the apex path or redirect every apex path
    to their front page (seen on stage's first OPML imports, 2026-09-10).
    When the canonical fetch does not yield a feed, try the `www.` form
    once; a feed there becomes the canonical URL, unless another row already
    owns it. None when there is no `www.` form to try or it did not help,
    so the caller records the original failure.'''
    found = try_www(feed['canonical_url'], USER_AGENT, fetch, parse_feed, variant_fn=www_variant)
    if found is None:
        return None
    alt, result, parsed = found
    if not move_canonical(feed, alt):
        return None
    feed['canonical_url'] = alt
    print(f'[rss-fetch] {feed["feed_id"]} apex did not serve the feed; www form does')
    now = datetime.now(timezone.utc)
    counts, inserted = upsert_items(feed['feed_id'], parsed.items, now)
    # The www result's own permanent redirect is deliberately not followed
    # here: a www -> apex redirect would just ping-pong.
    outcome = record_success(feed, bounds, result, parsed, counts, now)
    outcome.update(apply_feed_rules(feed['feed_id'], inserted, context))
    return outcome


# -- Outcome recording ---------------------------------------------------------

def record_success(feed, bounds, result, parsed, counts, now):  # pylint: disable=too-many-arguments,too-many-positional-arguments
    '''Health, metadata, and the next cadence after a 200.'''
    new, updated = counts
    previous_rate = _float(feed.get('observed_items_per_day'))
    if previous_rate is None:
        previous_rate = seed_rate(parsed.items, bounds)
    rate = update_items_per_day(previous_rate, new, hours_since(feed.get('last_fetched_at'), now))
    floor = publisher_floor_minutes(parsed.ttl_minutes, parsed.sy_period, parsed.sy_frequency,
                                    result.max_age_seconds)
    cadence = next_cadence_minutes(rate, bounds[0], bounds[1], floor)
    next_at = (now + timedelta(minutes=cadence)).isoformat()
    feeds.update_item(
        Key={'feed_id': feed['feed_id']},
        UpdateExpression=(
            'SET last_fetched_at = :now, last_attempt_at = :now, last_status_code = :status, '
            'last_etag = :etag, last_modified = :lm, consecutive_failure_count = :zero, '
            'cadence_minutes = :cadence, observed_items_per_day = :rate, next_fetch_at = :next, '
            'feed_type = :ftype, title = :title, description = :desc, site_url = :site '
            'ADD item_count :new REMOVE last_error'),
        ExpressionAttributeValues={
            ':now': now.isoformat(), ':status': 200, ':etag': result.etag,
            ':lm': result.last_modified, ':zero': 0, ':cadence': cadence,
            ':rate': _decimal(rate), ':next': next_at, ':ftype': parsed.feed_type,
            ':title': parsed.title[:512], ':desc': parsed.description[:2048],
            ':site': parsed.site_url[:2048], ':new': new,
        })
    return {'outcome': 'fetched', 'feed_id': feed['feed_id'], 'status': 200, 'new': new,
            'updated': updated, 'bytes': len(result.body), 'cadence': cadence,
            'next_fetch_at': next_at}


def record_not_modified(feed, bounds, result):
    '''A 304: nothing new, so the quiet interval widens the cadence.'''
    now = datetime.now(timezone.utc)
    rate = update_items_per_day(_float(feed.get('observed_items_per_day')), 0,
                                hours_since(feed.get('last_fetched_at'), now))
    cadence = next_cadence_minutes(rate, bounds[0], bounds[1],
                                   publisher_floor_minutes(max_age_seconds=result.max_age_seconds))
    next_at = (now + timedelta(minutes=cadence)).isoformat()
    feeds.update_item(
        Key={'feed_id': feed['feed_id']},
        UpdateExpression=(
            'SET last_fetched_at = :now, last_attempt_at = :now, last_status_code = :status, '
            'consecutive_failure_count = :zero, cadence_minutes = :cadence, '
            'observed_items_per_day = :rate, next_fetch_at = :next REMOVE last_error'),
        ExpressionAttributeValues={
            ':now': now.isoformat(), ':status': 304, ':zero': 0, ':cadence': cadence,
            ':rate': _decimal(rate), ':next': next_at,
        })
    return {'outcome': 'not_modified', 'feed_id': feed['feed_id'], 'status': 304,
            'cadence': cadence, 'next_fetch_at': next_at}


def record_failure(feed, bounds, reason, detail, status=0, retry_after=0):  # pylint: disable=too-many-arguments,too-many-positional-arguments
    '''Backs the feed off, dead-lettering it at the failure threshold.'''
    failures = int(feed.get('consecutive_failure_count', 0)) + 1
    error = f'{reason}: {detail}'[:MAX_ERROR_LENGTH]
    if failures >= DEAD_LETTER_FAILURES:
        return dead_letter(feed, error, status=status, failures=failures)
    now = datetime.now(timezone.utc)
    delay = max(backoff_minutes(failures, bounds[0], bounds[1]), (retry_after + 59) // 60)
    next_at = (now + timedelta(minutes=min(delay, bounds[1]))).isoformat()
    feeds.update_item(
        Key={'feed_id': feed['feed_id']},
        UpdateExpression=(
            'SET last_attempt_at = :now, last_status_code = :status, last_error = :error, '
            'consecutive_failure_count = :failures, next_fetch_at = :next'),
        ExpressionAttributeValues={
            ':now': now.isoformat(), ':status': status, ':error': error,
            ':failures': failures, ':next': next_at,
        })
    return {'outcome': 'failed', 'feed_id': feed['feed_id'], 'status': status,
            'error': error, 'failures': failures, 'next_fetch_at': next_at}


def dead_letter(feed, error, status=0, failures=None):
    '''Removes the feed from the by_due index; it stays readable but idle.'''
    now = datetime.now(timezone.utc).isoformat()
    feeds.update_item(
        Key={'feed_id': feed['feed_id']},
        UpdateExpression=(
            'SET last_attempt_at = :now, last_status_code = :status, last_error = :error, '
            'consecutive_failure_count = :failures, dead_lettered_at = :now REMOVE due_shard'),
        ExpressionAttributeValues={
            ':now': now, ':status': status, ':error': error[:MAX_ERROR_LENGTH],
            ':failures': failures if failures is not None
            else int(feed.get('consecutive_failure_count', 0)),
        })
    return {'outcome': 'dead_lettered', 'feed_id': feed['feed_id'], 'status': status,
            'error': error}


def follow_permanent_redirect(feed, result):
    '''Moves canonical_url to a 301/308 target when no other row owns it.'''
    if not result.permanent_redirect_to:
        return
    try:
        target = redirect_target(feed['canonical_url'], result.permanent_redirect_to)
    except FeedUrlError as err:
        print(f'[rss-fetch] {feed["feed_id"]} ignoring redirect target: {err}')
        return
    if target == feed['canonical_url']:
        return
    if move_canonical(feed, target):
        feed['canonical_url'] = target


def move_canonical(feed, target):
    '''Points the row at `target` unless another shared row already owns
    it, in which case the conflict is recorded for the operator and False
    returned (the row keeps its URL and its failure).'''
    owner = feeds.query(IndexName='by_canonical',
                        KeyConditionExpression=Key('canonical_url').eq(target)
                        & Key('owner_key').eq(feed.get('owner_key', '~shared')),
                        Limit=1).get('Items', [])
    if owner and owner[0]['feed_id'] != feed['feed_id']:
        feeds.update_item(Key={'feed_id': feed['feed_id']},
                          UpdateExpression='SET redirect_conflict_url = :url',
                          ExpressionAttributeValues={':url': target})
        print(f'[rss-fetch] {feed["feed_id"]} redirects to {target}, owned by '
              f'{owner[0]["feed_id"]}; recorded, not followed')
        return False
    feeds.update_item(Key={'feed_id': feed['feed_id']},
                      UpdateExpression='SET canonical_url = :url REMOVE redirect_conflict_url',
                      ExpressionAttributeValues={':url': target})
    print(f'[rss-fetch] {feed["feed_id"]} canonical_url -> {target}')
    return True


# -- Items -------------------------------------------------------------------

def upsert_items(feed_id, parsed_items, now):
    '''Inserts unseen items and refreshes changed ones. Returns
    ((new, updated), inserted): the counts, and each inserted item as
    (sort_key, parsed item) for the feed rules, which apply to an item
    once, when it is first seen, and never to a refresh.'''
    updated = 0
    inserted = []
    for item in parsed_items:
        digest = content_hash(item)
        existing = items.query(
            IndexName='by_guid',
            KeyConditionExpression=Key('feed_id').eq(feed_id) & Key('guid').eq(item.guid),
            Limit=1).get('Items', [])
        if existing:
            if refresh_item(feed_id, existing[0]['sort_key'], item, digest, now):
                updated += 1
            continue
        inserted.append((insert_item(feed_id, item, digest, now), item))
    return (len(inserted), updated), inserted


def insert_item(feed_id, item, digest, now):
    '''PutItem for a first-seen entry; returns its sort key. published_at
    is fixed here forever.'''
    item_id = str(uuid.uuid4())
    published = item.published_at or now
    sort_key = f'{published.isoformat()}#{item_id}'
    row = {
        'feed_id': feed_id,
        'sort_key': sort_key,
        'item_id': item_id,
        'guid': item.guid,
        'title': item.title[:1024],
        'author': item.author[:256],
        'url': item.url[:2048],
        'published_at': published.isoformat(),
        'updated_at': (item.updated_at or published).isoformat(),
        'fetched_at': now.isoformat(),
        'fetched_key': f'{now.isoformat()}#{item_id}',
        'content_hash': digest,
    }
    row.update(body_attributes(feed_id, item_id, item))
    items.put_item(Item={k: v for k, v in row.items() if v not in ('', None)},
                   ConditionExpression='attribute_not_exists(sort_key)')
    return sort_key


def refresh_item(feed_id, sort_key, item, digest, now):  # pylint: disable=too-many-arguments,too-many-positional-arguments
    '''Rewrites a known entry's mutable attributes when its content changed.

    Reads the stored hash first: a re-published-but-identical entry (the
    common case on every fetch) costs one GetItem and no write.'''
    key = {'feed_id': feed_id, 'sort_key': sort_key}
    current = items.get_item(Key=key, ProjectionExpression='content_hash, item_id').get('Item', {})
    if current.get('content_hash') == digest:
        return False
    item_id = current.get('item_id') or sort_key.split('#', 1)[-1]
    values = {':title': item.title[:1024], ':author': item.author[:256],
              ':url': item.url[:2048], ':hash': digest,
              ':updated': (item.updated_at or now).isoformat()}
    sets = ['title = :title', 'author = :author', '#u = :url', 'content_hash = :hash',
            'updated_at = :updated']
    removes = []
    for name, value in body_attributes(feed_id, item_id, item).items():
        values[f':{name}'] = value
        sets.append(f'{name} = :{name}')
    for name in ('summary_html', 'content_html', 'content_s3_key'):
        if f':{name}' not in values:
            removes.append(name)
    expression = 'SET ' + ', '.join(sets) + (' REMOVE ' + ', '.join(removes) if removes else '')
    items.update_item(Key=key, UpdateExpression=expression,
                      ExpressionAttributeNames={'#u': 'url'},
                      ExpressionAttributeValues=values)
    return True


def body_attributes(feed_id, item_id, item):
    '''summary_html / content_html, or content_s3_key when the body is too
    large for a DynamoDB row. Empty attributes are omitted.'''
    attrs = {}
    summary = item.summary_html or ''
    if len(summary.encode('utf-8')) > SUMMARY_CAP_BYTES:
        summary = summary.encode('utf-8')[:SUMMARY_CAP_BYTES].decode('utf-8', 'ignore')
    if summary:
        attrs['summary_html'] = summary
    content = item.content_html or ''
    if not content:
        return attrs
    if len(content.encode('utf-8')) > SPILL_BYTES:
        key = f'items/{feed_id}/{item_id}'
        s3.put_object(Bucket=CACHE_BUCKET, Key=key, Body=content.encode('utf-8'),
                      ContentType='text/html; charset=utf-8')
        attrs['content_s3_key'] = key
    else:
        attrs['content_html'] = content
    return attrs


def content_hash(item):
    '''Stable digest of everything refresh_item would rewrite.'''
    digest = hashlib.sha256()
    for part in (item.title, item.author, item.url, item.summary_html, item.content_html):
        digest.update((part or '').encode('utf-8', 'replace'))
        digest.update(b'\x00')
    return digest.hexdigest()


# -- Feed rules ----------------------------------------------------------------

def apply_feed_rules(feed_id, inserted, context=None):
    '''Evaluates every subscriber's feed rules against the items this fetch
    inserted and writes what they decide to the subscribers' state rows.
    Returns the RULE_STATS counters for the outcome dict.

    Never raises: the fetch has already been recorded as a success, and a
    rules failure is logged and counted (rule_failures) and nothing else. A
    failure reading one subscriber's palette or writing one state row stops
    that subscriber alone.'''
    stats = dict.fromkeys(RULE_STATS, 0)
    if not inserted:
        return stats
    started = time.monotonic()
    deadline = rules_deadline(started, context)
    try:
        run_feed_rules(feed_id, inserted, deadline, stats)
    except Exception as err:  # pylint: disable=broad-exception-caught
        stats['rule_failures'] += 1
        print(f'[rss-fetch] {feed_id} feed rules not applied: {err!r}')
    stats['rule_ms'] = int((time.monotonic() - started) * 1000)
    return stats


def rules_deadline(started, context):
    '''time.monotonic() at which the feed rules must stop (see
    RULES_BUDGET_SECONDS).'''
    deadline = started + RULES_BUDGET_SECONDS
    if context is not None:
        left = context.get_remaining_time_in_millis() / 1000.0
        deadline = min(deadline, started + left - RULES_RESERVE_SECONDS)
    return deadline


def run_feed_rules(feed_id, inserted, deadline, stats):
    '''apply_feed_rules without the safety net.'''
    if time.monotonic() >= deadline:
        # The fetch itself used the time. Not even the lookups are made;
        # how many evaluations that cost is not known without them.
        stats['rule_unfinished'] = len(inserted)
        print(f'[rss-fetch] {feed_id} feed rules not started: no time left')
        return
    subscribers = feed_subscribers(feed_id, deadline, stats)
    stats['rule_subscribers'] = len(subscribers)
    if not subscribers:
        return
    rules_by_user = subscriber_rules(sorted(subscribers), deadline, stats)
    # Only the subscribers who have rules; a feed whose subscribers have
    # none stops here and never parses an item's markup.
    work = [(user, subscribers[user], rules) for user, rules in sorted(rules_by_user.items())]
    if not work:
        return
    texts = [(sort_key, ItemText(item.title, item.author, item.summary_html, item.content_html))
             for sort_key, item in inserted]
    for position, subscriber in enumerate(work):
        try:
            finished = apply_subscriber_rules(subscriber, feed_id, texts, deadline, stats)
        except Exception as err:  # pylint: disable=broad-exception-caught
            # The message names the feed and the error, never the user:
            # these lines go to CloudWatch.
            stats['rule_failures'] += 1
            print(f'[rss-fetch] {feed_id} feed rules failed for one subscriber: {err!r}')
            continue
        if not finished:
            stats['rule_unfinished'] += sum(
                len(texts) * len(rules) for _, _, rules in work[position + 1:])
            print(f'[rss-fetch] {feed_id} feed rules out of time; '
                  f'{stats["rule_unfinished"]} rule evaluations not made')
            return


def feed_subscribers(feed_id, deadline, stats):
    '''{user: subscription_id} for every subscriber of the feed, from the
    plain by_feed index (keys only: it projects exactly these). Raises
    TimeoutError if the deadline passes between pages: half a subscriber
    list is not acted on.'''
    found = {}
    kwargs = {'IndexName': 'by_feed', 'KeyConditionExpression': Key('feed_id').eq(feed_id)}
    while True:
        response = subscriptions.query(**kwargs)
        stats['rule_read_calls'] += 1
        for row in response.get('Items', []):
            found[row['user']] = row['subscription_id']
        if 'LastEvaluatedKey' not in response:
            return found
        if time.monotonic() >= deadline:
            raise TimeoutError('out of time listing subscribers')
        kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']


def subscriber_rules(users, deadline, stats):
    '''{user: enabled feed rules} for the users who have any. One
    BatchGetItem per RULES_BATCH users, projecting only the feed rules: a
    rules row also carries the mail rules, which this worker has no use
    for. Keys DynamoDB leaves unprocessed are asked for again a few times
    and then given up on, which costs those users this fetch's rules; so
    does the deadline passing between batches, for the batches not read.'''
    found = {}
    for start in range(0, len(users), RULES_BATCH):
        if start and time.monotonic() >= deadline:
            stats['rule_failures'] += 1
            print('[rss-fetch] feed rules: out of time reading rules rows; '
                  f'{len(users) - start} subscribers not read')
            break
        request = {RULES_TABLE: {
            'Keys': [{'user': user} for user in users[start:start + RULES_BATCH]],
            'ProjectionExpression': '#u, feedRules',
            'ExpressionAttributeNames': {'#u': 'user'}}}
        for _ in range(RULES_BATCH_RETRIES):
            response = rules_ddb.batch_get_item(RequestItems=request)
            stats['rule_read_calls'] += 1
            for row in response.get('Responses', {}).get(RULES_TABLE, []):
                rules = parse_rules(row.get('feedRules'))
                if rules:
                    found[row['user']] = rules
            request = response.get('UnprocessedKeys') or {}
            if not request:
                break
        else:
            stats['rule_failures'] += 1
            print('[rss-fetch] feed rules: some rules rows stayed unprocessed; skipped')
    return found


def apply_subscriber_rules(subscriber, feed_id, texts, deadline, stats):
    '''Evaluates one subscriber's rules against each inserted item and
    writes each outcome. `subscriber` is (user, subscription_id, rules).
    Returns False when the deadline came first, having counted what was
    left in stats['rule_unfinished'].'''
    user, subscription_id, rules = subscriber
    cache = []

    def palette():
        # Read once per subscriber, and only if a matching rule sets a
        # custom flag. None (unreadable) makes such rules skip.
        if not cache:
            stats['rule_read_calls'] += 1
            cache.append(read_palette(user, feed_id))
        return cache[0]

    for index, (sort_key, text) in enumerate(texts):
        if time.monotonic() >= deadline:
            stats['rule_unfinished'] += (len(texts) - index) * len(rules)
            return False
        outcome = evaluate(rules, subscription_id, text, palette)
        stats['rules_evaluated'] += len(rules)
        stats['rule_skips'] += outcome.skipped
        if outcome:
            write_rule_outcome(f'{user}#{feed_id}', sort_key, outcome)
            stats['rule_matches'] += 1
            stats['rule_writes'] += 1
    return True


def read_palette(user, feed_id):
    '''The slots in a subscriber's flag palette, or None when it cannot be
    read (rules that set a custom flag then skip; the rest still apply).'''
    try:
        row = preferences.get_item(
            Key={'user': user}, ProjectionExpression='#a.#p',
            ExpressionAttributeNames={'#a': 'app', '#p': 'flag_palette'}).get('Item', {})
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[rss-fetch] {feed_id} feed rules: a palette was unreadable: {err!r}')
        return None
    return palette_slots((row.get('app') or {}).get('flag_palette', '[]'))


def write_rule_outcome(user_feed, sort_key, outcome):
    '''One UpdateItem on the subscriber's state row for the item, in the
    shape /rss_set_item_state writes: the same stamps (so the state sync's
    by_updated index carries it to every device), favorite_key beside
    is_favorite (the sparse favorites index), and flags by ADD.

    Everything here only adds, except the read mark, and that is written
    only where the row has none: the item was inserted moments ago, but a
    device that already fetched it may have marked it unread by hand, and
    a rule must not overrule the person.

    The stamp is the time of this write, not of the fetch. A device's
    state-sync cursor trails the clock by only a few seconds
    (rss_list_items, STATE_SYNC_OVERLAP), and a row stamped with the
    fetch's time, which can be much older by now, would land behind a
    cursor that has already passed it and never reach that device.'''
    now = datetime.now(timezone.utc).isoformat()
    item_id = sort_key.split('#', 1)[-1]
    sets = ['item_id = if_not_exists(item_id, :item_id)', 'updated_at = :now',
            'updated_key = :ukey']
    values = {':item_id': item_id, ':now': now, ':ukey': f'{now}#{item_id}'}
    if outcome.mark_read:
        sets.append('is_read = if_not_exists(is_read, :read)')
        values[':read'] = True
    if outcome.flag:
        sets += ['is_favorite = :fav', 'favorite_key = :fkey']
        values[':fav'] = True
        values[':fkey'] = sort_key
    expression = 'SET ' + ', '.join(sets)
    if outcome.flags:
        expression += ' ADD flags :add'
        values[':add'] = set(outcome.flags)
    state.update_item(Key={'user_feed': user_feed, 'sort_key': sort_key},
                      UpdateExpression=expression, ExpressionAttributeValues=values)


# -- Cadence helpers -----------------------------------------------------------

def seed_rate(parsed_items, bounds):
    '''Items/day for a feed with no history, from the spread of its items'
    dates; falls back to the rate that yields INITIAL_CADENCE_MINUTES.'''
    dates = sorted(i.published_at for i in parsed_items if i.published_at)
    if len(dates) >= 2:
        span_days = max((dates[-1] - dates[0]).total_seconds() / 86400.0, 1 / 24.0)
        return (len(dates) - 1) / span_days
    return 1440.0 / max(INITIAL_CADENCE_MINUTES, bounds[0])


def hours_since(iso, now):
    '''Hours between an ISO-8601 timestamp and `now`, or None if absent.'''
    if not iso:
        return None
    try:
        then = datetime.fromisoformat(str(iso))
    except ValueError:
        return None
    if then.tzinfo is None:
        then = then.replace(tzinfo=timezone.utc)
    return (now - then).total_seconds() / 3600.0


_bounds_cache = {'value': None, 'read_at': 0.0}


def cadence_bounds():
    '''(min_minutes, max_minutes) from SSM, cached for five minutes per
    container; defaults when the parameters are absent or unreadable.'''
    if _bounds_cache['value'] and time.monotonic() - _bounds_cache['read_at'] < 300:
        return _bounds_cache['value']
    lower, upper = CADENCE_DEFAULTS
    try:
        response = ssm.get_parameters(Names=[CADENCE_MIN_PARAM, CADENCE_MAX_PARAM],
                                      WithDecryption=True)
        values = {p['Name']: p['Value'] for p in response.get('Parameters', [])}
        lower = int(values.get(CADENCE_MIN_PARAM, lower))
        upper = int(values.get(CADENCE_MAX_PARAM, upper))
    except (ClientError, ValueError, KeyError) as err:
        print(f'[rss-fetch] cadence bounds unreadable, using defaults: {err}')
    lower = max(1, lower)
    upper = max(lower, upper)
    _bounds_cache.update(value=(lower, upper), read_at=time.monotonic())
    return _bounds_cache['value']


def _float(value):
    return float(value) if value is not None else None


def _decimal(value):
    return Decimal(str(round(float(value), 4)))


# -- Metrics -------------------------------------------------------------------

def emit_metrics(outcome):
    '''CloudWatch EMF line per feed: free metrics, no API call (as push_dispatch).'''
    kind = outcome['outcome']
    print(json.dumps({
        '_aws': {
            'Timestamp': int(time.time() * 1000),
            'CloudWatchMetrics': [{
                'Namespace': 'Cabal/Rss',
                'Dimensions': [[]],
                'Metrics': [
                    {'Name': 'Fetched', 'Unit': 'Count'},
                    {'Name': 'NotModified', 'Unit': 'Count'},
                    {'Name': 'Failed', 'Unit': 'Count'},
                    {'Name': 'DeadLettered', 'Unit': 'Count'},
                    {'Name': 'ItemsNew', 'Unit': 'Count'},
                    {'Name': 'ItemsUpdated', 'Unit': 'Count'},
                    {'Name': 'BytesFetched', 'Unit': 'Bytes'},
                    {'Name': 'RulesEvaluated', 'Unit': 'Count'},
                    {'Name': 'RuleMatches', 'Unit': 'Count'},
                    {'Name': 'RuleFailures', 'Unit': 'Count'},
                ],
            }],
        },
        'Fetched': int(kind == 'fetched'),
        'NotModified': int(kind == 'not_modified'),
        'Failed': int(kind == 'failed'),
        'DeadLettered': int(kind == 'dead_lettered'),
        'ItemsNew': outcome.get('new', 0),
        'ItemsUpdated': outcome.get('updated', 0),
        'BytesFetched': outcome.get('bytes', 0),
        'RulesEvaluated': outcome.get('rules_evaluated', 0),
        'RuleMatches': outcome.get('rule_matches', 0),
        'RuleFailures': outcome.get('rule_failures', 0),
    }))
