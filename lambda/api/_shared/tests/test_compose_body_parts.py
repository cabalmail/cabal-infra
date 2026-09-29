'''Unit tests for the MIME shape of a composed message body.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_compose_body_parts.py

compose.py's third-party imports (boto3, botocore) and helper's imap_session
are faked in sys.modules before import, so the suite needs no AWS access and
never dials an IMAP server. `helper` itself is the real module -- faking it
would hand every later-discovered suite the stub instead (#860/#863).

Every client sends both `text` and `html`, and the composer used to wrap them
as multipart/alternative whether or not each carried anything. A reader shows
the last alternative it can render, so a request with `"html": ""` -- the
tester's direct-API unblock email -- arrived as a blank body in any client
showing rich content, with the text the sender wrote hidden in the plain part.
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

# The tester's payload: long lines, so the text part goes out
# quoted-printable exactly as the delivered message's did.
TESTER_TEXT = (
    "Retest pass, on the Mini.\n\n"
    "Blocked: every macOS live (XCUITest) arm. mac-probe.sh fails with "
    "'Timed out while enabling automation mode.'\n"
)


def _body(text, html):
    '''A /send payload that is valid in every respect but its body.'''
    return {
        'sender': 'daily@qa.example.com',
        'to_list': ['daily@qa.example.com'],
        'cc_list': [],
        'bcc_list': [],
        'subject': 'body-parts probe',
        'html': html,
        'text': text,
        'draft': False,
        'attachments': [],
        'other_headers': {'message_id': [], 'in_reply_to': [], 'references': []},
    }


def _body_parts(msg):
    '''Every text part a reader could pick as the body, in wire order.'''
    return [part for part in msg.walk()
            if part.get_content_maintype() == 'text'
            and not part.is_attachment()]


class ComposeBodyPartsTest(unittest.TestCase):
    '''A composed body is multipart/alternative only when both halves carry
    content; otherwise it is the one half that does.'''

    def setUp(self):
        # Bind compose's module-level preferences table rather than trusting
        # this file's sys.modules fake to have won the import: under a
        # directory-wide `discover` a sibling suite's fake gets there first
        # and hands compose a table with no get_item (#860/#863).
        self._saved_table = compose._preferences_table  # pylint: disable=protected-access
        compose._preferences_table = _FakeTable()  # pylint: disable=protected-access

    def tearDown(self):
        compose._preferences_table = self._saved_table  # pylint: disable=protected-access

    def _compose(self, text, html, attachments=None):
        body = _body(text, html)
        if attachments is None:
            return compose.compose_from_body(body, 'testuser')
        # Attachments are staged from S3 by compose_from_body, so hand them
        # to compose_message directly, already decoded.
        return compose.compose_message(
            body['subject'], body['sender'],
            {'to': body['to_list'][0], 'cc': '', 'bcc': '',
             'message_id': [], 'in_reply_to': [], 'references': []},
            text, html, attachments)

    def test_both_halves_compose_as_alternatives(self):
        msg = self._compose('probe', '<p>probe</p>')
        self.assertEqual(msg.get_content_type(), 'multipart/alternative')
        parts = _body_parts(msg)
        self.assertEqual([p.get_content_type() for p in parts],
                         ['text/plain', 'text/html'])
        self.assertEqual(parts[0].get_content().strip(), 'probe')
        self.assertEqual(parts[1].get_content().strip(), '<p>probe</p>')

    def test_empty_html_composes_the_text_alone(self):
        # The delivered unblock email: text in the plain part, an empty
        # text/html part after it that every rich view displayed.
        msg = self._compose(TESTER_TEXT, '')
        self.assertEqual(msg.get_content_type(), 'text/plain')
        self.assertEqual(msg.get_content().rstrip('\n'), TESTER_TEXT.rstrip('\n'))
        self.assertNotIn('text/html', msg.as_string())

    def test_whitespace_html_counts_as_empty(self):
        msg = self._compose('probe', ' \n\t\n')
        self.assertEqual(msg.get_content_type(), 'text/plain')
        self.assertEqual(msg.get_content().strip(), 'probe')

    def test_empty_text_composes_the_html_alone(self):
        # The mirror image: a plain-text reader would show a blank body.
        msg = self._compose('', '<p>probe</p>')
        self.assertEqual(msg.get_content_type(), 'text/html')
        self.assertEqual(msg.get_content().strip(), '<p>probe</p>')
        self.assertNotIn('text/plain', msg.as_string())

    def test_neither_half_composes_one_empty_text_part(self):
        # A blank message is a legitimate send; it just isn't two parts.
        msg = self._compose('', '')
        self.assertEqual(msg.get_content_type(), 'text/plain')
        self.assertEqual(msg.get_content().strip(), '')
        self.assertEqual(len(_body_parts(msg)), 1)

    def test_attachments_keep_a_lone_text_body(self):
        attachment = {'data': b'%PDF-1.7', 'maintype': 'application',
                      'subtype': 'pdf', 'filename': 'probe.pdf'}
        msg = self._compose('probe', '', attachments=[attachment])
        self.assertEqual(msg.get_content_type(), 'multipart/mixed')
        first = next(msg.iter_parts())
        self.assertEqual(first.get_content_type(), 'text/plain')
        self.assertEqual(first.get_content().strip(), 'probe')
        self.assertEqual([p.get_content_type() for p in _body_parts(msg)],
                         ['text/plain'])
        self.assertEqual([p.get_filename() for p in msg.iter_attachments()],
                         ['probe.pdf'])

    def test_attachments_keep_both_alternatives(self):
        attachment = {'data': b'%PDF-1.7', 'maintype': 'application',
                      'subtype': 'pdf', 'filename': 'probe.pdf'}
        msg = self._compose('probe', '<p>probe</p>', attachments=[attachment])
        self.assertEqual(msg.get_content_type(), 'multipart/mixed')
        self.assertEqual(next(msg.iter_parts()).get_content_type(),
                         'multipart/alternative')
        self.assertEqual([p.get_content_type() for p in _body_parts(msg)],
                         ['text/plain', 'text/html'])

    def test_no_body_part_is_blank_beside_one_that_is_not(self):
        # The invariant, over every mix of empty, blank and filled halves:
        # whichever part a reader picks, it never shows a blank body for a
        # message that has one.
        texts = ('', ' \n', 'probe')
        htmls = ('', '\n', '<p>probe</p>')
        for text in texts:
            for html in htmls:
                with self.subTest(text=text, html=html):
                    parts = _body_parts(self._compose(text, html))
                    self.assertTrue(parts)
                    if text.strip() or html.strip():
                        for part in parts:
                            self.assertTrue(
                                part.get_content().strip(),
                                f'{part.get_content_type()} part is blank')


if __name__ == '__main__':
    unittest.main()
