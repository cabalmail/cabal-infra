'''Unit tests for dropping unsolicited FETCH entries before envelope decoding.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_unsolicited_fetch_entries.py

imapclient returns parse_fetch_response over every untagged FETCH imaplib has
collected, so a fetch response can hold `* N FETCH (FLAGS ...)` updates Dovecot
pushed for messages nobody asked about. These pin that /list_envelopes and
search's hydration both drop such an entry instead of handing it to
envelope_dict, which used to raise KeyError: b'ENVELOPE' and turn the whole
request into a 502 (#1990).

helper.py's third-party imports (boto3, botocore, imapclient, imap_session) are
faked in sys.modules before import, so the suite needs no AWS access and never
dials an IMAP server.
'''
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

# --- fake boto3 / botocore ---------------------------------------------------


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

# --- the fetch responses under test ------------------------------------------

_Address = types.SimpleNamespace


def _address(mailbox, host, name=None):
    return _Address(mailbox=mailbox.encode(), host=host.encode(),
                    name=name.encode() if name else None)


def _envelope(subject):
    '''The ENVELOPE attributes envelope_dict reads off a fetch entry.'''
    return types.SimpleNamespace(
        date='2026-10-20 12:00:00',
        subject=subject.encode(),
        from_=(_address('sender', 'example.com', 'A Sender'),),
        to=(_address('claude', 'test.example.com'),),
        cc=None,
        bcc=None,
        message_id=b'<one@example.com>',
        in_reply_to=None,
    )


def _solicited(subject, flags=(b'\\Seen',)):
    '''A complete entry, as a FETCH of ENVELOPE_FETCH_KEYS returns one.'''
    return {
        b'SEQ': 1,
        b'ENVELOPE': _envelope(subject),
        b'FLAGS': tuple(flags),
        b'BODYSTRUCTURE': (b'text', b'plain', (b'charset', b'utf-8'), None, None, b'7bit', 10, 1),
        b'BODY[HEADER.FIELDS (X-PRIORITY REFERENCES AUTHENTICATION-RESULTS)]': b'',
    }


# What Dovecot pushes when another session flags a message in the same folder:
# keyed by its own UID, carrying only SEQ, FLAGS and UID.
def _unsolicited_flags_update():
    return {b'SEQ': 7, b'FLAGS': (b'\\Flagged', b'\\Seen')}


# Requested uids, and the uid of a message nobody asked about.
REQUESTED = [841, 840]
BYSTANDER = 221

FETCHED = {}
SELECTED = []
OPENED = []


class _FakeImapClient:
    def __init__(self):
        self.fetches = []
        self.logged_out = False

    def fetch(self, ids, keys):
        self.fetches.append((list(ids), list(keys)))
        return dict(FETCHED)

    def folder_status(self, _folder, _attrs):
        return {b'MESSAGES': 22, b'UNSEEN': 0, b'UIDVALIDITY': 1, b'UIDNEXT': 900}

    def search(self, criteria):
        return list(range(1, 23)) if 'NOT' in criteria else []

    def select_folder(self, folder, readonly=False):
        SELECTED.append((folder, readonly))

    def logout(self):
        self.logged_out = True


def _open_imap_client(host, user, folder, _read_only, _mpw):
    client = _FakeImapClient()
    OPENED.append({'host': host, 'user': user, 'folder': folder, 'client': client})
    return client


if 'imap_session' not in sys.modules:
    _imap_session = types.ModuleType("imap_session")
    _imap_session.open_imap_client = _open_imap_client
    sys.modules['imap_session'] = _imap_session

import helper  # noqa: E402  pylint: disable=wrong-import-position


