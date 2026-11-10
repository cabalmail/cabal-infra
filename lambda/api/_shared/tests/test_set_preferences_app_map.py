'''Unit tests for set_preferences' `app` map validation: the enum keys, the
sticky filter-pill keys (`filter:mail:<folder>`, `filter:feeds:all`), the
flag palette, and the unknown-key rejection that keeps a client typo from
persisting silently.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_set_preferences_app_map.py

boto3 is faked in sys.modules before the handler is imported, so the suite
needs no AWS access.'''
import importlib.util
import json
import os
import sys
import types
import unittest

_API = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class _FakeTable:
    '''Records update_item calls; the handler never reads the row back.'''

    def __init__(self):
        self.updates = []

    def update_item(self, **kwargs):
        self.updates.append(kwargs)
        return {}


TABLE = _FakeTable()


def _install_fake_boto3():
    boto3 = types.ModuleType('boto3')
    boto3.resource = lambda *_a, **_k: types.SimpleNamespace(Table=lambda _name: TABLE)
    boto3.client = lambda *_a, **_k: types.SimpleNamespace(publish=lambda **_k: None)
    sys.modules['boto3'] = boto3


def _load_handler():
    _install_fake_boto3()
    path = os.path.join(_API, 'set_preferences', 'function.py')
    spec = importlib.util.spec_from_file_location('set_preferences_function', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MOD = _load_handler()


def call(app):
    '''Posts an `app` map for user alice; returns (status, decoded body).'''
    event = {'requestContext': {'authorizer': {'claims': {'cognito:username': 'alice'}}},
             'body': json.dumps({'app': app})}
    response = MOD.handler(event, None)
    return response['statusCode'], json.loads(response['body'])


class AppMap(unittest.TestCase):

    def setUp(self):
        TABLE.updates.clear()

    def test_all_feeds_filter_takes_the_feed_pills(self):
        status, body = call({'filter:feeds:all': 'all'})
        self.assertEqual((status, body['app']), (200, {'filter:feeds:all': 'all'}))
        self.assertEqual(call({'filter:feeds:all': 'flagged'})[0], 400)
        # Only the all-feeds list lives here; a feed's own pill is on its row.
        self.assertEqual(call({'filter:feeds:sub-1': 'all'})[0], 400)
        self.assertEqual(call({'filter:other': 'all'})[0], 400)

    def test_all_feeds_order_takes_the_feed_orderings(self):
        status, body = call({'order:feeds:all': 'oldest_day_newest_within'})
        self.assertEqual((status, body['app']), (200, {'order:feeds:all': 'oldest_day_newest_within'}))
        self.assertEqual(call({'order:feeds:all': 'oldest'})[0], 400)
        # Only the all-feeds list lives here; a feed's or folder's order is
        # on its own row, and no mail list has an order key yet.
        self.assertEqual(call({'order:feeds:sub-1': 'oldest_first'})[0], 400)
        self.assertEqual(call({'order:mail:INBOX': 'oldest_first'})[0], 400)

    def test_all_feeds_orderings_match_the_feed_rows(self):
        # set_preferences ships without rss_api, so the four modes are
        # restated here; they must stay the rows' ordering_mode values.
        rss_api = os.path.join(os.path.dirname(__file__), '..', 'rss_api.py')
        with open(rss_api, encoding='utf-8') as handle:
            source = handle.read()
        start = source.index('ORDERING_MODES = (')
        modes = source[start:source.index(')', start)]
        self.assertEqual(MOD.ALL_FEEDS_ORDER_VALUES,
                         {m.strip(" '\n") for m in modes.split('(', 1)[1].split(',') if m.strip(" '\n")})

    def test_mail_folder_filters_merge_per_key(self):
        status, body = call({'filter:mail:INBOX': 'unread', 'filter:mail:Archive/2026': 'flagged'})
        self.assertEqual(status, 200)
        self.assertEqual(body['app'],
                         {'filter:mail:INBOX': 'unread', 'filter:mail:Archive/2026': 'flagged'})
        # The ensure-map write, then one SET per member: a per-key merge,
        # never a wholesale replace of the map.
        self.assertEqual(len(TABLE.updates), 2)
        expression = TABLE.updates[1]['UpdateExpression']
        self.assertIn('#app.#a0 = :a0', expression)
        self.assertIn('#app.#a1 = :a1', expression)
        names = TABLE.updates[1]['ExpressionAttributeNames']
        self.assertEqual({names['#a0'], names['#a1']},
                         {'filter:mail:INBOX', 'filter:mail:Archive/2026'})

    def test_mail_folder_filter_bounds(self):
        # The feed pill name is not a mail pill.
        self.assertEqual(call({'filter:mail:INBOX': 'favorite'})[0], 400)
        # An empty, over-long, or control-bearing folder path is rejected.
        self.assertEqual(call({'filter:mail:': 'all'})[0], 400)
        self.assertEqual(call({'filter:mail:' + 'x' * 513: 'all'})[0], 400)
        self.assertEqual(call({'filter:mail:IN\nBOX': 'all'})[0], 400)
        self.assertEqual(call({'filter:mail:' + 'x' * 512: 'all'})[0], 200)

    def test_swipe_keys_take_their_own_action_sets(self):
        status, body = call({'swipe_leading': 'toggle_flag', 'swipe_trailing': 'none',
                             'rss_swipe_leading': 'none', 'rss_swipe_trailing': 'toggle_read'})
        self.assertEqual(status, 200)
        self.assertEqual(body['app'],
                         {'swipe_leading': 'toggle_flag', 'swipe_trailing': 'none',
                          'rss_swipe_leading': 'none', 'rss_swipe_trailing': 'toggle_read'})
        # Feeds have no flag and mail has no favorite; neither has a dispose
        # on the feed side.
        self.assertEqual(call({'swipe_leading': 'toggle_favorite'})[0], 400)
        self.assertEqual(call({'rss_swipe_trailing': 'toggle_flag'})[0], 400)
        self.assertEqual(call({'rss_swipe_leading': 'dispose'})[0], 400)

    def test_unknown_key_rejects_the_whole_map(self):
        status, body = call({'theme': 'dark', 'mail_filters': '{}'})
        self.assertEqual(status, 400)
        self.assertEqual(body['Error'], 'Invalid value for app.')
        self.assertEqual(TABLE.updates, [])


def entry(slot, label='Flag', color='blue', **extra):
    '''One palette entry as a client sends it.'''
    return {'slot': slot, 'label': label, 'color': color, **extra}


KEYWORD_SLOTS = [f'cabal-flag-{i:02d}' for i in range(1, 21)]


def save_palette(entries):
    '''Posts a palette (JSON-encoded, as it rides the app map); returns
    (status, the palette string the handler answered with or None).'''
    status, body = call({'flag_palette': json.dumps(entries)})
    return status, body.get('app', {}).get('flag_palette')


class FlagPalette(unittest.TestCase):
    '''The palette validator: the 20 keyword slots plus the system flag's
    `\\Flagged` entry (docs/1.x/unified-flags-plan.md, Phase 1).'''

    def setUp(self):
        TABLE.updates.clear()

    def test_system_slot_round_trips_canonically(self):
        sent = [entry('\\Flagged', 'Urgent', 'red'), entry('cabal-flag-03', 'Later', 'teal')]
        status, stored = save_palette(sent)
        self.assertEqual(status, 200)
        # Compact, key-sorted, order-preserving: the system entry stays first.
        self.assertEqual(
            stored,
            '[{"color":"red","label":"Urgent","slot":"\\\\Flagged"},'
            '{"color":"teal","label":"Later","slot":"cabal-flag-03"}]')
        self.assertEqual(json.loads(stored), sent)
        # What the handler answered is what it wrote.
        self.assertEqual(TABLE.updates[1]['ExpressionAttributeValues'], {':a0': stored})

    def test_system_slot_takes_the_same_fields_as_a_keyword_slot(self):
        self.assertEqual(save_palette([entry('\\Flagged', enabled=False)])[0], 200)
        self.assertEqual(save_palette([entry('\\Flagged', color='gold')])[0], 400)
        self.assertEqual(save_palette([entry('\\Flagged', label='')])[0], 400)
        self.assertEqual(save_palette([entry('\\Flagged', default=True)])[0], 400)

    def test_system_slot_is_unique_and_has_one_spelling(self):
        self.assertEqual(save_palette([entry('\\Flagged'), entry('\\Flagged')])[0], 400)
        # IMAP matches system flags case-insensitively; the palette does not,
        # or two spellings of one flag could sit in the list side by side.
        self.assertEqual(save_palette([entry('\\flagged')])[0], 400)
        self.assertEqual(save_palette([entry('Flagged')])[0], 400)
        # No other system flag is a palette entry.
        self.assertEqual(save_palette([entry('\\Seen')])[0], 400)

    def test_a_full_palette_is_every_keyword_slot_plus_the_system_flag(self):
        # Longest labels and the optional key on every entry, so the raw-length
        # bound is shown to leave room for the 21st entry.
        full = [entry(slot, 'x' * MOD.MAX_FLAG_LABEL_LENGTH, 'indigo', enabled=False)
                for slot in ['\\Flagged'] + KEYWORD_SLOTS]
        self.assertEqual(len(full), MOD.MAX_FLAG_PALETTE_ENTRIES)
        self.assertEqual(MOD.MAX_FLAG_PALETTE_ENTRIES, len(MOD.FLAG_PALETTE_SLOTS))
        status, stored = save_palette(full)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(stored), full)

    def test_twenty_two_entries_are_rejected(self):
        full = [entry(slot) for slot in ['\\Flagged'] + KEYWORD_SLOTS]
        status, _ = save_palette(full + [entry('cabal-flag-21')])
        self.assertEqual(status, 400)
        self.assertEqual(save_palette(full + [entry('cabal-flag-01')])[0], 400)
        self.assertEqual(TABLE.updates, [])

    def test_slot_ids_outside_the_fixed_set_are_still_rejected(self):
        # There is no synthetic slot zero: the system flag is `\Flagged`.
        self.assertEqual(save_palette([entry('cabal-flag-00')])[0], 400)
        self.assertEqual(save_palette([entry('cabal-flag-21')])[0], 400)
        self.assertEqual(save_palette([entry('cabal-flag-1')])[0], 400)
        self.assertEqual(save_palette([entry('urgent')])[0], 400)

    def test_keyword_only_palettes_are_unaffected(self):
        # The shape every palette saved before the system slot existed has.
        sent = [entry(slot) for slot in KEYWORD_SLOTS]
        status, stored = save_palette(sent)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(stored), sent)
        self.assertEqual(save_palette([])[1], '[]')


if __name__ == '__main__':
    unittest.main()
