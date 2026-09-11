'''Unit tests for the RSS read path: /rss_list_items (computed read state,
watermark, favorites, since-sync, multi-feed merge and cursor),
/rss_get_item, /rss_set_item_state, /rss_mark_all_read.

    python3 lambda/api/_shared/tests/test_rss_api_items.py

boto3 is faked with in-memory tables (rss_api_fakes); no AWS access.'''
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rss_api_fakes as fx  # noqa: E402  pylint: disable=wrong-import-position

import rss_api  # noqa: E402  pylint: disable=wrong-import-position

USER = 'alice'


def seed(tables, feed_id='f1', n=5, sub_extra=None):
    '''One subscription to feed_id with n items published on successive days.'''
    tables['cabal-rss-feed'].rows[(feed_id,)] = {'feed_id': feed_id, 'canonical_url': f'https://{feed_id}.test/',
                                                 'owner_key': '~shared', 'due_shard': 'active', 'title': feed_id.upper(),
                                                 'item_count': n, 'subscriber_count': 1}
    sub = {'user': USER, 'subscription_id': f'sub-{feed_id}', 'feed_id': feed_id, 'folder_id': '~root',
           'folder_key': f'~root#sub-{feed_id}', 'ordering_mode': 'newest_first', 'default_open_mode': 'summary',
           'default_styling': 'reader', 'notifications_enabled': False, 'data_store_uuid': 'ds'}
    sub.update(sub_extra or {})
    tables['cabal-rss-subscription'].rows[(USER, sub['subscription_id'])] = sub
    for i in range(1, n + 1):
        pub = f'2024-01-{i:02d}T00:00:00+00:00'
        sk = f'{pub}#i{i}'
        tables['cabal-rss-item'].rows[(feed_id, sk)] = {
            'feed_id': feed_id, 'sort_key': sk, 'item_id': f'i{i}', 'guid': f'g{i}', 'title': f'{feed_id} {i}',
            'published_at': pub, 'fetched_at': f'2024-02-01T00:00:{i:02d}+00:00',
            'fetched_key': f'2024-02-01T00:00:{i:02d}+00:00#i{i}', 'content_html': f'<p>{i}</p>'}
    return sub


def call(module, **kw):
    response = module.handler(fx.event(USER, **kw), None)
    return response['statusCode'], json.loads(response['body'])


class ReadState(unittest.TestCase):

    def test_rule(self):
        self.assertFalse(rss_api.is_read(None, '2024-01-05', ''))
        self.assertTrue(rss_api.is_read(None, '2024-01-05', '2024-01-05T00:00:00+00:00'))
        self.assertFalse(rss_api.is_read(None, '2024-01-06', '2024-01-05T00:00:00+00:00'))
        self.assertFalse(rss_api.is_read({'is_read': False}, '2024-01-01', '2024-12-31'))
        self.assertTrue(rss_api.is_read({'is_read': True}, '2024-12-01', ''))


