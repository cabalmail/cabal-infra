'''Unit tests for /search_envelopes' flag filters beyond `flagged` (docs/1.x/
cross-media-ux-plan.md, decision 8 and Phase 2a). `keyword`: a custom flag's
palette slot becomes an IMAP KEYWORD criterion, and anything that is not a
slot is a 400 before any IMAP session opens. `any_flag`: one OR over the
system flag and every palette slot. A request without either builds the
criteria it always did.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_search_envelopes_keyword.py

helper.py's third-party imports (boto3, botocore, imapclient, imap_session)
are faked in sys.modules before import, so the suite needs no AWS access and
never dials an IMAP server.
'''
import datetime
import importlib.util
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_SHARED_DIR = os.path.dirname(_TESTS_DIR)
_API_DIR = os.path.dirname(_SHARED_DIR)
sys.path.insert(0, _SHARED_DIR)

# --- fake boto3 / botocore / imapclient / imap_session -----------------------


class _FakeSSMExceptions:
    class ParameterNotFound(Exception):
        pass


class _FakeSSM:
    exceptions = _FakeSSMExceptions

    def get_parameter(self, Name=None, **_kwargs):  # pylint: disable=invalid-name
        if Name == '/cabal/maintenance/imap':
            raise _FakeSSMExceptions.ParameterNotFound()
        return {"Parameter": {"Value": "fake-master-password"}}


class _FakeResource:
    def Table(self, _name):  # pylint: disable=invalid-name
        return types.SimpleNamespace()


if 'boto3' not in sys.modules:
    _boto3 = types.ModuleType("boto3")
    _boto3.resource = lambda _name, **_kw: _FakeResource()
    _boto3.client = lambda name, **_kw: _FakeSSM() if name == 'ssm' else types.SimpleNamespace()
    _boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
    sys.modules['boto3'] = _boto3

if 'botocore' not in sys.modules:
    _botocore = types.ModuleType("botocore")
    _botocore_exceptions = types.ModuleType("botocore.exceptions")

    class _ClientError(Exception):
        pass

    _botocore_exceptions.ClientError = _ClientError
    _botocore.exceptions = _botocore_exceptions
    sys.modules['botocore'] = _botocore
    sys.modules['botocore.exceptions'] = _botocore_exceptions

if 'imapclient' not in sys.modules:
    _imapclient = types.ModuleType("imapclient")
    _imapclient_exceptions = types.ModuleType("imapclient.exceptions")

    class _IMAPClientError(Exception):
        pass

    _imapclient_exceptions.IMAPClientError = _IMAPClientError
    _imapclient.exceptions = _imapclient_exceptions
    sys.modules['imapclient'] = _imapclient
    sys.modules['imapclient.exceptions'] = _imapclient_exceptions

if 'imap_session' not in sys.modules:
    _imap_session = types.ModuleType("imap_session")
    _imap_session.open_imap_client = lambda *_a, **_kw: None
    sys.modules['imap_session'] = _imap_session


