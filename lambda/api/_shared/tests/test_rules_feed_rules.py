'''Unit tests for feed rules in /get_rules and /set_rules
(docs/1.x/cross-media-ux-plan.md, Phase 4): the `feedRules` list beside
`rules` in the caller's rules row, under the same version.

    python3 lambda/api/_shared/tests/test_rules_feed_rules.py

The property the storage decision rests on is the first suite's: a save
from a client that has never heard of feed rules (no `feedRules` key) can
neither see nor lose one. boto3 is faked with in-memory tables
(rss_api_fakes); no AWS access.'''
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rss_api_fakes as fx  # noqa: E402  pylint: disable=wrong-import-position

import rss_rules  # noqa: E402  pylint: disable=wrong-import-position

USER = 'alice'
LATER = 'cabal-flag-03'
RULES_TABLE = 'cabal-user-rules'
AUDIT_TABLE = 'cabal-user-rules-audit'

get_rules = fx.load_handler('get_rules')
set_rules = fx.load_handler('set_rules')


def mail_rule(name='Receipts', **over):
    made = {'name': name, 'conditions': [{'field': 'subject', 'value': 'receipt'}],
            'action': 'none', 'flag': True}
    made.update(over)
    return made


def feed_rule(name='Releases', **over):
    made = {'name': name, 'conditions': [{'field': 'title', 'value': 'release'}],
            'flags': [LATER], 'markRead': True}
    made.update(over)
    return made


def save(user=USER, **body):
    response = set_rules.handler(fx.event(user, body=body), None)
    return response['statusCode'], json.loads(response['body'])


def load(user=USER):
    response = get_rules.handler(fx.event(user), None)
    return response['statusCode'], json.loads(response['body'])


class _Case(unittest.TestCase):

    def setUp(self):
        self.tables = fx.reset_tables()
        self.row = lambda: self.tables[RULES_TABLE].rows.get((USER,), {})

    def stored_feed_rules(self):
        return json.loads(self.row().get('feedRules', '[]'))


class OlderClients(_Case):
    '''A client that does not know `feedRules` sends {rules, expectedVersion}.'''

    def test_save_without_the_key_keeps_the_stored_feed_rules(self):
        status, first = save(rules=[], feedRules=[feed_rule()], expectedVersion=0)
        self.assertEqual(status, 200)
        kept = self.stored_feed_rules()
        self.assertEqual(len(kept), 1)

        status, second = save(rules=[mail_rule()], expectedVersion=first['version'])

        self.assertEqual(status, 200)
        self.assertEqual(self.stored_feed_rules(), kept)
        self.assertEqual(json.loads(self.row()['rules'])[0]['name'], 'Receipts')
        # The response says what the row holds, which an older client ignores.
        self.assertEqual(second['feedRules'], kept)
        self.assertEqual(second['version'], first['version'] + 1)

    def test_its_write_never_names_the_attribute(self):
        save(rules=[], feedRules=[feed_rule()], expectedVersion=0)
        save(rules=[mail_rule()], expectedVersion=1)
        last = self.tables[RULES_TABLE].updates[-1]
        self.assertNotIn('#f', last['UpdateExpression'])
        self.assertNotIn(':f', last['ExpressionAttributeValues'])

    def test_first_save_ever_without_the_key_stores_no_feed_rules(self):
        status, body = save(rules=[mail_rule()], expectedVersion=0)
        self.assertEqual(status, 200)
        self.assertNotIn('feedRules', self.row())
        self.assertEqual(body['feedRules'], [])

    def test_get_rules_answers_an_empty_list_for_a_row_without_any(self):
        self.tables[RULES_TABLE].rows[(USER,)] = {
            'user': USER, 'rules': '[]', 'version': 3, 'updatedAt': 't'}
        status, body = load()
        self.assertEqual(status, 200)
        self.assertEqual(body, {'rules': [], 'feedRules': [], 'version': 3, 'updatedAt': 't'})

    def test_get_rules_answers_an_empty_list_for_no_row(self):
        self.assertEqual(load()[1], {'rules': [], 'feedRules': [], 'version': 0, 'updatedAt': ''})


