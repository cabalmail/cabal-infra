'''Unit tests for set_preferences' `app` map validation: the enum keys, the
sticky filter-pill keys (`filter:mail:<folder>`, `filter:feeds:all`), and the
unknown-key rejection that keeps a client typo from persisting silently.

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


if __name__ == '__main__':
    unittest.main()