def _load_handler(name):
    '''Imports lambda/api/<name>/function.py under a unique module name (#860).'''
    spec = importlib.util.spec_from_file_location(
        f'{name}_function_keyword', os.path.join(_API_DIR, name, 'function.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


search_envelopes = _load_handler('search_envelopes')

LATER, WORK = 'cabal-flag-03', 'cabal-flag-05'
DAY = datetime.datetime(2026, 11, 1, 12, 0, 0)

# The mailbox the fake serves: folder (IMAP name) -> {uid: flags}.
MAILBOX = {
    'INBOX': {11: {'\\Seen', LATER}, 12: {'\\Flagged'}, 13: {LATER, WORK}, 14: set()},
    'Archive.2026': {21: {WORK}, 22: {'\\Flagged', LATER}, 23: {'$Forwarded'}},
    'Trash': {31: {LATER}},
}
SESSIONS = []


def _one_key_holds(rest, flags):
    '''Takes one search key off the front of `rest`, as IMAP reads a SEARCH,
    and says whether a message carrying `flags` matches it. OR is a key made
    of the two keys after it.'''
    term = rest.pop(0)
    if term == 'OR':
        first = _one_key_holds(rest, flags)
        second = _one_key_holds(rest, flags)
        return first or second
    if term == 'FLAGGED':
        return '\\Flagged' in flags
    if term == 'UNSEEN':
        return '\\Seen' not in flags
    if term == 'KEYWORD':
        return rest.pop(0) in flags
    if term == 'ALL':
        return True
    raise AssertionError(f'unexpected criterion {term!r}')


class _FakeImapClient:
    '''Answers SEARCH for the criteria these tests send: ALL, FLAGGED, UNSEEN,
    KEYWORD <atom> and OR <key> <key>. Every key at the top level must hold.'''

    def __init__(self):
        self.selected = None
        self.searches = []

    def select_folder(self, folder, readonly=False):  # pylint: disable=unused-argument
        self.selected = folder

    def list_sub_folders(self):
        return [((), b'.', name) for name in MAILBOX]

    def search(self, criteria, charset=None):
        self.searches.append((self.selected, list(criteria), charset))
        uids = []
        for uid, flags in MAILBOX[self.selected].items():
            keep, rest = True, list(criteria)
            while rest:
                # The key is read first, so a key that fails still leaves
                # the ones after it to be read.
                keep = _one_key_holds(rest, flags) and keep
            if keep:
                uids.append(uid)
        return uids

    def fetch(self, uids, _keys):
        return {uid: {b'INTERNALDATE': DAY} for uid in uids}

    def logout(self):
        pass


def _get_imap_client(_host, _user, folder, _read_only=False):
    client = _FakeImapClient()
    client.selected = folder
    SESSIONS.append(client)
    return client


def _hydrate(_client, triples):
    '''Stands in for the envelope fetch, which is not what is under test.'''
    return [{'id': uid, 'folder': folder} for _date, folder, uid in triples]


_SAVED = {}


def setUpModule():
    for name, fake in (('get_imap_client', _get_imap_client), ('fetch_envelopes_grouped', _hydrate)):
        _SAVED[name] = getattr(search_envelopes, name)
        setattr(search_envelopes, name, fake)


def tearDownModule():
    for name, real in _SAVED.items():
        setattr(search_envelopes, name, real)


def _search(**params):
    event = {
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'tester'}}},
        'queryStringParameters': {'host': 'imap.test.example.com', **params},
    }
    response = search_envelopes.handler(event, None)
    return response['statusCode'], json.loads(response['body'])


def _found(body):
    return sorted((env['folder'], env['id']) for env in body['envelopes'])


# `any_flag` as IMAP sees it: twenty ORs, each over one key and the rest of
# the chain, ending on the last slot's key.
ANY_FLAG = ['OR', 'FLAGGED'] + [
    term for number in range(1, 20) for term in ('OR', 'KEYWORD', f'cabal-flag-{number:02d}')
] + ['KEYWORD', 'cabal-flag-20']

NOT_SLOTS = (
    '\\Flagged', 'Flagged', '$Junk', 'NonJunk', 'later', 'cabal-flag', 'cabal-flag-',
    'cabal-flag-00', 'cabal-flag-21', 'cabal-flag-1', 'cabal-flag-001', 'CABAL-FLAG-03',
    'cabal-flag-03 cabal-flag-05', 'cabal-flag-03 OR ALL', 'ALL', '*',
    'cabal-flag-03\r\nA1 DELETE INBOX', '"cabal-flag-03"', 'cabal-flag-03)',
)


