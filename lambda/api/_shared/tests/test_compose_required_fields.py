'''Unit tests for the required-field half of the /send payload contract.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_compose_required_fields.py

Companion to test_compose_threading_headers.py, which covers the keys the
composer treats as OPTIONAL. These cover the ones it genuinely needs: a body
missing `sender`, `subject`, `to_list`, `cc_list`, `bcc_list`, `text`, `html`,
or `host` used to die on a KeyError, which API Gateway surfaced as a bodiless
`{"message": "Internal server error"}` 502 (#895) rather than the named 400
both handlers already had for a rejected value.

The recipient lists need one check more than presence: a `to_list` that
arrives as a bare string satisfies every presence and CR/LF check and then
raises a TypeError in /send's envelope assembly, for the same bodiless 502
(#909). Those cases live here too.

Third-party imports (boto3, botocore, imapclient, imap_session, smtp_session)
are faked in sys.modules before import, so the suite needs no AWS access and
never dials IMAP or SMTP. `helper` and `compose` themselves are the real
modules -- faking them would hand every later-discovered suite the stub
instead (#860/#863). The handlers are loaded under unique module names for
the same reason.
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

TEST_USER = 'testuser'
TEST_SENDER = 'daily@qa.example.com'

# --- fake boto3 / botocore ---------------------------------------------------


class _FakeTable:
    '''cabal-addresses / cabal-user-preferences stand-in. The address row
    authorizes TEST_USER for TEST_SENDER so the handler tests reach the
    composition path rather than short-circuiting on the 500 an
    unauthorized sender gets.'''

    def get_item(self, Key=None, **_kwargs):  # pylint: disable=invalid-name
        if Key and Key.get('address') == TEST_SENDER:
            return {"Item": {"address": TEST_SENDER, "user": TEST_USER}}
        return {}


class _FakeResource:
    def Table(self, _name):  # pylint: disable=invalid-name
        return _FakeTable()


class _FakeSSMExceptions:
    class ParameterNotFound(Exception):
        pass


class _FakeSSM:
    exceptions = _FakeSSMExceptions

    def get_parameter(self, Name=None, **_kwargs):  # pylint: disable=invalid-name
        if Name == '/cabal/maintenance/imap':
            raise _FakeSSMExceptions.ParameterNotFound()
        return {"Parameter": {"Value": "fake-master-password"}}


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

if 'smtp_session' not in sys.modules:
    _smtp_session = types.ModuleType("smtp_session")
    _smtp_session.open_smtp_client = lambda *_a, **_kw: None
    sys.modules['smtp_session'] = _smtp_session

if 'imapclient' not in sys.modules:
    _imapclient = types.ModuleType("imapclient")
    _imapclient_exceptions = types.ModuleType("imapclient.exceptions")

    class _IMAPClientError(Exception):
        pass

    _imapclient_exceptions.IMAPClientError = _IMAPClientError
    _imapclient.exceptions = _imapclient_exceptions
    sys.modules['imapclient'] = _imapclient
    sys.modules['imapclient.exceptions'] = _imapclient_exceptions

import compose  # noqa: E402  pylint: disable=wrong-import-position
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


send = _load_handler('send')
save_draft = _load_handler('save_draft')


def _body(**overrides):
    '''The tester's control payload from #895: a complete, valid /send body.'''
    body = {
        'host': 'imap.qa.example.com',
        'smtp_host': 'smtp.qa.example.com',
        'sender': TEST_SENDER,
        'to_list': [TEST_SENDER],
        'cc_list': [],
        'bcc_list': [],
        'subject': 'req0803 probe',
        'html': '<p>probe</p>',
        'text': 'probe',
        'draft': False,
        'attachments': [],
        'other_headers': {'message_id': [], 'in_reply_to': [], 'references': []},
    }
    body.update(overrides)
    return body


def _without(*fields):
    '''The control payload with `fields` omitted entirely.'''
    body = _body()
    for field in fields:
        body.pop(field)
    return body


def _event(body):
    '''Wraps a body in the API Gateway event shape both handlers read.'''
    return {
        "body": json.dumps(body),
        "requestContext": {"authorizer": {"claims": {"cognito:username": TEST_USER}}},
    }


class _ComposeCase(unittest.TestCase):
    '''Binds the module-level tables compose and helper resolved at import
    time. Rebinding rather than relying on this file's sys.modules fake keeps
    the suite correct under a directory-wide `discover` run, where a sibling
    suite's fake may already have won the import (#860/#863).'''

    def setUp(self):
        table = _FakeTable()
        # pylint: disable=protected-access
        self._saved = (compose._preferences_table, helper.ddb_table)
        compose._preferences_table = table
        helper.ddb_table = table

    def tearDown(self):
        # pylint: disable=protected-access
        compose._preferences_table, helper.ddb_table = self._saved


