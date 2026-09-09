'''Unit tests for the rss_fetch worker's outcome recording: what a 200, a
304, a failure run, a 410, and a permanent redirect each write to the feed
and item tables. boto3 is faked in sys.modules and the HTTP fetch is stubbed,
so the suite runs on a bare interpreter with no AWS or network access.

    python3 lambda/api/_shared/tests/test_rss_fetch_outcomes.py
'''
import os
import sys
import types
import unittest
from datetime import datetime, timezone

os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_FUNC = os.path.join(os.path.dirname(_SHARED), 'rss_fetch')
sys.path.insert(0, _SHARED)
sys.path.insert(0, _FUNC)

# --- fake boto3 ---------------------------------------------------------------


class _Cond:
    def __init__(self, parts):
        self.parts = parts

    def __and__(self, other):
        return _Cond(self.parts + other.parts)


class _Key:
    def __init__(self, name):
        self.name = name

    def eq(self, value):
        return _Cond([(self.name, '=', value)])

    def lte(self, value):
        return _Cond([(self.name, '<=', value)])


class _ClientError(Exception):
    def __init__(self, code='Boom'):
        super().__init__(code)
        self.response = {'Error': {'Code': code}}


class FakeTable:
    '''Records writes; answers get_item/query from a dict of rows.'''

    def __init__(self):
        self.rows = {}
        self.updates = []
        self.puts = []
        self.queries = []

    def get_item(self, Key=None, **_kw):  # pylint: disable=invalid-name
        return {'Item': self.rows.get(tuple(Key.values()))} if tuple(Key.values()) in self.rows else {}

    def update_item(self, **kw):
        self.updates.append(kw)
        return {}

    def put_item(self, **kw):
        self.puts.append(kw['Item'])
        return {}

    def query(self, **kw):
        self.queries.append(kw)
        conds = {p[0]: p[2] for p in kw['KeyConditionExpression'].parts}
        hits = [r for r in self.rows.values() if all(r.get(k) == v for k, v in conds.items())]
        return {'Items': hits[:kw.get('Limit', 100)]}


TABLES = {}


class _Resource:
    def Table(self, name):  # pylint: disable=invalid-name
        return TABLES.setdefault(name, FakeTable())


class _SSM:
    def get_parameters(self, **_kw):
        return {'Parameters': [{'Name': '/cabal/rss/cadence_min_minutes', 'Value': '15'},
                               {'Name': '/cabal/rss/cadence_max_minutes', 'Value': '1440'}]}


class _S3:
    def __init__(self):
        self.objects = {}

    def put_object(self, Bucket, Key, Body, **_kw):  # pylint: disable=invalid-name
        self.objects[(Bucket, Key)] = Body


_s3 = _S3()
_boto3 = types.ModuleType('boto3')
_boto3.resource = lambda _n, **_k: _Resource()
_boto3.client = lambda name, **_k: _SSM() if name == 'ssm' else _s3
_dyn = types.ModuleType('boto3.dynamodb')
_conds = types.ModuleType('boto3.dynamodb.conditions')
_conds.Key = _Key
sys.modules['boto3'] = _boto3
sys.modules['boto3.dynamodb'] = _dyn
sys.modules['boto3.dynamodb.conditions'] = _conds
_botocore = types.ModuleType('botocore')
_exc = types.ModuleType('botocore.exceptions')
_exc.ClientError = _ClientError
sys.modules['botocore'] = _botocore
sys.modules['botocore.exceptions'] = _exc

import function  # noqa: E402  pylint: disable=wrong-import-position,import-error
from rss_http import FetchError, FetchResult  # noqa: E402  pylint: disable=wrong-import-position
from rss_parse import ParsedFeed, ParsedItem  # noqa: E402  pylint: disable=wrong-import-position

FEED_ID = 'feed-1'


def feed_row(**over):
    row = {'feed_id': FEED_ID, 'canonical_url': 'https://example.com/feed/',
           'owner_key': '~shared', 'due_shard': 'active', 'is_shared': True,
           'next_fetch_at': '2024-01-01T00:00:00+00:00'}
    row.update(over)
    return row


def install(feed=None, result=None, error=None, parsed=None):
    '''Resets the fake tables and stubs fetch/parse for one scenario.'''
    TABLES.clear()
    function.feeds = TABLES.setdefault('cabal-rss-feed', FakeTable())
    function.items = TABLES.setdefault('cabal-rss-item', FakeTable())
    function._bounds_cache.update(value=None, read_at=0.0)  # pylint: disable=protected-access
    if feed is not None:
        function.feeds.rows[(FEED_ID,)] = feed

    def fake_fetch(*_a, **_k):
        if error:
            raise error
        return result
    function.fetch = fake_fetch
    if parsed is not None:
        function.parse_feed = lambda *_a, **_k: parsed
    return function.feeds, function.items


