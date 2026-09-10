'''The subscribe path shared by /rss_subscribe and /rss_opml_import
(docs/1.x/rss-implementation-plan.md, phases 3 and 4).

resolve_feed() turns a user-supplied URL into a shared feed row: an
existing one by exact canonical URL, or a new one. In `probe` mode
(interactive subscribe) the document is fetched once to prove it is a feed
and learn its title, a web page is autodiscovered, and a permanent redirect
is followed to its canonical target before the lookup - so a publisher
that answers /feed with a 301 to /feed/ ends up on the one row the other
form already has. In no-probe mode (OPML import, where dozens of feeds must
fit one request) the row is created from the OPML's own title and handed to
the fetch worker, which validates it; a bad entry surfaces as feed health.

subscribe() then creates the caller's subscription row (or returns the
existing one) and counts the subscriber, reviving a dead-lettered feed.
'''
import json
import os
import uuid
from datetime import datetime, timedelta, timezone
import boto3  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error
from rss_api import (ApiError, ROOT_FOLDER, SHARED_OWNER, feeds, folder_key,  # pylint: disable=import-error
                     folders, list_subscriptions, subscriptions)
from rss_discover import discover_feed_links, looks_like_html  # pylint: disable=import-error
from rss_http import FetchError, fetch  # pylint: disable=import-error
from rss_parse import ParseError, ParsedFeed, parse_feed  # pylint: disable=import-error
from rss_url import FeedUrlError, normalize_feed_url  # pylint: disable=import-error

CONTROL_DOMAIN = os.environ.get('CONTROL_DOMAIN', '')
USER_AGENT = f'Cabalmail-Feedbot/1 (+https://www.{CONTROL_DOMAIN}/feedbot.html)'
FETCH_QUEUE_URL = os.environ.get('RSS_FETCH_QUEUE_URL', '')
# Same lease as rss_schedule: the enqueue IS the claim, so the scheduler
# leaves the feed alone until the worker sets a real next_fetch_at.
CLAIM_LEASE_MINUTES = 30
INITIAL_CADENCE_MINUTES = 60

sqs = boto3.client('sqs')


def canonicalize(url):
    '''rss_url.normalize_feed_url mapped to the API error.'''
    try:
        return normalize_feed_url(url or '')
    except FeedUrlError as err:
        raise ApiError(400, 'invalid_url', str(err)) from err


def find_shared_feed(canonical):
    '''The shared feed row for exactly this canonical URL, if any.'''
    rows = feeds.query(IndexName='by_canonical',
                       KeyConditionExpression=Key('canonical_url').eq(canonical)
                       & Key('owner_key').eq(SHARED_OWNER),
                       Limit=1).get('Items', [])
    if not rows:
        return None
    return feeds.get_item(Key={'feed_id': rows[0]['feed_id']}).get('Item')


def resolve_feed(url, probe=True, title=''):
    '''The shared feed row for `url`, created if needed (see module doc).'''
    canonical = canonicalize(url)
    feed = find_shared_feed(canonical)
    if feed:
        return feed
    if probe:
        canonical, parsed = probe_feed(canonical, url)
        feed = find_shared_feed(canonical)   # redirect/autodiscovery may land on a known feed
        if feed:
            return feed
    else:
        parsed = ParsedFeed(feed_type='', title=str(title or '')[:512])
    return create_feed(canonical, parsed)


def create_feed(canonical, parsed):
    '''Writes the shared row and hands it to the worker.'''
    now = datetime.now(timezone.utc)
    row = {
        'feed_id': str(uuid.uuid4()),
        'canonical_url': canonical,
        'is_shared': True,
        'owner_key': SHARED_OWNER,
        'due_shard': 'active',
        'next_fetch_at': (now + timedelta(minutes=CLAIM_LEASE_MINUTES)).isoformat(),
        'subscriber_count': 0,
        'item_count': 0,
        'consecutive_failure_count': 0,
        'cadence_minutes': INITIAL_CADENCE_MINUTES,
        'feed_type': parsed.feed_type,
        'title': parsed.title[:512],
        'description': parsed.description[:2048],
        'site_url': parsed.site_url[:2048],
        'created_at': now.isoformat(),
    }
    feeds.put_item(Item={k: v for k, v in row.items() if v != ''},
                   ConditionExpression='attribute_not_exists(feed_id)')
    enqueue(row['feed_id'], now)
    return row


