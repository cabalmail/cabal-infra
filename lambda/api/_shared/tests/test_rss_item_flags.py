'''Unit tests for custom flags on feed items (docs/1.x/cross-media-ux-plan.md,
Phase 2a): /rss_set_item_state's add_flags and remove_flags, and the `flags`
list the item and state serializers emit.

    python3 lambda/api/_shared/tests/test_rss_item_flags.py

boto3 is faked with in-memory tables (rss_api_fakes); no AWS access. The
fake's set ADD and DELETE, and its refusal of an expression that writes one
attribute twice, follow what DynamoDB does.'''
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rss_api_fakes as fx  # noqa: E402  pylint: disable=wrong-import-position

import rss_api  # noqa: E402  pylint: disable=wrong-import-position

USER = 'alice'
FEED = 'f1'
SK1 = '2024-01-01T00:00:00+00:00#i1'
SK2 = '2024-01-02T00:00:00+00:00#i2'
LATER, WORK, OFF, GONE = 'cabal-flag-03', 'cabal-flag-05', 'cabal-flag-07', 'cabal-flag-19'
# What a call with no flag fields has always sent for is_read + is_favorite.
LEGACY_EXPRESSION = ('SET item_id = if_not_exists(item_id, :item_id), updated_at = :now, '
                     'updated_key = :ukey, is_read = :read, is_favorite = :fav, favorite_key = :fkey')


def seed(tables, palette=None):
    '''One subscription to FEED with two items, and the caller's palette:
    LATER and WORK enabled (LATER by leaving `enabled` out), OFF disabled.'''
    tables['cabal-rss-subscription'].rows[(USER, 'sub-f1')] = {
        'user': USER, 'subscription_id': 'sub-f1', 'feed_id': FEED, 'folder_id': '~root'}
    for sort_key in (SK1, SK2):
        published, item_id = sort_key.split('#')
        tables['cabal-rss-item'].rows[(FEED, sort_key)] = {
            'feed_id': FEED, 'sort_key': sort_key, 'item_id': item_id, 'title': item_id,
            'published_at': published, 'fetched_key': f'2024-02-01T00:00:00+00:00#{item_id}'}
    if palette is None:
        palette = json.dumps([
            {'slot': '\\Flagged', 'label': 'Urgent', 'color': 'red', 'enabled': False},
            {'slot': LATER, 'label': 'Later', 'color': 'teal'},
            {'slot': WORK, 'label': 'Work', 'color': 'blue', 'enabled': True},
            {'slot': OFF, 'label': 'Off', 'color': 'gray', 'enabled': False}])
    tables['cabal-user-preferences'].rows[(USER,)] = {'user': USER, 'app': {'flag_palette': palette}}


def call(module, **kw):
    response = module.handler(fx.event(USER, **kw), None)
    return response['statusCode'], json.loads(response['body'])


def entry(sort_key=SK1, **fields):
    return {'feed_id': FEED, 'sort_key': sort_key, **fields}


class _NoPalette:  # pylint: disable=too-few-public-methods
    '''A preferences table that cannot be read.'''

    def __init__(self):
        self.reads = 0

    def get_item(self, **_kw):
        self.reads += 1
        raise fx.ClientError({'Error': {'Code': 'InternalServerError'}}, 'GetItem')


class Serializers(unittest.TestCase):
    '''`flags` on the wire: a sorted list, empty when there is nothing.'''

    SUB = {'subscription_id': 'sub-f1'}

    def test_item_flags_are_sorted_and_default_to_empty(self):
        row = {'feed_id': FEED, 'sort_key': SK1}
        flagged = rss_api.serialize_item(row, self.SUB, {'flags': {WORK, GONE, LATER}})
        self.assertEqual(flagged['flags'], [LATER, WORK, GONE])
        self.assertEqual(rss_api.serialize_item(row, self.SUB, None)['flags'], [])
        self.assertEqual(rss_api.serialize_item(row, self.SUB, {'is_read': True})['flags'], [])

    def test_state_flags_are_sorted_and_default_to_empty(self):
        row = {'user_feed': f'{USER}#{FEED}', 'sort_key': SK1}
        self.assertEqual(rss_api.serialize_state({**row, 'flags': {WORK, LATER}}, self.SUB)['flags'],
                         [LATER, WORK])
        self.assertEqual(rss_api.serialize_state(row, self.SUB)['flags'], [])

    def test_the_fields_shipped_clients_read_are_unchanged(self):
        # The one difference a serialized item or state row shows is the new
        # key; every key a shipped client decodes keeps its value.
        row = {'feed_id': FEED, 'sort_key': SK1, 'item_id': 'i1', 'published_at': '2024-01-01T00:00:00+00:00'}
        state = {'user_feed': f'{USER}#{FEED}', 'sort_key': SK1, 'is_read': True, 'is_favorite': True}
        plain, flagged = (rss_api.serialize_item(row, self.SUB, {**state, **extra})
                          for extra in ({}, {'flags': {LATER}}))
        self.assertEqual(set(flagged) - {'flags'},
                         {'feed_id', 'subscription_id', 'item_id', 'sort_key', 'guid', 'title', 'author',
                          'url', 'published_at', 'updated_at', 'fetched_at', 'fetched_key',
                          'summary_html', 'content_html', 'is_read', 'is_read_explicit', 'is_favorite'})
        self.assertEqual({k: v for k, v in flagged.items() if k != 'flags'},
                         {k: v for k, v in plain.items() if k != 'flags'})
        self.assertEqual(set(rss_api.serialize_state({**state, 'flags': {LATER}}, self.SUB)) - {'flags'},
                         {'feed_id', 'sort_key', 'item_id', 'is_read', 'is_read_explicit', 'is_favorite',
                          'updated_at'})


