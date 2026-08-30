'''Unit tests for cabal-append-drain.py (rules-composition plan, decision 5
erratum): request validation, the owner-authentication contract, APPEND
argument shaping, and the always-answer/always-clean-up handling loop.

Run from the repo root (CI: lint.yml python job):
    python3 -m unittest discover -s docker/shared/test/append-drain -p "test_*.py"

The IMAP client is injected, so nothing here dials a server.
'''
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DRAIN = os.path.join(HERE, '..', '..', 'cabal-append-drain.py')

spec = importlib.util.spec_from_file_location('cabal_append_drain', DRAIN)
drain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drain)


def meta(**kw):
    base = {'user': 'alice', 'folder': 'Receipts',
            'flags': ['cabal-flag-01', '\\Seen']}
    base.update(kw)
    return base


class ValidateRequestTest(unittest.TestCase):
    def test_valid_shapes(self):
        self.assertIsNone(drain.validate_request(meta(), 'alice'))
        # root-owned files are the pre-DROPPRIVS pass.
        self.assertIsNone(drain.validate_request(meta(), 'root'))
        self.assertIsNone(drain.validate_request(
            meta(folder='INBOX', flags=['\\Flagged']), 'alice'))
        self.assertIsNone(drain.validate_request(
            meta(folder='Work.Clients'), 'alice'))
        self.assertIsNone(drain.validate_request(
            meta(folder='My Stuff'), 'alice'))

    def test_owner_mismatch_is_spoofing(self):
        self.assertIn('does not match',
                      drain.validate_request(meta(), 'mallory'))

    def test_bad_users(self):
        for user in ('', 'a b', 'a/b', None, 42):
            with self.subTest(user=user):
                self.assertEqual(
                    drain.validate_request(meta(user=user), 'root'),
                    'bad user')

    def test_bad_folders(self):
        for folder in ('', '.Receipts', 'a..b', 'a|b', 'a\nb', None,
                       '/abs', 'tick`tock'):
            with self.subTest(folder=folder):
                self.assertEqual(
                    drain.validate_request(meta(folder=folder), 'alice'),
                    'bad folder')

    def test_bad_flags(self):
        for flags in ([], None, 'cabal-flag-01', [42]):
            with self.subTest(flags=flags):
                self.assertEqual(
                    drain.validate_request(meta(flags=flags), 'alice'),
                    'bad flags')

    def test_flags_dedupe_before_the_cap(self):
        # Rule-own and pending keyword unions may repeat a slot (Phase 5);
        # the cap bounds the distinct vocabulary, not the token count.
        request = meta(flags=['cabal-flag-01'] * 30 + ['\\Seen'])
        self.assertIsNone(drain.validate_request(request, 'alice'))
        self.assertEqual(request['flags'], ['cabal-flag-01', '\\Seen'])
        # Distinct overflow is still refused.
        too_many = meta(flags=[f'cabal-flag-{i:02d}' for i in range(1, 21)]
                        + ['\\Seen', '\\Flagged', 'cabal-flag-01'])
        # 20 slots + 2 system = 22 distinct: at the cap, allowed.
        self.assertIsNone(drain.validate_request(too_many, 'alice'))
        for flag in ('\\Deleted', '\\Answered', 'cabal-flag-21',
                     'cabal-flag-00', '$Forwarded', 'a b'):
            with self.subTest(flag=flag):
                self.assertIn('not deliverable', drain.validate_request(
                    meta(flags=[flag]), 'alice'))


class ShapingTest(unittest.TestCase):
    def test_flag_list(self):
        self.assertEqual(
            drain.imap_flag_list(['cabal-flag-01', '\\Seen']),
            '(cabal-flag-01 \\Seen)')

    def test_mailbox_quoting(self):
        self.assertEqual(drain.quoted_mailbox('My Stuff'), '"My Stuff"')
        self.assertEqual(drain.quoted_mailbox('INBOX'), '"INBOX"')


class _FakeClient:
    def __init__(self, fail=False):
        self.fail = fail
        self.calls = []

    def login(self, user, password):
        self.calls.append(('login', user, password))
        if self.fail == 'login':
            raise RuntimeError('auth')

    def append(self, mailbox, flags, date_time, message):
        self.calls.append(('append', mailbox, flags, date_time, message))
        if self.fail == 'append':
            return 'NO', [b'nope']
        return 'OK', [b'done']

    def logout(self):
        self.calls.append(('logout',))


