'''Unit tests for the RSS subscription and folder endpoints: subscribe
(canonicalization, reuse of a shared feed, autodiscovery, error mapping,
idempotence, revival of a dead-lettered feed, enqueue), unsubscribe (state
cleanup, purge on last subscriber), update_subscription (enums, notify
index attribute), list_subscriptions, and the folder CRUD (reparenting,
cycle refusal).

    python3 lambda/api/_shared/tests/test_rss_api_subscriptions.py
'''
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rss_api_fakes as fx  # noqa: E402  pylint: disable=wrong-import-position

from rss_http import FetchError, FetchResult  # noqa: E402  pylint: disable=wrong-import-position
from rss_parse import ParsedFeed  # noqa: E402  pylint: disable=wrong-import-position

USER = 'alice'
HTML = b'<!doctype html><html><head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head><body></body></html>'


def call(module, **kw):
    response = module.handler(fx.event(USER, **kw), None)
    return response['statusCode'], json.loads(response['body'])


class Subscribe(unittest.TestCase):

    def setUp(self):
        self.tables = fx.reset_tables()
        fx.SQS.sent.clear()
        self.mod = fx.load_handler('rss_subscribe')
        self.mod.FETCH_QUEUE_URL = 'https://sqs/queue'
        self.mod.normalize_feed_url = lambda url: url.replace('http://', 'https://')
        self.fetches = []

        def fake_fetch(url, **_kw):
            self.fetches.append(url)
            return self.responses.pop(0)
        self.mod.fetch = fake_fetch
        self.responses = []
        self.mod.parse_feed = lambda body, ctype: self.parses.pop(0)
        self.parses = []

    def test_new_feed_creates_row_enqueues_and_subscribes(self):
        self.responses = [FetchResult(status=200, url='u', body=b'<rss/>', content_type='application/rss+xml')]
        self.parses = [ParsedFeed(feed_type='rss', title='T', site_url='https://site/')]
        status, body = call(self.mod, body={'url': 'http://example.com/feed'})
        self.assertEqual(status, 200)
        self.assertFalse(body['existing'])
        sub = body['subscription']
        self.assertEqual(sub['feed']['title'], 'T')
        self.assertEqual(sub['ordering_mode'], 'newest_first')
        self.assertTrue(sub['data_store_uuid'])
        feed = list(self.tables['cabal-rss-feed'].rows.values())[0]
        self.assertEqual((feed['canonical_url'], feed['owner_key'], feed['due_shard'], feed['subscriber_count']),
                         ('https://example.com/feed', '~shared', 'active', 1))
        self.assertEqual(json.loads(fx.SQS.sent[0]['MessageBody'])['feed_id'], feed['feed_id'])

    def test_existing_shared_feed_is_reused_without_fetch(self):
        self.tables['cabal-rss-feed'].rows[('f1',)] = {'feed_id': 'f1', 'canonical_url': 'https://example.com/feed/',
                                                        'owner_key': '~shared', 'due_shard': 'active',
                                                        'subscriber_count': 1, 'title': 'Shared'}
        # The stored form has the slash; the user types it without. Same feed.
        status, body = call(self.mod, body={'url': 'https://example.com/feed'})
        self.assertEqual((status, body['subscription']['feed_id']), (200, 'f1'))
        self.assertEqual(self.fetches, [])
        self.assertEqual(self.tables['cabal-rss-feed'].rows[('f1',)]['subscriber_count'], 2)
        # Second subscribe by the same user is idempotent.
        status, body = call(self.mod, body={'url': 'https://example.com/feed'})
        self.assertTrue(body['existing'])
        self.assertEqual(len(self.tables['cabal-rss-subscription'].rows), 1)

    def test_dead_lettered_feed_is_revived(self):
        self.tables['cabal-rss-feed'].rows[('f1',)] = {'feed_id': 'f1', 'canonical_url': 'https://example.com/feed/',
                                                        'owner_key': '~shared', 'subscriber_count': 0,
                                                        'consecutive_failure_count': 20, 'dead_lettered_at': 'x'}
        call(self.mod, body={'url': 'https://example.com/feed'})
        feed = self.tables['cabal-rss-feed'].rows[('f1',)]
        self.assertEqual((feed['due_shard'], feed['consecutive_failure_count'], feed['subscriber_count']),
                         ('active', 0, 1))
        self.assertNotIn('dead_lettered_at', feed)
        self.assertEqual(len(fx.SQS.sent), 1)

    def test_autodiscovery_from_html(self):
        self.responses = [FetchResult(status=200, url='https://example.com/', body=HTML, content_type='text/html'),
                          FetchResult(status=200, url='u', body=b'<rss/>', content_type='application/rss+xml')]
        self.parses = [ParsedFeed(feed_type='rss', title='Found')]
        self.mod.parse_feed = lambda body, ctype: (_ for _ in ()).throw(self.mod.ParseError('html')) \
            if body == HTML else ParsedFeed(feed_type='rss', title='Found')
        status, body = call(self.mod, body={'url': 'https://example.com'})
        self.assertEqual(status, 200)
        # (the test's stand-in normalizer leaves the root path alone)
        self.assertEqual(self.fetches, ['https://example.com', 'https://example.com/feed.xml'])
        self.assertEqual(body['subscription']['feed']['title'], 'Found')

    def test_error_mapping(self):
        cases = [
            ([FetchError('tls', 'x')], 'http://example.com/feed', 'not_https'),
            ([FetchError('blocked_address', 'x')], 'https://example.com/feed', 'unreachable'),
            ([FetchResult(status=401, url='u')], 'https://example.com/feed', 'needs_credentials'),
            ([FetchResult(status=404, url='u')], 'https://example.com/feed', 'feed_gone'),
            ([FetchResult(status=503, url='u')], 'https://example.com/feed', 'publisher_error'),
        ]
        for responses, url, code in cases:
            self.responses = list(responses)
            fetch = self.mod.fetch

            def raising(_url, **_kw):
                r = self.responses.pop(0)
                if isinstance(r, Exception):
                    raise r
                return r
            self.mod.fetch = raising
            status, body = call(self.mod, body={'url': url})
            self.mod.fetch = fetch
            self.assertEqual((status, body['code']), (400, code), code)
        self.mod.normalize_feed_url = lambda url: (_ for _ in ()).throw(self.mod.FeedUrlError('bad'))
        self.assertEqual(call(self.mod, body={'url': 'ftp://x'})[1]['code'], 'invalid_url')

    def test_not_a_feed(self):
        self.responses = [FetchResult(status=200, url='u', body=b'<html><body>hi</body></html>', content_type='text/html')]
        self.mod.parse_feed = lambda body, ctype: (_ for _ in ()).throw(self.mod.ParseError('no'))
        self.assertEqual(call(self.mod, body={'url': 'https://example.com/x'})[1]['code'], 'not_a_feed')

    def test_unknown_folder(self):
        self.assertEqual(call(self.mod, body={'url': 'https://example.com/feed', 'folder_id': 'nope'})[0], 404)


