'''Unit tests for fetch_attachment's query-string validation, and for the two
validators it added to helper.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_fetch_attachment_validation.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access and never dials an
IMAP server. The handler is loaded under a unique module name and its own
helper bindings are patched per test, so nothing here depends on being the
first suite to import `helper` (see #860).'''
import email
import importlib.util
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_API = os.path.dirname(_SHARED)
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


def _load_handler(name):
    '''Imports lambda/api/<name>/function.py under a unique module name.

    The deployed zips all name their handler module `function`, so importing
    them as `function` lets whichever suite runs first win the sys.modules
    slot and hands every later suite the wrong handler (#860).
    '''
    path = os.path.join(_API, name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


fetch_attachment = _load_handler('fetch_attachment')

RAW_MESSAGE = (b'From: someone@example.com\r\n'
               b'Subject: has an attachment\r\n'
               b'Content-Type: multipart/mixed; boundary="b"\r\n\r\n'
               b'--b\r\nContent-Type: text/plain\r\n\r\nbody\r\n'
               b'--b\r\nContent-Type: text/plain\r\n'
               b'Content-Disposition: attachment; filename="probe.txt"\r\n\r\n'
               b'attached\r\n--b--\r\n')


def _event(**params):
    query = {'host': 'imap.test.example.com', 'folder': 'INBOX', 'id': '21',
             'filename': 'probe.txt', 'index': '2'}
    for key, value in params.items():
        if value is None:
            query.pop(key, None)
        else:
            query[key] = value
    return {
        'queryStringParameters': query,
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'testuser'}}},
    }


class FetchAttachmentValidationTest(unittest.TestCase):
    '''A malformed request is the caller's fault: it used to escape as a
    KeyError/ValueError and reach the client as a bodiless 502 that reads
    "Internal server error" (#859).'''

    def setUp(self):
        self._saved = (fetch_attachment.get_message, fetch_attachment.key_exists,
                       fetch_attachment.upload_object, fetch_attachment.sign_url)
        self.fetched = []
        fetch_attachment.get_message = self._fake_get_message
        fetch_attachment.key_exists = lambda _bucket, _key: True
        fetch_attachment.upload_object = lambda *_a: True
        fetch_attachment.sign_url = lambda _bucket, key: f'https://example.invalid/{key}'

    def tearDown(self):
        (fetch_attachment.get_message, fetch_attachment.key_exists,
         fetch_attachment.upload_object, fetch_attachment.sign_url) = self._saved

    def _fake_get_message(self, *args):
        self.fetched.append(args)
        return email.message_from_bytes(RAW_MESSAGE)

    def test_missing_filename_is_a_400(self):
        response = fetch_attachment.handler(_event(filename=None), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('filename', response['body'])
        # A bad request must not cost an IMAP round trip.
        self.assertEqual(self.fetched, [])

    def test_missing_index_is_a_400(self):
        response = fetch_attachment.handler(_event(index=None), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('index', response['body'])

    def test_non_integer_index_is_a_400(self):
        response = fetch_attachment.handler(_event(index='abc'), None)
        self.assertEqual(response['statusCode'], 400)
        self.assertIn('index', response['body'])

    def test_missing_folder_and_id_are_400s(self):
        for param in ('folder', 'id'):
            with self.subTest(param=param):
                response = fetch_attachment.handler(_event(**{param: None}), None)
                self.assertEqual(response['statusCode'], 400)

    def test_traversal_shaped_filename_is_a_400(self):
        response = fetch_attachment.handler(_event(filename='../../raw'), None)
        self.assertEqual(response['statusCode'], 400)

    def test_a_well_formed_request_still_serves_the_attachment(self):
        response = fetch_attachment.handler(_event(), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertIn('testuser/INBOX/21/probe.txt', response['body'])
        # The UID reaches get_message as an int, and the folder unchanged.
        self.assertEqual(self.fetched[-1][2:], ('INBOX', 21))


class ValidatorTest(unittest.TestCase):

    def test_part_index_accepts_zero(self):
        # Part 0 is the message itself; validate_uid's [1, ...] floor would
        # reject a legal index.
        self.assertEqual(helper.validate_part_index('0'), 0)
        self.assertEqual(helper.validate_part_index(4), 4)

    def test_part_index_rejects_junk(self):
        for value in (None, '', 'abc', '-1', True, [2]):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    helper.validate_part_index(value)

    def test_filename_keeps_real_mime_names(self):
        for name in ('probe.txt', 'Q3 résumé (final).pdf', 'photo-4DE49790.jpg'):
            with self.subTest(name=name):
                self.assertEqual(helper.validate_attachment_filename(name), name)

    def test_filename_rejects_key_shaped_values(self):
        for name in (None, '', '.', '..', 'a/b.txt', 'a\\b.txt', 'nul\x00.txt', 'x' * 300):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    helper.validate_attachment_filename(name)


if __name__ == '__main__':
    unittest.main()
