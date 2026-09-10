'''POST /rss_subscribe - subscribe the caller to a feed.

Body: {"url": "...", "folder_id": "..."?}

The URL is canonicalized (rss_url) and resolved to a shared feed row
(rss_subscribe_core.resolve_feed): an existing one by canonical URL, or a
new one after fetching and parsing the document once to prove it is a feed
and learn its title. A permanent redirect is followed to its target, and a
web page instead of a feed triggers autodiscovery of the feed it
advertises. A new or revived feed is handed to the fetch worker at once, so
items appear within seconds; the worker, not this endpoint, ingests them.

Idempotent per (user, feed): subscribing again returns the existing
subscription with "existing": true.

Error codes (400 unless noted): invalid_url, not_https (the https form of
an http URL is unreachable - D1 revised), unreachable, not_a_feed,
needs_credentials (401/403 from the publisher; phase 9 adds the
credential flow), feed_gone (404/410), publisher_error, unknown_folder (404).
'''
from rss_api import body_of, guarded, ok, serialize_subscription, username  # pylint: disable=import-error
from rss_subscribe_core import require_folder, resolve_feed, subscribe  # pylint: disable=import-error


@guarded
def handler(event, _context):
    '''Resolves the feed, creates or returns the subscription.'''
    user = username(event)
    body = body_of(event)
    folder_id = body.get('folder_id') or ''
    require_folder(user, folder_id)
    feed = resolve_feed(body.get('url'), probe=True)
    row, created = subscribe(user, feed, folder_id)
    return ok({'subscription': serialize_subscription(row, feed), 'existing': not created})