def values(update):
    return update['ExpressionAttributeValues']


class NotModified(unittest.TestCase):

    def test_304_resets_failures_and_widens_cadence(self):
        feeds, _ = install(feed_row(consecutive_failure_count=3, observed_items_per_day=24,
                                    last_fetched_at='2000-01-01T00:00:00+00:00'),
                           FetchResult(status=304, url='u'))
        outcome = function.process_feed(FEED_ID)
        self.assertEqual(outcome['outcome'], 'not_modified')
        upd = feeds.updates[-1]
        self.assertIn('REMOVE last_error', upd['UpdateExpression'])
        self.assertEqual(values(upd)[':zero'], 0)
        self.assertEqual(values(upd)[':status'], 304)
        # A long quiet gap decays the rate, so the cadence stretches past the
        # 60 minutes that 24/day implied.
        self.assertGreater(outcome['cadence'], 60)


class Failures(unittest.TestCase):

    def test_network_failure_backs_off(self):
        feeds, _ = install(feed_row(consecutive_failure_count=2), error=FetchError('timeout', 'x'))
        outcome = function.process_feed(FEED_ID)
        self.assertEqual(outcome['outcome'], 'failed')
        self.assertEqual(outcome['failures'], 3)
        upd = feeds.updates[-1]
        self.assertEqual(values(upd)[':failures'], 3)
        self.assertTrue(values(upd)[':error'].startswith('timeout'))
        self.assertNotIn('REMOVE due_shard', upd['UpdateExpression'])

    def test_retry_after_honoured(self):
        feeds, _ = install(feed_row(), FetchResult(status=429, url='u', retry_after_seconds=7200))
        function.process_feed(FEED_ID)
        next_at = datetime.fromisoformat(values(feeds.updates[-1])[':next'])
        self.assertGreater((next_at - datetime.now(timezone.utc)).total_seconds(), 7000)

    def test_threshold_dead_letters(self):
        feeds, _ = install(feed_row(consecutive_failure_count=19), FetchResult(status=500, url='u'))
        outcome = function.process_feed(FEED_ID)
        self.assertEqual(outcome['outcome'], 'dead_lettered')
        self.assertIn('REMOVE due_shard', feeds.updates[-1]['UpdateExpression'])

    def test_410_dead_letters_immediately(self):
        feeds, _ = install(feed_row(), FetchResult(status=410, url='u'))
        self.assertEqual(function.process_feed(FEED_ID)['outcome'], 'dead_lettered')
        self.assertIn('REMOVE due_shard', feeds.updates[-1]['UpdateExpression'])

    def test_parse_error_is_a_failure(self):
        feeds, _ = install(feed_row(), FetchResult(status=200, url='u', body=b'<html/>'))
        function.parse_feed = lambda *_a, **_k: (_ for _ in ()).throw(function.ParseError('nope'))
        outcome = function.process_feed(FEED_ID)
        self.assertEqual(outcome['outcome'], 'failed')
        self.assertTrue(values(feeds.updates[-1])[':error'].startswith('parse'))

    def test_missing_or_idle_feed_skipped(self):
        install(None, FetchResult(status=200, url='u'))
        self.assertEqual(function.process_feed(FEED_ID)['outcome'], 'skipped')
        feeds, _ = install(feed_row(), FetchResult(status=200, url='u'))
        del feeds.rows[(FEED_ID,)]['due_shard']
        self.assertEqual(function.process_feed(FEED_ID)['outcome'], 'skipped')