class HandleRequestTest(unittest.TestCase):
    '''End-to-end through handle_request with an injected client and a
    temp spool; pwd is stubbed so the file owner reads as the test user.'''

    def setUp(self):
        self.spool = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.spool.cleanup)
        self._spool_patch = mock.patch.object(
            drain, 'SPOOL_DIR', self.spool.name)
        self._spool_patch.start()
        self.addCleanup(self._spool_patch.stop)
        self._pwd_patch = mock.patch.object(
            drain.pwd, 'getpwuid',
            lambda uid: mock.Mock(pw_name=self.owner))
        self._pwd_patch.start()
        self.addCleanup(self._pwd_patch.stop)
        self.owner = 'alice'
        self.client = _FakeClient()

    def _spool(self, request, message=b'From: x\r\n\r\nbody\r\n'):
        msg = os.path.join(self.spool.name, 'n1.msg')
        with open(msg, 'wb') as handle:
            handle.write(message)
        # handle_request receives the CLAIMED (renamed) path, as the main
        # loop hands it over after the rename-as-claim.
        path = os.path.join(self.spool.name, '.work.n1.json')
        with open(path, 'w', encoding='utf-8') as handle:
            json.dump(request, handle)
        return path

    def _run(self):
        return drain.handle_request(
            self._path, 'cabal.example', 'master-pw',
            client_factory=lambda _domain: self.client)

    def test_delivers_and_cleans_up(self):
        self._path = self._spool(meta())
        verdict = self._run()
        self.assertEqual(verdict, 'ok')
        self.assertEqual(self.client.calls[0],
                         ('login', 'alice*admin', 'master-pw'))
        kind, mailbox, flags, date_time, message = self.client.calls[1]
        self.assertEqual((kind, mailbox, flags, date_time),
                         ('append', '"Receipts"', '(cabal-flag-01 \\Seen)',
                          None))
        self.assertIn(b'body', message)
        remaining = sorted(os.listdir(self.spool.name))
        self.assertEqual(remaining, ['n1.resp'])
        with open(os.path.join(self.spool.name, 'n1.resp'),
                  encoding='ascii') as handle:
            self.assertEqual(handle.read().strip(), 'ok')

    def test_response_is_chowned_to_the_requester(self):
        # The spool is sticky, so a root-owned response would be one the
        # requesting helper cannot collect-and-delete - its rm under
        # `set -e` then failed a SUCCESSFUL append into a duplicate
        # fall-through delivery. The drain must hand the response to the
        # request's owner before committing it.
        self._path = self._spool(meta())
        owner_uid = os.stat(self._path).st_uid
        with mock.patch.object(drain.os, 'chown') as chown:
            self.assertEqual(self._run(), 'ok')
        tmp = os.path.join(self.spool.name, '.tmp.n1.resp')
        chown.assert_called_once_with(tmp, owner_uid, -1)

    def test_chown_failure_still_commits_the_response(self):
        self._path = self._spool(meta())
        with mock.patch.object(drain.os, 'chown', side_effect=OSError):
            self.assertEqual(self._run(), 'ok')
        self.assertIn('n1.resp', os.listdir(self.spool.name))

    def test_spoofed_owner_is_refused_without_imap(self):
        self.owner = 'mallory'
        self._path = self._spool(meta())
        self.assertEqual(self._run(), 'fail')
        self.assertEqual(self.client.calls, [])
        self.assertEqual(sorted(os.listdir(self.spool.name)), ['n1.resp'])

    def test_append_failure_answers_fail(self):
        self.client = _FakeClient(fail='append')
        self._path = self._spool(meta())
        self.assertEqual(self._run(), 'fail')
        # logout still happened; the request files are gone either way.
        self.assertEqual(self.client.calls[-1], ('logout',))
        self.assertEqual(sorted(os.listdir(self.spool.name)), ['n1.resp'])

    def test_login_failure_answers_fail(self):
        self.client = _FakeClient(fail='login')
        self._path = self._spool(meta())
        self.assertEqual(self._run(), 'fail')

    def test_missing_message_half_fails(self):
        self._path = self._spool(meta())
        os.unlink(os.path.join(self.spool.name, 'n1.msg'))
        self.assertEqual(self._run(), 'fail')
        self.assertEqual(self.client.calls, [])

    def test_empty_message_fails(self):
        self._path = self._spool(meta(), message=b'')
        self.assertEqual(self._run(), 'fail')
        self.assertEqual(self.client.calls, [])

    def test_malformed_json_fails(self):
        msg = os.path.join(self.spool.name, 'n2.msg')
        with open(msg, 'wb') as handle:
            handle.write(b'x')
        self._path = os.path.join(self.spool.name, '.work.n2.json')
        with open(self._path, 'w', encoding='utf-8') as handle:
            handle.write('not json')
        self.assertEqual(self._run(), 'fail')
        self.assertEqual(self.client.calls, [])


class SweepTest(unittest.TestCase):
    def test_ages_out_responses_and_orphans(self):
        with tempfile.TemporaryDirectory() as spool:
            with mock.patch.object(drain, 'SPOOL_DIR', spool):
                fresh = os.path.join(spool, 'a.resp')
                stale_resp = os.path.join(spool, 'b.resp')
                stale_msg = os.path.join(spool, 'c.msg')
                for path in (fresh, stale_resp, stale_msg):
                    with open(path, 'w', encoding='ascii') as handle:
                        handle.write('x')
                old = drain.MAX_RESPONSE_AGE_SECONDS + 60
                os.utime(stale_resp, (0, 0))
                os.utime(stale_msg, (0, 0))
                del old
                drain.sweep_stale()
                self.assertEqual(sorted(os.listdir(spool)), ['a.resp'])


if __name__ == '__main__':
    unittest.main()
