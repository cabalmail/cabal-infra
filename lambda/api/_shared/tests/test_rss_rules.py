'''Unit tests for rss_rules: what a subscriber's feed rules decide for one
newly fetched item (docs/1.x/cross-media-ux-plan.md, Phase 4). Pure logic,
no AWS and no fakes.

    python3 lambda/api/_shared/tests/test_rss_rules.py
'''
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rss_rules  # noqa: E402  pylint: disable=wrong-import-position

SUB = 'sub-1'
LATER, WORK, GONE = 'cabal-flag-03', 'cabal-flag-05', 'cabal-flag-19'


def text(title='Version 2.0 Release Notes', author='Ann Author',
         summary='<p>Hello <b>world</b></p>', content=''):
    return rss_rules.ItemText(title, author, summary, content)


def rule(*conditions, **actions):
    made = {'id': 'r-000000000001', 'name': 'r', 'enabled': True,
            'conditions': [{'field': f, 'value': v} for f, v in conditions],
            'flag': False, 'flags': [], 'markRead': False}
    made.update(actions)
    return made


def palette_of(*slots):
    return lambda: frozenset(slots)


def no_palette_expected():
    raise AssertionError('the palette was read for a rule that sets no custom flag')


class PlainText(unittest.TestCase):

    def test_tags_go_and_entities_decode(self):
        self.assertEqual(rss_rules.plain_text('<p>Fish &amp; chips</p>'), 'Fish & chips')

    def test_inline_markup_does_not_split_a_word(self):
        self.assertEqual(rss_rules.plain_text('re<b>lease</b> day'), 'release day')

    def test_block_markup_separates_words(self):
        self.assertEqual(rss_rules.plain_text('<p>one</p><p>two</p>three<br>four'),
                         'one two three four')

    def test_script_and_style_are_not_text(self):
        self.assertEqual(
            rss_rules.plain_text('a<script>var release = 1;</script><style>p{}</style>b'), 'ab')

    def test_empty_and_none(self):
        self.assertEqual(rss_rules.plain_text(''), '')
        self.assertEqual(rss_rules.plain_text(None), '')


class Matching(unittest.TestCase):

    def test_contains_is_case_insensitive(self):
        self.assertTrue(rss_rules.matches(rule(('title', 'RELEASE')), SUB, text()))
        self.assertFalse(rss_rules.matches(rule(('title', 'beta')), SUB, text()))

    def test_conditions_are_anded(self):
        both = rule(('title', 'release'), ('author', 'ann'))
        one = rule(('title', 'release'), ('author', 'bob'))
        self.assertTrue(rss_rules.matches(both, SUB, text()))
        self.assertFalse(rss_rules.matches(one, SUB, text()))

    def test_no_conditions_matches_everything(self):
        self.assertTrue(rss_rules.matches(rule(), SUB, text()))

    def test_feed_is_the_subscription_id_exactly(self):
        self.assertTrue(rss_rules.matches(rule(('feed', SUB)), SUB, text()))
        self.assertFalse(rss_rules.matches(rule(('feed', 'sub-2')), SUB, text()))
        # Not a substring match and not case-folded: it is an id.
        self.assertFalse(rss_rules.matches(rule(('feed', 'sub')), SUB, text()))
        self.assertFalse(rss_rules.matches(rule(('feed', 'SUB-1')), SUB, text()))

    def test_summary_searches_summary_and_body_text(self):
        item = text(summary='<p>Short teaser</p>', content='<div>The <i>full</i> story</div>')
        self.assertTrue(rss_rules.matches(rule(('summary', 'teaser')), SUB, item))
        self.assertTrue(rss_rules.matches(rule(('summary', 'full story')), SUB, item))
        # Markup is not text: a tag name or attribute never matches.
        self.assertFalse(rss_rules.matches(rule(('summary', 'div')), SUB, item))

    def test_summary_matches_a_feed_with_only_a_body(self):
        item = text(summary='', content='<p>Security advisory</p>')
        self.assertTrue(rss_rules.matches(rule(('summary', 'advisory')), SUB, item))

    def test_title_matches_as_written_or_with_markup_removed(self):
        angled = text(title='Using <vector> well')
        marked = text(title='<em>Big</em> news')
        self.assertTrue(rss_rules.matches(rule(('title', 'vector')), SUB, angled))
        self.assertTrue(rss_rules.matches(rule(('title', 'big news')), SUB, marked))

    def test_whitespace_runs_do_not_defeat_a_match(self):
        item = text(title='Release   notes\n for  2.0')
        self.assertTrue(rss_rules.matches(rule(('title', 'release notes for')), SUB, item))

    def test_unknown_field_matches_nothing(self):
        # A mail field in a feed rule, or a field a later version adds.
        self.assertFalse(rss_rules.matches(rule(('subject', 'release')), SUB, text()))
        self.assertFalse(rss_rules.matches(rule(('_markup', 'hello')), SUB, text()))

    def test_malformed_conditions_match_nothing(self):
        for conditions in ('title', [None], [{'field': 'title'}],
                           [{'field': 'title', 'value': ''}],
                           [{'field': 'title', 'value': 7}]):
            broken = rule()
            broken['conditions'] = conditions
            self.assertFalse(rss_rules.matches(broken, SUB, text()), conditions)


