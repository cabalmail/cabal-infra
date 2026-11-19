'''Unit tests for feed rules in the rss_fetch worker
(docs/1.x/cross-media-ux-plan.md, Phase 4): when a fetch inserts an item,
each subscriber's feed rules are evaluated against it and the outcome is
written to that subscriber's state row.

    python3 lambda/api/_shared/tests/test_rss_fetch_feed_rules.py

Two properties carry the weight. The outcome lands in the state row in the
shape the API reads back (the serializer under test is the real one). And
none of it can hurt ingestion: every failure here still ends in a fetch
recorded as a success, with the feed's health written before the first
rules read. boto3 is faked with in-memory tables (rss_api_fakes); no AWS
or network access.'''
import json
import os
import sys
import time
import types
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rss_api_fakes as fx  # noqa: E402  pylint: disable=wrong-import-position

import rss_api  # noqa: E402  pylint: disable=wrong-import-position
from rss_http import FetchResult  # noqa: E402  pylint: disable=wrong-import-position
from rss_parse import ParsedFeed, ParsedItem  # noqa: E402  pylint: disable=wrong-import-position

function = fx.load_handler('rss_fetch')

FEED, OTHER_FEED = 'feed-1', 'feed-2'
ALICE, BOB, CAROL = 'alice', 'bob', 'carol'
LATER, WORK, GONE = 'cabal-flag-03', 'cabal-flag-05', 'cabal-flag-19'
PUBLISHED = datetime(2024, 5, 1, 12, 0, tzinfo=timezone.utc)


def item(guid='g1', title='Version 2.0 release', **over):
    fields = {'author': 'Ann Author', 'url': f'https://example.com/{guid}',
              'summary_html': '<p>Out <b>now</b></p>', 'published_at': PUBLISHED}
    fields.update(over)
    return ParsedItem(guid=guid, title=title, **fields)


def feed_rule(*conditions, **actions):
    made = {'id': 'r-000000000001', 'name': 'r', 'enabled': True,
            'conditions': [{'field': f, 'value': v} for f, v in conditions],
            'flag': False, 'flags': [], 'markRead': False}
    made.update(actions)
    return made


class _Context:  # pylint: disable=too-few-public-methods
    '''A Lambda context with a fixed time left.'''

    def __init__(self, millis):
        self.millis = millis

    def get_remaining_time_in_millis(self):
        return self.millis


class _Case(unittest.TestCase):

    def setUp(self):
        self.tables = fx.reset_tables()
        self.state = self.tables['cabal-rss-user-item-state']
        self.feeds = self.tables['cabal-rss-feed']
        self.feeds.rows[(FEED,)] = {
            'feed_id': FEED, 'canonical_url': 'https://example.com/feed/',
            'owner_key': '~shared', 'due_shard': 'active'}
        function._bounds_cache.update(value=None, read_at=0.0)  # pylint: disable=protected-access
        function.fetch = lambda *_a, **_k: FetchResult(status=200, url='u', body=b'x')
        self.publish(item())
        self.addCleanup(setattr, function, 'rules_ddb', function.rules_ddb)
        self.addCleanup(setattr, function, 'RULES_BUDGET_SECONDS', function.RULES_BUDGET_SECONDS)

    def publish(self, *items):
        '''What the publisher's feed holds at the next fetch.'''
        function.parse_feed = lambda *_a, **_k: ParsedFeed(
            feed_type='rss', title='T', items=list(items))

    def subscribe(self, user, feed_id=FEED, subscription_id=None):
        subscription_id = subscription_id or f'sub-{user}-{feed_id}'
        self.tables['cabal-rss-subscription'].rows[(user, subscription_id)] = {
            'user': user, 'subscription_id': subscription_id, 'feed_id': feed_id,
            'folder_id': '~root'}
        return subscription_id

    def rules(self, user, *feed_rules, mail_rules='[]'):
        self.tables['cabal-user-rules'].rows[(user,)] = {
            'user': user, 'rules': mail_rules, 'feedRules': json.dumps(list(feed_rules)),
            'version': 1}

    def palette(self, user, *slots):
        self.tables['cabal-user-preferences'].rows[(user,)] = {
            'user': user,
            'app': {'flag_palette': json.dumps([{'slot': s, 'label': s} for s in slots])}}

    def fetch(self, context=None):
        return function.process_feed(FEED, context)

    def state_of(self, user, feed_id=FEED):
        '''The user's state rows for the feed, as /rss_list_items' state
        sync would send them.'''
        rows = [row for (key, _), row in self.state.rows.items()
                if key == rss_api.user_feed_key(user, feed_id)]
        return [rss_api.serialize_state(row, {}) for row in rows]

    def recorded_success(self):
        return self.feeds.rows[(FEED,)].get('last_status_code') == 200