class Criteria(unittest.TestCase):
    '''build_criteria, the translation from the query string to IMAP SEARCH.'''

    def test_keyword_becomes_one_keyword_criterion(self):
        self.assertEqual(search_envelopes.build_criteria({'keyword': LATER}, None), ['KEYWORD', LATER])

    def test_every_palette_slot_is_accepted(self):
        for number in range(1, 21):
            slot = f'cabal-flag-{number:02d}'
            with self.subTest(slot=slot):
                self.assertEqual(search_envelopes.build_criteria({'keyword': slot}, None),
                                 ['KEYWORD', slot])

    def test_keyword_joins_the_other_filters(self):
        qs = {'text': 'quarterly report', 'from': 'a@example.com', 'since': '2026-01-01',
              'unread': '1', 'flagged': '1', 'keyword': WORK}
        self.assertEqual(search_envelopes.build_criteria(qs, None), [
            'TEXT', 'quarterly', 'TEXT', 'report', 'FROM', 'a@example.com',
            'SINCE', datetime.date(2026, 1, 1), 'UNSEEN', 'FLAGGED', 'KEYWORD', WORK])

    def test_keyword_keeps_the_cursor_prune(self):
        cursor = {'last_date': '2026-11-01', 'last_folder': 'INBOX', 'last_uid': 9}
        self.assertEqual(search_envelopes.build_criteria({'keyword': LATER}, cursor),
                         ['KEYWORD', LATER, 'BEFORE', datetime.date(2026, 11, 2)])

    def test_anything_but_a_slot_is_refused(self):
        for value in NOT_SLOTS:
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as raised:
                    search_envelopes.build_criteria({'keyword': value}, None)
                self.assertIn('invalid keyword', str(raised.exception))
                # `any_flag` beside it does not let it through.
                with self.assertRaises(ValueError):
                    search_envelopes.build_criteria({'keyword': value, 'any_flag': '1'}, None)

    def test_requests_without_a_keyword_build_what_they_always_did(self):
        # What every shipped client sends. The expected lists are the
        # criteria as they stood before `keyword` existed.
        cursor = {'last_date': '2026-11-01', 'last_folder': 'INBOX', 'last_uid': 9}
        cases = (
            ({}, None, ['ALL']),
            ({'text': ' two words '}, None, ['TEXT', 'two', 'TEXT', 'words']),
            ({'from': 'a', 'to': 'b', 'subject': 'c d'}, None, ['FROM', 'a', 'TO', 'b', 'SUBJECT', 'c d']),
            ({'since': '2026-01-01', 'before': '2026-02-01'}, None,
             ['SINCE', datetime.date(2026, 1, 1), 'BEFORE', datetime.date(2026, 2, 1)]),
            ({'unread': '1'}, None, ['UNSEEN']),
            ({'flagged': 'true'}, None, ['FLAGGED']),
            ({'unread': '0', 'flagged': 'no', 'has_attachment': '1'}, None, ['ALL']),
            ({'flagged': '1'}, cursor, ['FLAGGED', 'BEFORE', datetime.date(2026, 11, 2)]),
        )
        for qs, cur, expected in cases:
            with self.subTest(qs=qs):
                self.assertEqual(search_envelopes.build_criteria(qs, cur), expected)
                # An empty or blank keyword is no keyword.
                for blank in ('', '  ', None):
                    self.assertEqual(search_envelopes.build_criteria({**qs, 'keyword': blank}, cur),
                                     expected)
                # Nor is an `any_flag` that is not a yes.
                for off in ('', '0', 'no', 'false', 'False', 'on', None):
                    self.assertEqual(search_envelopes.build_criteria({**qs, 'any_flag': off}, cur),
                                     expected)

    def test_any_flag_is_an_or_over_the_system_flag_and_every_slot(self):
        criteria = search_envelopes.build_criteria({'any_flag': '1'}, None)
        self.assertEqual(criteria, ANY_FLAG)
        # Every yes the other switches take, and no other spelling.
        for yes in sorted(search_envelopes.TRUTHY):
            with self.subTest(yes=yes):
                self.assertEqual(search_envelopes.build_criteria({'any_flag': yes}, None), ANY_FLAG)
        self.assertEqual(criteria.count('OR'), 20)
        self.assertEqual(
            [term for term in criteria if term not in ('OR', 'KEYWORD')],
            ['FLAGGED'] + [f'cabal-flag-{number:02d}' for number in range(1, 21)])

    def test_any_flag_reads_as_one_search_key(self):
        # What lets it sit among the other filters: read as IMAP reads it,
        # the chain is used up exactly, so the key after it is not drawn
        # into the last OR.
        rest = search_envelopes.build_criteria({'any_flag': '1'}, None) + ['UNSEEN']
        _one_key_holds(rest, set())
        self.assertEqual(rest, ['UNSEEN'])

    def test_any_flag_matches_each_flag_alone_and_nothing_else(self):
        def _any_flag():
            return search_envelopes.build_criteria({'any_flag': '1'}, None)

        carried = ['\\Flagged'] + [f'cabal-flag-{number:02d}' for number in range(1, 21)]
        for flag in carried:
            with self.subTest(flag=flag):
                self.assertTrue(_one_key_holds(_any_flag(), {flag, '\\Seen'}))
        for flags in (set(), {'\\Seen'}, {'$Forwarded', 'NonJunk'}, {'cabal-flag-21'}, {'\\Answered'}):
            with self.subTest(flags=flags):
                self.assertFalse(_one_key_holds(_any_flag(), flags))

    def test_any_flag_joins_the_other_filters(self):
        qs = {'text': 'report', 'unread': '1', 'flagged': '1', 'keyword': WORK, 'any_flag': '1'}
        cursor = {'last_date': '2026-11-01', 'last_folder': 'INBOX', 'last_uid': 9}
        self.assertEqual(search_envelopes.build_criteria(qs, cursor), [
            'TEXT', 'report', 'UNSEEN', 'FLAGGED', 'KEYWORD', WORK, *ANY_FLAG,
            'BEFORE', datetime.date(2026, 11, 2)])
        # The list's own request for a second page: the chain, then the
        # cursor's date, and the chain as it was for the request after.
        self.assertEqual(search_envelopes.build_criteria({'any_flag': '1'}, cursor),
                         [*ANY_FLAG, 'BEFORE', datetime.date(2026, 11, 2)])
        self.assertEqual(search_envelopes.build_criteria({'any_flag': '1'}, None), ANY_FLAG)


