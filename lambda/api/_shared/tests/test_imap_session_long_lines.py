'''Unit tests for imap_session's raised imaplib line cap.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_imap_session_long_lines.py

A large folder's SORT response is one untagged line holding every UID. Stock
imaplib rejects any line over 1,000,000 bytes, which is what made
/list_messages 502 on a ~145k-message folder. These tests feed a real
imaplib.IMAP4 reader (no socket, no server) a SORT line of that size and pin
that it parses once imap_session is imported. The negative control runs the
same line against the stock cap, so the test fails if the override is removed.

imapclient is faked in sys.modules so imap_session imports without
third-party deps; imaplib itself is the real stdlib module.
'''
import collections
import imaplib
import importlib
import io
import os
import sys
import types
import unittest

_SHARED_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED_DIR)

STOCK_MAXLINE = 1_000_000
# ~145k UIDs at 7 bytes each: the size of the production response that failed.
SORT_LINE = b'* SORT ' + b' '.join(
    str(uid).encode() for uid in range(1_000_000, 1_145_000)) + b'\r\n'


def _install_fake_imapclient():
    imapclient_mod = types.ModuleType('imapclient')
    imapclient_mod.IMAPClient = type('IMAPClient', (), {})
    imapclient_mod.SocketTimeout = collections.namedtuple(
        'SocketTimeout', ['connect', 'read'])
    imap4_mod = types.ModuleType('imapclient.imap4')
    imap4_mod.IMAP4WithTimeout = object
    imapclient_mod.imap4 = imap4_mod
    exceptions_mod = types.ModuleType('imapclient.exceptions')
    exceptions_mod.IMAPClientError = type('IMAPClientError', (Exception,), {})
    imapclient_mod.exceptions = exceptions_mod
    sys.modules['imapclient'] = imapclient_mod
    sys.modules['imapclient.imap4'] = imap4_mod
    sys.modules['imapclient.exceptions'] = exceptions_mod


class _FakeSock:
    '''Serves a byte string through recv(), for imaplib versions whose
    readline() reads the socket directly.'''

    def __init__(self, data):
        self._data = io.BytesIO(data)

    def recv(self, size):
        return self._data.read(size)


def _reader(data):
    '''An unconnected imaplib.IMAP4 whose readline() reads `data`. Sets both
    the file (older imaplib) and the socket buffer (newer imaplib), so the
    test exercises whichever readline() the running Python has.'''
    reader = imaplib.IMAP4.__new__(imaplib.IMAP4)
    try:
        reader.file = io.BytesIO(data)
    except AttributeError:
        pass  # newer imaplib: `file` is a read-only property; sock is used
    reader.sock = _FakeSock(data)
    reader._readbuf = []  # pylint: disable=protected-access
    return reader


class LongSortLineTest(unittest.TestCase):
    '''A SORT line over the stock 1 MB cap.'''

    def setUp(self):
        self.saved = imaplib._MAXLINE  # pylint: disable=protected-access
        self.assertGreater(len(SORT_LINE), STOCK_MAXLINE)

    def tearDown(self):
        imaplib._MAXLINE = self.saved  # pylint: disable=protected-access

    def test_stock_cap_rejects_the_line(self):
        '''Negative control: without imap_session's override, imaplib raises
        the error seen in production.'''
        imaplib._MAXLINE = STOCK_MAXLINE  # pylint: disable=protected-access
        with self.assertRaisesRegex(imaplib.IMAP4.error, 'got more than'):
            _reader(SORT_LINE).readline()

    def test_imap_session_import_lets_the_line_through(self):
        imaplib._MAXLINE = STOCK_MAXLINE  # pylint: disable=protected-access
        _install_fake_imapclient()
        sys.modules.pop('imap_session', None)
        importlib.import_module('imap_session')
        self.assertEqual(_reader(SORT_LINE).readline(), SORT_LINE)


if __name__ == '__main__':
    unittest.main()