class ComposeRequiredFieldsTest(_ComposeCase):
    '''compose_from_body rejects an incomplete payload by name instead of
    dying on a KeyError (#895).'''

    def test_control_payload_composes(self):
        msg = compose.compose_from_body(_body(), TEST_USER)
        self.assertEqual(msg['Subject'], 'req0803 probe')

    def test_each_required_field_is_named_when_omitted(self):
        for field in compose.COMPOSE_REQUIRED_FIELDS:
            with self.subTest(field=field):
                with self.assertRaises(ValueError) as caught:
                    compose.compose_from_body(_without(field), TEST_USER)
                self.assertIn(field, str(caught.exception))

    def test_every_missing_field_is_named_at_once(self):
        with self.assertRaises(ValueError) as caught:
            compose.compose_from_body(_without('text', 'html'), TEST_USER)
        message = str(caught.exception)
        self.assertIn('text', message)
        self.assertIn('html', message)

    def test_null_recipient_lists_compose_as_empty(self):
        # The validator reads each list as `... or []`, so a null list is a
        # payload it accepts; the composer must not then die on ','.join(None).
        msg = compose.compose_from_body(
            _body(cc_list=None, bcc_list=None), TEST_USER)
        self.assertIsNone(msg['Cc'])
        self.assertIsNone(msg['Bcc'])
        self.assertEqual(msg['To'], TEST_SENDER)

    def test_present_but_empty_fields_are_not_missing(self):
        # Presence, not truthiness: an empty subject is a real (if dull)
        # message, not a client error.
        msg = compose.compose_from_body(_body(subject=''), TEST_USER)
        self.assertEqual(msg['Subject'], '')


class SendHandlerRequiredFieldsTest(_ComposeCase):
    '''/send returns the 400 rather than letting a KeyError escape as a
    bodiless 502 -- including for the keys it reads before composing.'''

    def _assert_400(self, response, field):
        self.assertEqual(response['statusCode'], 400)
        self.assertIn(field, json.loads(response['body'])['status'])

    def test_missing_sender_is_a_400(self):
        # `sender` is read before compose_from_body, so only the handler's own
        # check can turn it into a 400.
        self._assert_400(send.handler(_event(_without('sender')), None), 'sender')

    def test_missing_host_is_a_400(self):
        # `host` is indexed after delivery (the Sent-copy queue), so without
        # this check the 502 arrived on a message that had already been sent.
        self._assert_400(send.handler(_event(_without('host')), None), 'host')

    def test_missing_body_field_is_a_400(self):
        self._assert_400(send.handler(_event(_without('text')), None), 'text')


class SaveDraftHandlerRequiredFieldsTest(_ComposeCase):
    '''/save_draft composes through the same shared code and had the same
    exposure on both of its ops.'''

    def _assert_400(self, response, field):
        self.assertEqual(response['statusCode'], 400)
        self.assertIn(field, json.loads(response['body'])['status'])

    def test_save_missing_sender_is_a_400(self):
        self._assert_400(save_draft.handler(_event(_without('sender')), None), 'sender')

    def test_save_missing_host_is_a_400(self):
        self._assert_400(save_draft.handler(_event(_without('host')), None), 'host')

    def test_discard_missing_host_is_a_400(self):
        event = _event({'op': 'discard', 'replaces_uid': 1, 'replaces_uidvalidity': 1})
        self._assert_400(save_draft.handler(event, None), 'host')


class ComposeListShapeTest(_ComposeCase):
    '''The recipient lists have to BE lists of strings (#909). Presence and
    CR/LF checks both pass a bare string through; the composer then builds a
    header of comma-separated characters and /send dies assembling the
    envelope.'''

    def test_each_string_list_is_named_when_it_is_not_a_list(self):
        for field in compose.RECIPIENT_LIST_FIELDS:
            with self.subTest(field=field):
                with self.assertRaises(ValueError) as caught:
                    compose.compose_from_body(
                        _body(**{field: TEST_SENDER}), TEST_USER)
                self.assertIn(field, str(caught.exception))

    def test_a_non_list_of_any_type_is_rejected(self):
        for value in ({'address': TEST_SENDER}, 7, True):
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as caught:
                    compose.compose_from_body(_body(to_list=value), TEST_USER)
                self.assertIn('to_list', str(caught.exception))

    def test_a_non_string_entry_is_named(self):
        # A list of the right shape whose entries aren't addresses fails the
        # same way one step later, in ','.join().
        with self.assertRaises(ValueError) as caught:
            compose.compose_from_body(
                _body(cc_list=[{'address': TEST_SENDER}]), TEST_USER)
        self.assertIn('cc_list', str(caught.exception))

    def test_the_accepted_shapes_still_compose(self):
        # Null (read as `... or []` everywhere) and empty stay valid payloads:
        # this is a shape check, not a new required-value check.
        msg = compose.compose_from_body(
            _body(to_list=[TEST_SENDER], cc_list=None, bcc_list=[]), TEST_USER)
        self.assertEqual(msg['To'], TEST_SENDER)
        self.assertIsNone(msg['Cc'])


class HandlerListShapeTest(_ComposeCase):
    '''Both composing endpoints answer the bad shape with the named 400
    instead of the bodiless 502 the escaping TypeError became (#909).'''

    def _assert_400(self, response, field):
        self.assertEqual(response['statusCode'], 400)
        self.assertIn(field, json.loads(response['body'])['status'])

    def test_send_string_to_list_is_a_400(self):
        # The report's payload: `to_list` sent as a bare address string.
        self._assert_400(
            send.handler(_event(_body(to_list=TEST_SENDER)), None), 'to_list')

    def test_send_string_bcc_list_is_a_400(self):
        self._assert_400(
            send.handler(_event(_body(bcc_list=TEST_SENDER)), None), 'bcc_list')

    def test_save_draft_string_to_list_is_a_400(self):
        self._assert_400(
            save_draft.handler(_event(_body(to_list=TEST_SENDER)), None), 'to_list')


if __name__ == '__main__':
    unittest.main()
