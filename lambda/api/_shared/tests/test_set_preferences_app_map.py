'''Unit tests for set_preferences' `app` map validation: the enum keys, the
sticky filter-pill keys (`filter:mail:<folder>`, `filter:feeds:all`), the
flag palette, and the unknown-key rejection that keeps a client typo from
persisting silently. Also when a palette write publishes to the rules
topic: only when its keyword slots change (#2450).

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
    '''Records update_item calls and keeps the one row's `app` map, so a
    write that asks for `ALL_OLD` is answered as DynamoDB answers it: with
    the row as it was before that write.'''

    def __init__(self):
        self.updates = []
        self.app = {}
        self.failing = False

    def update_item(self, **kwargs):
        if self.failing:
            raise RuntimeError('DynamoDB is down')
        self.updates.append(kwargs)
        names = kwargs.get('ExpressionAttributeNames', {})
        values = kwargs.get('ExpressionAttributeValues', {})
        before = {'user': kwargs['Key']['user'], 'app': dict(self.app)}
        # The nested SETs are `#app.#aN = :aN`; the flat ones are not kept.
        for alias, key in names.items():
            if alias.startswith('#a') and alias != '#app':
                self.app[key] = values[':' + alias[1:]]
        if kwargs.get('ReturnValues') == 'ALL_OLD':
            return {'Attributes': before}
        return {}


class _FakeSns:
    '''Records publishes; `failing` makes the next ones raise.'''

    def __init__(self):
        self.published = []
        self.failing = False

    def publish(self, **kwargs):
        if self.failing:
            raise RuntimeError('SNS is down')
        self.published.append(kwargs)


TABLE = _FakeTable()
SNS = _FakeSns()


def _install_fake_boto3():
    boto3 = types.ModuleType('boto3')
    boto3.resource = lambda *_a, **_k: types.SimpleNamespace(Table=lambda _name: TABLE)
    boto3.client = lambda *_a, **_k: SNS
    sys.modules['boto3'] = boto3


def _load_handler():
    _install_fake_boto3()
    path = os.path.join(_API, 'set_preferences', 'function.py')
    spec = importlib.util.spec_from_file_location('set_preferences_function', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MOD = _load_handler()


def call_body(body):
    '''Posts a whole request body for user alice; returns (status, decoded
    body). The Android app sends flat keys beside the `app` map.'''
    event = {'requestContext': {'authorizer': {'claims': {'cognito:username': 'alice'}}},
             'body': json.dumps(body)}
    response = MOD.handler(event, None)
    return response['statusCode'], json.loads(response['body'])


def call(app):
    '''Posts an `app` map for user alice; returns (status, decoded body).'''
    return call_body({'app': app})


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

    def test_enabled_is_deprecated_but_still_accepted_and_stored(self):
        # Builds in the field write `enabled` on every entry, and one refused
        # entry refuses the whole app map, so the field is accepted until 2.0
        # (docs/2.x/flag-palette-enabled-removal.md). Nothing reads it.
        sent = [entry('cabal-flag-01', enabled=False), entry('cabal-flag-02', enabled=True),
                entry('cabal-flag-03')]
        status, stored = save_palette(sent)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(stored), sent)
        self.assertEqual(save_palette([entry('cabal-flag-01', enabled='no')])[0], 400)

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


class PalettePublish(unittest.TestCase):
    '''A palette write publishes to the rules topic only when its keyword
    slots change. The imap tier answers every message on that topic with a
    regenerate that restarts sendmail, and the clients send the palette
    with every settings change, so a publish for an unchanged list was a
    restart for nothing (#2450). The rule compiler reads the slot ids and
    nothing else (`slots_in_palette` in docker/shared/compile-user-rules.py).'''

    TOPIC = 'arn:aws:sns:us-east-1:000000000000:user-rules'

    def setUp(self):
        TABLE.updates.clear()
        TABLE.app.clear()
        TABLE.failing = False
        SNS.published.clear()
        SNS.failing = False
        self.topic_before = MOD.RULES_TOPIC_ARN
        MOD.RULES_TOPIC_ARN = self.TOPIC

    def tearDown(self):
        MOD.RULES_TOPIC_ARN = self.topic_before
        TABLE.app.clear()
        TABLE.failing = False
        SNS.failing = False

    def published(self):
        '''How many messages went out since the last call.'''
        count = len(SNS.published)
        SNS.published.clear()
        return count

    def test_the_first_flag_of_the_users_own_publishes(self):
        self.assertEqual(save_palette([entry('cabal-flag-01', 'Later', 'teal')])[0], 200)
        self.assertEqual(
            SNS.published,
            [{'TopicArn': self.TOPIC,
              'Message': json.dumps({'user': 'alice', 'palette': True})}])

    def test_the_same_palette_sent_again_publishes_nothing(self):
        # What every settings change sends: the whole map, the list in it.
        palette = [entry('\\Flagged', 'Urgent', 'red'), entry('cabal-flag-01'),
                   entry('cabal-flag-02')]
        save_palette(palette)
        self.assertEqual(self.published(), 1)
        for _ in range(3):
            status, _ = call({'theme': 'dark', 'flag_palette': json.dumps(palette),
                              'filter:mail:INBOX': 'unread'})
            self.assertEqual(status, 200)
        self.assertEqual(self.published(), 0)
        # The same many-key map with one more flag in it is a change.
        call({'theme': 'dark', 'filter:mail:INBOX': 'unread',
              'flag_palette': json.dumps(palette + [entry('cabal-flag-03')])})
        self.assertEqual(self.published(), 1)

    def test_flat_keys_beside_the_map_change_nothing(self):
        # The Android app's request: name, accent and density beside `app`.
        def push(palette):
            return call_body({'accent': 'ink', 'density': 'normal', 'name': 'A',
                              'app': {'theme': 'dark',
                                      'flag_palette': json.dumps(palette)}})[0]
        self.assertEqual(push([entry('cabal-flag-01')]), 200)
        self.assertEqual(self.published(), 1)
        for _ in range(3):
            self.assertEqual(push([entry('cabal-flag-01')]), 200)
        self.assertEqual(self.published(), 0)
        self.assertEqual(TABLE.updates[-1]['ReturnValues'], 'ALL_OLD')
        self.assertEqual(push([entry('cabal-flag-01'), entry('cabal-flag-02')]), 200)
        self.assertEqual(self.published(), 1)

    def test_a_rename_a_recolor_and_a_reorder_publish_nothing(self):
        save_palette([entry('cabal-flag-01', 'Later', 'teal'), entry('cabal-flag-02')])
        self.published()
        save_palette([entry('cabal-flag-01', 'Soon', 'teal'), entry('cabal-flag-02')])
        save_palette([entry('cabal-flag-01', 'Soon', 'pink'), entry('cabal-flag-02')])
        save_palette([entry('cabal-flag-02'), entry('cabal-flag-01', 'Soon', 'pink')])
        save_palette([entry('cabal-flag-02', enabled=False),
                      entry('cabal-flag-01', 'Soon', 'pink')])
        self.assertEqual(self.published(), 0)

    def test_adding_and_deleting_a_flag_each_publish(self):
        save_palette([entry('cabal-flag-01')])
        self.published()
        save_palette([entry('cabal-flag-01'), entry('cabal-flag-02')])
        self.assertEqual(self.published(), 1)
        save_palette([entry('cabal-flag-02')])
        self.assertEqual(self.published(), 1)
        # One flag deleted and another made in one write: as many slots,
        # not the same ones.
        save_palette([entry('cabal-flag-03')])
        self.assertEqual(self.published(), 1)

    def test_deleting_the_last_flag_publishes(self):
        save_palette([entry('cabal-flag-07')])
        self.published()
        save_palette([])
        self.assertEqual(self.published(), 1)
        # And an empty list over an empty one does not.
        save_palette([])
        self.assertEqual(self.published(), 0)

    def test_the_system_flags_entry_is_not_a_slot_the_rules_read(self):
        # Never stored, stored renamed, renamed again, reset: no keyword
        # slot came or went.
        save_palette([])
        save_palette([entry('\\Flagged', 'Urgent', 'red')])
        save_palette([entry('\\Flagged', 'Today', 'orange')])
        save_palette([])
        self.assertEqual(self.published(), 0)
        # Beside a flag of the user's own it changes nothing either.
        save_palette([entry('cabal-flag-01')])
        self.assertEqual(self.published(), 1)
        save_palette([entry('\\Flagged', 'Urgent', 'red'), entry('cabal-flag-01')])
        self.assertEqual(self.published(), 0)

    def test_a_map_without_the_palette_publishes_nothing_and_asks_for_nothing(self):
        save_palette([entry('cabal-flag-01')])
        self.published()
        self.assertEqual(call({'theme': 'dark'})[0], 200)
        self.assertEqual(self.published(), 0)
        self.assertEqual(TABLE.updates[-1]['ReturnValues'], 'NONE')
        # The list is still what it was: the next write of it is no change.
        save_palette([entry('cabal-flag-01')])
        self.assertEqual(self.published(), 0)

    def test_the_old_list_comes_back_from_the_write_itself(self):
        # No read before the write: one request, so two devices saving at
        # once cannot both miss a change.
        save_palette([entry('cabal-flag-01')])
        self.assertEqual(len(TABLE.updates), 2)  # the map's creation, the write
        self.assertEqual(TABLE.updates[1]['ReturnValues'], 'ALL_OLD')

    def test_a_stored_value_that_is_not_a_palette_reads_as_no_slots(self):
        for stored in ('not json', '{"slot":"cabal-flag-01"}', '[["cabal-flag-01"]]',
                       '[{"slot":["cabal-flag-01"]}]', '[{"slot":"cabal-flag-21"}]',
                       '7', 'null', 'true', 7):
            TABLE.app['flag_palette'] = stored
            save_palette([])
            self.assertEqual(self.published(), 0, stored)
            TABLE.app['flag_palette'] = stored
            save_palette([entry('cabal-flag-01')])
            self.assertEqual(self.published(), 1, stored)

    def test_a_response_of_another_shape_is_taken_as_no_old_list(self):
        for answer in (None, {}, {'Attributes': None}, {'Attributes': {'app': 'x'}},
                       {'Attributes': {'app': {}}}):
            self.assertIsNone(MOD._stored_palette(answer))  # pylint: disable=protected-access
        self.assertEqual(
            MOD._stored_palette(  # pylint: disable=protected-access
                {'Attributes': {'app': {'flag_palette': '[]', 'theme': 'dark'}}}),
            '[]')

    def test_a_failed_publish_does_not_fail_the_save(self):
        SNS.failing = True
        status, stored = save_palette([entry('cabal-flag-01')])
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(stored), [entry('cabal-flag-01')])

    def test_without_a_topic_nothing_is_published(self):
        MOD.RULES_TOPIC_ARN = ''
        self.assertEqual(save_palette([entry('cabal-flag-01')])[0], 200)
        self.assertEqual(self.published(), 0)

    def test_a_failed_write_publishes_nothing(self):
        TABLE.failing = True
        status, _ = save_palette([entry('cabal-flag-01')])
        self.assertEqual(status, 500)
        self.assertEqual(self.published(), 0)

    def test_the_slots_are_the_ones_the_rule_compiler_reads(self):
        # The handler skips a publish only because the imap tier's compiler
        # takes nothing but these slot ids from a palette. The two are
        # separate copies in separate deploys (the Lambda zip, the imap
        # image); this fails if either moves without the other.
        compiler_path = os.path.join(_API, '..', '..', 'docker', 'shared',
                                     'compile-user-rules.py')
        spec = importlib.util.spec_from_file_location('compile_user_rules', compiler_path)
        compiler = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(compiler)
        palettes = [
            [],
            [entry('\\Flagged', 'Urgent', 'red')],
            [entry('cabal-flag-01')],
            [entry('cabal-flag-01', 'Soon', 'pink', enabled=False)],
            [entry('\\Flagged'), entry('cabal-flag-20'), entry('cabal-flag-07')],
            [entry(slot) for slot in ['\\Flagged'] + KEYWORD_SLOTS],
            # Shapes the validator refuses, which only a row written some
            # other way could hold.
            [entry('cabal-flag-00'), entry('cabal-flag-21'), entry('urgent')],
            [entry('cabal-flag-02'), entry('cabal-flag-02')],
            [{'slot': 7}, {'slot': ['cabal-flag-01']}, 'cabal-flag-01', None],
        ]
        raws = [json.dumps(palette) for palette in palettes]
        raws += ['', 'not json', '7', 'null', '{"slot":"cabal-flag-01"}', None]
        for raw in raws:
            self.assertEqual(MOD._keyword_slots(raw),  # pylint: disable=protected-access
                             compiler.slots_in_palette(raw), raw)
        self.assertEqual(MOD.FLAG_PALETTE_KEYWORD_SLOTS,
                         {slot for slot in KEYWORD_SLOTS if compiler.SLOT_RE.match(slot)})


if __name__ == '__main__':
    unittest.main()