class Saving(_Case):

    def test_feed_rules_round_trip_in_canonical_form(self):
        status, body = save(rules=[], feedRules=[feed_rule()], expectedVersion=0)
        self.assertEqual(status, 200)
        stored = dict(body['feedRules'][0])
        self.assertRegex(stored.pop('id'), r'^r-[0-9a-f]{12}$')
        self.assertEqual(stored, {
            'name': 'Releases', 'enabled': True,
            'conditions': [{'field': 'title', 'value': 'release'}],
            'flag': False, 'flags': [LATER], 'markRead': True})
        self.assertEqual(load()[1]['feedRules'], body['feedRules'])

    def test_an_empty_list_clears_them(self):
        save(rules=[], feedRules=[feed_rule()], expectedVersion=0)
        status, body = save(rules=[], feedRules=[], expectedVersion=1)
        self.assertEqual(status, 200)
        self.assertEqual(body['feedRules'], [])
        self.assertEqual(self.stored_feed_rules(), [])

    def test_ids_are_kept_across_saves_and_unique_across_both_lists(self):
        _, first = save(rules=[mail_rule()], feedRules=[feed_rule()], expectedVersion=0)
        mail_id, feed_id = first['rules'][0]['id'], first['feedRules'][0]['id']
        self.assertNotEqual(mail_id, feed_id)
        # A feed rule that claims a mail rule's id gets one of its own.
        _, second = save(rules=first['rules'],
                         feedRules=[first['feedRules'][0], feed_rule('Other', id=mail_id)],
                         expectedVersion=1)
        ids = [r['id'] for r in second['feedRules']]
        self.assertEqual(ids[0], feed_id)
        self.assertNotIn(mail_id, ids)
        self.assertEqual(len(set(ids)), 2)

    def test_an_id_is_matched_whole(self):
        _, body = save(rules=[], feedRules=[feed_rule(id='r-0123456789ab\n')], expectedVersion=0)
        self.assertRegex(body['feedRules'][0]['id'], r'\Ar-[0-9a-f]{12}\Z')
        self.assertNotEqual(body['feedRules'][0]['id'], 'r-0123456789ab\n')

    def test_both_lists_share_one_version(self):
        _, first = save(rules=[], feedRules=[feed_rule()], expectedVersion=0)
        self.assertEqual(first['version'], 1)
        # A writer who saw version 0 loses, whichever list it meant to change.
        status, body = save(rules=[mail_rule()], expectedVersion=0)
        self.assertEqual(status, 409)
        self.assertEqual(body['version'], 1)
        status, _ = save(rules=[], feedRules=[], expectedVersion=0)
        self.assertEqual(status, 409)
        self.assertEqual(len(self.stored_feed_rules()), 1)

    def test_a_refused_save_stores_nothing(self):
        status, _ = save(rules=[mail_rule()], feedRules=[feed_rule(name='')], expectedVersion=0)
        self.assertEqual(status, 400)
        self.assertEqual(self.row(), {})