class ListItems(unittest.TestCase):

    def setUp(self):
        self.tables = fx.reset_tables()
        self.mod = fx.load_handler('rss_list_items')

    def test_single_feed_newest_first_with_state(self):
        seed(self.tables)
        self.tables['cabal-rss-user-item-state'].rows[(f'{USER}#f1', '2024-01-05T00:00:00+00:00#i5')] = {
            'user_feed': f'{USER}#f1', 'sort_key': '2024-01-05T00:00:00+00:00#i5', 'is_read': True,
            'is_favorite': True, 'favorite_key': '2024-01-05T00:00:00+00:00#i5'}
        status, body = call(self.mod, params={'subscription_id': 'sub-f1'})
        self.assertEqual(status, 200)
        self.assertEqual([i['item_id'] for i in body['items']], ['i5', 'i4', 'i3', 'i2', 'i1'])
        self.assertEqual((body['items'][0]['is_read'], body['items'][0]['is_favorite']), (True, True))
        self.assertEqual((body['items'][1]['is_read'], body['items'][1]['is_favorite']), (False, False))
        self.assertIsNone(body['next_cursor'])
        self.assertEqual(body['items'][0]['subscription_id'], 'sub-f1')
        self.assertEqual(body['items'][0]['content_html'], '<p>5</p>')

    def test_unread_filter_honours_watermark_and_explicit_rows(self):
        seed(self.tables, sub_extra={'read_watermark': '2024-01-03T00:00:00+00:00'})
        state = self.tables['cabal-rss-user-item-state']
        # i2 explicitly unread despite the watermark; i5 explicitly read.
        state.rows[(f'{USER}#f1', '2024-01-02T00:00:00+00:00#i2')] = {
            'user_feed': f'{USER}#f1', 'sort_key': '2024-01-02T00:00:00+00:00#i2', 'is_read': False}
        state.rows[(f'{USER}#f1', '2024-01-05T00:00:00+00:00#i5')] = {
            'user_feed': f'{USER}#f1', 'sort_key': '2024-01-05T00:00:00+00:00#i5', 'is_read': True}
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'filter': 'unread'})
        self.assertEqual([i['item_id'] for i in body['items']], ['i4', 'i2'])

    def test_favorite_filter_uses_sparse_index(self):
        seed(self.tables)
        state = self.tables['cabal-rss-user-item-state']
        for i in (1, 3):
            sk = f'2024-01-0{i}T00:00:00+00:00#i{i}'
            state.rows[(f'{USER}#f1', sk)] = {'user_feed': f'{USER}#f1', 'sort_key': sk,
                                              'is_favorite': True, 'favorite_key': sk}
        state.rows[(f'{USER}#f1', '2024-01-02T00:00:00+00:00#i2')] = {
            'user_feed': f'{USER}#f1', 'sort_key': '2024-01-02T00:00:00+00:00#i2', 'is_favorite': False}
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'filter': 'favorite', 'order': 'oldest'})
        self.assertEqual([i['item_id'] for i in body['items']], ['i1', 'i3'])
        self.assertTrue(all(i['is_favorite'] for i in body['items']))

    def test_merge_across_feeds_and_cursor(self):
        seed(self.tables, 'f1', 3)
        seed(self.tables, 'f2', 3)
        # f2's items are dated later in the month so the merge interleaves by date.
        for sk, row in list(self.tables['cabal-rss-item'].rows.items()):
            if sk[0] == 'f2':
                new_pub = row['published_at'].replace('2024-01-0', '2024-01-1')
                new_sk = f'{new_pub}#{row["item_id"]}'
                del self.tables['cabal-rss-item'].rows[sk]
                row.update(published_at=new_pub, sort_key=new_sk)
                self.tables['cabal-rss-item'].rows[('f2', new_sk)] = row
        _, page1 = call(self.mod, params={'limit': '4'})
        self.assertEqual([i['feed_id'] for i in page1['items']], ['f2', 'f2', 'f2', 'f1'])
        self.assertIsNotNone(page1['next_cursor'])
        _, page2 = call(self.mod, params={'limit': '4', 'cursor': page1['next_cursor']})
        self.assertEqual([i['item_id'] for i in page2['items']], ['i2', 'i1'])
        self.assertIsNone(page2['next_cursor'])

    def test_folder_scope_includes_descendants(self):
        seed(self.tables, 'f1', 1, {'folder_id': 'child', 'folder_key': 'child#sub-f1'})
        seed(self.tables, 'f2', 1)
        folders = self.tables['cabal-rss-folder']
        folders.rows[(USER, 'top')] = {'user': USER, 'folder_id': 'top', 'name': 'Top'}
        folders.rows[(USER, 'child')] = {'user': USER, 'folder_id': 'child', 'name': 'C', 'parent_folder_id': 'top'}
        _, body = call(self.mod, params={'folder_id': 'top'})
        self.assertEqual([i['feed_id'] for i in body['items']], ['f1'])
        status, body = call(self.mod, params={'folder_id': 'nope'})
        self.assertEqual((status, body['code']), (404, 'unknown_folder'))

    def test_since_sync_by_ingest_time(self):
        seed(self.tables)
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'since': '', 'limit': '2'})
        self.assertEqual([i['item_id'] for i in body['items']], ['i1', 'i2'])
        self.assertTrue(body['has_more'])
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'since': body['next_since'], 'limit': '10'})
        self.assertEqual([i['item_id'] for i in body['items']], ['i3', 'i4', 'i5'])
        self.assertFalse(body['has_more'])
        status, body = call(self.mod, params={'since': ''})
        self.assertEqual((status, body['code']), (400, 'since_needs_subscription'))

    def test_state_sync_full_pull_then_changes(self):
        seed(self.tables, sub_extra={'read_watermark': '2024-01-03T00:00:00+00:00'})
        state = self.tables['cabal-rss-user-item-state']
        uf = f'{USER}#f1'

        def row(i, **flags):
            sk = f'2024-01-{i:02d}T00:00:00+00:00#i{i}'
            state.rows[(uf, sk)] = {'user_feed': uf, 'sort_key': sk, 'item_id': f'i{i}',
                                    'updated_at': '2024-03-01T00:00:00+00:00', **flags}
            return sk
        # i1: marked unread after mark-all-read (a legacy row: no updated_key).
        row(1, is_read=False)
        # i2: favorited, never marked read: read follows the watermark.
        row(2, is_favorite=True, favorite_key='2024-01-02T00:00:00+00:00#i2',
            updated_key='2024-03-01T00:00:00+00:00#i2')
        row(4, is_read=True, updated_key='2024-03-01T00:00:00+00:00#i4')
        # Phase one: the whole partition, in sort-key order, paged.
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'state_since': '', 'limit': '2'})
        self.assertEqual([s['item_id'] for s in body['states']], ['i1', 'i2'])
        self.assertTrue(body['has_more'])
        self.assertEqual([(s['is_read'], s['is_read_explicit'], s['is_favorite']) for s in body['states']],
                         [(False, True, False), (True, False, True)])
        self.assertEqual(body['states'][0]['feed_id'], 'f1')
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'state_since': body['next_state_since'],
                                         'limit': '2'})
        self.assertEqual([s['item_id'] for s in body['states']], ['i4'])
        self.assertFalse(body['has_more'])
        cursor = rss_api.decode_cursor(body['next_state_since'])
        self.assertEqual(cursor['phase'], 'updated')
        # Phase two: only rows changed since; the legacy row never reappears.
        settled = body['next_state_since']
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'state_since': settled})
        self.assertEqual(body['states'], [])
        self.assertFalse(body['has_more'])
        state.rows[(uf, '2024-01-01T00:00:00+00:00#i1')]['is_read'] = True
        state.rows[(uf, '2024-01-01T00:00:00+00:00#i1')]['updated_key'] = '2999-01-01T00:00:00+00:00#i1'
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'state_since': settled})
        self.assertEqual([(s['item_id'], s['is_read'], s['is_read_explicit']) for s in body['states']],
                         [('i1', True, True)])
        # A row newer than the overlap boundary keeps the cursor behind it,
        # so it is delivered again rather than stepped past.
        _, again = call(self.mod, params={'subscription_id': 'sub-f1', 'state_since': body['next_state_since']})
        self.assertEqual([s['item_id'] for s in again['states']], ['i1'])
        status, body = call(self.mod, params={'state_since': ''})
        self.assertEqual((status, body['code']), (400, 'state_since_needs_subscription'))

    def test_items_carry_explicit_marker(self):
        seed(self.tables, n=2, sub_extra={'read_watermark': '2024-12-31T00:00:00+00:00'})
        sk = '2024-01-01T00:00:00+00:00#i1'
        self.tables['cabal-rss-user-item-state'].rows[(f'{USER}#f1', sk)] = {
            'user_feed': f'{USER}#f1', 'sort_key': sk, 'is_read': False}
        _, body = call(self.mod, params={'subscription_id': 'sub-f1', 'order': 'oldest'})
        self.assertEqual([(i['is_read'], i['is_read_explicit']) for i in body['items']],
                         [(False, True), (True, False)])

    def test_bad_inputs(self):
        seed(self.tables)
        self.assertEqual(call(self.mod, params={'filter': 'starred'})[1]['code'], 'invalid_filter')
        self.assertEqual(call(self.mod, params={'limit': 'x'})[1]['code'], 'invalid_limit')
        self.assertEqual(call(self.mod, params={'cursor': '!!'})[1]['code'], 'invalid_cursor')
        self.assertEqual(call(self.mod, params={'subscription_id': 'zzz'})[0], 404)


