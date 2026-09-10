'''GET /rss_opml_export - the caller's subscriptions as an OPML 2.0 document.

Response: {"opml": "<xml text>", "filename": "cabalmail-feeds-YYYYMMDD.opml"}

Folders become nested outlines; each subscription is a type="rss" outline
titled with the custom title when set, else the feed's own. The file
round-trips into Feedly, NetNewsWire, Reeder, and this endpoint's own
importer.
'''
from datetime import datetime, timezone
from rss_api import (FEED_TABLE, batch_get, guarded, list_folders,  # pylint: disable=import-error
                     list_subscriptions, ok, serialize_folder,
                     serialize_subscription, username)
from rss_opml import build_opml  # pylint: disable=import-error


@guarded
def handler(event, _context):
    '''Builds the document from the caller's folders and subscriptions.'''
    user = username(event)
    subs = list_subscriptions(user)
    feed_ids = sorted({s['feed_id'] for s in subs})
    feed_rows = batch_get(FEED_TABLE, [{'feed_id': f} for f in feed_ids]) if feed_ids else []
    by_id = {row['feed_id']: row for row in feed_rows}
    opml = build_opml([serialize_folder(f) for f in list_folders(user)],
                      [serialize_subscription(s, by_id.get(s['feed_id'])) for s in subs])
    stamp = datetime.now(timezone.utc).strftime('%Y%m%d')
    return ok({'opml': opml, 'filename': f'cabalmail-feeds-{stamp}.opml'})
