'''Unit tests for helper.folder_subscription_response and the two handlers
built on it (subscribe_folder, unsubscribe_folder).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_folder_subscription_response.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, guarded so the alphabetically-first test file in the
suite stays the owner of the fakes (#860). Each handler is loaded under a unique
module name. Nothing here reaches AWS or dials an IMAP server: the fake
open_imap_client records what was asked of it.
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

import helper  # noqa: E402  pylint: disable=wrong-import-position

# What the fake server was asked to do, in order.
OPENED = []


class _FakeImapClient:
    def subscribe_folder(self, folder):
        OPENED.append(('subscribe', folder))
        return b'SUBSCRIBE completed.'

    def unsubscribe_folder(self, folder):
        OPENED.append(('unsubscribe', folder))
        return b'UNSUBSCRIBE completed.'

    def logout(self):
        OPENED.append(('logout',))
        return b'Logging out'


def _open_imap_client(host, user, folder, _read_only, _mpw):
    OPENED.append(('open', host, user, folder))
    return _FakeImapClient()


def _load_handler(name):
    '''Imports lambda/api/<name>/function.py under a unique module name (#860).'''
    path = os.path.join(_API, name, 'function.py')
    spec = importlib.util.spec_from_file_location(f'folder_subscription_{name}', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


SUBSCRIBE = _load_handler('subscribe_folder')
UNSUBSCRIBE = _load_handler('unsubscribe_folder')

_SAVED = {}


def setUpModule():
    '''Binds this suite's fake into `helper`, whatever the import order (#860).'''
    _SAVED['open_imap_client'] = helper.open_imap_client
    helper.open_imap_client = _open_imap_client


def tearDownModule():
    helper.open_imap_client = _SAVED['open_imap_client']


def _event(body, user='testuser'):
    event = {'requestContext': {'authorizer': {'claims': {'cognito:username': user}}}}
    if body is not None:
        event['body'] = body if isinstance(body, str) else json.dumps(body)
    return event


class FolderSubscriptionResponseTest(unittest.TestCase):
    '''The shared builder's own contract.'''

    def setUp(self):
        OPENED.clear()

    def test_the_folder_reaches_the_operation_dot_delimited(self):
        calls = []
        response = helper.folder_subscription_response(
            _event({'folder': 'Parent/Child'}),
            lambda folder, host, user: calls.append((folder, host, user)) or b'OK')
        self.assertEqual(calls, [('Parent.Child', None, 'testuser')])
        self.assertEqual(response, {
            "statusCode": 200,
            "body": json.dumps({"status": "b'OK'"})
        })

    def test_the_status_is_stringified(self):
        response = helper.folder_subscription_response(
            _event({'folder': 'INBOX'}), lambda *_a: b'SUBSCRIBE completed.')
        self.assertEqual(json.loads(response['body']),
                         {"status": "b'SUBSCRIBE completed.'"})

    def test_a_refused_folder_is_a_400_and_never_reaches_the_operation(self):
        calls = []
        response = helper.folder_subscription_response(
            _event({'folder': 'bad*name'}), lambda *a: calls.append(a))
        self.assertEqual(calls, [])
        self.assertEqual(response,
                         helper.invalid_input_response("invalid folder name: 'bad*name'"))

    def test_a_missing_body_is_refused_before_the_folder_is_read(self):
        response = helper.folder_subscription_response(_event(None), lambda *_a: b'OK')
        self.assertEqual(response, helper.invalid_input_response('request body is required'))

    def test_a_non_object_body_is_refused(self):
        response = helper.folder_subscription_response(_event('[]'), lambda *_a: b'OK')
        self.assertEqual(response,
                         helper.invalid_input_response('request body must be a JSON object'))

    def test_a_bad_body_is_refused_before_the_username_is_read(self):
        '''Ordering: a request with no username claim and an unparseable body
        answers the body's 400 rather than raising.'''
        event = {'requestContext': {'authorizer': {'claims': {}}}, 'body': 'not json'}
        self.assertEqual(helper.folder_subscription_response(event, lambda *_a: b'OK'),
                         helper.invalid_input_response('request body is not valid JSON'))


class HandlersUseTheSharedBuilderTest(unittest.TestCase):
    '''Each handler must reach the shared builder with its own operation.'''

    def setUp(self):
        OPENED.clear()

    def test_subscribe_passes_helper_subscribe_folder(self):
        seen = []
        saved = SUBSCRIBE.folder_subscription_response
        SUBSCRIBE.folder_subscription_response = lambda event, operate: seen.append(operate)
        try:
            SUBSCRIBE.handler(_event({'folder': 'Archive'}), None)
        finally:
            SUBSCRIBE.folder_subscription_response = saved
        self.assertEqual(seen, [helper.subscribe_folder])

    def test_unsubscribe_passes_helper_unsubscribe_folder(self):
        seen = []
        saved = UNSUBSCRIBE.folder_subscription_response
        UNSUBSCRIBE.folder_subscription_response = lambda event, operate: seen.append(operate)
        try:
            UNSUBSCRIBE.handler(_event({'folder': 'Archive'}), None)
        finally:
            UNSUBSCRIBE.folder_subscription_response = saved
        self.assertEqual(seen, [helper.unsubscribe_folder])

    def test_subscribe_selects_the_folder_it_subscribes(self):
        response = SUBSCRIBE.handler(_event({'folder': 'Parent/Child'}), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body']),
                         {"status": "b'SUBSCRIBE completed.'"})
        self.assertEqual([c for c in OPENED if c[0] != 'open'],
                         [('subscribe', 'Parent.Child'), ('logout',)])
        self.assertEqual(OPENED[0][3], 'Parent.Child')

    def test_unsubscribe_selects_inbox_and_clears_the_named_folder(self):
        '''An unsubscribe must keep working for a mailbox that is already gone,
        so it selects INBOX rather than the folder it is clearing.'''
        response = UNSUBSCRIBE.handler(_event({'folder': 'Parent/Child'}), None)
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body']),
                         {"status": "b'UNSUBSCRIBE completed.'"})
        self.assertEqual([c for c in OPENED if c[0] != 'open'],
                         [('unsubscribe', 'Parent.Child'), ('logout',)])
        self.assertEqual(OPENED[0][3], 'INBOX')

    def test_both_handlers_refuse_a_bad_folder_with_the_shared_400(self):
        for module in (SUBSCRIBE, UNSUBSCRIBE):
            with self.subTest(handler=module.__name__):
                response = module.handler(_event({'folder': 'bad*name'}), None)
                self.assertEqual(response['statusCode'], 400)
                self.assertIn('Invalid input: ', json.loads(response['body'])['status'])
                self.assertEqual(OPENED, [])

    def test_a_host_in_the_body_changes_nothing(self):
        '''helper.get_imap_client ignores its host argument (`_host`), so the
        None the builder passes is inert: a body naming a host is answered
        identically and still connects to the configured IMAP_HOST.'''
        with_host = SUBSCRIBE.handler(_event({'folder': 'Archive', 'host': 'elsewhere'}), None)
        asked_with = list(OPENED)
        OPENED.clear()
        without = SUBSCRIBE.handler(_event({'folder': 'Archive'}), None)
        self.assertEqual(with_host, without)
        self.assertEqual(asked_with, OPENED)


if __name__ == '__main__':
    unittest.main()
