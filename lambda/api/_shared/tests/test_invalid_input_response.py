'''Unit tests for helper.invalid_input_response and for the handlers that
return it when a validator refuses the request.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_invalid_input_response.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, guarded so the alphabetically-first test file in the
suite stays the owner of the fakes (#860). Each handler is loaded under a unique
module name; nothing here reaches AWS or dials an IMAP server, because every
case is refused by a validator before the handler opens a connection.
'''
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

if 'imapclient' not in sys.modules:
    # delete_folder/new_folder map IMAPClientError onto a 409/404, so the
    # exception type has to exist even though no case here raises one.
    _imapclient = types.ModuleType("imapclient")
    _imapclient.__path__ = []
    _imapclient_exceptions = types.ModuleType("imapclient.exceptions")

    class _IMAPClientError(Exception):
        pass

    _imapclient_exceptions.IMAPClientError = _IMAPClientError
    _imapclient.exceptions = _imapclient_exceptions
    sys.modules['imapclient'] = _imapclient
    sys.modules['imapclient.exceptions'] = _imapclient_exceptions

import helper  # noqa: E402  pylint: disable=wrong-import-position


def _load_handler(name):
    '''Imports lambda/api/<name>/function.py under a unique module name (#860).'''
    path = os.path.join(_API, name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'invalid_input_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _claims(user='testuser'):
    return {'requestContext': {'authorizer': {'claims': {'cognito:username': user}}}}


def _body_event(obj):
    event = _claims()
    event['body'] = obj if isinstance(obj, str) else json.dumps(obj)
    return event


def _query_event(params):
    event = _claims()
    event['queryStringParameters'] = params
    return event


# One rejected request per handler that answers a validator refusal with the
# shared builder. Each case is refused before the handler opens an IMAP
# connection, which is why the fake client above is never needed.
REFUSED = {
    'delete_folder': _body_event({'name': 'bad*name'}),
    'empty_trash': _body_event({'folder': 'INBOX'}),
    'fetch_attachment': _query_event({'host': 'h', 'folder': 'bad*name', 'id': '1',
                                      'index': '0', 'filename': 'a.txt'}),
    'fetch_inline_image': _query_event({'host': 'h', 'folder': 'bad*name', 'id': '1',
                                        'index': '<cid>'}),
    'fetch_message': _query_event({'folder': 'INBOX', 'id': '1'}),
    'folder_status': _query_event({'host': 'h', 'folder': 'bad*name'}),
    'list_attachments': _query_event({'folder': 'INBOX', 'id': '1'}),
    'list_envelopes': _query_event({'host': 'h', 'folder': 'bad*name', 'ids': '[1]'}),
    'list_folders': _query_event(None),
    'list_messages': _query_event({'host': 'h', 'folder': 'bad*name'}),
    'mark_folder_read': _body_event({'folder': 'bad*name'}),
    'move_messages': _body_event({'source': 'bad*name', 'destination': 'Trash',
                                  'ids': [1], 'host': 'h'}),
    'new_folder': _body_event({'name': 'bad*name'}),
    'purge_messages': _body_event({'folder': 'INBOX', 'ids': [1]}),
    'save_draft': _body_event({'op': 'nonsense'}),
    'set_flag': _body_event({'folder': 'bad*name', 'ids': [1], 'flag': 'Seen',
                             'host': 'h'}),
    'subscribe_folder': _body_event({'folder': 'bad*name'}),
    'unsubscribe_folder': _body_event({'folder': 'bad*name'}),
}

HANDLERS = {name: _load_handler(name) for name in REFUSED}


class InvalidInputResponseTest(unittest.TestCase):
    '''The 400 shape itself. Every handler used to build this dict inline, so
    the bytes are the contract a client already depends on.'''

    def test_a_value_error_is_rendered_by_str(self):
        response = helper.invalid_input_response(ValueError('folder name is required'))
        self.assertEqual(response, {
            "statusCode": 400,
            "body": json.dumps({"status": "Invalid input: folder name is required"})
        })

    def test_a_plain_message_renders_the_same_way(self):
        response = helper.invalid_input_response('request body is not valid JSON')
        self.assertEqual(json.loads(response['body']),
                         {"status": "Invalid input: request body is not valid JSON"})

    def test_the_body_is_a_json_string_not_a_dict(self):
        self.assertIsInstance(helper.invalid_input_response('x')['body'], str)

    def test_no_headers_are_added(self):
        self.assertEqual(set(helper.invalid_input_response('x')), {'statusCode', 'body'})

    def test_a_non_string_detail_is_rendered_by_str_too(self):
        self.assertEqual(json.loads(helper.invalid_input_response(42)['body']),
                         {"status": "Invalid input: 42"})


class SharedBuilderIsReachedTest(unittest.TestCase):
    '''Each handler must reach the shared builder rather than re-inlining the
    dict: patching the name in the handler's own namespace has to change what
    the handler returns.'''

    def test_every_handler_returns_what_the_shared_builder_returns(self):
        sentinel = {"statusCode": 499, "body": "sentinel"}
        for name, module in HANDLERS.items():
            with self.subTest(handler=name):
                saved = module.invalid_input_response
                module.invalid_input_response = lambda _err, _s=sentinel: _s
                try:
                    self.assertIs(module.handler(REFUSED[name], None), sentinel)
                finally:
                    module.invalid_input_response = saved

    def test_positive_control_the_unpatched_handlers_answer_a_real_400(self):
        '''Without this the identity above could hold for a handler that never
        reaches the call at all.'''
        for name, module in HANDLERS.items():
            with self.subTest(handler=name):
                response = module.handler(REFUSED[name], None)
                self.assertEqual(response['statusCode'], 400)
                self.assertIn('Invalid input: ', json.loads(response['body'])['status'])


class ParseHelpersUseTheSharedBuilderTest(unittest.TestCase):
    '''helper.parse_json_body and helper.parse_bulk_request built the same 400
    inline; their error halves are the same bytes as the builder's.'''

    def test_parse_json_body_rejects_a_missing_body(self):
        body, error = helper.parse_json_body({})
        self.assertIsNone(body)
        self.assertEqual(error, helper.invalid_input_response('request body is required'))

    def test_parse_json_body_rejects_a_non_object(self):
        body, error = helper.parse_json_body({'body': '[]'})
        self.assertIsNone(body)
        self.assertEqual(error,
                         helper.invalid_input_response('request body must be a JSON object'))

    def test_parse_json_body_rejects_unparseable_json(self):
        body, error = helper.parse_json_body({'body': 'not json'})
        self.assertIsNone(body)
        self.assertEqual(error,
                         helper.invalid_input_response('request body is not valid JSON'))

    def test_parse_bulk_request_rejects_unparseable_json(self):
        body, error = helper.parse_bulk_request({'body': 'not json'})
        self.assertIsNone(body)
        self.assertEqual(error,
                         helper.invalid_input_response('request body is not valid JSON'))

    def test_parse_bulk_request_still_answers_413_over_the_id_cap(self):
        '''The sibling response builder beside it is untouched.'''
        oversized = json.dumps({'ids': list(range(helper.MAX_IDS_PER_REQUEST + 1))})
        body, error = helper.parse_bulk_request({'body': oversized})
        self.assertIsNone(body)
        self.assertEqual(error, helper.too_many_ids_response())


if __name__ == '__main__':
    unittest.main()