class Success(unittest.TestCase):

    def parsed(self):
        return ParsedFeed(feed_type='rss', title='T', description='D', site_url='https://example.com/',
                          ttl_minutes=0, items=[
                              ParsedItem(guid='a', title='A', url='https://example.com/a',
                                         content_html='<p>a</p>',
                                         published_at=datetime(2024, 1, 1, tzinfo=timezone.utc)),
                              ParsedItem(guid='b', title='B', summary_html='s',
                                         published_at=datetime(2024, 1, 3, tzinfo=timezone.utc)),
                          ])

    def test_first_fetch_inserts_items_and_seeds_cadence(self):
        feeds, items = install(feed_row(), FetchResult(status=200, url='u', body=b'x' * 10,
                                                       etag='"e"', last_modified='lm'),
                               parsed=self.parsed())
        outcome = function.process_feed(FEED_ID)
        self.assertEqual((outcome['outcome'], outcome['new'], outcome['updated']), ('fetched', 2, 0))
        self.assertEqual(len(items.puts), 2)
        first = items.puts[0]
        self.assertEqual(first['guid'], 'a')
        self.assertTrue(first['sort_key'].startswith('2024-01-01T00:00:00+00:00#'))
        self.assertEqual(first['content_html'], '<p>a</p>')
        self.assertNotIn('summary_html', first)
        self.assertEqual(items.puts[1]['summary_html'], 's')
        self.assertNotIn('content_html', items.puts[1])
        upd = feeds.updates[-1]
        vals = values(upd)
        self.assertEqual((vals[':etag'], vals[':lm'], vals[':title'], vals[':new']), ('"e"', 'lm', 'T', 2))
        self.assertIn('ADD item_count :new', upd['UpdateExpression'])
        # Two items two days apart seed ~0.5/day -> cadence at the maximum.
        self.assertEqual(outcome['cadence'], 1440)

    def test_refetch_updates_changed_item_only(self):
        parsed = self.parsed()
        feeds, items = install(feed_row(observed_items_per_day=2,
                                        last_fetched_at='2024-01-01T00:00:00+00:00'),
                               FetchResult(status=200, url='u'), parsed=parsed)
        digest_a = function.content_hash(parsed.items[0])
        items.rows[(FEED_ID, 'sk-a')] = {'feed_id': FEED_ID, 'sort_key': 'sk-a', 'guid': 'a',
                                          'item_id': 'ia', 'content_hash': digest_a}
        items.rows[(FEED_ID, 'sk-b')] = {'feed_id': FEED_ID, 'sort_key': 'sk-b', 'guid': 'b',
                                          'item_id': 'ib', 'content_hash': 'stale'}
        outcome = function.process_feed(FEED_ID)
        self.assertEqual((outcome['new'], outcome['updated']), (0, 1))
        self.assertEqual(items.puts, [])
        upd = items.updates[-1]
        self.assertEqual(upd['Key'], {'feed_id': FEED_ID, 'sort_key': 'sk-b'})
        self.assertIn('summary_html = :summary_html', upd['UpdateExpression'])
        self.assertIn('REMOVE', upd['UpdateExpression'])
        self.assertIn('content_html', upd['UpdateExpression'].split('REMOVE')[1])
        self.assertEqual(values(feeds.updates[-1])[':new'], 0)

    def test_oversized_body_spills_to_s3(self):
        function.SPILL_BYTES = 5
        try:
            parsed = self.parsed()
            parsed.items = [parsed.items[0]]
            _, items = install(feed_row(), FetchResult(status=200, url='u'), parsed=parsed)
            function.process_feed(FEED_ID)
        finally:
            function.SPILL_BYTES = 300000
        row = items.puts[0]
        self.assertNotIn('content_html', row)
        self.assertEqual(row['content_s3_key'], f'items/{FEED_ID}/{row["item_id"]}')
        self.assertIn(('rss-cache.test.example.com', row['content_s3_key']), _s3.objects)


class Redirects(unittest.TestCase):

    def test_permanent_redirect_moves_canonical_url(self):
        feeds, _ = install(feed_row(), FetchResult(status=200, url='u',
                                                   permanent_redirect_to='https://www.example.com/feed'),
                           parsed=ParsedFeed(feed_type='rss'))
        function.normalize_feed_url = lambda url: 'https://example.com/feed/'
        function.process_feed(FEED_ID)
        moves = [u for u in feeds.updates if 'canonical_url = :url' in u['UpdateExpression']]
        self.assertEqual(len(moves), 0)   # same canonical URL as before: nothing to do
        function.normalize_feed_url = lambda url: 'https://example.com/new/'
        install(feed_row(), FetchResult(status=200, url='u', permanent_redirect_to='https://example.com/new'),
                parsed=ParsedFeed(feed_type='rss'))
        function.process_feed(FEED_ID)
        moves = [u for u in function.feeds.updates if 'canonical_url = :url' in u['UpdateExpression']]
        self.assertEqual(values(moves[0])[':url'], 'https://example.com/new/')

    def test_conflicting_target_recorded_not_followed(self):
        feeds, _ = install(feed_row(), FetchResult(status=200, url='u', permanent_redirect_to='https://example.com/new'),
                           parsed=ParsedFeed(feed_type='rss'))
        feeds.rows[('feed-2',)] = feed_row(feed_id='feed-2', canonical_url='https://example.com/new/')
        function.normalize_feed_url = lambda url: 'https://example.com/new/'
        function.process_feed(FEED_ID)
        conflict = [u for u in feeds.updates if 'redirect_conflict_url = :url' in u['UpdateExpression']]
        self.assertEqual(len(conflict), 1)
        self.assertFalse([u for u in feeds.updates if 'SET canonical_url' in u['UpdateExpression']])


if __name__ == '__main__':
    unittest.main()
