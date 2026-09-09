'''GET /rss_list_items - items for one subscription, a folder, or everything.

Query: subscription_id | folder_id | (neither = all subscriptions)
       filter=all|unread|favorite   (default all)
       order=newest|oldest          (default newest; the two day-grouped
                                     orderings are applied client-side)
       limit=1..100                 (default 50)
       cursor=<opaque>              (from a prior response's next_cursor)
       since=<fetched_key>          (single subscription only: incremental
                                     sync by server ingest time, returns
                                     items ingested after the cursor,
                                     oldest-ingested first)

Response: {"items": [...], "next_cursor": "..."|null, "next_since": "..."}

Read state is computed per rss_api.is_read (explicit state row, else the
subscription's read watermark). Folder and all views merge one page per
feed by sort key; the cursor remembers where each feed's page ended.
'''
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error
from rss_api import (ApiError, ITEM_TABLE, ROOT_FOLDER, batch_get,  # pylint: disable=import-error
                     decode_cursor, encode_cursor, folder_and_descendants,
                     get_subscription, guarded, is_read, items, list_subscriptions,
                     ok, page_size, params_of, serialize_item, state, state_map,
                     user_feed_key, username)

FILTERS = ('all', 'unread', 'favorite')
# Pages of a feed inspected per call while hunting unread items; bounds the
# work for a feed whose recent items are all read.
MAX_UNREAD_PAGES = 4


@guarded
def handler(event, _context):
    '''Routes to the since-sync or the merged listing.'''
    user = username(event)
    params = params_of(event)
    limit = page_size(params)
    subs = target_subscriptions(user, params)
    if params.get('since') is not None:
        if len(subs) != 1 or not params.get('subscription_id'):
            raise ApiError(400, 'since_needs_subscription',
                           'since requires a single subscription_id.')
        return ok(sync_since(user, subs[0], params['since'], limit))
    flt = params.get('filter', 'all')
    if flt not in FILTERS:
        raise ApiError(400, 'invalid_filter', f'filter must be one of {", ".join(FILTERS)}.')
    newest_first = params.get('order', 'newest') != 'oldest'
    if params.get('order', 'newest') not in ('newest', 'oldest'):
        raise ApiError(400, 'invalid_order', 'order must be newest or oldest.')
    return ok(listing(user, subs, flt, newest_first, limit, decode_cursor(params.get('cursor'))))


def target_subscriptions(user, params):
    '''The subscriptions the request addresses.'''
    if params.get('subscription_id'):
        return [get_subscription(user, params['subscription_id'])]
    subs = list_subscriptions(user)
    if params.get('folder_id'):
        wanted = folder_and_descendants(user, params['folder_id'])
        return [s for s in subs if (s.get('folder_id') or ROOT_FOLDER) in wanted]
    return subs


# -- Incremental sync ---------------------------------------------------------

def sync_since(user, sub, since, limit):
    '''Items ingested after `since` (a fetched_key), oldest-ingested first.'''
    condition = Key('feed_id').eq(sub['feed_id'])
    if since:
        condition = condition & Key('fetched_key').gt(since)
    response = items.query(IndexName='by_fetched', KeyConditionExpression=condition,
                           ScanIndexForward=True, Limit=limit)
    keys = [{'feed_id': r['feed_id'], 'sort_key': r['sort_key']} for r in response.get('Items', [])]
    rows = batch_get(ITEM_TABLE, keys) if keys else []
    rows.sort(key=lambda r: r.get('fetched_key', ''))
    states = state_map(user, sub['feed_id'], [r['sort_key'] for r in rows])
    out = [serialize_item(r, sub, states.get(r['sort_key'])) for r in rows]
    next_since = rows[-1]['fetched_key'] if rows else since
    return {'items': out, 'next_since': next_since or '',
            'has_more': 'LastEvaluatedKey' in response}


# -- Merged listing ----------------------------------------------------------------

def listing(user, subs, flt, newest_first, limit, cursor):  # pylint: disable=too-many-arguments,too-many-positional-arguments
    '''One page per feed, merged by sort key; cursor = per-feed resume keys.'''
    per_feed = cursor.get('feeds', {})
    exhausted = set(cursor.get('done', []))
    candidates = []
    for sub in subs:
        feed_id = sub['feed_id']
        if feed_id in exhausted:
            continue
        rows, more = feed_page(user, sub, flt, newest_first, limit, per_feed.get(feed_id))
        if not more and not rows:
            exhausted.add(feed_id)
        candidates.extend((sub, row, more) for row in rows)
    candidates.sort(key=lambda c: c[1]['sort_key'], reverse=newest_first)
    page = candidates[:limit]
    more = len(candidates) > limit or any(m for _, _, m in candidates)
    return {'items': [serialize_item(row, sub, row.pop('_state', None)) for sub, row, _ in page],
            'next_cursor': next_cursor(per_feed, exhausted, page) if more else None}


def next_cursor(per_feed, exhausted, page):
    '''Cursor resuming each feed after the last row of it on this page.'''
    resume = dict(per_feed)
    for sub, row, _ in page:
        resume[sub['feed_id']] = row['sort_key']
    return encode_cursor({'feeds': resume, 'done': sorted(exhausted)})


def feed_page(user, sub, flt, newest_first, limit, resume_key):  # pylint: disable=too-many-arguments,too-many-positional-arguments
    '''Up to `limit` matching rows of one feed after `resume_key`; each row
    carries its state under '_state'. Returns (rows, more_available).'''
    if flt == 'favorite':
        return favorite_page(user, sub, newest_first, limit, resume_key)
    feed_id = sub['feed_id']
    kwargs = {'KeyConditionExpression': Key('feed_id').eq(feed_id),
              'ScanIndexForward': not newest_first, 'Limit': limit}
    if resume_key:
        kwargs['ExclusiveStartKey'] = {'feed_id': feed_id, 'sort_key': resume_key}
    matched, pages = [], 0
    while len(matched) < limit and pages < MAX_UNREAD_PAGES:
        response = items.query(**kwargs)
        pages += 1
        rows = response.get('Items', [])
        states = state_map(user, feed_id, [r['sort_key'] for r in rows])
        for row in rows:
            row['_state'] = states.get(row['sort_key'])
            if flt == 'unread' and is_read(row['_state'], row.get('published_at', ''),
                                           sub.get('read_watermark')):
                continue
            matched.append(row)
        if 'LastEvaluatedKey' not in response:
            return matched[:limit], len(matched) > limit
        kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
        if flt != 'unread':
            break
    return matched[:limit], True


def favorite_page(user, sub, newest_first, limit, resume_key):
    '''Favorites come from the sparse favorite_by_feed index.'''
    key = user_feed_key(user, sub['feed_id'])
    kwargs = {'IndexName': 'favorite_by_feed',
              'KeyConditionExpression': Key('user_feed').eq(key),
              'ScanIndexForward': not newest_first, 'Limit': limit}
    if resume_key:
        kwargs['ExclusiveStartKey'] = {'user_feed': key, 'sort_key': resume_key,
                                       'favorite_key': resume_key}
    response = state.query(**kwargs)
    state_rows = response.get('Items', [])
    if not state_rows:
        return [], False
    keys = [{'feed_id': sub['feed_id'], 'sort_key': r['sort_key']} for r in state_rows]
    by_key = {r['sort_key']: r for r in batch_get(ITEM_TABLE, keys)}
    rows = []
    for srow in state_rows:
        row = by_key.get(srow['sort_key'])
        if row:
            row['_state'] = srow
            rows.append(row)
    return rows, 'LastEvaluatedKey' in response
