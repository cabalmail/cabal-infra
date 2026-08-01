'''Unit tests for smtp_session's connection dialing (private-submission
cutover).

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_smtp_session_dial.py

smtp_session is stdlib-only, so the module imports for real; the tests
stub the transport - the TCP connect and the TLS wrap - and let the rest
of smtplib run, so the assertions see the values smtplib itself computes.
Stubbing any higher (SMTP.connect, say) would hide the very code that
picks the TLS server_hostname. The assertions pin the contract the
cutover depends on:

  - with SMTP_INTERNAL_HOST set, the TCP dial goes to the internal name
    while TLS is negotiated for the public name (which is what the
    wildcard certificate carries, so verification is unchanged);
  - a failed internal dial (gaierror et al.) falls back to the public
    listener, but an ssl.SSLError - despite subclassing OSError - does
    NOT fall back;
  - with the env var unset, a plain smtplib.SMTP_SSL(host) is built.
'''
import importlib
import io
import os
import socket
import smtplib
import ssl
import sys
import unittest

_SHARED_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED_DIR)

PUBLIC_HOST = 'smtp-out.control.example'
INTERNAL = 'smtp-out.cabal.internal'
SUBMISSION_PORT = 465


def _import_smtp_session(internal_host):
    '''(Re)imports smtp_session with SMTP_INTERNAL_HOST set as given -
    the module reads the env var at import time.'''
    if internal_host is None:
        os.environ.pop('SMTP_INTERNAL_HOST', None)
    else:
        os.environ['SMTP_INTERNAL_HOST'] = internal_host
    sys.modules.pop('smtp_session', None)
    return importlib.import_module('smtp_session')


class _FakeSocket:
    '''The slice of the socket surface smtplib.connect uses: a greeting
    to read back, and a close.'''

    def makefile(self, *args, **kwargs):
        del args, kwargs
        return io.BytesIO(b'220 smtp-out.test ESMTP ready\r\n')

    def close(self):
        pass


class _StubbedTransport(unittest.TestCase):
    '''Base: replaces socket.create_connection (the TCP dial) and
    SSLContext.wrap_socket (the TLS handshake), recording what each was
    asked for, so a dial runs the real smtplib code path without a
    network. Also pins socket.getfqdn - smtplib calls it to build the
    EHLO name, and a unit test has no business consulting the resolver.

    Subclasses may set self.dial_error (a callable taking the dial host
    and returning an exception to raise, or None) and self.tls_error (an
    exception to raise from the handshake) to inject failures.'''

    def setUp(self):
        self.dials = []       # (host, port) the TCP layer was asked for
        self.tls_names = []   # server_hostname each handshake verified
        self.dial_error = None
        self.tls_error = None
        tests = self

        def fake_create_connection(address, timeout=None,
                                   source_address=None):
            del timeout, source_address
            host, port = address
            tests.dials.append((host, port))
            if tests.dial_error is not None:
                err = tests.dial_error(host)
                if err is not None:
                    raise err
            return _FakeSocket()

        def fake_wrap_socket(context, sock, *args, server_hostname=None,
                             **kwargs):
            del context, args, kwargs
            tests.tls_names.append(server_hostname)
            if tests.tls_error is not None:
                raise tests.tls_error
            return sock

        self._patch(socket, 'create_connection', fake_create_connection)
        self._patch(ssl.SSLContext, 'wrap_socket', fake_wrap_socket)
        self._patch(socket, 'getfqdn', lambda name='': 'lambda.test.invalid')

    def _patch(self, target, name, replacement):
        original = getattr(target, name)
        setattr(target, name, replacement)
        self.addCleanup(setattr, target, name, original)


class PublicPathTest(_StubbedTransport):

    def setUp(self):
        super().setUp()
        self.session = _import_smtp_session(None)

    def test_plain_smtp_ssl_to_public_host(self):
        client = self.session.dial_smtp(PUBLIC_HOST)
        self.assertIs(type(client), smtplib.SMTP_SSL)
        self.assertEqual(self.dials, [(PUBLIC_HOST, SUBMISSION_PORT)])
        self.assertEqual(self.tls_names, [PUBLIC_HOST])


class InternalPathTest(_StubbedTransport):

    def setUp(self):
        super().setUp()
        self.session = _import_smtp_session(INTERNAL)

    def test_host_stays_public_for_tls_verification(self):
        self.session.dial_smtp(PUBLIC_HOST)
        # SMTP_SSL hands the handshake server_hostname=self._host, the
        # host the client was constructed with; the public name there is
        # what keeps certificate verification real against the wildcard.
        self.assertEqual(self.tls_names, [PUBLIC_HOST])

    def test_socket_override_dials_internal_name(self):
        self.session.dial_smtp(PUBLIC_HOST)
        # The override swaps the public name for the internal one before
        # delegating to the parent (which does the TLS wrap).
        self.assertEqual(self.dials, [(INTERNAL, SUBMISSION_PORT)])

    def test_gaierror_falls_back_to_public(self):
        self.dial_error = lambda host: (
            socket.gaierror(8, 'name not yet registered')
            if host == INTERNAL else None)
        client = self.session.dial_smtp(PUBLIC_HOST)
        self.assertIs(type(client), smtplib.SMTP_SSL)
        self.assertEqual(self.dials, [(INTERNAL, SUBMISSION_PORT),
                                      (PUBLIC_HOST, SUBMISSION_PORT)])

    def test_ssl_error_does_not_fall_back(self):
        self.tls_error = ssl.SSLError('certificate verify failed')
        with self.assertRaises(ssl.SSLError):
            self.session.dial_smtp(PUBLIC_HOST)
        # No second dial: the public listener would fail the same way.
        self.assertEqual(self.dials, [(INTERNAL, SUBMISSION_PORT)])


if __name__ == '__main__':
    unittest.main()
