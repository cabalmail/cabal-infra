'''Unit tests for the /folder_status handler's SEARCH-derived counts.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_folder_status_counts.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access and never dials an
IMAP server. The fake IMAP client records every SEARCH, which is what these
tests pin: the cheap STATUS-only path runs none, and `?flagged=1` runs the two
that need the folder selected -- the flagged count, and the NOT DELETED count
the list's positions are in (#1836).
'''
import importlib.util
import os
import json
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


_boto3 = types.ModuleType("boto3")
_boto3.resource = lambda _name, **_kw: _FakeResource()
_boto3.client = lambda name, **_kw: _FakeSSM() if name == 'ssm' else types.SimpleNamespace()
_boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
sys.modules['boto3'] = _boto3

_botocore = types.ModuleType("botocore")
_botocore_exceptions = types.ModuleType("botocore.exceptions")


class _ClientError(Exception):
    pass


_botocore_exceptions.ClientError = _ClientError
_botocore.exceptions = _botocore_exceptions
sys.modules['botocore'] = _botocore
sys.modules['botocore.exceptions'] = _botocore_exceptions

# --- fake imap_session -------------------------------------------------------

# The folder as the fakes answer for it: 40 messages counted by STATUS, two of
# them flagged \Deleted and not yet expunged, so 38 in the NOT DELETED set and
# 3 of those flagged.
STATUS = {b'MESSAGES': 40, b'UNSEEN': 5, b'UIDVALIDITY': 77, b'UIDNEXT': 900}
SEARCH_RESULTS = {
    ('FLAGGED', 'NOT', 'DELETED'): [1, 2, 3],
    ('NOT', 'DELETED'): list(range(1, 39)),
}
OPENED = []


class _FakeImapClient:
    def __init__(self):
        self.searches = []
        self.statuses = []
        self.logged_out = False

    def folder_status(self, folder, attrs):
        self.statuses.append((folder, list(attrs)))
        return dict(STATUS)

    def search(self, criteria):
        self.searches.append(list(criteria))
        return list(SEARCH_RESULTS[tuple(criteria)])

    def logout(self):
        self.logged_out = True


def _open_imap_client(host, user, folder, _read_only, _mpw):
    client = _FakeImapClient()
    OPENED.append({'host': host, 'user': user, 'folder': folder, 'client': client})
    return client


_imap_session = types.ModuleType("imap_session")
_imap_session.open_imap_client = _open_imap_client
sys.modules['imap_session'] = _imap_session

import helper  # noqa: E402  pylint: disable=wrong-import-position

_SPEC = importlib.util.spec_from_file_location(
    'folder_status_function', os.path.join(_API_DIR, 'folder_status', 'function.py'))
function = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(function)

_SAVED = {}


def setUpModule():
    '''Binds this suite's fake into `helper` whatever the import order (#860).'''
    _SAVED['open_imap_client'] = helper.open_imap_client
    helper.open_imap_client = _open_imap_client


def tearDownModule():
    helper.open_imap_client = _SAVED['open_imap_client']


def _event(params):
    return {
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'testuser'}}},
        'queryStringParameters': params,
    }


class FolderStatusCountsTest(unittest.TestCase):

    def setUp(self):
        OPENED.clear()

    def test_cheap_path_returns_status_only_and_searches_nothing(self):
        response = function.handler(_event({'folder': 'Lists/Cabal'}), None)
        self.assertEqual(response['statusCode'], 200)
        body = json.loads(response['body'])
        self.assertEqual(body, {'messages': 40, 'unseen': 5, 'uid_validity': 77, 'uid_next': 900})
        opened = OPENED[-1]
        # STATUS reads any folder regardless of selection, so the cheap path
        # stays on INBOX and runs no SEARCH.
        self.assertEqual(opened['folder'], 'INBOX')
        self.assertEqual(opened['client'].searches, [])
        self.assertEqual(opened['client'].statuses, [('Lists.Cabal', function.ATTRS)])
        self.assertTrue(opened['client'].logged_out)

    def test_flagged_path_returns_both_search_counts(self):
        response = function.handler(_event({'folder': 'Lists/Cabal', 'flagged': '1'}), None)
        self.assertEqual(response['statusCode'], 200)
        body = json.loads(response['body'])
        self.assertEqual(body['flagged'], 3)
        # The count /list_messages' positions are over: MESSAGES still counts
        # the two \Deleted-but-unexpunged messages it leaves out (#1836).
        self.assertEqual(body['undeleted'], 38)
        self.assertEqual(body['messages'], 40)
        opened = OPENED[-1]
        self.assertEqual(opened['folder'], 'Lists.Cabal', 'SEARCH needs the target folder selected')
        self.assertEqual(opened['client'].searches,
                         [['FLAGGED', 'NOT', 'DELETED'], ['NOT', 'DELETED']])
        self.assertTrue(opened['client'].logged_out)

    def test_rejects_a_bad_folder_without_opening_a_client(self):
        self.assertEqual(function.handler(_event({'folder': ''}), None)['statusCode'], 400)
        self.assertEqual(function.handler(_event({'folder': 'x' * 300}), None)['statusCode'], 400)
        self.assertEqual(OPENED, [])


if __name__ == '__main__':
    unittest.main()
