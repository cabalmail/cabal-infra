'''Unit tests for compose_from_body's handling of the threading headers.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_compose_threading_headers.py

compose.py's third-party imports (boto3, botocore) and helper's imap_session
are faked in sys.modules before import, so the suite needs no AWS access and
never dials an IMAP server. `helper` itself is the real module — faking it
would hand every later-discovered suite the stub instead (#860/#863).
`other_headers` is optional to validate_outbound_headers, so it has to be
optional to the composer too: a fresh (non-reply) compose carries no
Message-Id / In-Reply-To / References, and hard-indexing them turned that
payload into a KeyError and a bodiless 502 (#895).
'''
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

# --- fake boto3 / botocore ---------------------------------------------------


class _FakeTable:
    def get_item(self, **_kwargs):  # pylint: disable=invalid-name
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

import compose  # noqa: E402  pylint: disable=wrong-import-position


def _body(**overrides):
    '''The tester's control payload: valid but for `other_headers`.'''
    body = {
        'sender': 'daily@qa.example.com',
        'to_list': ['daily@qa.example.com'],
        'cc_list': [],
        'bcc_list': [],
        'subject': 'hdr0803 probe',
        'html': '<p>probe</p>',
        'text': 'probe',
        'draft': False,
        'attachments': [],
        'other_headers': {'message_id': [], 'in_reply_to': [], 'references': []},
    }
    for key, value in overrides.items():
        if value is None:
            body.pop(key, None)
        else:
            body[key] = value
    return body


class ComposeThreadingHeadersTest(unittest.TestCase):
    '''A payload with no threading context composes a message with no
    threading headers -- it does not blow up (#895).'''

    def setUp(self):
        # Bind compose's module-level preferences table rather than trusting
        # this file's sys.modules fake to have won the import: under a
        # directory-wide `discover` a sibling suite's fake gets there first
        # and hands compose a table with no get_item (#860/#863).
        self._saved_table = compose._preferences_table  # pylint: disable=protected-access
        compose._preferences_table = _FakeTable()  # pylint: disable=protected-access

    def tearDown(self):
        compose._preferences_table = self._saved_table  # pylint: disable=protected-access

    def test_control_payload_composes(self):
        msg = compose.compose_from_body(_body(), 'testuser')
        self.assertEqual(msg['Subject'], 'hdr0803 probe')
        self.assertIsNone(msg['Message-Id'])

    def test_empty_other_headers_composes(self):
        msg = compose.compose_from_body(_body(other_headers={}), 'testuser')
        self.assertIsNone(msg['Message-Id'])
        self.assertIsNone(msg['In-Reply-To'])
        self.assertIsNone(msg['References'])

    def test_partial_other_headers_composes(self):
        msg = compose.compose_from_body(
            _body(other_headers={'message_id': ['<probe@example.com>']}), 'testuser')
        self.assertEqual(msg['Message-Id'], '<probe@example.com>')
        self.assertIsNone(msg['In-Reply-To'])

    def test_omitted_other_headers_composes(self):
        msg = compose.compose_from_body(_body(other_headers=None), 'testuser')
        self.assertIsNone(msg['Message-Id'])

    def test_null_other_headers_composes(self):
        # `other_headers: null` — the shape a client sends when it has
        # nothing to thread against and doesn't special-case the key.
        msg = compose.compose_from_body(_body(other_headers=False), 'testuser')
        self.assertIsNone(msg['Message-Id'])

    def test_supplied_threading_headers_are_still_written(self):
        msg = compose.compose_from_body(_body(other_headers={
            'message_id': ['<new@example.com>'],
            'in_reply_to': ['<parent@example.com>'],
            'references': ['<gramps@example.com>', '<parent@example.com>'],
        }), 'testuser')
        self.assertEqual(msg['Message-Id'], '<new@example.com>')
        self.assertEqual(msg['In-Reply-To'], '<parent@example.com>')
        self.assertEqual(msg['References'], '<gramps@example.com> <parent@example.com>')

    def test_string_threading_header_is_rejected(self):
        # The tester's payload (#1013): a bare string where a one-element list
        # belongs. It used to compose Message-Id: '<' -- the string's first
        # character -- which /send then claimed as a dedupe key shared by
        # every such request, silently discarding all but the first.
        for field in ('message_id', 'in_reply_to', 'references'):
            with self.subTest(field=field):
                with self.assertRaises(ValueError) as caught:
                    compose.compose_from_body(
                        _body(other_headers={field: '<a-1@example.com>'}), 'testuser')
                self.assertIn(f'other_headers.{field}', str(caught.exception))

    def test_no_payload_composes_a_threading_header_the_caller_did_not_supply(self):
        # The invariant behind the case above: whatever shape arrives, a
        # composed message either carries a header the caller actually sent or
        # carries none -- never a fragment of one.
        shapes = ('<a@example.com>', 123, {'0': '<a@example.com>'},
                  ['<a@example.com>', 7], [None])
        for shape in shapes:
            for field, header in (('message_id', 'Message-Id'),
                                  ('in_reply_to', 'In-Reply-To'),
                                  ('references', 'References')):
                with self.subTest(shape=shape, field=field):
                    body = _body(other_headers={field: shape})
                    try:
                        msg = compose.compose_from_body(body, 'testuser')
                    except ValueError:
                        continue
                    supplied = [s for s in shape if isinstance(s, str)] \
                        if isinstance(shape, list) else []
                    allowed = {None, ' '.join(supplied), *supplied}
                    self.assertIn(msg[header], allowed)

    def test_non_object_other_headers_is_rejected(self):
        # `others.get(...)` on a string is an AttributeError, i.e. the
        # bodiless 502 the shape checks exist to prevent (#895).
        with self.assertRaises(ValueError) as caught:
            compose.compose_from_body(_body(other_headers='<a-1@example.com>'), 'testuser')
        self.assertIn('other_headers', str(caught.exception))

    def test_header_injection_is_still_rejected(self):
        with self.assertRaises(ValueError):
            compose.compose_from_body(
                _body(other_headers={'message_id': ['<x@example.com>\r\nBcc: evil@example.com']}),
                'testuser')


if __name__ == '__main__':
    unittest.main()