class Outcome(_Case):

    def test_matching_rule_writes_the_state_row_the_api_reads(self):
        sub = self.subscribe(ALICE)
        self.palette(ALICE, LATER, WORK)
        self.rules(ALICE, feed_rule(('feed', sub), ('title', 'RELEASE'),
                                    flag=True, flags=[WORK, LATER], markRead=True))

        outcome = self.fetch()

        self.assertEqual(outcome['outcome'], 'fetched')
        [sent] = self.state_of(ALICE)
        sort_key = next(iter(self.tables['cabal-rss-item'].rows))[1]
        self.assertEqual(sent['sort_key'], sort_key)
        self.assertEqual(sent['item_id'], sort_key.split('#', 1)[1])
        self.assertEqual(sent['flags'], [LATER, WORK])
        self.assertTrue(sent['is_favorite'])
        self.assertTrue(sent['is_read'])
        self.assertTrue(sent['is_read_explicit'])
        # The keys the indexes are built on, as /rss_set_item_state sets them.
        [row] = self.state.rows.values()
        self.assertEqual(row['favorite_key'], sort_key)
        self.assertEqual(row['updated_key'], rss_api.updated_key(row['updated_at'], sort_key))
        self.assertEqual((outcome['rule_subscribers'], outcome['rule_matches'],
                          outcome['rule_writes'], outcome['rule_failures']), (1, 1, 1, 0))

    def test_the_stamp_is_the_time_of_the_write_not_of_the_fetch(self):
        # A device's state-sync cursor trails the clock by a few seconds. A
        # row stamped with the fetch's own time, taken before the items were
        # upserted, would sit behind a cursor that had already passed it.
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        table = self.tables['cabal-rss-subscription']
        real, looked_up = table.query, []

        def watching(**kw):
            looked_up.append(datetime.now(timezone.utc).isoformat())
            return real(**kw)
        table.query = watching
        self.addCleanup(setattr, table, 'query', real)
        self.fetch()
        [row] = self.state.rows.values()
        [item_row] = self.tables['cabal-rss-item'].rows.values()
        self.assertGreater(row['updated_at'], looked_up[0])
        self.assertGreater(row['updated_at'], item_row['fetched_at'])
        self.assertTrue(row['updated_key'].startswith(row['updated_at'] + '#'))

    def test_mark_read_does_not_overrule_a_mark_made_by_hand(self):
        # A device fetched the item and marked it unread between the insert
        # and the rules write.
        function.uuid = types.SimpleNamespace(uuid4=lambda: 'item-1')
        self.addCleanup(setattr, function, 'uuid', __import__('uuid'))
        sort_key = f'{PUBLISHED.isoformat()}#item-1'
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(markRead=True, flag=True))
        self.state.rows[(rss_api.user_feed_key(ALICE, FEED), sort_key)] = {
            'user_feed': rss_api.user_feed_key(ALICE, FEED), 'sort_key': sort_key,
            'item_id': 'item-1', 'is_read': False}
        self.fetch()
        [sent] = self.state_of(ALICE)
        self.assertEqual((sent['is_read'], sent['is_read_explicit'], sent['is_favorite']),
                         (False, True, True))

    def test_only_what_the_rule_sets_is_written(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(('title', 'release'), markRead=True))
        self.fetch()
        [row] = self.state.rows.values()
        self.assertIs(row['is_read'], True)
        for absent in ('is_favorite', 'favorite_key', 'flags'):
            self.assertNotIn(absent, row)
        [sent] = self.state_of(ALICE)
        self.assertEqual((sent['is_favorite'], sent['flags']), (False, []))

    def test_each_subscriber_gets_their_own_rules(self):
        self.subscribe(ALICE)
        self.subscribe(BOB)
        self.subscribe(CAROL)
        self.palette(BOB, LATER)
        self.rules(ALICE, feed_rule(('title', 'release'), flag=True))
        self.rules(BOB, feed_rule(('author', 'ann'), flags=[LATER]))
        # Carol has a rules row with mail rules only.
        self.rules(CAROL, mail_rules='[{"name": "x"}]')

        outcome = self.fetch()

        self.assertTrue(self.state_of(ALICE)[0]['is_favorite'])
        self.assertEqual(self.state_of(ALICE)[0]['flags'], [])
        self.assertEqual(self.state_of(BOB)[0]['flags'], [LATER])
        self.assertFalse(self.state_of(BOB)[0]['is_favorite'])
        self.assertEqual(self.state_of(CAROL), [])
        self.assertEqual((outcome['rule_subscribers'], outcome['rule_matches']), (3, 2))

    def test_feed_condition_limits_a_rule_to_one_subscription(self):
        here = self.subscribe(ALICE)
        elsewhere = self.subscribe(ALICE, OTHER_FEED)
        self.rules(ALICE, feed_rule(('feed', elsewhere), flag=True))
        self.fetch()
        self.assertEqual(self.state_of(ALICE), [])
        self.rules(ALICE, feed_rule(('feed', here), flag=True))
        self.publish(item('g2'))
        self.fetch()
        self.assertEqual(len(self.state_of(ALICE)), 1)

    def test_subscribers_of_other_feeds_are_not_read_or_written(self):
        self.subscribe(ALICE, OTHER_FEED)
        self.rules(ALICE, feed_rule(flag=True))
        outcome = self.fetch()
        self.assertEqual(self.state.rows, {})
        self.assertEqual(outcome['rule_subscribers'], 0)

    def test_non_matching_and_disabled_rules_write_nothing(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(('title', 'beta'), flag=True),
                   feed_rule(('title', 'release'), flag=True, enabled=False))
        outcome = self.fetch()
        self.assertEqual(self.state.rows, {})
        self.assertEqual(outcome['rule_matches'], 0)

    def test_every_new_item_is_evaluated(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(('title', 'release'), flag=True))
        self.publish(item('g1'), item('g2', title='Weekly notes'), item('g3', title='Release 3'))
        outcome = self.fetch()
        self.assertEqual(len(self.state.rows), 2)
        self.assertEqual((outcome['new'], outcome['rules_evaluated'], outcome['rule_matches']),
                         (3, 3, 2))