class Validation(_Case):

    def refused(self, *feed_rules):
        status, body = save(rules=[], feedRules=list(feed_rules), expectedVersion=0)
        self.assertEqual(status, 400, body)
        return body

    def test_errors_name_the_list_the_rule_and_the_field(self):
        body = self.refused(feed_rule(), feed_rule(name=''))
        self.assertEqual(body['errors'], [{
            'list': 'feedRules', 'rule': 1, 'field': 'name',
            'error': 'Must be 1-100 characters, no control characters.'}])

    def test_mail_rule_errors_are_unchanged(self):
        status, body = save(rules=[mail_rule(name='')], feedRules=[feed_rule()],
                            expectedVersion=0)
        self.assertEqual(status, 400)
        self.assertEqual(body['errors'], [{
            'rule': 0, 'field': 'name',
            'error': 'Must be 1-100 characters, no control characters.'}])

    def test_each_list_has_its_own_condition_fields(self):
        body = self.refused(feed_rule(conditions=[{'field': 'subject', 'value': 'x'}]))
        self.assertEqual(body['errors'][0]['field'], 'conditions[0].field')
        for name in ('feed', 'title', 'author', 'summary'):
            status, body = save(rules=[mail_rule(conditions=[{'field': name, 'value': 'x'}])],
                                expectedVersion=0)
            self.assertEqual(status, 400, name)
            self.assertEqual(body['errors'][0]['field'], 'conditions[0].field')

    def test_every_feed_field_is_accepted(self):
        conditions = [{'field': name, 'value': 'x'} for name in ('feed', 'title', 'author',
                                                                 'summary')]
        status, _ = save(rules=[], feedRules=[feed_rule(conditions=conditions)],
                         expectedVersion=0)
        self.assertEqual(status, 200)

    def test_a_feed_rule_has_no_mail_only_keys(self):
        for key, value in (('action', 'move'), ('moveFolder', 'Lists'), ('copyFolders', []),
                           ('forward', []), ('reply', False), ('replyBody', ''),
                           ('continueToNext', True), ('source', 'feed')):
            body = self.refused(feed_rule(**{key: value}))
            self.assertEqual(body['errors'], [{'list': 'feedRules', 'rule': 0, 'field': key,
                                               'error': 'Unknown field.'}], key)

    def test_at_most_one_feed_condition(self):
        body = self.refused(feed_rule(conditions=[{'field': 'feed', 'value': 'sub-1'},
                                                  {'field': 'feed', 'value': 'sub-2'}]))
        self.assertEqual(body['errors'][0]['field'], 'conditions')

    def test_condition_and_flag_shapes(self):
        cases = (
            (feed_rule(conditions='title'), 'conditions'),
            (feed_rule(conditions=[{'field': 'title'}]), 'conditions[0]'),
            (feed_rule(conditions=[{'field': 'title', 'value': ''}]), 'conditions[0].value'),
            (feed_rule(conditions=[{'field': 'title', 'value': 'x' * 501}]),
             'conditions[0].value'),
            (feed_rule(conditions=[{'field': 'title', 'value': 'x'}] * 11), 'conditions'),
            (feed_rule(flags=['\\Flagged']), 'flags[0]'),
            (feed_rule(flags=[LATER, LATER]), 'flags[1]'),
            (feed_rule(flags=LATER), 'flags'),
            (feed_rule(flags=[LATER + '\n']), 'flags[0]'),
            (feed_rule(conditions=[{'field': [], 'value': 'x'}]), 'conditions[0].field'),
            (feed_rule(conditions=[{'field': {}, 'value': 'x'}]), 'conditions[0].field'),
            (feed_rule(markRead='yes'), 'markRead'),
            (feed_rule(flag=1), 'flag'),
            (feed_rule(enabled=None), 'enabled'),
        )
        for rule, field in cases:
            body = self.refused(rule)
            self.assertEqual([e['field'] for e in body['errors']], [field], rule)

    def test_the_list_itself(self):
        for bad in (None, {}, 'x', 7):
            status, body = save(rules=[], feedRules=bad, expectedVersion=0)
            self.assertEqual((status, body), (400, {'Error': 'feedRules must be a list.'}), bad)
        status, body = save(rules=[], feedRules=[feed_rule()] * 101, expectedVersion=0)
        self.assertEqual((status, body), (400, {'Error': 'At most 100 feed rules.'}))
        body = self.refused('not a rule')
        self.assertEqual(body['errors'], [{'list': 'feedRules', 'rule': 0, 'field': '',
                                           'error': 'Rule must be an object.'}])

    def test_size_cap_is_the_feed_rules_own(self):
        big = feed_rule(conditions=[{'field': 'summary', 'value': 'x' * 500}] * 10)
        status, body = save(rules=[], feedRules=[big] * 100, expectedVersion=0)
        self.assertEqual((status, body), (400, {'Error': 'Feed rule set too large.'}))
        # The two caps together leave room in one DynamoDB item (400 KB).
        self.assertLess(set_rules.MAX_RULES_BYTES + set_rules.MAX_FEED_RULES_BYTES, 400_000)


