'''Unit tests for helper.decode_body_structure's tolerance of non-UTF-8
bytes in BODYSTRUCTURE strings.

BODYSTRUCTURE strings are ASCII per RFC 3501, but real-world messages leak
raw 8-bit bytes into MIME parameter values (unencoded Latin-1 filenames and
the like). A strict UTF-8 decode raised UnicodeDecodeError and failed the
whole envelope page -- one poison message 500'd every /search_envelopes and
/list_envelopes response whose page contained it.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_body_structure_decode.py

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


class DecodeBodyStructureTest(unittest.TestCase):
    '''Byte strings in a BODYSTRUCTURE decode without raising, whatever
    their charset.'''

    def test_plain_ascii_structure(self):
        '''The ordinary case is unchanged: bytes become strings in place.'''
        struct = [b'text', b'plain', [b'charset', b'utf-8'], None, None, b'7bit', 42]
        self.assertEqual(
            helper.decode_body_structure(struct),
            ['text', 'plain', ['charset', 'utf-8'], None, None, '7bit', 42],
        )

    def test_utf8_bytes_decode_as_utf8(self):
        '''Valid UTF-8 stays UTF-8 -- the fallback must not kick in early.'''
        struct = [[b'name', 'Ça va.pdf'.encode('utf-8')]]
        self.assertEqual(helper.decode_body_structure(struct), [['name', 'Ça va.pdf']])

    def test_latin1_filename_falls_back(self):
        '''A raw Latin-1 parameter value (the prod poison message: 0xC7,
        "Ç") decodes via the fallback instead of raising.'''
        struct = [b'application', b'pdf', [b'name', b'\xc7a va.pdf']]
        self.assertEqual(
            helper.decode_body_structure(struct),
            ['application', 'pdf', ['name', 'Ça va.pdf']],
        )

    def test_nested_tuple_structure(self):
        '''The recursion reaches bad bytes inside nested multipart tuples,
        which is where the prod traceback hit them.'''
        struct = (
            (
                (b'text', b'plain', (b'charset', b'iso-8859-1'), None),
                (b'application', b'octet-stream', (b'name', b'r\xe9sum\xe9.doc'), None),
                b'mixed',
            ),
        )
        decoded = helper.decode_body_structure(struct)
        self.assertEqual(decoded[0][1][2], ['name', 'résumé.doc'])
        self.assertEqual(decoded[0][2], 'mixed')

    def test_arbitrary_binary_never_raises(self):
        '''Latin-1 maps every byte, so no byte string can raise.'''
        struct = [bytes(range(256))]
        decoded = helper.decode_body_structure(struct)
        self.assertEqual(len(decoded[0]), 256)


if __name__ == '__main__':
    unittest.main()
