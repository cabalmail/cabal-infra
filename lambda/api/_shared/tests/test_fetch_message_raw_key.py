'''Unit tests for the presigned `message_raw` URL /fetch_message returns: it
must point at the object get_message cached, for top-level and nested folders
alike (#1803). Nested folders arrive as "Parent/Child" while the IMAP path, and
so the cache key, is "Parent.Child"; signing the slash path sent the Apple
reader, which loads every body through `message_raw`, to a key that does not
exist, and S3 answered 404.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_fetch_message_raw_key.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access and never dials an
IMAP server. The real get_message runs against an in-memory cache, so the test
compares the key it actually wrote with the key the handler signed.'''
import importlib.util
import json
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_API = os.path.dirname(_SHARED)
sys.path.insert(0, _SHARED)

# --- fake boto3 / botocore / imap_session -------------------------------------


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

    _botocore = types.ModuleType("botocore")
    _botocore_exceptions = types.ModuleType("botocore.exceptions")

    class _ClientError(Exception):
        pass

    _botocore_exceptions.ClientError = _ClientError
    _botocore.exceptions = _botocore_exceptions
    sys.modules['botocore'] = _botocore
    sys.modules['botocore.exceptions'] = _botocore_exceptions

if 'imap_session' not in sys.modules:
    _imap_session = types.ModuleType("imap_session")
    _imap_session.open_imap_client = lambda *_a, **_kw: None
    sys.modules['imap_session'] = _imap_session

import helper  # noqa: E402  pylint: disable=wrong-import-position


def _load_fetch_message():
    '''Imports lambda/api/fetch_message/function.py under a unique module name (#860).'''
    path = os.path.join(_API, 'fetch_message', 'function.py')
    spec = importlib.util.spec_from_file_location('function_fetch_message_raw_key', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


fetch_message = _load_fetch_message()

RAW_MESSAGE = (b'From: someone@example.com\r\n'
               b'Subject: nested\r\n'
               b'Content-Type: text/plain\r\n\r\n'
               b'body\r\n')


class _FakeImapClient:
    '''The IMAP connection get_message opens on a cache miss.'''

    def fetch(self, ids, _keys):
        return {ids[0]: {b'RFC822': RAW_MESSAGE}}

    def logout(self):
        return None


def _event(folder, msg_id='7'):
    return {
        'queryStringParameters': {'host': 'imap.test.example.com', 'folder': folder, 'id': msg_id},
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'testuser'}}},
    }


class FetchMessageRawKeyTest(unittest.TestCase):
    '''The signed `message_raw` key is the key get_message cached (#1803).'''

    def setUp(self):
        self.cache = {}
        self.opened = []
        self.signed = []
        self._saved = {name: getattr(helper, name) for name in
                       ('key_exists', 'get_object', 'upload_object', 'delete_object', 'get_imap_client')}
        self._saved_sign = fetch_message.sign_url
        helper.key_exists = lambda _bucket, key: key in self.cache
        helper.get_object = lambda _bucket, key: self.cache[key]
        helper.delete_object = lambda _bucket, key: self.cache.pop(key, None)
        helper.upload_object = self._upload
        helper.get_imap_client = self._open
        fetch_message.sign_url = self._sign

    def tearDown(self):
        for name, value in self._saved.items():
            setattr(helper, name, value)
        fetch_message.sign_url = self._saved_sign

    def _upload(self, _bucket, key, _content_type, obj):
        self.cache[key] = obj

    def _open(self, _host, _user, folder, _read_only=False):
        self.opened.append(folder)
        return _FakeImapClient()

    def _sign(self, _bucket, key, expiration=86400):  # pylint: disable=unused-argument
        self.signed.append(key)
        return f'https://cache.example.invalid/{key}?signature=x'

    def _open_message(self, folder):
        response = fetch_message.handler(_event(folder), None)
        self.assertEqual(response['statusCode'], 200)
        return json.loads(response['body'])

    def test_a_nested_folder_signs_the_key_get_message_cached(self):
        body = self._open_message('Lists/Foo')
        self.assertEqual(self.opened, ['Lists.Foo'], 'IMAP selects the dotted path')
        self.assertEqual(list(self.cache), ['testuser/Lists.Foo/7/raw'])
        self.assertEqual(self.signed, ['testuser/Lists.Foo/7/raw'])
        self.assertIn('testuser/Lists.Foo/7/raw', body['message_raw'])

    def test_a_deeper_nested_folder_signs_the_cached_key(self):
        self._open_message('Lists/Foo/Bar')
        self.assertEqual(self.signed, list(self.cache))
        self.assertEqual(self.signed, ['testuser/Lists.Foo.Bar/7/raw'])

    def test_a_top_level_folder_keeps_its_key(self):
        self._open_message('INBOX')
        self.assertEqual(self.signed, ['testuser/INBOX/7/raw'])
        self.assertEqual(list(self.cache), ['testuser/INBOX/7/raw'])

    def test_a_cache_hit_signs_the_same_key_without_dialing_imap(self):
        self.cache['testuser/Lists.Foo/7/raw'] = RAW_MESSAGE
        self._open_message('Lists/Foo')
        self.assertEqual(self.opened, [])
        self.assertEqual(self.signed, ['testuser/Lists.Foo/7/raw'])


if __name__ == '__main__':
    unittest.main()
