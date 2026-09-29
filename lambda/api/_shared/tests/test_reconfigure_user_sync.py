'''Unit test for the reconfigure sidecar converging OS accounts on the Cognito
pool, not only at container start.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_reconfigure_user_sync.py

Issue #1721: sync-users.sh had exactly one caller, entrypoint.sh, so a Cognito
user created outside the signup flow -- AdminCreateUser, or Terraform's
aws_cognito_user, neither of which fires the PostConfirmation trigger that
force-rolls the services -- had no passwd entry and no Maildir until the tier
next rolled for an unrelated reason. Measured on stage: the ci-probe user was
created 2026-09-24 22:54:43Z and provisioned at 23:06:07Z only because an
unrelated docker deploy happened to follow, while the running container did a
full map regeneration at 23:03:21Z with the user still absent.

There is no seam for a bash sidecar's control flow, so this reads the two
scripts, in the shape the repo's other invariant scans take. Four things have
to hold together, which is why they are pinned in one place: the sync is called
from regenerate(), it is gated on the same tiers entrypoint.sh gates it on
(smtp-in has no local users and dropped the capabilities the sync needs), it
cannot take the loop down with it (reconfigure.sh runs under `set -e`), and it
precedes compile-user-rules.py, whose user list is derived from the synced
homes.
'''
import os
import re
import unittest

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))))))
RECONFIGURE = os.path.join(_ROOT, 'docker', 'shared', 'reconfigure.sh')
ENTRYPOINT = os.path.join(_ROOT, 'docker', 'shared', 'entrypoint.sh')

SYNC = '/usr/local/bin/sync-users.sh'
COMPILE = '/usr/local/bin/compile-user-rules.py'
# The tier gate, either script's spelling: `[ "$TIER" = "imap" ] || [ "$TIER" = "smtp-out" ]`
GATE = re.compile(r'\[\s*"\$TIER"\s*=\s*"([a-z-]+)"\s*\]')


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def code(body):
    '''`body` with comment lines cut, so prose naming a script is not a call.'''
    return '\n'.join(re.sub(r'(^|\s)#.*$', '', line) for line in body.split('\n'))


def shell_function(body, name):
    '''The body of `name() { ... }`, from its opener to the line that is a bare `}`.'''
    lines = body.split('\n')
    for i, line in enumerate(lines):
        if line.startswith('%s() {' % name):
            for j in range(i + 1, len(lines)):
                if lines[j] == '}':
                    return '\n'.join(lines[i + 1:j])
            raise AssertionError('%s() is not closed' % name)
    raise AssertionError('%s() not found' % name)


def gated_tiers(body, target):
    '''The tiers named by the `if` that guards the line calling `target`.'''
    lines = body.split('\n')
    for i, line in enumerate(lines):
        if target in line:
            for j in range(i, -1, -1):
                if lines[j].lstrip().startswith('if '):
                    return sorted(GATE.findall(lines[j]))
                if lines[j].lstrip().startswith('fi'):
                    return []          # the guard above belongs to an earlier block
            return []
    raise AssertionError('%s is not called' % target)


class ReconfigureSyncsUsers(unittest.TestCase):

    def setUp(self):
        self.reconfigure = code(read(RECONFIGURE))
        self.entrypoint = code(read(ENTRYPOINT))
        self.regenerate = shell_function(self.reconfigure, 'regenerate')

    # ── the invariant ──────────────────────────────────────────

    def test_regenerate_syncs_users(self):
        self.assertIn(
            SYNC, self.regenerate,
            'regenerate() must call sync-users.sh, or a Cognito user created '
            'outside the signup flow gets no OS account until the tier rolls (#1721)')

    def test_the_sync_is_gated_on_the_same_tiers_as_the_startup_sync(self):
        self.assertEqual(
            gated_tiers(self.regenerate, SYNC), gated_tiers(self.entrypoint, SYNC),
            'the reconfigure gate and the entrypoint gate must name the same tiers: '
            'smtp-in has no local users and dropped CHOWN/FOWNER/DAC_OVERRIDE')
        self.assertEqual(gated_tiers(self.regenerate, SYNC), ['imap', 'smtp-out'])

    def test_a_failed_sync_cannot_kill_the_loop(self):
        line = [l for l in self.regenerate.split('\n') if SYNC in l][0]
        tail = self.regenerate.split(SYNC, 1)[1].split('\n')[0:2]
        self.assertTrue(
            '||' in line or '||' in '\n'.join(tail),
            'reconfigure.sh runs under `set -e`: an unguarded sync-users failure '
            'takes the whole reconfigure sidecar down')

    def test_the_sync_precedes_the_rules_compiler(self):
        self.assertLess(
            self.regenerate.index(SYNC), self.regenerate.index(COMPILE),
            'compile-user-rules.py derives its user list from /home/*/Maildir, so '
            'a user synced after it is not compiled until the next pass')

    # ── detector self-tests ────────────────────────────────────

    def test_shell_function_slices_the_declaration_not_the_file(self):
        body = ('before() {\n  ' + SYNC + '\n}\n'
                'regenerate() {\n  echo hi\n}\n'
                'after() {\n  ' + SYNC + '\n}\n')
        self.assertEqual(shell_function(body, 'regenerate'), '  echo hi')
        with self.assertRaises(AssertionError):
            shell_function(body, 'absent')

    def test_the_scan_reads_code_not_prose(self):
        self.assertNotIn(SYNC, code('# see ' + SYNC + ' for the startup sync'))
        self.assertIn(SYNC, code('  ' + SYNC + '  # the startup sync'))

    def test_gated_tiers_reads_the_guard_above_the_call(self):
        guarded = ('if [ "$TIER" = "imap" ] || [ "$TIER" = "smtp-out" ]; then\n'
                   '  ' + SYNC + '\nfi\n')
        self.assertEqual(gated_tiers(guarded, SYNC), ['imap', 'smtp-out'])
        self.assertEqual(gated_tiers('  ' + SYNC + '\n', SYNC), [],
                         'an ungated call must not borrow a gate')
        earlier = ('if [ "$TIER" = "imap" ]; then\n  echo x\nfi\n' + SYNC + '\n')
        self.assertEqual(gated_tiers(earlier, SYNC), [],
                         "a closed block's gate is not this call's gate")
        with self.assertRaises(AssertionError):
            gated_tiers('echo nothing\n', SYNC)

    # ── corpus floor ───────────────────────────────────────────

    def test_both_scripts_are_read(self):
        for path, body in ((RECONFIGURE, self.reconfigure), (ENTRYPOINT, self.entrypoint)):
            self.assertGreater(len(body), 2000, '%s: mis-rooted or truncated read' % path)
        self.assertIn('regenerate()', self.reconfigure)
        self.assertIn(COMPILE, self.regenerate, 'the rules compiler left regenerate()')


if __name__ == '__main__':
    unittest.main()
