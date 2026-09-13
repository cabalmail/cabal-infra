'''Unit tests for the `host` presence check on the five GET handlers that
index it, and for helper.query_params.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_query_param_presence.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access and never dials an
IMAP server. Each handler is loaded under a unique module name and its own
helper bindings are patched per test (see #860).'''
import email
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
    '''Imports lambda/api/<name>/function.py under a unique module name (#860).'''
    path = os.path.join(_API, name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'function_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


RAW_MESSAGE = (b'From: someone@example.com\r\n'
               b'Subject: probe\r\n'
               b'Content-Type: text/plain\r\n\r\nbody\r\n')


class _FakeImapClient:
    '''Stands in for the IMAP connection get_imap_client hands back.'''

    def sort(self, _criterion, _flags):
        return [11, 12]

    def fetch(self, _ids, _keys):
        return {}

    def logout(self):
        return None


# Every entry: (handler module name, the full query string a good request
# sends, the extra helper bindings that handler reaches for). The `host` value
# is ignored downstream -- get_imap_client takes it as `_host` and derives the
# real target from CONTROL_DOMAIN -- but the handlers index the key, which is
# the whole defect (#1410).
GOOD_QUERY = {
    'list_folders': {'host': 'imap.test.example.com'},
    'list_messages': {'host': 'imap.test.example.com', 'folder': 'INBOX',
                      'sort_field': 'ARRIVAL', 'sort_order': ''},
    'list_envelopes': {'host': 'imap.test.example.com', 'folder': 'INBOX',
                       'ids': '[11]'},
    'fetch_message': {'host': 'imap.test.example.com', 'folder': 'INBOX', 'id': '11'},
    'list_attachments': {'host': 'imap.test.example.com', 'folder': 'INBOX', 'id': '11'},
}

HANDLERS = {name: _load_handler(name) for name in GOOD_QUERY}


def _event(query):
    '''Builds an authorized API Gateway event; `query` of None is a bare GET,
    which is how API Gateway spells "no query string at all".'''
    return {
        'queryStringParameters': query,
        'requestContext': {'authorizer': {'claims': {'cognito:username': 'testuser'}}},
    }


class QueryParamsTest(unittest.TestCase):
    '''helper.query_params is the query-string twin of require_fields (#895).'''

    def test_returns_the_params_when_everything_is_present(self):
        params = helper.query_params(_event({'host': 'h', 'folder': 'INBOX'}), 'host')
        self.assertEqual(params, {'host': 'h', 'folder': 'INBOX'})

    def test_names_every_missing_parameter(self):
        with self.assertRaises(ValueError) as caught:
            helper.query_params(_event({'folder': 'INBOX'}), 'host', 'id')
        self.assertIn('host', str(caught.exception))
        self.assertIn('id', str(caught.exception))

    def test_a_bare_get_is_an_empty_dict_not_a_type_error(self):
        self.assertEqual(helper.query_params(_event(None)), {})

    def test_a_bare_get_names_the_missing_parameter(self):
        with self.assertRaises(ValueError) as caught:
            helper.query_params(_event(None), 'host')
        self.assertIn('host', str(caught.exception))


class MissingHostIsA400Test(unittest.TestCase):
    '''Omitting `host` used to raise KeyError inside the handler and reach the
    client as a bodiless `502 {"message": "Internal server error"}`, which gives
    a client author nothing to act on (#1410). A bare GET was the same 502 by a
    different exception (TypeError on a None query string).'''

    def setUp(self):
        self._saved = {}
        for name, module in HANDLERS.items():
            saved = {}
            for attr, fake in (
                    ('get_imap_client', lambda *_a, **_kw: _FakeImapClient()),
                    ('get_message', lambda *_a, **_kw: email.message_from_bytes(RAW_MESSAGE)),
                    ('get_folder_list', lambda _client: {"folders": [], "subscribed": []}),
                    ('folder_message_count', lambda *_a: 0),
                    ('log_folder_size_bucket', lambda *_a, **_kw: None),
                    ('sign_url', lambda _bucket, key: f'https://example.invalid/{key}'),
            ):
                if hasattr(module, attr):
                    saved[attr] = getattr(module, attr)
                    setattr(module, attr, fake)
            self._saved[name] = saved

    def tearDown(self):
        for name, saved in self._saved.items():
            for attr, original in saved.items():
                setattr(HANDLERS[name], attr, original)

    def test_every_handler_names_the_missing_host(self):
        for name, module in HANDLERS.items():
            with self.subTest(handler=name):
                query = dict(GOOD_QUERY[name])
                query.pop('host')
                response = module.handler(_event(query), None)
                self.assertEqual(response['statusCode'], 400)
                self.assertIn('host', json.loads(response['body'])['status'])

    def test_every_handler_answers_a_bare_get_with_a_400(self):
        for name, module in HANDLERS.items():
            with self.subTest(handler=name):
                response = module.handler(_event(None), None)
                self.assertEqual(response['statusCode'], 400)
                self.assertIn('Invalid input', json.loads(response['body'])['status'])

    def test_positive_control_the_same_fixture_answers_200_with_host(self):
        '''Without this the 400s above could come from the fixture rather than
        from the missing parameter.'''
        for name, module in HANDLERS.items():
            with self.subTest(handler=name):
                response = module.handler(_event(dict(GOOD_QUERY[name])), None)
                self.assertEqual(response['statusCode'], 200)


if __name__ == '__main__':
    unittest.main()
