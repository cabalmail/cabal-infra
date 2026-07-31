'''Unit tests for helper's folder-subscription functions.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_folder_subscriptions.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access and never dials an
IMAP server. The fake imap_session mirrors the behavior under test: like the
real open_imap_client, it selects the requested folder at connect time and
fails when that mailbox does not exist.'''
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

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

# Mailboxes that "exist" on the fake server; open_imap_client selects the
# requested folder and fails for anything else, like the real one.
EXISTING_FOLDERS = set()
OPENED = []


class _SelectFailed(Exception):
    pass


class _FakeImapClient:
    def __init__(self):
        self.unsubscribed = []
        self.logged_out = False

    def unsubscribe_folder(self, folder):
        self.unsubscribed.append(folder)
        return b'UNSUBSCRIBE completed.'

    def logout(self):
        self.logged_out = True


def _open_imap_client(host, user, folder, _read_only, _mpw):
    if folder not in EXISTING_FOLDERS:
        raise _SelectFailed(f"select failed: Mailbox doesn't exist: {folder}")
    client = _FakeImapClient()
    OPENED.append({'host': host, 'user': user, 'folder': folder, 'client': client})
    return client


_imap_session = types.ModuleType("imap_session")
_imap_session.open_imap_client = _open_imap_client
sys.modules['imap_session'] = _imap_session

import helper  # noqa: E402  pylint: disable=wrong-import-position

_SAVED = {}


def setUpModule():
    '''Binds this suite's fake into `helper`.

    The `sys.modules` fake above only takes effect if this file is what first
    imports `helper`. Under a directory-wide `discover` run it usually isn't:
    `helper` is already imported, still holding a sibling suite's fake, and the
    `import helper` above is a no-op. Rebinding here runs whatever the import
    order turns out to be (#860).
    '''
    _SAVED['open_imap_client'] = helper.open_imap_client
    helper.open_imap_client = _open_imap_client


def tearDownModule():
    helper.open_imap_client = _SAVED['open_imap_client']


class UnsubscribeFolderTest(unittest.TestCase):

    def setUp(self):
        EXISTING_FOLDERS.clear()
        EXISTING_FOLDERS.update({'INBOX', 'Archive'})
        OPENED.clear()

    def test_unsubscribe_survives_deleted_mailbox(self):
        # QA0723 has been deleted; only its LSUB entry remains. Clearing the
        # subscription must not require selecting the dead mailbox.
        helper.unsubscribe_folder('QA0723', None, 'testuser')
        client = OPENED[-1]['client']
        self.assertEqual(client.unsubscribed, ['QA0723'])
        self.assertTrue(client.logged_out)

    def test_unsubscribe_existing_folder_still_works(self):
        helper.unsubscribe_folder('Archive', None, 'testuser')
        client = OPENED[-1]['client']
        self.assertEqual(client.unsubscribed, ['Archive'])
        self.assertTrue(client.logged_out)


if __name__ == '__main__':
    unittest.main()