class Evaluating(unittest.TestCase):

    def test_every_matching_rule_applies(self):
        rules = [rule(('title', 'release'), flag=True),
                 rule(('author', 'ann'), markRead=True, flags=[LATER]),
                 rule(('title', 'nope'), flags=[WORK])]
        outcome = rss_rules.evaluate(rules, SUB, text(), palette_of(LATER, WORK))
        self.assertTrue(outcome.flag)
        self.assertTrue(outcome.mark_read)
        self.assertEqual(outcome.flags, {LATER})
        self.assertEqual((outcome.matched, outcome.skipped), (2, 0))
        self.assertTrue(outcome)

    def test_nothing_matching_is_an_empty_outcome(self):
        outcome = rss_rules.evaluate([rule(('title', 'nope'), flag=True)], SUB, text(),
                                     no_palette_expected)
        self.assertFalse(outcome)
        self.assertEqual(outcome.matched, 0)

    def test_a_matching_rule_with_no_action_changes_nothing(self):
        outcome = rss_rules.evaluate([rule(('title', 'release'))], SUB, text(),
                                     no_palette_expected)
        self.assertFalse(outcome)
        self.assertEqual(outcome.matched, 1)

    def test_slot_not_in_palette_skips_the_whole_rule(self):
        rules = [rule(('title', 'release'), flags=[LATER, GONE], flag=True, markRead=True)]
        outcome = rss_rules.evaluate(rules, SUB, text(), palette_of(LATER))
        # Not even the parts of it that need no palette.
        self.assertFalse(outcome)
        self.assertEqual((outcome.matched, outcome.skipped), (0, 1))

    def test_a_skipped_rule_does_not_stop_the_others(self):
        rules = [rule(('title', 'release'), flags=[GONE]),
                 rule(('title', 'release'), markRead=True)]
        outcome = rss_rules.evaluate(rules, SUB, text(), palette_of(LATER))
        self.assertTrue(outcome.mark_read)
        self.assertEqual(outcome.flags, set())
        self.assertEqual((outcome.matched, outcome.skipped), (1, 1))

    def test_palette_is_not_read_unless_a_matching_rule_sets_a_slot(self):
        rules = [rule(('title', 'release'), flag=True),
                 rule(('title', 'nope'), flags=[LATER])]
        outcome = rss_rules.evaluate(rules, SUB, text(), no_palette_expected)
        self.assertTrue(outcome.flag)

    def test_unreadable_palette_fails_closed_for_slot_rules_only(self):
        rules = [rule(('title', 'release'), flags=[LATER]),
                 rule(('title', 'release'), flag=True)]
        outcome = rss_rules.evaluate(rules, SUB, text(), lambda: None)
        self.assertTrue(outcome.flag)
        self.assertEqual(outcome.flags, set())
        self.assertEqual(outcome.skipped, 1)

    def test_flags_that_are_not_slots_skip_the_rule(self):
        for flags in ('cabal-flag-03', ['\\Flagged'], ['cabal-flag-21'], [3]):
            broken = rule(('title', 'release'), flag=True)
            broken['flags'] = flags
            outcome = rss_rules.evaluate([broken], SUB, text(), palette_of(LATER))
            self.assertFalse(outcome, flags)
            self.assertEqual(outcome.skipped, 1, flags)

    def test_truthy_non_booleans_are_not_actions(self):
        outcome = rss_rules.evaluate([rule(('title', 'release'), flag='yes', markRead=1)],
                                     SUB, text(), no_palette_expected)
        self.assertFalse(outcome)


class Stored(unittest.TestCase):

    def test_only_enabled_rule_objects_are_kept(self):
        stored = json.dumps([rule(name='on'), rule(name='off', enabled=False), 'junk', None,
                             {'name': 'no enabled key'}])
        self.assertEqual([r['name'] for r in rss_rules.parse_rules(stored)], ['on'])

    def test_unreadable_values_have_no_rules(self):
        for raw in (None, '', 'not json', '{"a": 1}', '7'):
            self.assertEqual(rss_rules.parse_rules(raw), [], raw)

    def test_palette_slots(self):
        raw = json.dumps([{'slot': '\\Flagged', 'label': 'Urgent'},
                          {'slot': LATER, 'label': 'Later', 'enabled': False},
                          {'label': 'no slot'}, 'junk'])
        self.assertEqual(rss_rules.palette_slots(raw), frozenset(('\\Flagged', LATER)))
        for bad in (None, '', 'not json', '{}'):
            self.assertEqual(rss_rules.palette_slots(bad), frozenset(), bad)


if __name__ == '__main__':
    unittest.main()