class Unsubscribe(unittest.TestCase):

    def test_last_subscriber_purges_feed(self):
        tables = fx.reset_tables()
        fx.S3.deleted.clear()
        mod = fx.load_handler('rss_unsubscribe')
        tables['cabal-rss-feed'].rows[('f1',)] = {'feed_id': 'f1', 'subscriber_count': 1, 'due_shard': 'active'}
        tables['cabal-rss-subscription'].rows[(USER, 's1')] = {'user': USER, 'subscription_id': 's1', 'feed_id': 'f1'}
        tables['cabal-rss-item'].rows[('f1', 'a#1')] = {'feed_id': 'f1', 'sort_key': 'a#1', 'content_s3_key': 'items/f1/1'}
        tables['cabal-rss-item'].rows[('f1', 'b#2')] = {'feed_id': 'f1', 'sort_key': 'b#2'}
        tables['cabal-rss-user-item-state'].rows[(f'{USER}#f1', 'a#1')] = {'user_feed': f'{USER}#f1', 'sort_key': 'a#1'}
        status, body = call(mod, body={'subscription_id': 's1'})
        self.assertEqual((status, body['feed_purged']), (200, True))
        self.assertEqual(tables['cabal-rss-item'].rows, {})
        self.assertEqual(tables['cabal-rss-feed'].rows, {})
        self.assertEqual(tables['cabal-rss-user-item-state'].rows, {})
        self.assertEqual(fx.S3.deleted[0][1], 'items/f1/1')

    def test_other_subscribers_keep_feed(self):
        tables = fx.reset_tables()
        mod = fx.load_handler('rss_unsubscribe')
        tables['cabal-rss-feed'].rows[('f1',)] = {'feed_id': 'f1', 'subscriber_count': 2, 'due_shard': 'active'}
        tables['cabal-rss-subscription'].rows[(USER, 's1')] = {'user': USER, 'subscription_id': 's1', 'feed_id': 'f1'}
        tables['cabal-rss-item'].rows[('f1', 'a#1')] = {'feed_id': 'f1', 'sort_key': 'a#1'}
        _, body = call(mod, body={'subscription_id': 's1'})
        self.assertFalse(body['feed_purged'])
        self.assertEqual(tables['cabal-rss-feed'].rows[('f1',)]['subscriber_count'], 1)
        self.assertEqual(len(tables['cabal-rss-item'].rows), 1)
        self.assertEqual(call(mod, body={'subscription_id': 's1'})[0], 404)