def probe_feed(canonical, original_url):
    '''(canonical_url, ParsedFeed) for the URL, its permanent-redirect
    target, or the feed its web page advertises.'''
    result = guarded_fetch(canonical, original_url)
    if result.permanent_redirect_to:
        canonical = canonicalize(result.permanent_redirect_to)
    try:
        return canonical, parse_feed(result.body, result.content_type)
    except ParseError as err:
        if not looks_like_html(result.body, result.content_type):
            raise ApiError(400, 'not_a_feed',
                           'That address did not return an RSS, Atom, or JSON feed.') from err
    links = discover_feed_links(result.body, result.url)
    if not links:
        raise ApiError(400, 'not_a_feed', 'That page does not advertise a feed.')
    discovered = canonicalize(links[0][0])
    result = guarded_fetch(discovered, None)
    if result.permanent_redirect_to:
        discovered = canonicalize(result.permanent_redirect_to)
    try:
        return discovered, parse_feed(result.body, result.content_type)
    except ParseError as err:
        raise ApiError(400, 'not_a_feed',
                       'The feed that page advertises could not be read.') from err


def guarded_fetch(url, original_url):
    '''rss_http.fetch mapped to API errors.'''
    try:
        result = fetch(url, user_agent=USER_AGENT)
    except FetchError as err:
        if original_url and str(original_url).strip().lower().startswith('http://') \
                and err.reason in ('tls', 'connection', 'dns', 'timeout'):
            raise ApiError(400, 'not_https',
                           'This feed is not available over https, so Cabalmail '
                           'cannot fetch it.') from err
        raise ApiError(400, 'unreachable', f'Could not fetch the feed ({err.reason}).') from err
    if result.status in (401, 403):
        raise ApiError(400, 'needs_credentials',
                       'The publisher requires a login for this feed.')
    if result.status in (404, 410):
        raise ApiError(400, 'feed_gone',
                       f'The publisher returned {result.status} for that address.')
    if result.status != 200:
        raise ApiError(400, 'publisher_error', f'The publisher returned HTTP {result.status}.')
    return result


def subscribe(user, feed, folder_id='', existing_subs=None):
    '''(subscription_row, created) for the caller on `feed`; idempotent.'''
    subs = existing_subs if existing_subs is not None else list_subscriptions(user)
    existing = next((s for s in subs if s['feed_id'] == feed['feed_id']), None)
    if existing:
        return existing, False
    row = create_subscription(user, feed, folder_id)
    attach_subscriber(feed)
    return row, True


def require_folder(user, folder_id):
    '''ApiError 404 unless the folder is the root or exists.'''
    if folder_id and not folders.get_item(Key={'user': user, 'folder_id': folder_id}).get('Item'):
        raise ApiError(404, 'unknown_folder', 'No such folder.')


def create_subscription(user, feed, folder_id):
    '''Writes the caller's subscription row with the default preferences.'''
    now = datetime.now(timezone.utc).isoformat()
    subscription_id = str(uuid.uuid4())
    row = {
        'user': user,
        'subscription_id': subscription_id,
        'feed_id': feed['feed_id'],
        'folder_id': folder_id or ROOT_FOLDER,
        'folder_key': folder_key(folder_id, subscription_id),
        'custom_title': '',
        'ordering_mode': 'newest_first',
        'default_open_mode': 'summary',
        'default_styling': 'reader',
        'notifications_enabled': False,
        'data_store_uuid': str(uuid.uuid4()),
        'created_at': now,
    }
    subscriptions.put_item(Item={k: v for k, v in row.items() if v != ''})
    row['folder_id'] = folder_id
    return row


def attach_subscriber(feed):
    '''Counts the new subscriber; revives a dead-lettered feed on the way.'''
    now = datetime.now(timezone.utc)
    if 'due_shard' in feed:
        feeds.update_item(Key={'feed_id': feed['feed_id']},
                          UpdateExpression='ADD subscriber_count :one',
                          ExpressionAttributeValues={':one': 1})
        return
    feeds.update_item(
        Key={'feed_id': feed['feed_id']},
        UpdateExpression=('SET due_shard = :active, next_fetch_at = :lease, '
                          'consecutive_failure_count = :zero REMOVE dead_lettered_at '
                          'ADD subscriber_count :one'),
        ExpressionAttributeValues={
            ':active': 'active', ':zero': 0, ':one': 1,
            ':lease': (now + timedelta(minutes=CLAIM_LEASE_MINUTES)).isoformat()})
    enqueue(feed['feed_id'], now)


def enqueue(feed_id, now):
    '''Hands the feed to the worker right away (best effort: the scheduler
    picks it up when the lease lapses if this fails).'''
    if not FETCH_QUEUE_URL:
        return
    try:
        sqs.send_message(QueueUrl=FETCH_QUEUE_URL,
                         MessageBody=json.dumps({'feed_id': feed_id,
                                                 'claimed_at': now.isoformat()}))
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[rss-subscribe] enqueue failed for {feed_id}: {err}')
