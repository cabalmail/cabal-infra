'''Unit tests for get_message's handling of a UID that is no longer in the
folder, and for the 404 the guard builds from it.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_get_message_gone.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access and never dials an
IMAP server. The fake client mirrors the behavior under test: like a real
server, an IMAP UID FETCH for a UID that has been expunged succeeds and returns
an empty dict rather than failing.'''
import importlib.util
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

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

# UIDs the fake server still holds; a FETCH for anything else comes back empty.
PRESENT_UIDS = {}
OPENED = []

RAW_MESSAGE = (b'From: someone@example.com\r\n'
               b'Subject: still here\r\n'
               b'Content-Type: text/plain\r\n\r\n'
               b'body\r\n')


class _FakeImapClient:
    def __init__(self):
        self.logged_out = False

    def fetch(self, uids, _parts):
        return {uid: {b'RFC822': PRESENT_UIDS[uid]} for uid in uids if uid in PRESENT_UIDS}

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


def _load_handler(name):
    '''Imports lambda/api/<name>/function.py under a unique module name.

    Every deployed zip names its handler module `function`, so a plain
    `import function` lets whichever suite runs first win the `sys.modules`
    slot and hands every later suite the wrong handler (#860). The handler
    still imports `helper` by name, exactly as it does inside its zip, so the
    real module above is what it binds to.
    '''
    path = os.path.join(os.path.dirname(_SHARED), name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


fetch_message = _load_handler('fetch_message')

_SAVED = {}


def setUpModule():
    '''Binds this suite's fake into `helper`.

    The `sys.modules` fake above only takes effect if this file is what first
    imports `helper`. Under a directory-wide `discover` run it usually isn't:
    `helper` is already imported, still holding a sibling suite's fake (whose
    client has no `fetch`), and the `import helper` above is a no-op.
    Rebinding here runs whatever the import order turns out to be (#860).
    '''
    _SAVED['open_imap_client'] = helper.open_imap_client
    helper.open_imap_client = _open_imap_client


def tearDownModule():
    helper.open_imap_client = _SAVED['open_imap_client']


UPLOADED = []


def _event(folder='INBOX', msg_id=27):
    return {
        'queryStringParameters': {'host': 'imap.test.example.com',
                                  'folder': folder,
                                  'id': str(msg_id)},
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'testuser'}}},
    }


class GetMessageGoneTest(unittest.TestCase):

    def setUp(self):
        PRESENT_UIDS.clear()
        OPENED.clear()
        UPLOADED.clear()
        # Nothing is in the S3 cache, so every read goes to IMAP.
        self._saved = (helper.key_exists, helper.upload_object)
        helper.key_exists = lambda _bucket, _key: False
        helper.upload_object = lambda bucket, key, ctype, obj: UPLOADED.append(key) or True

    def tearDown(self):
        helper.key_exists, helper.upload_object = self._saved

    def test_expunged_uid_raises_message_gone(self):
        # UID 27 was moved out of INBOX and expunged: the FETCH succeeds and
        # returns nothing for it.
        with self.assertRaises(helper.MessageGoneError) as caught:
            helper.get_message(None, 'testuser', 'INBOX', 27)
        self.assertEqual(caught.exception.folder, 'INBOX')
        self.assertEqual(caught.exception.msg_id, 27)
        self.assertTrue(OPENED[-1]['client'].logged_out)
        # Nothing may be written to the body cache for a message that is gone.
        self.assertEqual(UPLOADED, [])

    def test_present_uid_still_loads(self):
        PRESENT_UIDS[28] = RAW_MESSAGE
        message = helper.get_message(None, 'testuser', 'INBOX', 28)
        self.assertEqual(message.get('Subject'), 'still here')
        self.assertEqual(UPLOADED, ['testuser/INBOX/28/raw'])


class SuiteIsolationTest(unittest.TestCase):
    '''Guards the two ways a sibling suite used to hijack this one under a
    directory-wide `discover` run (#860): `helper` already imported with
    another suite's fake bound in, and another suite's handler sitting in the
    `function` slot of sys.modules.'''

    def test_this_suites_fake_is_what_helper_calls(self):
        self.assertIs(helper.open_imap_client, _open_imap_client)

    def test_the_handler_under_test_is_fetch_messages(self):
        self.assertTrue(fetch_message.__file__.endswith('fetch_message/function.py'))


class MessageGoneResponseTest(unittest.TestCase):

    def test_guard_turns_the_error_into_a_404(self):
        @helper.message_gone_guard
        def handler(_event, _context):
            raise helper.MessageGoneError('Archive.2026', 27)

        response = handler({}, None)
        self.assertEqual(response['statusCode'], 404)
        self.assertIn('2026', response['body'])

    def test_guard_passes_a_normal_response_through(self):
        @helper.message_gone_guard
        def handler(_event, _context):
            return {'statusCode': 200, 'body': '{}'}

        self.assertEqual(handler({}, None)['statusCode'], 200)


class FetchMessageHandlerTest(unittest.TestCase):
    '''The handler is what the clients see: an expunged UID used to escape as a
    KeyError and reach the client as a bodiless 502.'''

    def setUp(self):
        PRESENT_UIDS.clear()
        OPENED.clear()
        self._saved = (helper.key_exists, helper.upload_object)
        helper.key_exists = lambda _bucket, _key: False
        helper.upload_object = lambda _bucket, _key, _ctype, _obj: True

    def tearDown(self):
        helper.key_exists, helper.upload_object = self._saved

    def test_expunged_uid_is_a_404_not_a_502(self):
        response = fetch_message.handler(_event(msg_id=27), None)
        self.assertEqual(response['statusCode'], 404)
        self.assertTrue(response['body'])

    def test_present_uid_is_unaffected(self):
        PRESENT_UIDS[28] = RAW_MESSAGE
        fetch_message.sign_url = lambda _bucket, _key: 'https://example.invalid/raw'
        response = fetch_message.handler(_event(msg_id=28), None)
        self.assertEqual(response['statusCode'], 200)


if __name__ == '__main__':
    unittest.main()
