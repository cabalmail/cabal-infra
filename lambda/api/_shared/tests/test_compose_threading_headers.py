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

    def test_header_injection_is_still_rejected(self):
        with self.assertRaises(ValueError):
            compose.compose_from_body(
                _body(other_headers={'message_id': ['<x@example.com>\r\nBcc: evil@example.com']}),
                'testuser')


if __name__ == '__main__':
    unittest.main()
