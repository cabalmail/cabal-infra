'''POST /rss_set_item_state - mark items read/unread and favorite/unfavorite.

Body: {"items": [{"feed_id": "...", "sort_key": "...",
                  "is_read": bool?, "is_favorite": bool?}, ...]}  (<= 100)

Writes the caller's state rows (created on first touch). A favorite also
sets favorite_key (= sort_key) so the sparse favorite_by_feed index carries
exactly the favorites; unfavoriting removes it. An explicit is_read value
overrides the subscription's read watermark for that item, in either
direction - marking something unread after mark-all-read sticks.
'''
from datetime import datetime, timezone
from rss_api import (ApiError, body_of, guarded, list_subscriptions, ok,  # pylint: disable=import-error
                     state, updated_key, user_feed_key, username)

MAX_ITEMS = 100


@guarded
def handler(event, _context):
    '''Applies each requested state change.'''
    user = username(event)
    body = body_of(event)
    requested = body.get('items')
    if not isinstance(requested, list) or not requested:
        raise ApiError(400, 'missing_items', 'items must be a non-empty list.')
    if len(requested) > MAX_ITEMS:
        raise ApiError(400, 'too_many_items', f'At most {MAX_ITEMS} items per call.')
    subscribed = {s['feed_id'] for s in list_subscriptions(user)}
    now = datetime.now(timezone.utc).isoformat()
    updated = 0
    for entry in requested:
        feed_id, sort_key = validate_entry(entry, subscribed)
        expression, values = build_expression(entry, sort_key, now)
        if not values:
            continue
        state.update_item(Key={'user_feed': user_feed_key(user, feed_id), 'sort_key': sort_key},
                          UpdateExpression=expression, ExpressionAttributeValues=values)
        updated += 1
    return ok({'updated': updated})


def validate_entry(entry, subscribed):
    '''(feed_id, sort_key) of a well-formed entry the caller may touch.'''
    if not isinstance(entry, dict):
        raise ApiError(400, 'invalid_item', 'Each item must be an object.')
    feed_id, sort_key = entry.get('feed_id') or '', entry.get('sort_key') or ''
    if not feed_id or not sort_key or '#' not in sort_key:
        raise ApiError(400, 'invalid_item', 'Each item needs feed_id and sort_key.')
    if feed_id not in subscribed:
        raise ApiError(404, 'not_subscribed', f'Not subscribed to feed {feed_id}.')
    return feed_id, sort_key


def build_expression(entry, sort_key, now):
    '''(UpdateExpression, values) for the flags present in `entry`.'''
    sets = ['item_id = if_not_exists(item_id, :item_id)', 'updated_at = :now',
            'updated_key = :ukey']
    removes = []
    values = {':item_id': sort_key.split('#', 1)[1], ':now': now,
              ':ukey': updated_key(now, sort_key)}
    touched = False
    if 'is_read' in entry:
        sets.append('is_read = :read')
        values[':read'] = bool(entry['is_read'])
        touched = True
    if 'is_favorite' in entry:
        favorite = bool(entry['is_favorite'])
        sets.append('is_favorite = :fav')
        values[':fav'] = favorite
        if favorite:
            sets.append('favorite_key = :fkey')
            values[':fkey'] = sort_key
        else:
            removes.append('favorite_key')
        touched = True
    if not touched:
        return '', {}
    expression = 'SET ' + ', '.join(sets)
    if removes:
        expression += ' REMOVE ' + ', '.join(removes)
    return expression, values
