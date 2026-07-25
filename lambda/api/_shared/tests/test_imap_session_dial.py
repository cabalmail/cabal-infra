'''Unit tests for imap_session's connection dialing (private-IMAP replumb).

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_imap_session_dial.py

imapclient is faked in sys.modules so the module under test imports without
third-party deps or a live IMAP server. The fakes record constructor
arguments and method calls; the assertions pin the contract the replumb
depends on:

  - with IMAP_INTERNAL_HOST set, the TCP dial goes to the internal name on
    143 while self.host keeps the public name (starttls() verifies the
    server certificate against self.host, so this split is what makes the
    wildcard *.<control-domain> cert check work on a connection to
    imap.cabal.internal), and STARTTLS runs before any LOGIN;
  - without it, the original implicit-TLS client is built, byte-for-byte:
    ssl=True, no port override, no STARTTLS.
'''
import collections
import importlib
import os
import sys
import types
import unittest

_SHARED_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED_DIR)

SocketTimeout = collections.namedtuple('SocketTimeout', ['connect', 'read'])


class FakeIMAP4WithTimeout:
    '''Records the (address, port, timeout) the override dials.'''

    def __init__(self, address, port, timeout):
        self.address = address
        self.port = port
        self.timeout = timeout


class FakeIMAPClient:
    '''Mirrors the slice of imapclient.IMAPClient that imap_session touches:
    the constructor stores connection parameters and immediately "connects"
    via _create_IMAP4 (the real client does this too, which is what makes
    the subclass override effective).'''

    def __init__(self, host=None, port=None, use_uid=None, ssl=True,
                 timeout=None):
        self.host = host
        self.port = port
        self.use_uid = use_uid
        self.ssl = ssl
        self._timeout = timeout
        self.calls = []
        self._imap = self._create_IMAP4()  # pylint: disable=invalid-name

    def _create_IMAP4(self):  # pylint: disable=invalid-name
        return FakeIMAP4WithTimeout(self.host, self.port, None)

    def starttls(self, ssl_context=None):
        self.calls.append('starttls')

    def login(self, user, password):
        self.calls.append(('login', user))

    def select_folder(self, folder, read_only):
        self.calls.append(('select_folder', folder, read_only))


def _install_fake_imapclient():
    imapclient_mod = types.ModuleType('imapclient')
    imapclient_mod.IMAPClient = FakeIMAPClient
    imapclient_mod.SocketTimeout = SocketTimeout

    imap4_mod = types.ModuleType('imapclient.imap4')
    imap4_mod.IMAP4WithTimeout = FakeIMAP4WithTimeout
    imapclient_mod.imap4 = imap4_mod

    exceptions_mod = types.ModuleType('imapclient.exceptions')
    exceptions_mod.IMAPClientError = type('IMAPClientError', (Exception,), {})
    imapclient_mod.exceptions = exceptions_mod

    sys.modules['imapclient'] = imapclient_mod
    sys.modules['imapclient.imap4'] = imap4_mod
    sys.modules['imapclient.exceptions'] = exceptions_mod


def _import_imap_session(internal_host):
    '''(Re)imports imap_session with IMAP_INTERNAL_HOST set as given -
    the module reads the env var at import time.'''
    if internal_host is None:
        os.environ.pop('IMAP_INTERNAL_HOST', None)
    else:
        os.environ['IMAP_INTERNAL_HOST'] = internal_host
    sys.modules.pop('imap_session', None)
    return importlib.import_module('imap_session')


PUBLIC_HOST = 'imap.control.example'
INTERNAL = 'imap.cabal.internal'


class PublicPathTest(unittest.TestCase):
    '''IMAP_INTERNAL_HOST unset: the pre-replumb client, unchanged.'''

    def setUp(self):
        _install_fake_imapclient()
        self.session = _import_imap_session(None)

    def test_dial_is_implicit_tls_to_public_host(self):
        client = self.session.dial_imap(PUBLIC_HOST)
        self.assertEqual(client.host, PUBLIC_HOST)
        self.assertTrue(client.ssl)
        self.assertIsNone(client.port)  # imapclient's default (993 for ssl)
        self.assertEqual(client.calls, [])  # no STARTTLS on the 993 path

    def test_open_imap_client_logs_in_then_selects(self):
        client = self.session.open_imap_client(
            PUBLIC_HOST, 'alice', 'INBOX', False, 'mpw')
        self.assertEqual(client.calls, [
            ('login', 'alice*admin'),
            ('select_folder', 'INBOX', False),
        ])


class InternalPathTest(unittest.TestCase):
    '''IMAP_INTERNAL_HOST set: dial the Cloud Map name, STARTTLS first.'''

    def setUp(self):
        _install_fake_imapclient()
        self.session = _import_imap_session(INTERNAL)

    def test_tcp_goes_internal_but_host_stays_public(self):
        client = self.session.dial_imap(PUBLIC_HOST)
        # The socket dials the Cloud Map name on 143...
        self.assertEqual(client._imap.address, INTERNAL)  # pylint: disable=protected-access
        self.assertEqual(client._imap.port, 143)  # pylint: disable=protected-access
        # ...while self.host keeps the public name starttls() verifies the
        # certificate against.
        self.assertEqual(client.host, PUBLIC_HOST)
        self.assertFalse(client.ssl)

    def test_starttls_runs_before_login(self):
        client = self.session.open_imap_client(
            PUBLIC_HOST, 'alice', 'INBOX', True, 'mpw')
        self.assertEqual(client.calls, [
            'starttls',
            ('login', 'alice*admin'),
            ('select_folder', 'INBOX', True),
        ])


if __name__ == '__main__':
    unittest.main()