class SetFlags(unittest.TestCase):

    def setUp(self):
        self.tables = fx.reset_tables()
        self.mod = fx.load_handler('rss_set_item_state')
        self.state = self.tables['cabal-rss-user-item-state']
        seed(self.tables)

    def row(self, sort_key=SK1):
        return self.state.rows.get((f'{USER}#{FEED}', sort_key))

    def test_a_call_without_flag_fields_is_what_it_always_was(self):
        # A shipped client: no add_flags, no remove_flags. The same single
        # write as before, and the palette is never read, so nothing about
        # the palette can fail it.
        unreadable = _NoPalette()
        self.mod.preferences = unreadable
        status, body = call(self.mod, body={'items': [entry(is_read=True, is_favorite=True)]})
        self.assertEqual((status, body), (200, {'updated': 1}))
        self.assertEqual(unreadable.reads, 0)
        self.assertEqual([u['UpdateExpression'] for u in self.state.updates], [LEGACY_EXPRESSION])
        self.assertEqual(set(self.state.updates[0]['ExpressionAttributeValues']),
                         {':item_id', ':now', ':ukey', ':read', ':fav', ':fkey'})
        self.assertNotIn('flags', self.row())

    def test_add_writes_the_set_and_moves_the_sync_key(self):
        status, body = call(self.mod, body={'items': [entry(add_flags=[LATER])]})
        self.assertEqual((status, body), (200, {'updated': 1}))
        row = self.row()
        self.assertEqual(row['flags'], {LATER})
        self.assertEqual((row['item_id'], row['updated_key']), ('i1', f"{row['updated_at']}#i1"))
        # A flags-only entry leaves read and favorite state alone.
        self.assertTrue({'is_read', 'is_favorite', 'favorite_key'}.isdisjoint(row))
        self.assertIn('ADD flags :add', self.state.updates[0]['UpdateExpression'])

    def test_two_devices_adding_different_slots_both_win(self):
        call(self.mod, body={'items': [entry(add_flags=[LATER])]})
        call(self.mod, body={'items': [entry(add_flags=[WORK])]})
        self.assertEqual(self.row()['flags'], {LATER, WORK})
        # Adding one that is already there changes nothing.
        call(self.mod, body={'items': [entry(add_flags=[WORK, WORK])]})
        self.assertEqual(self.row()['flags'], {LATER, WORK})

    def test_remove_takes_one_slot_and_the_last_takes_the_attribute(self):
        self.state.rows[(f'{USER}#{FEED}', SK1)] = {
            'user_feed': f'{USER}#{FEED}', 'sort_key': SK1, 'is_read': True, 'flags': {LATER, WORK}}
        call(self.mod, body={'items': [entry(remove_flags=[WORK])]})
        self.assertEqual(self.row()['flags'], {LATER})
        status, body = call(self.mod, body={'items': [entry(remove_flags=[LATER])]})
        self.assertEqual((status, body), (200, {'updated': 1}))
        self.assertNotIn('flags', self.row())
        self.assertTrue(self.row()['is_read'])
        self.assertEqual(rss_api.serialize_state(self.row(), {})['flags'], [])

    def test_remove_never_needs_the_palette(self):
        # A flag whose palette entry is disabled or gone can still be cleared,
        # even while the palette cannot be read.
        self.state.rows[(f'{USER}#{FEED}', SK1)] = {
            'user_feed': f'{USER}#{FEED}', 'sort_key': SK1, 'flags': {OFF, GONE, LATER}}
        unreadable = _NoPalette()
        self.mod.preferences = unreadable
        status, _ = call(self.mod, body={'items': [entry(remove_flags=[OFF, GONE])]})
        self.assertEqual((status, unreadable.reads), (200, 0))
        self.assertEqual(self.row()['flags'], {LATER})
        # Removing from an item that has no state row is not an error.
        self.assertEqual(call(self.mod, body={'items': [entry(SK2, remove_flags=[GONE])]})[0], 200)
        self.assertNotIn('flags', self.row(SK2))

    def test_add_and_remove_in_one_entry_are_two_writes(self):
        self.state.rows[(f'{USER}#{FEED}', SK1)] = {
            'user_feed': f'{USER}#{FEED}', 'sort_key': SK1, 'flags': {LATER}}
        status, body = call(self.mod, body={'items': [
            entry(is_read=True, add_flags=[WORK], remove_flags=[LATER, GONE])]})
        self.assertEqual((status, body), (200, {'updated': 1}))
        self.assertEqual(self.row()['flags'], {WORK})
        self.assertTrue(self.row()['is_read'])
        expressions = [u['UpdateExpression'] for u in self.state.updates]
        self.assertEqual(len(expressions), 2)
        # One expression cannot ADD to and DELETE from the same attribute.
        for expression in expressions:
            self.assertEqual(expression.count('flags'), 1)
        self.assertEqual(self.row()['updated_key'], f"{self.row()['updated_at']}#i1")

    def test_one_expression_cannot_add_and_delete(self):
        # The fake refuses what DynamoDB refuses, so the split above is
        # tested and not only asserted.
        with self.assertRaises(fx.ClientError):
            self.state.update_item(Key={'user_feed': 'u#f', 'sort_key': 'a#b'},
                                   UpdateExpression='ADD flags :a DELETE flags :r',
                                   ExpressionAttributeValues={':a': {LATER}, ':r': {WORK}})
        self.assertEqual(self.state.rows, {})

    def test_flags_ride_with_read_and_favorite_in_one_write(self):
        status, _ = call(self.mod, body={'items': [
            entry(is_read=True, is_favorite=False, add_flags=[LATER]),
            entry(SK2, is_favorite=True, remove_flags=[WORK])]})
        self.assertEqual(status, 200)
        self.assertEqual(len(self.state.updates), 2)
        first, second = self.row(), self.row(SK2)
        self.assertEqual((first['is_read'], first['is_favorite'], first['flags']), (True, False, {LATER}))
        self.assertNotIn('favorite_key', first)
        self.assertEqual((second['is_favorite'], second['favorite_key']), (True, SK2))
        self.assertNotIn('flags', second)

    def test_empty_and_null_lists_change_nothing(self):
        unreadable = _NoPalette()
        self.mod.preferences = unreadable
        status, body = call(self.mod, body={'items': [
            entry(add_flags=[], remove_flags=[]), entry(SK2, add_flags=None, remove_flags=None)]})
        self.assertEqual((status, body), (200, {'updated': 0}))
        self.assertEqual((self.state.updates, unreadable.reads), ([], 0))

    def refused(self, flagged, status, code, flags=None):
        '''Sends a good entry followed by `flagged`; asserts the refusal and
        that the good entry was not written either.'''
        got, body = call(self.mod, body={'items': [entry(SK2, is_read=True), flagged]})
        self.assertEqual((got, body.get('code'), body.get('flags')), (status, code, flags), flagged)
        self.assertEqual((self.state.rows, self.state.updates), ({}, []), flagged)
        self.assertTrue(body['Error'])

    def test_a_slot_the_palette_does_not_enable_is_refused(self):
        self.refused(entry(add_flags=[OFF]), 400, 'flag_not_in_palette', [OFF])
        self.refused(entry(add_flags=[GONE]), 400, 'flag_not_in_palette', [GONE])
        # Every refused slot of the call is named, sorted, and only those.
        got, body = call(self.mod, body={'items': [
            entry(add_flags=[GONE, LATER]), entry(SK2, add_flags=[WORK, OFF])]})
        self.assertEqual((got, body['code'], body['flags']), (400, 'flag_not_in_palette', [OFF, GONE]))
        self.assertEqual(self.state.rows, {})

    def test_a_slot_in_both_lists_is_refused(self):
        self.refused(entry(add_flags=[LATER, WORK], remove_flags=[WORK]), 400, 'flag_conflict', [WORK])

    def test_anything_but_a_keyword_slot_is_refused(self):
        # The system flag is is_favorite on a feed item, never a member of
        # `flags`; and no spelling outside cabal-flag-01..20 is a slot.
        for name in ('add_flags', 'remove_flags'):
            for bad in ('\\Flagged', 'cabal-flag-00', 'cabal-flag-21', 'cabal-flag-1', 'CABAL-FLAG-03',
                        'cabal-flag-03\n', ' cabal-flag-03', 'later', '', 3, None, [LATER]):
                with self.subTest(name=name, bad=bad):
                    self.refused(entry(**{name: [bad]}), 400, 'invalid_flags')
            for not_a_list in (LATER, {'slot': LATER}, 3, True):
                with self.subTest(name=name, not_a_list=not_a_list):
                    self.refused(entry(**{name: not_a_list}), 400, 'invalid_flags')

    def test_an_unreadable_palette_fails_closed(self):
        self.mod.preferences = _NoPalette()
        self.refused(entry(add_flags=[LATER]), 500, 'palette_unavailable')

    def test_a_missing_or_malformed_palette_has_no_slots(self):
        prefs = self.tables['cabal-user-preferences']
        for item in (None, {'user': USER}, {'user': USER, 'app': {}},
                     {'user': USER, 'app': {'flag_palette': 'not json'}},
                     {'user': USER, 'app': {'flag_palette': '{}'}},
                     {'user': USER, 'app': {'flag_palette': '["cabal-flag-03"]'}}):
            with self.subTest(item=item):
                prefs.rows.clear()
                if item is not None:
                    prefs.rows[(USER,)] = item
                self.refused(entry(add_flags=[LATER]), 400, 'flag_not_in_palette', [LATER])

    def test_another_users_palette_is_not_consulted(self):
        self.tables['cabal-user-preferences'].rows[(USER,)] = {'user': USER, 'app': {'flag_palette': '[]'}}
        self.tables['cabal-user-preferences'].rows[('bob',)] = {
            'user': 'bob', 'app': {'flag_palette': json.dumps([{'slot': LATER, 'label': 'L', 'color': 'red'}])}}
        self.refused(entry(add_flags=[LATER]), 400, 'flag_not_in_palette', [LATER])

    def test_entries_before_a_bad_item_are_still_written(self):
        # Unchanged from before flags: an entry that is not an object, or
        # names a feed the caller does not have, stops the call where it
        # stands. Only a flag refusal is decided before the first write.
        status, body = call(self.mod, body={'items': [
            entry(add_flags=[LATER]), entry(SK2, add_flags=[WORK]) | {'feed_id': 'zz'}]})
        self.assertEqual((status, body['code']), (404, 'not_subscribed'))
        self.assertEqual(self.row()['flags'], {LATER})
        status, body = call(self.mod, body={'items': [entry(add_flags=[WORK]), 'nope']})
        self.assertEqual((status, body['code']), (400, 'invalid_item'))
        self.assertEqual(self.row()['flags'], {LATER, WORK})


