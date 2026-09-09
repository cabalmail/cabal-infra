'''GET /rss_get_item - one item with the caller's state, body inlined.

Query: feed_id, sort_key (the item's key as returned by /rss_list_items)

The caller must be subscribed to the feed; the subscription supplies the
read watermark that decides the computed read state.
'''
from rss_api import (ApiError, guarded, items, list_subscriptions, ok,  # pylint: disable=import-error
                     params_of, serialize_item, state_map, username)


@guarded
def handler(event, _context):
    '''Returns the item or 404.'''
    user = username(event)
    params = params_of(event)
    feed_id, sort_key = params.get('feed_id') or '', params.get('sort_key') or ''
    if not feed_id or not sort_key:
        raise ApiError(400, 'missing_key', 'feed_id and sort_key are required.')
    sub = next((s for s in list_subscriptions(user) if s['feed_id'] == feed_id), None)
    if not sub:
        raise ApiError(404, 'not_subscribed', 'You are not subscribed to that feed.')
    row = items.get_item(Key={'feed_id': feed_id, 'sort_key': sort_key}).get('Item')
    if not row:
        raise ApiError(404, 'unknown_item', 'No such item.')
    state_row = state_map(user, feed_id, [sort_key]).get(sort_key)
    return ok({'item': serialize_item(row, sub, state_row)})
