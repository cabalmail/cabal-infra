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
from rss_url import FeedUrlError, redirect_target, www_variant  # pylint: disable=import-error
from rss_www import try_www  # pylint: disable=import-error

FEED_TABLE = 'cabal-rss-feed'
ITEM_TABLE = 'cabal-rss-item'
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

ddb = boto3.resource('dynamodb')
feeds = ddb.Table(FEED_TABLE)
items = ddb.Table(ITEM_TABLE)
s3 = boto3.client('s3')
ssm = boto3.client('ssm')


def handler(event, _context):
    '''Processes each queued feed (batch_size = 1 in practice).'''
    outcomes = []
    for record in event.get('Records', []):
        feed_id = json.loads(record['body'])['feed_id']
        outcome = process_feed(feed_id)
        emit_metrics(outcome)
        print(f'[rss-fetch] {feed_id} {outcome["outcome"]} status={outcome.get("status")} '
              f'new={outcome.get("new", 0)} updated={outcome.get("updated", 0)} '
              f'next={outcome.get("next_fetch_at", "")} {outcome.get("error", "")}')
        outcomes.append(outcome)
    return {'statusCode': 200, 'body': json.dumps(outcomes, default=str)}


def process_feed(feed_id):
    '''Fetches one feed and records the result; returns the outcome dict.'''
    feed = feeds.get_item(Key={'feed_id': feed_id}, ConsistentRead=True).get('Item')
    if not feed or 'due_shard' not in feed:
        return {'outcome': 'skipped', 'feed_id': feed_id}
    bounds = cadence_bounds()
    try:
        result = fetch(feed['canonical_url'], etag=feed.get('last_etag', ''),
                       last_modified=feed.get('last_modified', ''), user_agent=USER_AGENT)
    except FetchError as err:
        return www_fallback(feed, bounds) or record_failure(feed, bounds, err.reason, str(err))
    if result.status != 200:
        if result.status not in (304, 410):
            return www_fallback(feed, bounds) or record_non_200(feed, bounds, result)
        return record_non_200(feed, bounds, result)
    return ingest(feed, bounds, result)


def record_non_200(feed, bounds, result):
    '''Routes a non-200 answer: 304 is quiet, 410 is final, the rest back off.'''
    if result.status == 304:
        return record_not_modified(feed, bounds, result)
    if result.status == 410:
        return dead_letter(feed, '410 Gone', status=410)
    return record_failure(feed, bounds, f'http_{result.status}',
                          f'HTTP {result.status} from {result.url}',
                          status=result.status, retry_after=result.retry_after_seconds)


def ingest(feed, bounds, result):
    '''Parses a 200 body, upserts its items, and records success.'''
    try:
        parsed = parse_feed(result.body, result.content_type)
    except ParseError as err:
        return (www_fallback(feed, bounds)
                or record_failure(feed, bounds, 'parse', str(err), status=200))
    now = datetime.now(timezone.utc)
    counts = upsert_items(feed['feed_id'], parsed.items, now)
    follow_permanent_redirect(feed, result)
    return record_success(feed, bounds, result, parsed, counts, now)


def www_fallback(feed, bounds):
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
    counts = upsert_items(feed['feed_id'], parsed.items, now)
    # The www result's own permanent redirect is deliberately not followed
    # here: a www -> apex redirect would just ping-pong.
    return record_success(feed, bounds, result, parsed, counts, now)


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
    '''Inserts unseen items and refreshes changed ones; returns (new, updated).'''
    new = updated = 0
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
        insert_item(feed_id, item, digest, now)
        new += 1
    return new, updated


def insert_item(feed_id, item, digest, now):
    '''PutItem for a first-seen entry. published_at is fixed here forever.'''
    item_id = str(uuid.uuid4())
    published = item.published_at or now
    row = {
        'feed_id': feed_id,
        'sort_key': f'{published.isoformat()}#{item_id}',
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
    }))