def _load_handler(name):
    '''Imports lambda/api/<name>/function.py under a unique module name (#860).'''
    spec = importlib.util.spec_from_file_location(
        f'{name}_function_1990', os.path.join(_API_DIR, name, 'function.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


list_envelopes = _load_handler('list_envelopes')
search_envelopes = _load_handler('search_envelopes')

_SAVED = {}


def setUpModule():
    '''Binds this suite's fake into `helper` whatever the import order (#860).'''
    _SAVED['open_imap_client'] = helper.open_imap_client
    helper.open_imap_client = _open_imap_client


def tearDownModule():
    helper.open_imap_client = _SAVED['open_imap_client']


def _event(ids):
    return {
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'testuser'}}},
        'queryStringParameters': {'host': 'mail.test.example.com', 'folder': 'INBOX',
                                  'ids': json.dumps(ids)},
    }


class UnsolicitedFetchEntryTest(unittest.TestCase):

    def setUp(self):
        FETCHED.clear()
        SELECTED.clear()
        OPENED.clear()
        FETCHED.update({uid: _solicited(f'subject {uid}') for uid in REQUESTED})

    def test_list_envelopes_ignores_an_update_for_a_message_nobody_asked_about(self):
        '''The reported race: the 502 was this entry reaching envelope_dict.'''
        FETCHED[BYSTANDER] = _unsolicited_flags_update()
        response = list_envelopes.handler(_event(REQUESTED), None)
        self.assertEqual(response['statusCode'], 200)
        envelopes = json.loads(response['body'])['envelopes']
        self.assertEqual(sorted(envelopes), ['840', '841'])
        self.assertNotIn(str(BYSTANDER), envelopes)
        self.assertEqual(envelopes['841']['subject'], 'subject 841')
        self.assertEqual(envelopes['841']['flags'], ['\\Seen'])

    def test_list_envelopes_drops_a_requested_id_whose_entry_has_no_envelope(self):
        '''The unobserved hazard: an update keyed by a sequence number that is
        also a requested uid leaves that entry carrying FLAGS and nothing else.
        One unusable row beats a 502 for the page.'''
        FETCHED[840] = _unsolicited_flags_update()
        response = list_envelopes.handler(_event(REQUESTED), None)
        self.assertEqual(response['statusCode'], 200)
        envelopes = json.loads(response['body'])['envelopes']
        self.assertEqual(list(envelopes), ['841'])

    def test_list_envelopes_still_returns_nothing_for_an_empty_folder(self):
        '''A uid that left the mailbox mid-fetch returns no entry at all.'''
        FETCHED.clear()
        response = list_envelopes.handler(_event(REQUESTED), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body'])['envelopes'], {})

    def test_search_hydration_ignores_an_unsolicited_entry(self):
        FETCHED[BYSTANDER] = _unsolicited_flags_update()
        triples = [('2026-10-20', 'INBOX', 841), ('2026-10-19', 'INBOX', 840)]
        client = _FakeImapClient()
        hydrated = search_envelopes.fetch_envelopes_grouped(client, triples)
        self.assertEqual([env['id'] for env in hydrated], [841, 840])
        self.assertEqual([env['folder'] for env in hydrated], ['INBOX', 'INBOX'])

    def test_search_hydration_drops_an_entry_with_no_envelope(self):
        FETCHED[840] = _unsolicited_flags_update()
        triples = [('2026-10-20', 'INBOX', 841), ('2026-10-19', 'INBOX', 840)]
        hydrated = search_envelopes.fetch_envelopes_grouped(_FakeImapClient(), triples)
        self.assertEqual([env['id'] for env in hydrated], [841])

    def test_entries_come_back_in_the_order_they_were_requested(self):
        '''The reply's order must not depend on when an update arrived.'''
        FETCHED.clear()
        FETCHED[BYSTANDER] = _unsolicited_flags_update()
        FETCHED.update({uid: _solicited(f'subject {uid}') for uid in reversed(REQUESTED)})
        entries = helper.solicited_envelope_entries(FETCHED, REQUESTED)
        self.assertEqual([uid for uid, _ in entries], REQUESTED)


if __name__ == '__main__':
    unittest.main()