class OnceOnly(_Case):

    def test_a_known_item_is_not_evaluated_again(self):
        self.subscribe(ALICE)
        self.fetch()                       # inserts g1 while Alice has no rules
        self.rules(ALICE, feed_rule(flag=True))
        outcome = self.fetch()             # same item, unchanged
        self.assertEqual(outcome['new'], 0)
        self.assertEqual(self.state.rows, {})

    def test_a_changed_item_is_refreshed_but_not_evaluated(self):
        self.subscribe(ALICE)
        self.fetch()
        self.rules(ALICE, feed_rule(('title', 'release'), flag=True))
        self.publish(item(title='Version 2.0 release (corrected)'))
        outcome = self.fetch()
        self.assertEqual((outcome['new'], outcome['updated']), (0, 1))
        self.assertEqual(self.state.rows, {})

    def test_no_new_item_means_no_rules_reads_at_all(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        self.fetch()
        function.rules_ddb = types.SimpleNamespace(batch_get_item=self.fail)
        query, self.tables['cabal-rss-subscription'].query = (
            self.tables['cabal-rss-subscription'].query, self.fail)
        self.addCleanup(setattr, self.tables['cabal-rss-subscription'], 'query', query)
        outcome = self.fetch()
        self.assertEqual((outcome['outcome'], outcome['rule_read_calls']), ('fetched', 0))


class Palette(_Case):

    def test_slot_not_in_the_palette_skips_the_rule_whole(self):
        self.subscribe(ALICE)
        self.palette(ALICE, LATER)
        self.rules(ALICE, feed_rule(flags=[GONE], markRead=True, flag=True))
        outcome = self.fetch()
        self.assertEqual(self.state.rows, {})
        self.assertEqual((outcome['rule_skips'], outcome['rule_matches']), (1, 0))

    def test_no_palette_row_means_no_custom_flags(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flags=[LATER]), feed_rule(markRead=True))
        self.fetch()
        [sent] = self.state_of(ALICE)
        self.assertEqual((sent['flags'], sent['is_read']), ([], True))

    def test_palette_is_read_once_and_only_when_a_rule_sets_a_slot(self):
        preferences = self.tables['cabal-user-preferences']
        reads = []
        real = preferences.get_item
        preferences.get_item = lambda **kw: reads.append(kw) or real(**kw)
        self.addCleanup(setattr, preferences, 'get_item', real)
        self.subscribe(ALICE)
        self.subscribe(BOB)
        self.palette(ALICE, LATER)
        self.rules(ALICE, feed_rule(flags=[LATER]))
        self.rules(BOB, feed_rule(flag=True))
        self.publish(item('g1'), item('g2'), item('g3'))
        self.fetch()
        self.assertEqual([kw['Key'] for kw in reads], [{'user': ALICE}])
        self.assertEqual(len(self.state_of(ALICE)), 3)

    def test_unreadable_palette_skips_slot_rules_and_applies_the_rest(self):
        preferences = self.tables['cabal-user-preferences']
        real = preferences.get_item
        preferences.get_item = lambda **_kw: (_ for _ in ()).throw(
            fx.ClientError({'Error': {'Code': 'AccessDeniedException'}}, 'GetItem'))
        self.addCleanup(setattr, preferences, 'get_item', real)
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flags=[LATER]), feed_rule(flag=True))
        outcome = self.fetch()
        [sent] = self.state_of(ALICE)
        self.assertEqual((sent['flags'], sent['is_favorite']), ([], True))
        self.assertEqual(outcome['outcome'], 'fetched')