class Handler(unittest.TestCase):
    '''The endpoint end to end over a fake mailbox.'''

    def setUp(self):
        SESSIONS.clear()

    def test_one_folder_returns_only_messages_carrying_the_flag(self):
        status, body = _search(folder='INBOX', keyword=LATER)
        self.assertEqual(status, 200)
        self.assertEqual(_found(body), [('INBOX', 11), ('INBOX', 13)])
        self.assertEqual(body['total_estimate'], 2)
        self.assertEqual(SESSIONS[0].searches, [('INBOX', ['KEYWORD', LATER], 'UTF-8')])

    def test_all_folders_filters_each_and_still_skips_trash(self):
        status, body = _search(keyword=LATER)
        self.assertEqual(status, 200)
        self.assertEqual(_found(body), [('Archive/2026', 22), ('INBOX', 11), ('INBOX', 13)])
        self.assertEqual(body['folders_searched'], ['INBOX', 'Archive/2026'])
        self.assertEqual([(folder, criteria) for folder, criteria, _ in SESSIONS[0].searches],
                         [('INBOX', ['KEYWORD', LATER]), ('Archive.2026', ['KEYWORD', LATER])])

    def test_keyword_narrows_the_other_flag_filters(self):
        self.assertEqual(_found(_search(keyword=LATER, flagged='1')[1]), [('Archive/2026', 22)])
        self.assertEqual(_found(_search(folder='INBOX', keyword=LATER, unread='1')[1]), [('INBOX', 13)])

    def test_a_slot_no_message_carries_finds_nothing(self):
        status, body = _search(keyword='cabal-flag-20')
        self.assertEqual((status, body['envelopes'], body['total_estimate']), (200, [], 0))

    def test_without_a_keyword_nothing_is_filtered(self):
        status, body = _search(folder='INBOX')
        self.assertEqual((status, len(body['envelopes'])), (200, 4))
        self.assertEqual(SESSIONS[0].searches, [('INBOX', ['ALL'], 'UTF-8')])

    def test_any_flag_in_one_folder_returns_every_flagged_message(self):
        status, body = _search(folder='INBOX', any_flag='1')
        self.assertEqual(status, 200)
        self.assertEqual(_found(body), [('INBOX', 11), ('INBOX', 12), ('INBOX', 13)])
        self.assertEqual(body['total_estimate'], 3)
        self.assertEqual(SESSIONS[0].searches, [('INBOX', ANY_FLAG, 'UTF-8')])

    def test_any_flag_across_folders_skips_trash_and_other_keywords(self):
        status, body = _search(any_flag='1')
        self.assertEqual(status, 200)
        # Not Archive's 23, whose only keyword is one the API never stores,
        # and not Trash's 31.
        self.assertEqual(_found(body), [
            ('Archive/2026', 21), ('Archive/2026', 22), ('INBOX', 11), ('INBOX', 12), ('INBOX', 13)])
        self.assertEqual(body['folders_searched'], ['INBOX', 'Archive/2026'])

    def test_any_flag_narrows_and_is_narrowed_by_the_other_filters(self):
        self.assertEqual(_found(_search(folder='INBOX', any_flag='1', unread='1')[1]),
                         [('INBOX', 12), ('INBOX', 13)])
        self.assertEqual(_found(_search(any_flag='1', flagged='1')[1]),
                         [('Archive/2026', 22), ('INBOX', 12)])
        self.assertEqual(_found(_search(any_flag='1', keyword=WORK)[1]),
                         [('Archive/2026', 21), ('INBOX', 13)])

    def test_an_any_flag_that_is_not_a_yes_filters_nothing(self):
        status, body = _search(folder='INBOX', any_flag='0')
        self.assertEqual((status, len(body['envelopes'])), (200, 4))
        self.assertEqual(SESSIONS[0].searches, [('INBOX', ['ALL'], 'UTF-8')])

    def test_a_keyword_that_is_not_a_slot_is_a_400_before_any_session(self):
        for value in NOT_SLOTS:
            with self.subTest(value=value):
                status, body = _search(folder='INBOX', keyword=value)
                self.assertEqual(status, 400)
                self.assertIn('invalid keyword', body['Error'])
        self.assertEqual(SESSIONS, [])


if __name__ == '__main__':
    unittest.main()
