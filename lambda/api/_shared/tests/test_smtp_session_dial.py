'''Unit tests for smtp_session's connection dialing (private-submission
cutover).

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_smtp_session_dial.py

smtp_session is stdlib-only, so the module imports for real; the tests
patch smtplib internals at the class level so nothing dials a network.
The assertions pin the contract the cutover depends on:

  - with SMTP_INTERNAL_HOST set, the TCP dial goes to the internal name
    while self._host keeps the public name (which SMTP_SSL passes as
    server_hostname, so the wildcard-certificate check is unchanged);
  - a failed internal dial (gaierror et al.) falls back to the public
    listener, but an ssl.SSLError - despite subclassing OSError - does
    NOT fall back;
  - with the env var unset, a plain smtplib.SMTP_SSL(host) is built.
'''
import importlib
import os
import smtplib
import socket
import ssl
import sys
import unittest

_SHARED_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED_DIR)

PUBLIC_HOST = 'smtp-out.control.example'
INTERNAL = 'smtp-out.cabal.internal'


def _import_smtp_session(internal_host):
    '''(Re)imports smtp_session with SMTP_INTERNAL_HOST set as given -
    the module reads the env var at import time.'''
    if internal_host is None:
        os.environ.pop('SMTP_INTERNAL_HOST', None)
    else:
        os.environ['SMTP_INTERNAL_HOST'] = internal_host
    sys.modules.pop('smtp_session', None)
    return importlib.import_module('smtp_session')


class _RecordingConnects(unittest.TestCase):
    '''Base: patches smtplib.SMTP.connect to record its host argument and
    skip the network. connect() is what __init__ calls, and it is also the
    only caller of _get_socket, so recording here captures the TCP target
    each dial variant would use.'''

    def setUp(self):
        self.connects = []
        tests = self

        def fake_connect(client, host='localhost', port=0, source_address=None):
            del source_address
            tests.connects.append((client, host, port))
            return (220, b'ok')

        self._orig_connect = smtplib.SMTP.connect
        smtplib.SMTP.connect = fake_connect
        self.addCleanup(setattr, smtplib.SMTP, 'connect', self._orig_connect)


class PublicPathTest(_RecordingConnects):

    def setUp(self):
        super().setUp()
        self.session = _import_smtp_session(None)

    def test_plain_smtp_ssl_to_public_host(self):
        client = self.session.dial_smtp(PUBLIC_HOST)
        self.assertIs(type(client), smtplib.SMTP_SSL)
        self.assertEqual(self.connects[-1][1], PUBLIC_HOST)


class InternalPathTest(_RecordingConnects):

    def setUp(self):
        super().setUp()
        self.session = _import_smtp_session(INTERNAL)

    def test_host_stays_public_for_tls_verification(self):
        client = self.session.dial_smtp(PUBLIC_HOST)
        # smtplib.SMTP.__init__ stores the constructor host in _host and
        # SMTP_SSL wraps sockets with server_hostname=self._host; the
        # public name there is what keeps certificate verification real.
        self.assertEqual(client._host, PUBLIC_HOST)  # pylint: disable=protected-access

    def test_socket_override_dials_internal_name(self):
        client = self.session.dial_smtp(PUBLIC_HOST)
        wrapped = []

        def fake_parent_get_socket(instance, host, port, timeout):
            del instance, timeout
            wrapped.append((host, port))
            return 'sentinel-socket'

        orig = smtplib.SMTP_SSL._get_socket
        smtplib.SMTP_SSL._get_socket = fake_parent_get_socket
        try:
            result = client._get_socket(PUBLIC_HOST, 465, None)  # pylint: disable=protected-access
        finally:
            smtplib.SMTP_SSL._get_socket = orig
        # The override swaps the public name for the internal one before
        # delegating to the parent (which does the TLS wrap).
        self.assertEqual(result, 'sentinel-socket')
        self.assertEqual(wrapped, [(INTERNAL, 465)])

    def test_gaierror_falls_back_to_public(self):
        def failing_connect(client, host='localhost', port=0,
                            source_address=None):
            del source_address
            if isinstance(client, self.session._InternalRouteSMTPSSL):  # pylint: disable=protected-access
                raise socket.gaierror(8, 'name not yet registered')
            self.connects.append((client, host, port))
            return (220, b'ok')

        smtplib.SMTP.connect = failing_connect
        client = self.session.dial_smtp(PUBLIC_HOST)
        self.assertIs(type(client), smtplib.SMTP_SSL)
        self.assertEqual(self.connects[-1][1], PUBLIC_HOST)

    def test_ssl_error_does_not_fall_back(self):
        def failing_connect(client, host='localhost', port=0,
                            source_address=None):
            del client, host, port, source_address
            raise ssl.SSLError('certificate verify failed')

        smtplib.SMTP.connect = failing_connect
        with self.assertRaises(ssl.SSLError):
            self.session.dial_smtp(PUBLIC_HOST)


if __name__ == '__main__':
    unittest.main()