class SideEffects(_Case):

    def published(self):
        return [json.loads(call['Message']) for call in fx.SNS.published]

    def last_diff(self):
        rows = self.tables[AUDIT_TABLE].rows
        return json.loads(rows[max(rows)]['diff'])

    def test_a_feed_rule_edit_does_not_notify_the_mail_tier(self):
        _, first = save(rules=[mail_rule()], expectedVersion=0)
        self.assertEqual(self.published(), [{'user': USER, 'version': 1}])
        save(rules=first['rules'], feedRules=[feed_rule()], expectedVersion=1)
        self.assertEqual(len(self.published()), 1)

    def test_a_save_that_changes_nothing_still_notifies(self):
        # Saving again is how a rule gets recompiled after its folder is
        # created; that holds for a client that sends feedRules too.
        _, first = save(rules=[mail_rule()], feedRules=[feed_rule()], expectedVersion=0)
        save(rules=first['rules'], expectedVersion=1)
        save(rules=first['rules'], feedRules=first['feedRules'], expectedVersion=2)
        self.assertEqual([p['version'] for p in self.published()], [1, 2, 3])

    def test_a_mail_rule_change_still_notifies(self):
        _, first = save(rules=[mail_rule()], feedRules=[feed_rule()], expectedVersion=0)
        save(rules=first['rules'] + [mail_rule('Second')], feedRules=first['feedRules'],
             expectedVersion=1)
        self.assertEqual(self.published(), [{'user': USER, 'version': 1},
                                            {'user': USER, 'version': 2}])

    def test_audit_diff_covers_feed_rules(self):
        _, first = save(rules=[mail_rule()], feedRules=[feed_rule()], expectedVersion=0)
        self.assertEqual({op['path'] for op in self.last_diff()}, {'/rules/0', '/feedRules/0'})
        save(rules=first['rules'], feedRules=[], expectedVersion=1)
        self.assertEqual(self.last_diff(), [{'op': 'remove', 'path': '/feedRules/0'}])

    def test_audit_diff_of_a_save_without_the_key_has_no_feed_rule_paths(self):
        save(rules=[], feedRules=[feed_rule()], expectedVersion=0)
        save(rules=[mail_rule()], expectedVersion=1)
        self.assertEqual([op['path'] for op in self.last_diff()], ['/rules/0'])


class OneSchema(unittest.TestCase):
    '''set_rules validates what rss_rules reads; the two must agree.'''

    def test_condition_fields(self):
        self.assertEqual(set_rules.FEED_FIELDS, set(rss_rules.FIELDS))

    def test_slots(self):
        for slot in ('cabal-flag-01', 'cabal-flag-20', 'cabal-flag-00', 'cabal-flag-21',
                     '\\Flagged', 'cabal-flag-1'):
            self.assertEqual(bool(set_rules.SLOT_RE.fullmatch(slot)),
                             bool(rss_rules.SLOT_RE.fullmatch(slot)), slot)

    def test_a_saved_rule_is_one_the_reader_applies(self):
        fx.reset_tables()
        _, body = save(rules=[], feedRules=[feed_rule(conditions=[
            {'field': 'feed', 'value': 'sub-1'}, {'field': 'title', 'value': 'Release'}])],
            expectedVersion=0)
        rules = rss_rules.parse_rules(json.dumps(body['feedRules']))
        outcome = rss_rules.evaluate(rules, 'sub-1', rss_rules.ItemText('2.0 release'),
                                     lambda: frozenset((LATER,)))
        self.assertEqual((outcome.flags, outcome.mark_read), ({LATER}, True))


if __name__ == '__main__':
    unittest.main()
