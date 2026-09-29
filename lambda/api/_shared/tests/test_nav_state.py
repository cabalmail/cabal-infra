'''Unit tests for the navigation cursor pair (/set_nav_state, /get_nav_state):
the mail cursor as it always was, the feed cursor added by the resume-session
plan's Phase C (kind "rss", rss_item required, no folder), and the msg_fraction
reading position stored as a Decimal and read back as a float.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_nav_state.py

boto3 is faked in sys.modules before the handlers are imported, so the suite
needs no AWS access.'''
import importlib.util
import json
import os
import sys
import types
import unittest
from decimal import Decimal

_API = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class _FakeTable:
    '''Keeps one row per user, like the preferences table's nav_state attribute.'''

    def __init__(self):
        self.rows = {}

    def update_item(self, Key=None, ExpressionAttributeValues=None, **_kwargs):  # pylint: disable=invalid-name
        self.rows.setdefault(Key['user'], {})['nav_state'] = ExpressionAttributeValues[':ns']
        return {}

    def get_item(self, Key=None):  # pylint: disable=invalid-name
        row = self.rows.get(Key['user'])
        return {'Item': row} if row else {}


TABLE = _FakeTable()


def _load(name):
    '''Imports a handler against a fake boto3, then puts back whatever boto3
    the process had, so the fake never leaks into other suites under discovery.'''
    previous = sys.modules.get('boto3')
    boto3 = types.ModuleType('boto3')
    boto3.resource = lambda *_a, **_k: types.SimpleNamespace(Table=lambda _name: TABLE)
    boto3.client = lambda *_a, **_k: types.SimpleNamespace()
    sys.modules['boto3'] = boto3
    try:
        path = os.path.join(_API, name, 'function.py')
        spec = importlib.util.spec_from_file_location(f'{name}_function', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        if previous is None:
            sys.modules.pop('boto3', None)
        else:
            sys.modules['boto3'] = previous
    return module


SET = _load('set_nav_state')
GET = _load('get_nav_state')


def _event(body=None):
    event = {'requestContext': {'authorizer': {'claims': {'cognito:username': 'alice'}}}}
    if body is not None:
        event['body'] = json.dumps(body)
    return event


def put(body):
    '''Writes a cursor for alice; returns (status, decoded body).'''
    response = SET.handler(_event(body), None)
    return response['statusCode'], json.loads(response['body'])


def get():
    response = GET.handler(_event(), None)
    return response['statusCode'], json.loads(response['body'])


class MailCursor(unittest.TestCase):
    def setUp(self):
        TABLE.rows.clear()

    def test_mail_cursor_round_trips_without_a_kind(self):
        status, _ = put({'folder': 'Lists.Cabal', 'client_id': 'mac', 'uid': 42,
                         'message_id': '<m@x>', 'msg_anchor': 'i2.0.5|-12', 'msg_fraction': 0.31416})
        self.assertEqual(status, 200)
        stored = TABLE.rows['alice']['nav_state']
        self.assertNotIn('kind', stored, 'mail cursors stay unmarked for shipped readers')
        self.assertEqual(stored['msg_fraction'], Decimal('0.3142'))
        status, cursor = get()
        self.assertEqual(status, 200)
        self.assertEqual(cursor['folder'], 'Lists.Cabal')
        self.assertEqual(cursor['uid'], 42)
        self.assertAlmostEqual(cursor['msg_fraction'], 0.3142)
        self.assertIsInstance(cursor['updated_at'], int)

    def test_mail_cursor_still_needs_folder_and_client_id(self):
        self.assertEqual(put({'client_id': 'mac'})[0], 400)
        self.assertEqual(put({'folder': 'INBOX'})[0], 400)
        self.assertEqual(put({'folder': 'INBOX', 'client_id': 'mac', 'kind': 'mail'})[0], 200)
        self.assertEqual(put({'folder': 'INBOX', 'client_id': 'mac', 'kind': None})[0], 200)

    def test_fraction_must_be_zero_to_one(self):
        for bad in (-0.1, 1.5, 'half', True, float('nan')):
            status, body = put({'folder': 'INBOX', 'client_id': 'mac', 'msg_fraction': bad})
            self.assertEqual(status, 400, bad)
            self.assertIn('msg_fraction', body['Error'])
        self.assertEqual(put({'folder': 'INBOX', 'client_id': 'mac', 'msg_fraction': 1})[0], 200)
        self.assertEqual(TABLE.rows['alice']['nav_state']['msg_fraction'], Decimal('1.0'))


class FeedCursor(unittest.TestCase):
    def setUp(self):
        TABLE.rows.clear()

    def test_feed_cursor_needs_an_item_not_a_folder(self):
        status, cursor = put({'kind': 'rss', 'client_id': 'pixel',
                              'rss_item': 'f1#2026-09-28T00:00:00+00:00#i1', 'rss_scope': 'sub:s1',
                              'msg_anchor': 'f0.420', 'msg_fraction': 0.42, 'folder': 'ignored'})
        self.assertEqual(status, 200)
        self.assertEqual(cursor['kind'], 'rss')
        stored = TABLE.rows['alice']['nav_state']
        self.assertNotIn('folder', stored)
        self.assertEqual(stored['rss_item'], 'f1#2026-09-28T00:00:00+00:00#i1')
        self.assertEqual(stored['rss_scope'], 'sub:s1')
        self.assertEqual(stored['msg_anchor'], 'f0.420')
        _, read = get()
        self.assertEqual(read['kind'], 'rss')
        self.assertAlmostEqual(read['msg_fraction'], 0.42)

    def test_feed_cursor_validation(self):
        self.assertEqual(put({'kind': 'rss', 'client_id': 'pixel'})[0], 400)
        self.assertEqual(put({'kind': 'rss', 'client_id': 'pixel', 'rss_item': 'no-hash'})[0], 400)
        self.assertEqual(put({'kind': 'rss', 'rss_item': 'f#k'})[0], 400)
        self.assertEqual(put({'kind': 'rss', 'client_id': 'pixel', 'rss_item': 'f#k', 'rss_scope': 7})[0], 400)
        self.assertEqual(put({'kind': 'video', 'client_id': 'pixel', 'folder': 'INBOX'})[0], 400)

    def test_a_feed_cursor_replaces_the_mail_cursor_wholesale(self):
        put({'folder': 'INBOX', 'client_id': 'mac', 'uid': 7})
        put({'kind': 'rss', 'client_id': 'pixel', 'rss_item': 'f#k'})
        stored = TABLE.rows['alice']['nav_state']
        self.assertNotIn('uid', stored)
        self.assertNotIn('folder', stored)


class Empty(unittest.TestCase):
    def test_no_cursor_reads_as_an_empty_object(self):
        TABLE.rows.clear()
        self.assertEqual(get(), (200, {}))


if __name__ == '__main__':
    unittest.main()