class UpdateSubscription(unittest.TestCase):

    def test_fields_and_notify_attribute(self):
        tables = fx.reset_tables()
        mod = fx.load_handler('rss_update_subscription')
        tables['cabal-rss-feed'].rows[('f1',)] = {'feed_id': 'f1', 'title': 'T', 'due_shard': 'active'}
        tables['cabal-rss-subscription'].rows[(USER, 's1')] = {'user': USER, 'subscription_id': 's1', 'feed_id': 'f1'}
        tables['cabal-rss-folder'].rows[(USER, 'fo')] = {'user': USER, 'folder_id': 'fo', 'name': 'F'}
        status, body = call(mod, body={'subscription_id': 's1', 'notifications_enabled': True,
                                       'ordering_mode': 'oldest_first', 'folder_id': 'fo', 'custom_title': 'Mine'})
        self.assertEqual(status, 200)
        row = tables['cabal-rss-subscription'].rows[(USER, 's1')]
        self.assertEqual((row['notify_feed_id'], row['folder_key'], row['ordering_mode']), ('f1', 'fo#s1', 'oldest_first'))
        self.assertEqual(body['subscription']['custom_title'], 'Mine')
        call(mod, body={'subscription_id': 's1', 'notifications_enabled': False, 'folder_id': ''})
        row = tables['cabal-rss-subscription'].rows[(USER, 's1')]
        self.assertNotIn('notify_feed_id', row)
        self.assertEqual(row['folder_key'], '~root#s1')
        self.assertEqual(call(mod, body={'subscription_id': 's1', 'default_styling': 'fancy'})[1]['code'],
                         'invalid_default_styling')
        self.assertEqual(call(mod, body={'subscription_id': 's1'})[1]['code'], 'nothing_to_update')


class Folders(unittest.TestCase):

    def test_crud_reparent_and_cycle(self):
        tables = fx.reset_tables()
        new, upd, dele, lst = (fx.load_handler(n) for n in
                               ('rss_new_folder', 'rss_update_folder', 'rss_delete_folder', 'rss_list_subscriptions'))
        _, top = call(new, body={'name': 'Top'})
        top_id = top['folder']['folder_id']
        _, child = call(new, body={'name': 'Child', 'parent_folder_id': top_id})
        child_id = child['folder']['folder_id']
        self.assertEqual(call(new, body={'name': ''})[1]['code'], 'invalid_name')
        self.assertEqual(call(upd, body={'folder_id': top_id, 'parent_folder_id': child_id})[1]['code'], 'cyclic_folder')
        _, renamed = call(upd, body={'folder_id': child_id, 'name': 'Kid', 'display_order': 3})
        self.assertEqual((renamed['folder']['name'], renamed['folder']['display_order']), ('Kid', 3))
        tables['cabal-rss-feed'].rows[('f1',)] = {'feed_id': 'f1', 'title': 'T', 'due_shard': 'active'}
        tables['cabal-rss-subscription'].rows[(USER, 's1')] = {'user': USER, 'subscription_id': 's1', 'feed_id': 'f1',
                                                                'folder_id': child_id, 'folder_key': f'{child_id}#s1'}
        _, listing = call(lst)
        self.assertEqual(len(listing['folders']), 2)
        self.assertEqual(listing['subscriptions'][0]['feed']['title'], 'T')
        self.assertFalse(listing['subscriptions'][0]['feed']['dead_lettered'])
        _, deleted = call(dele, body={'folder_id': child_id})
        self.assertEqual((deleted['moved_subscriptions'], deleted['parent_folder_id']), (1, top_id))
        self.assertEqual(tables['cabal-rss-subscription'].rows[(USER, 's1')]['folder_id'], top_id)
        _, deleted = call(dele, body={'folder_id': top_id})
        self.assertEqual(tables['cabal-rss-subscription'].rows[(USER, 's1')]['folder_id'], '~root')
        self.assertEqual(tables['cabal-rss-folder'].rows, {})


if __name__ == '__main__':
    unittest.main()