class GetItem(unittest.TestCase):

    def test_get_and_spill(self):
        tables = fx.reset_tables()
        mod = fx.load_handler('rss_get_item')
        seed(tables, n=1)
        row = tables['cabal-rss-item'].rows[('f1', '2024-01-01T00:00:00+00:00#i1')]
        del row['content_html']
        row['content_s3_key'] = 'items/f1/i1'
        fx.S3.objects[(rss_api.CACHE_BUCKET, 'items/f1/i1')] = b'<p>big</p>'
        status, body = call(mod, params={'feed_id': 'f1', 'sort_key': row['sort_key']})
        self.assertEqual(status, 200)
        self.assertEqual(body['item']['content_html'], '<p>big</p>')
        self.assertEqual(call(mod, params={'feed_id': 'other', 'sort_key': 'x#y'})[1]['code'], 'not_subscribed')
        self.assertEqual(call(mod, params={'feed_id': 'f1', 'sort_key': 'x#y'})[1]['code'], 'unknown_item')


class SetState(unittest.TestCase):

    def test_expressions_and_rows(self):
        tables = fx.reset_tables()
        mod = fx.load_handler('rss_set_item_state')
        seed(tables, n=2)
        sk1 = '2024-01-01T00:00:00+00:00#i1'
        status, body = call(mod, body={'items': [
            {'feed_id': 'f1', 'sort_key': sk1, 'is_read': True, 'is_favorite': True},
            {'feed_id': 'f1', 'sort_key': '2024-01-02T00:00:00+00:00#i2', 'is_favorite': False},
            {'feed_id': 'f1', 'sort_key': 'x#y'}]})
        self.assertEqual((status, body['updated']), (200, 2))
        row = tables['cabal-rss-user-item-state'].rows[(f'{USER}#f1', sk1)]
        self.assertEqual((row['is_read'], row['is_favorite'], row['favorite_key'], row['item_id']),
                         (True, True, sk1, 'i1'))
        self.assertEqual(row['updated_key'], f"{row['updated_at']}#i1")
        row2 = tables['cabal-rss-user-item-state'].rows[(f'{USER}#f1', '2024-01-02T00:00:00+00:00#i2')]
        self.assertNotIn('favorite_key', row2)
        self.assertEqual(call(mod, body={'items': [{'feed_id': 'zz', 'sort_key': 'a#b', 'is_read': True}]})[1]['code'],
                         'not_subscribed')
        self.assertEqual(call(mod, body={'items': []})[1]['code'], 'missing_items')


