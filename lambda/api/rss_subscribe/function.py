'''POST /rss_subscribe - subscribe the caller to a feed.

Body: {"url": "...", "folder_id": "..."?}

The URL is canonicalized (rss_url), then resolved to a shared feed row: an
existing one by canonical URL, or a new one after fetching and parsing the
document once to prove it is a feed and learn its title. A web page instead
of a feed triggers autodiscovery (rss_discover) of the feed it advertises.
A new or revived feed is enqueued for the fetch worker immediately, so its
items appear within seconds rather than at the next scheduler tick; the
worker, not this endpoint, does the ingest (one code path for items).

Idempotent per (user, feed): subscribing again returns the existing
subscription with "existing": true.

Error codes (400 unless noted): invalid_url, not_https (the https form
of an http URL is unreachable - D1 revised), unreachable, not_a_feed,
needs_credentials (401/403 from the publisher; phase 9 adds the
credential flow), feed_gone (404/410), publisher_error, unknown_folder (404).
'''
import json
import os
import uuid
from datetime import datetime, timedelta, timezone
import boto3  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error
from rss_api import (ApiError, ROOT_FOLDER, SHARED_OWNER, body_of, feeds,  # pylint: disable=import-error
                     folder_key, guarded, list_subscriptions, ok,
                     serialize_subscription, subscriptions, username, folders)
from rss_discover import discover_feed_links, looks_like_html  # pylint: disable=import-error
from rss_http import FetchError, fetch  # pylint: disable=import-error
from rss_parse import ParseError, parse_feed  # pylint: disable=import-error
from rss_url import FeedUrlError, normalize_feed_url  # pylint: disable=import-error

CONTROL_DOMAIN = os.environ.get('CONTROL_DOMAIN', '')
USER_AGENT = f'Cabalmail-Feedbot/1 (+https://www.{CONTROL_DOMAIN}/feedbot.html)'
FETCH_QUEUE_URL = os.environ.get('RSS_FETCH_QUEUE_URL', '')
# Same lease as rss_schedule: the enqueue below IS the claim, so the
# scheduler leaves the feed alone until the worker sets a real next_fetch_at.
CLAIM_LEASE_MINUTES = 30
INITIAL_CADENCE_MINUTES = 60

sqs = boto3.client('sqs')


@guarded
def handler(event, _context):
    '''Resolves the feed, creates or returns the subscription.'''
    user = username(event)
    body = body_of(event)
    folder_id = body.get('folder_id') or ''
    if folder_id and not folders.get_item(Key={'user': user, 'folder_id': folder_id}).get('Item'):
        raise ApiError(404, 'unknown_folder', 'No such folder.')
    canonical = canonicalize(body.get('url'))
    feed = find_shared_feed(canonical) or create_feed(canonical, body.get('url'))
    existing = next((s for s in list_subscriptions(user) if s['feed_id'] == feed['feed_id']), None)
    if existing:
        return ok({'subscription': serialize_subscription(existing, feed), 'existing': True})
    subscription = create_subscription(user, feed, folder_id)
    attach_subscriber(feed)
    return ok({'subscription': serialize_subscription(subscription, feed), 'existing': False})


def canonicalize(url):
    '''rss_url.normalize_feed_url mapped to the API error.'''
    try:
        return normalize_feed_url(url or '')
    except FeedUrlError as err:
        raise ApiError(400, 'invalid_url', str(err)) from err


def find_shared_feed(canonical):
    '''The shared feed row for a canonical URL, if any.'''
    rows = feeds.query(IndexName='by_canonical',
                       KeyConditionExpression=Key('canonical_url').eq(canonical)
                       & Key('owner_key').eq(SHARED_OWNER),
                       Limit=1).get('Items', [])
    if not rows:
        return None
    return feeds.get_item(Key={'feed_id': rows[0]['feed_id']}).get('Item')


def create_feed(canonical, original_url):
    '''Fetch + parse once (with autodiscovery), write the shared row, enqueue.'''
    canonical, parsed = probe(canonical, original_url)
    again = find_shared_feed(canonical)   # autodiscovery may land on a known feed
    if again:
        return again
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


def probe(canonical, original_url):
    '''(canonical_url, ParsedFeed) for the URL or the feed its page advertises.'''
    result = guarded_fetch(canonical, original_url)
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