class FlagsOnTheReadPath(unittest.TestCase):
    '''What was set comes back from /rss_list_items and /rss_get_item, as JSON.'''

    def setUp(self):
        self.tables = fx.reset_tables()
        seed(self.tables)
        call(fx.load_handler('rss_set_item_state'),
             body={'items': [entry(add_flags=[WORK, LATER]), entry(SK2, is_read=True)]})

    def test_listing_and_single_item(self):
        status, body = call(fx.load_handler('rss_list_items'),
                            params={'subscription_id': 'sub-f1', 'order': 'oldest'})
        self.assertEqual(status, 200)
        self.assertEqual([i['flags'] for i in body['items']], [[LATER, WORK], []])
        status, body = call(fx.load_handler('rss_get_item'), params={'feed_id': FEED, 'sort_key': SK1})
        self.assertEqual((status, body['item']['flags']), (200, [LATER, WORK]))

    def test_item_sync_and_state_sync(self):
        mod = fx.load_handler('rss_list_items')
        _, body = call(mod, params={'subscription_id': 'sub-f1', 'since': ''})
        self.assertEqual({i['item_id']: i['flags'] for i in body['items']}, {'i1': [LATER, WORK], 'i2': []})
        _, body = call(mod, params={'subscription_id': 'sub-f1', 'state_since': ''})
        self.assertEqual([(s['item_id'], s['flags']) for s in body['states']],
                         [('i1', [LATER, WORK]), ('i2', [])])
        # A later flag change reaches a device through the changed-since
        # phase (which also re-delivers i2, written inside its overlap).
        state = self.tables['cabal-rss-user-item-state']
        state.rows[(f'{USER}#{FEED}', SK1)]['updated_key'] = '2999-01-01T00:00:00+00:00#i1'
        state.rows[(f'{USER}#{FEED}', SK1)]['flags'] = {GONE}
        _, changed = call(mod, params={'subscription_id': 'sub-f1', 'state_since': body['next_state_since']})
        self.assertEqual({s['item_id']: s['flags'] for s in changed['states']}, {'i1': [GONE], 'i2': []})


if __name__ == '__main__':
    unittest.main()