class MarkAllRead(unittest.TestCase):

    def test_watermark_and_flip(self):
        tables = fx.reset_tables()
        mod = fx.load_handler('rss_mark_all_read')
        seed(tables, 'f1', 2)
        seed(tables, 'f2', 2)
        state = tables['cabal-rss-user-item-state']
        sk = '2024-01-01T00:00:00+00:00#i1'
        state.rows[(f'{USER}#f1', sk)] = {'user_feed': f'{USER}#f1', 'sort_key': sk, 'is_read': False}
        status, body = call(mod, body={'subscription_id': 'sub-f1'})
        self.assertEqual((status, body['subscriptions'], body['flipped']), (200, 1, 1))
        self.assertTrue(state.rows[(f'{USER}#f1', sk)]['is_read'])
        self.assertTrue(tables['cabal-rss-subscription'].rows[(USER, 'sub-f1')]['read_watermark'])
        self.assertEqual(state.rows[(f'{USER}#f1', sk)]['updated_key'],
                         f"{state.rows[(f'{USER}#f1', sk)]['updated_at']}#i1")
        self.assertNotIn('read_watermark', tables['cabal-rss-subscription'].rows[(USER, 'sub-f2')])
        _, body = call(mod, body={})
        self.assertEqual(body['subscriptions'], 2)


if __name__ == '__main__':
    unittest.main()
