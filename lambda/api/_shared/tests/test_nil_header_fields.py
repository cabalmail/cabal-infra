'''Unit tests for helper.envelope_dict's tolerance of a NIL header-fields
section in an IMAP fetch entry.

Dovecot can answer BODY[HEADER.FIELDS (...)] with NIL, which imapclient
parses as the key being PRESENT with value None. A `.get(key, b'')` default
only applies when the key is ABSENT, so the None reached `.decode()` and
raised AttributeError -- and since no caller wraps envelope_dict, one such
message 502'd the whole /list_envelopes page and would do the same to a
/search_envelopes one (#2050, observed once in prod on 2026-10-12).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_nil_header_fields.py

helper.py's third-party imports (boto3, botocore, imap_session) are faked in
sys.modules before import, so the suite needs no AWS access and never dials
an IMAP server.'''
import os
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')
os.environ.setdefault('CONTROL_DOMAIN', 'test.example.com')

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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


_boto3 = types.ModuleType("boto3")
_boto3.resource = lambda _name, **_kw: _FakeResource()
_boto3.client = lambda name, **_kw: _FakeSSM() if name == 'ssm' else types.SimpleNamespace()
_boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
sys.modules.setdefault('boto3', _boto3)

_botocore = types.ModuleType("botocore")
_botocore_exceptions = types.ModuleType("botocore.exceptions")


class _ClientError(Exception):
    pass


_botocore_exceptions.ClientError = _ClientError
_botocore.exceptions = _botocore_exceptions
sys.modules.setdefault('botocore', _botocore)
sys.modules.setdefault('botocore.exceptions', _botocore_exceptions)

_imap_session = types.ModuleType("imap_session")
_imap_session.open_imap_client = lambda *_a, **_kw: None
sys.modules.setdefault('imap_session', _imap_session)


import helper  # noqa: E402  pylint: disable=wrong-import-position

_HEADER_KEY = helper.ENVELOPE_HEADER_FIELDS_KEY.encode()


def _address(mailbox, host, name=None):
    return types.SimpleNamespace(mailbox=mailbox.encode(), host=host.encode(),
                                 name=name.encode() if name else None)


def _entry(header_fields):
    '''One fetch entry, with the header-fields slot as imapclient parsed it.

    `header_fields` is the parsed value: bytes for a literal, None for NIL,
    and the key is left out entirely when it is omitted.
    '''
    data = {
        b'ENVELOPE': types.SimpleNamespace(
            date='2026-10-12 09:00:00',
            subject=b'A subject',
            from_=(_address('sender', 'example.com', 'A Sender'),),
            to=(_address('claude', 'test.example.com'),),
            cc=None,
            bcc=None,
            message_id=b'<one@example.com>',
            in_reply_to=None,
        ),
        b'FLAGS': (b'\\Seen',),
        b'BODYSTRUCTURE': (b'text', b'plain', (b'charset', b'utf-8'),
                           None, None, b'7bit', 10, 1),
    }
    if header_fields is not _OMITTED:
        data[_HEADER_KEY] = header_fields
    return data


_OMITTED = object()


class NilHeaderFieldsTest(unittest.TestCase):
    '''A NIL header-fields section yields an envelope, not an AttributeError.'''

    def test_nil_section_builds_an_envelope(self):
        '''The reported crash: the key is present and its value is None.'''
        built = helper.envelope_dict(586, _entry(None))
        self.assertEqual(built['subject'], 'A subject')
        self.assertEqual(built['priority'], [])
        self.assertEqual(built['references'], [])
        # The whole payload a NIL section yields is the payload an empty
        # literal yields: the two differ only in what imapclient parsed.
        self.assertEqual(built, helper.envelope_dict(586, _entry(b'')))

    def test_a_literal_section_is_still_parsed(self):
        '''Positive control: the fix must not swallow real headers. Without
        it this case passes too, which is what makes the arm meaningful.'''
        built = helper.envelope_dict(587, _entry(
            b'X-Priority: 1\r\nReferences: <a@example.com> <b@example.com>\r\n'))
        self.assertEqual(built['priority'], ['priority-1'])
        self.assertEqual(built['references'], ['<a@example.com>', '<b@example.com>'])

    def test_an_omitted_section_still_works(self):
        '''The case the `.get` default was written for, which is NOT the
        reported one: the key absent from the entry altogether.'''
        built = helper.envelope_dict(588, _entry(_OMITTED))
        self.assertEqual(built['priority'], [])
        self.assertEqual(built['references'], [])

    def test_an_empty_literal_is_not_the_nil_case(self):
        '''Dovecot usually answers with an empty literal, which never
        raised -- so an arm that only covered b'' would not have caught
        this.'''
        self.assertEqual(helper.envelope_dict(589, _entry(b''))['priority'], [])


if __name__ == '__main__':
    unittest.main()