class BestEffort(_Case):
    '''Nothing the rules do can fail the fetch.'''

    def denied(self, *_a, **_kw):
        raise fx.ClientError({'Error': {'Code': 'AccessDeniedException'}}, 'Query')

    def test_health_is_recorded_before_the_first_rules_read(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        table = self.tables['cabal-rss-subscription']
        real, seen = table.query, []

        def watching(**kw):
            seen.append(self.recorded_success())
            return real(**kw)
        table.query = watching
        self.addCleanup(setattr, table, 'query', real)
        self.fetch()
        self.assertEqual(seen, [True])

    def test_subscriber_lookup_refused(self):
        # The index or its grant is not there yet (code deployed before
        # Terraform), or the index is still being built.
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        table = self.tables['cabal-rss-subscription']
        real, table.query = table.query, self.denied
        self.addCleanup(setattr, table, 'query', real)

        outcome = self.fetch()

        self.assertEqual((outcome['outcome'], outcome['new']), ('fetched', 1))
        self.assertTrue(self.recorded_success())
        self.assertNotIn('dead_lettered_at', self.feeds.rows[(FEED,)])
        self.assertEqual(self.feeds.rows[(FEED,)]['consecutive_failure_count'], 0)
        self.assertEqual(outcome['rule_failures'], 1)
        self.assertEqual(self.state.rows, {})

    def test_rules_read_refused(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        function.rules_ddb = types.SimpleNamespace(batch_get_item=self.denied)
        outcome = self.fetch()
        self.assertEqual((outcome['outcome'], outcome['rule_failures']), ('fetched', 1))
        self.assertTrue(self.recorded_success())

    def test_one_subscribers_failed_write_does_not_stop_the_next(self):
        self.subscribe(ALICE)
        self.subscribe(BOB)
        self.rules(ALICE, feed_rule(flag=True))
        self.rules(BOB, feed_rule(flag=True))
        real = self.state.update_item

        def flaky(**kw):
            if kw['Key']['user_feed'].startswith(ALICE):
                raise fx.ClientError({'Error': {'Code': 'ProvisionedThroughputExceededException'}},
                                     'UpdateItem')
            return real(**kw)
        self.state.update_item = flaky
        self.addCleanup(setattr, self.state, 'update_item', real)

        outcome = self.fetch()

        self.assertEqual(self.state_of(ALICE), [])
        self.assertEqual(len(self.state_of(BOB)), 1)
        self.assertEqual((outcome['outcome'], outcome['rule_failures'], outcome['rule_writes']),
                         ('fetched', 1, 1))

    def test_unprocessed_keys_are_asked_for_again(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        real, calls = function.rules_ddb, []

        def stingy(RequestItems=None):  # pylint: disable=invalid-name
            calls.append(RequestItems)
            if len(calls) == 1:
                return {'Responses': {}, 'UnprocessedKeys': RequestItems}
            return real.batch_get_item(RequestItems=RequestItems)
        function.rules_ddb = types.SimpleNamespace(batch_get_item=stingy)
        outcome = self.fetch()
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(self.state_of(ALICE)), 1)
        self.assertEqual(outcome['rule_failures'], 0)

    def test_keys_that_stay_unprocessed_are_given_up_on(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        function.rules_ddb = types.SimpleNamespace(
            batch_get_item=lambda RequestItems=None: {'Responses': {},
                                                      'UnprocessedKeys': RequestItems})
        outcome = self.fetch()
        self.assertEqual((outcome['outcome'], outcome['rule_failures']), ('fetched', 1))
        self.assertEqual(self.state.rows, {})

    def test_rules_rows_are_read_in_batches_of_one_hundred(self):
        for n in range(205):
            self.subscribe(f'user-{n:03d}')
        real, sizes = function.rules_ddb, []

        def counting(RequestItems=None):  # pylint: disable=invalid-name
            request = RequestItems['cabal-user-rules']
            sizes.append(len(request['Keys']))
            # Only the feed rules are asked for, never the mail rules.
            self.assertEqual(request['ProjectionExpression'], '#u, feedRules')
            return real.batch_get_item(RequestItems=RequestItems)
        function.rules_ddb = types.SimpleNamespace(batch_get_item=counting)
        outcome = self.fetch()
        self.assertEqual(sizes, [100, 100, 5])
        self.assertEqual(outcome['rule_subscribers'], 205)

    def test_subscriber_lookup_follows_pages(self):
        self.subscribe(ALICE)
        self.subscribe(BOB)
        self.rules(ALICE, feed_rule(flag=True))
        self.rules(BOB, feed_rule(flag=True))
        table = self.tables['cabal-rss-subscription']
        real = table.query
        table.query = lambda **kw: real(**{**kw, 'Limit': 1})
        self.addCleanup(setattr, table, 'query', real)
        outcome = self.fetch()
        self.assertEqual(outcome['rule_subscribers'], 2)
        self.assertEqual(len(self.state.rows), 2)


class Budget(_Case):

    def ticking(self):
        '''Replaces the worker's clock with one that moves a second each
        time it is read, so a budget counts reads of the clock.'''
        ticks = iter(range(10_000))
        function.time = types.SimpleNamespace(monotonic=lambda: float(next(ticks)),
                                              time=time.time)
        self.addCleanup(setattr, function, 'time', time)

    def test_out_of_time_part_way_stops_writing_and_still_succeeds(self):
        self.subscribe(ALICE)
        self.subscribe(BOB)
        self.rules(ALICE, feed_rule(flag=True), feed_rule(markRead=True))
        self.rules(BOB, feed_rule(flag=True))
        self.publish(item('g1'), item('g2'))
        self.ticking()
        # The clock is read once to start, once before the lookups, and once
        # per item: this budget lets Alice's two items through and stops at
        # Bob's first.
        function.RULES_BUDGET_SECONDS = 3.5
        outcome = self.fetch()
        self.assertEqual(len(self.state_of(ALICE)), 2)
        self.assertEqual(self.state_of(BOB), [])
        self.assertEqual((outcome['outcome'], outcome['new']), ('fetched', 2))
        # Bob's one rule against two items.
        self.assertEqual(outcome['rule_unfinished'], 2)
        self.assertEqual(outcome['rule_failures'], 0)

    def test_no_time_at_all_makes_no_call(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        self.publish(item('g1'), item('g2'))
        table = self.tables['cabal-rss-subscription']
        real, table.query = table.query, self.fail
        self.addCleanup(setattr, table, 'query', real)
        function.RULES_BUDGET_SECONDS = 0.0
        outcome = self.fetch()
        self.assertEqual(self.state.rows, {})
        self.assertEqual((outcome['outcome'], outcome['rule_read_calls'],
                          outcome['rule_unfinished']), ('fetched', 0, 2))
        self.assertTrue(self.recorded_success())

    def test_out_of_time_between_rules_batches_reads_no_more(self):
        for n in range(150):
            self.subscribe(f'user-{n:03d}')
        self.rules('user-000', feed_rule(flag=True))
        real, sizes = function.rules_ddb, []

        def counting(RequestItems=None):  # pylint: disable=invalid-name
            sizes.append(len(RequestItems['cabal-user-rules']['Keys']))
            return real.batch_get_item(RequestItems=RequestItems)
        function.rules_ddb = types.SimpleNamespace(batch_get_item=counting)
        self.ticking()
        # Started, checked before the lookups, then checked before the
        # second batch: that third reading is past the budget.
        function.RULES_BUDGET_SECONDS = 1.5
        outcome = self.fetch()
        self.assertEqual(sizes, [100])
        self.assertEqual((outcome['outcome'], outcome['rule_failures']), ('fetched', 1))

    def test_the_rules_calls_are_short_ones(self):
        # A stalled request must not be able to outlast the reserve: the
        # deadline is only looked at between calls.
        self.assertLess(2 * (2 + 3), function.RULES_RESERVE_SECONDS)

    def test_the_lambdas_own_deadline_wins_when_it_is_nearer(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        # Less left than the reserve: the rules must not start.
        outcome = self.fetch(_Context(int(function.RULES_RESERVE_SECONDS * 1000) - 1))
        self.assertEqual(self.state.rows, {})
        self.assertEqual((outcome['rule_unfinished'], outcome['rule_read_calls']), (1, 0))

    def test_plenty_of_time_left_changes_nothing(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        outcome = self.fetch(_Context(110_000))
        self.assertEqual(len(self.state.rows), 1)
        self.assertEqual(outcome['rule_unfinished'], 0)


class Reporting(_Case):

    def test_handler_logs_and_counts_the_rules_pass(self):
        self.subscribe(ALICE)
        self.rules(ALICE, feed_rule(flag=True))
        printed = []
        function.print = lambda *a, **_k: printed.append(' '.join(str(x) for x in a))
        self.addCleanup(delattr, function, 'print')
        event = {'Records': [{'body': json.dumps({'feed_id': FEED})}]}
        response = function.handler(event, _Context(110_000))
        self.assertEqual(response['statusCode'], 200)
        line = next(p for p in printed if 'feed-rules' in p)
        self.assertIn('rule_subscribers=1', line)
        self.assertIn('rule_matches=1', line)
        # No subscriber is named in the log.
        self.assertNotIn(ALICE, ' '.join(printed))
        metrics = next(json.loads(p) for p in printed if p.startswith('{"_aws"'))
        self.assertEqual((metrics['RulesEvaluated'], metrics['RuleMatches'],
                          metrics['RuleFailures']), (1, 1, 0))
        names = [m['Name'] for m in metrics['_aws']['CloudWatchMetrics'][0]['Metrics']]
        for name in ('RulesEvaluated', 'RuleMatches', 'RuleFailures'):
            self.assertIn(name, names)
        # One metric per name for the whole worker, not one per feed.
        self.assertEqual(metrics['_aws']['CloudWatchMetrics'][0]['Dimensions'], [[]])

    def test_a_fetch_with_no_subscribers_logs_no_rules_line(self):
        printed = []
        function.print = lambda *a, **_k: printed.append(' '.join(str(x) for x in a))
        self.addCleanup(delattr, function, 'print')
        function.handler({'Records': [{'body': json.dumps({'feed_id': FEED})}]}, None)
        self.assertFalse([p for p in printed if 'feed-rules' in p])


if __name__ == '__main__':
    unittest.main()
