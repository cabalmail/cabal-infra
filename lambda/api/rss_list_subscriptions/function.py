'''GET /rss_list_subscriptions - the caller's folders and subscriptions.

Response: {"folders": [...], "subscriptions": [... each with a "feed"
summary: title, site, type, item count, and health (D10: last fetch, last
status, last error, failure count, dead_lettered)]}

One call renders the whole sidebar. Unread counts are deliberately absent:
the native clients hold a local item cache and count from it, and the
watermark plus per-item state they need to do so ride along on each
subscription and item.
'''
from rss_api import (FEED_TABLE, batch_get, guarded, list_folders,  # pylint: disable=import-error
                     list_subscriptions, ok, serialize_folder,
                     serialize_subscription, username)


@guarded
def handler(event, _context):
    '''Folders plus subscriptions joined to their feed summaries.'''
    user = username(event)
    subs = list_subscriptions(user)
    feed_ids = sorted({s['feed_id'] for s in subs})
    feed_rows = batch_get(FEED_TABLE, [{'feed_id': f} for f in feed_ids]) if feed_ids else []
    by_id = {row['feed_id']: row for row in feed_rows}
    return ok({
        'folders': sorted((serialize_folder(f) for f in list_folders(user)),
                          key=lambda f: (f['parent_folder_id'], f['display_order'], f['name'])),
        'subscriptions': [serialize_subscription(s, by_id.get(s['feed_id'])) for s in subs],
    })
