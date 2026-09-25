'''Unit tests for the /mark_folder_read handler.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_mark_folder_read.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access and never dials an
IMAP server. The fake IMAP client records the SEARCH and the STORE batches so
the tests can pin the two things that matter: only the unseen set is stored,
and it is stored in bounded batches.'''
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

UNSEEN = []
SEARCH_RAISES = [False]
OPENED = []


class _FakeImapClient:
    def __init__(self):
        self.searches = []
        self.stores = []
        self.logged_out = False

    def search(self, criteria):
        self.searches.append(criteria)
        if SEARCH_RAISES[0]:
            raise OSError('connection reset')
        return list(UNSEEN)

    def add_flags(self, messages, flags, silent=False):
        self.stores.append((list(messages), flags, silent))
        return {}

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
    'mark_folder_read_function', os.path.join(_API_DIR, 'mark_folder_read', 'function.py'))
function = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(function)

_SAVED = {}


def setUpModule():
    '''Binds this suite's fake into `helper` whatever the import order (#860).'''
    _SAVED['open_imap_client'] = helper.open_imap_client
    helper.open_imap_client = _open_imap_client


def tearDownModule():
    helper.open_imap_client = _SAVED['open_imap_client']


def _event(body):
    return {
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'testuser'}}},
        'body': body if isinstance(body, str) else json.dumps(body),
    }


class MarkFolderReadTest(unittest.TestCase):

    def setUp(self):
        UNSEEN.clear()
        SEARCH_RAISES[0] = False
        OPENED.clear()

    def test_stores_only_the_unseen_set_silently(self):
        UNSEEN.extend([3, 7, 11])
        response = function.handler(_event({'host': 'h', 'folder': 'Lists/Cabal'}), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body']), {'status': 'marked', 'flipped': 3, 'failed': 0})
        opened = OPENED[-1]
        self.assertEqual(opened['folder'], 'Lists.Cabal')
        client = opened['client']
        self.assertEqual(client.searches, [['UNSEEN']])
        self.assertEqual(client.stores, [([3, 7, 11], '\\Seen', True)])
        self.assertTrue(client.logged_out)

    def test_empty_folder_stores_nothing(self):
        response = function.handler(_event({'folder': 'INBOX'}), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body'])['flipped'], 0)
        client = OPENED[-1]['client']
        self.assertEqual(client.stores, [])
        self.assertTrue(client.logged_out)

    def test_large_unseen_set_is_stored_in_batches(self):
        UNSEEN.extend(range(1, helper.MAX_IDS_PER_IMAP_CMD * 2 + 2))
        response = function.handler(_event({'folder': 'INBOX'}), None)
        self.assertEqual(json.loads(response['body'])['flipped'], helper.MAX_IDS_PER_IMAP_CMD * 2 + 1)
        client = OPENED[-1]['client']
        self.assertEqual([len(batch) for batch, _, _ in client.stores],
                         [helper.MAX_IDS_PER_IMAP_CMD, helper.MAX_IDS_PER_IMAP_CMD, 1])

    def test_rejects_bad_folder_and_bad_json(self):
        self.assertEqual(function.handler(_event({'folder': ''}), None)['statusCode'], 400)
        self.assertEqual(function.handler(_event({'folder': 'x' * 300}), None)['statusCode'], 400)
        self.assertEqual(function.handler(_event('not json'), None)['statusCode'], 400)
        self.assertEqual(function.handler(_event('[1]'), None)['statusCode'], 400)
        self.assertEqual(OPENED, [])

    def test_search_failure_is_a_500_and_logs_out(self):
        SEARCH_RAISES[0] = True
        response = function.handler(_event({'folder': 'INBOX'}), None)
        self.assertEqual(response['statusCode'], 500)
        self.assertTrue(OPENED[-1]['client'].logged_out)


if __name__ == '__main__':
    unittest.main()
