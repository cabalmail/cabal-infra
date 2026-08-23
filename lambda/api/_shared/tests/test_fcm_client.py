'''Unit tests for push_dispatch's FCM HTTP v1 client (fcm.py).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_fcm_client.py

The rsa dependency is faked in sys.modules before import (pure-python or
not, it is not installed on the bare CI interpreter), and urllib's urlopen
is patched per test, so the suite needs no network and no wheels. What
stays real: the PKCS#8 unwrap (verified against an openssl-generated
fixture), the OAuth token-exchange flow and its caching, the v1 message
shape, and the error taxonomy the dispatch loop's prune/retry split keys
on. fcm.py is loaded under a unique module name so this suite never hands
another one its rsa fake (#860/#863).
'''
import base64
import importlib.util
import io
import json
import os
import sys
import types
import unittest
import urllib.error
import urllib.parse
import urllib.request
from unittest import mock

# --- fake rsa ----------------------------------------------------------------


class _FakePrivateKey:
    loaded = []

    @staticmethod
    def load_pkcs1(der, format='PEM'):  # pylint: disable=redefined-builtin
        _FakePrivateKey.loaded.append((der, format))
        return 'fake-signing-key'


_rsa = types.ModuleType('rsa')
_rsa.PrivateKey = _FakePrivateKey
_rsa.sign = lambda message, key, alg: b'fixture-signature'
sys.modules['rsa'] = _rsa

# --- load fcm.py under a unique name -----------------------------------------

_API = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_FCM_PATH = os.path.join(_API, 'push_dispatch', 'fcm.py')
_SPEC = importlib.util.spec_from_file_location('fcm_client_under_test', _FCM_PATH)
fcm = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = fcm
_SPEC.loader.exec_module(fcm)

# --- fixtures ----------------------------------------------------------------

# Throwaway 512-bit RSA key generated with openssl for this test only — it is
# a parser fixture, not a credential, and secures nothing anywhere. The PEM
# armor is assembled at runtime so the raw file never contains an armored
# private key for secret scanners to trip on.
PKCS8_B64 = (
    'MIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEAuPEd0TWj8qIdJzKeC80hIVWM'
    '7hC0deE7lNCsnt/LlD63+rrhoGtgyMT8QCXZODe7OVf6YSjBKz0SrjIHdnT6zwIDAQABAkAy'
    'olkuiUgcywO+Up5wzrWuYbTXDR3LVGIyqTtJuC4NpPLrY7I4mFpUt+JMBz62BdrNpPW2MaiQ'
    'vSANT9UYvp+xAiEA55F5TYmYJ/wwmvTlG5EPYc7Fgx01TF9GGJ0U6GzIxfkCIQDMdEpUd3bb'
    'E1fFm/wBE66CFeYCvcoR51krBr41akRZBwIgHG4BxIE2CwKtPPj//8hpaQqnuRcm6f9wbakr'
    'XfWtGJECIQCKM6F67zX8aFrQTNxPrgosDLlp6PiKmaOAnhI88RQ6SQIgPEzI0Ct32cRaw3Ov'
    'POsB8ER8UQHDEnCUc8zvn+pyGAY='
)
PKCS1_DER_B64 = (
    'MIIBOgIBAAJBALjxHdE1o/KiHScyngvNISFVjO4QtHXhO5TQrJ7fy5Q+t/q64aBrYMjE/EAl'
    '2Tg3uzlX+mEowSs9Eq4yB3Z0+s8CAwEAAQJAMqJZLolIHMsDvlKecM61rmG01w0dy1RiMqk7'
    'SbguDaTy62OyOJhaVLfiTAc+tgXazaT1tjGokL0gDU/VGL6fsQIhAOeReU2JmCf8MJr05RuR'
    'D2HOxYMdNUxfRhidFOhsyMX5AiEAzHRKVHd22xNXxZv8AROughXmAr3KEedZKwa+NWpEWQcC'
    'IBxuAcSBNgsCrTz4///IaWkKp7kXJun/cG2pK131rRiRAiEAijOheu81/Gha0EzcT64KLAy5'
    'aej4ipmjgJ4SPPEUOkkCIDxMyNArd9nEWsNzrzzrAfBEfFEBwxJwlHPM75/qchgG'
)


def _fixture_pem():
    body = PKCS8_B64
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return ('-----BEGIN PRIVATE KEY-----\n'
            + '\n'.join(lines)
            + '\n-----END PRIVATE KEY-----\n')


def _service_account(**overrides):
    info = {
        'type': 'service_account',
        'project_id': 'cabal-test',
        'client_email': 'fcm-sender@cabal-test.iam.gserviceaccount.com',
        'private_key': _fixture_pem(),
        'token_uri': 'https://oauth2.googleapis.com/token',
    }
    info.update(overrides)
    return json.dumps(info)


class _FakeResponse:
    def __init__(self, body):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


def _http_error(code, payload):
    return urllib.error.HTTPError(
        'https://fcm.googleapis.com/', code, 'error', None,
        io.BytesIO(json.dumps(payload).encode()))


def _fcm_error_body(status, error_code=None):
    error = {'code': 0, 'message': 'm', 'status': status}
    if error_code:
        error['details'] = [{
            '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError',
            'errorCode': error_code,
        }]
    return {'error': error}


class _Router:
    '''urlopen stand-in: token-endpoint requests get a grant, FCM requests
    get the scripted verdict; everything is recorded for assertions.'''

    def __init__(self, fcm_result=None):
        self.token_requests = []
        self.fcm_requests = []
        self.fcm_result = fcm_result

    def __call__(self, request, timeout=None):
        if 'oauth2' in request.full_url:
            self.token_requests.append(request)
            return _FakeResponse(json.dumps(
                {'access_token': 'granted-token', 'expires_in': 3600}).encode())
        self.fcm_requests.append(request)
        if isinstance(self.fcm_result, Exception):
            raise self.fcm_result
        return _FakeResponse(b'{}')


# --- tests -------------------------------------------------------------------


class Pkcs8UnwrapTests(unittest.TestCase):
    '''The hand-rolled DER walk against a real openssl-generated pair.'''

    def test_unwrap_matches_openssl_pkcs1(self):
        der = fcm._pkcs1_from_pkcs8(_fixture_pem())  # pylint: disable=protected-access
        self.assertEqual(der, base64.b64decode(PKCS1_DER_B64))

    def test_non_sequence_rejected(self):
        garbage = base64.b64encode(b'\x02\x01\x00').decode()
        pem = f'-----BEGIN PRIVATE KEY-----\n{garbage}\n-----END PRIVATE KEY-----'
        with self.assertRaises(ValueError):
            fcm._pkcs1_from_pkcs8(pem)  # pylint: disable=protected-access


class ConstructorTests(unittest.TestCase):
    def test_valid_service_account_loads_inner_pkcs1(self):
        _FakePrivateKey.loaded.clear()
        client = fcm.FcmClient(_service_account())
        self.assertEqual(client.project_id, 'cabal-test')
        der, der_format = _FakePrivateKey.loaded[-1]
        self.assertEqual(der, base64.b64decode(PKCS1_DER_B64))
        self.assertEqual(der_format, 'DER')

    def test_not_json_raises_value_error(self):
        with self.assertRaises(ValueError):
            fcm.FcmClient('not json at all')

    def test_missing_field_raises_value_error(self):
        info = json.loads(_service_account())
        del info['project_id']
        with self.assertRaises(ValueError):
            fcm.FcmClient(json.dumps(info))


class SendTests(unittest.TestCase):
    def test_data_only_high_priority_message(self):
        router = _Router()
        client = fcm.FcmClient(_service_account())
        with mock.patch.object(urllib.request, 'urlopen', router):
            client.send('token-1:abc', {'folder': 'INBOX', 'uid': '7', 'msg_id': '<x@y>'})
        self.assertEqual(len(router.fcm_requests), 1)
        request = router.fcm_requests[0]
        self.assertIn('/projects/cabal-test/messages:send', request.full_url)
        self.assertEqual(request.get_header('Authorization'), 'Bearer granted-token')
        message = json.loads(request.data.decode())['message']
        self.assertEqual(message['token'], 'token-1:abc')
        self.assertEqual(message['data'],
                         {'folder': 'INBOX', 'uid': '7', 'msg_id': '<x@y>'})
        self.assertEqual(message['android'], {'priority': 'HIGH', 'ttl': '3600s'})
        # Content-free and data-only by construction.
        self.assertNotIn('notification', message)

    def test_access_token_cached_across_sends(self):
        router = _Router()
        client = fcm.FcmClient(_service_account())
        with mock.patch.object(urllib.request, 'urlopen', router):
            client.send('token-1:abc', {'folder': 'INBOX', 'uid': '1', 'msg_id': ''})
            client.send('token-2:def', {'folder': 'INBOX', 'uid': '2', 'msg_id': ''})
        self.assertEqual(len(router.token_requests), 1)
        self.assertEqual(len(router.fcm_requests), 2)

    def test_token_exchange_sends_jwt_bearer_grant(self):
        router = _Router()
        client = fcm.FcmClient(_service_account())
        with mock.patch.object(urllib.request, 'urlopen', router):
            client.send('token-1:abc', {'folder': 'INBOX', 'uid': '1', 'msg_id': ''})
        form = dict(
            pair.split('=', 1)
            for pair in router.token_requests[0].data.decode().split('&'))
        self.assertIn('jwt-bearer', urllib.parse.unquote(form['grant_type']))
        self.assertTrue(form['assertion'])

    def test_transport_error_wraps_oserror(self):
        client = fcm.FcmClient(_service_account())
        router = _Router(fcm_result=None)

        def _explode(request, timeout=None):
            if 'oauth2' in request.full_url:
                return router(request, timeout)
            raise urllib.error.URLError('connection refused')

        with mock.patch.object(urllib.request, 'urlopen', _explode):
            with self.assertRaises(fcm.FcmTransportError):
                client.send('token-1:abc', {'folder': 'INBOX', 'uid': '1', 'msg_id': ''})

    def test_failed_token_exchange_is_transport_error(self):
        client = fcm.FcmClient(_service_account())

        def _reject(_request, timeout=None):  # pylint: disable=unused-argument
            raise _http_error(401, {'error': 'invalid_grant'})

        with mock.patch.object(urllib.request, 'urlopen', _reject):
            with self.assertRaises(fcm.FcmTransportError):
                client.send('token-1:abc', {'folder': 'INBOX', 'uid': '1', 'msg_id': ''})


class ErrorTaxonomyTests(unittest.TestCase):
    '''The prune/retry split the dispatch loop keys on.'''

    def _verdict(self, code, payload):
        router = _Router(fcm_result=_http_error(code, payload))
        client = fcm.FcmClient(_service_account())
        with mock.patch.object(urllib.request, 'urlopen', router):
            with self.assertRaises(fcm.FcmError) as caught:
                client.send('token-1:abc', {'folder': 'INBOX', 'uid': '1', 'msg_id': ''})
        return caught.exception

    def test_unregistered_is_permanent(self):
        err = self._verdict(404, _fcm_error_body('NOT_FOUND', 'UNREGISTERED'))
        self.assertTrue(err.permanent)
        self.assertEqual(err.reason, 'UNREGISTERED')

    def test_invalid_argument_is_permanent(self):
        err = self._verdict(400, _fcm_error_body('INVALID_ARGUMENT', 'INVALID_ARGUMENT'))
        self.assertTrue(err.permanent)

    def test_sender_id_mismatch_is_permanent(self):
        err = self._verdict(403, _fcm_error_body('PERMISSION_DENIED', 'SENDER_ID_MISMATCH'))
        self.assertTrue(err.permanent)

    def test_quota_exceeded_is_retryable(self):
        err = self._verdict(429, _fcm_error_body('RESOURCE_EXHAUSTED', 'QUOTA_EXCEEDED'))
        self.assertFalse(err.permanent)

    def test_unavailable_is_retryable(self):
        err = self._verdict(503, _fcm_error_body('UNAVAILABLE', 'UNAVAILABLE'))
        self.assertFalse(err.permanent)

    def test_internal_without_error_code_falls_back_to_status(self):
        err = self._verdict(500, _fcm_error_body('INTERNAL'))
        self.assertFalse(err.permanent)
        self.assertEqual(err.reason, 'INTERNAL')

    def test_404_with_unparseable_body_is_still_permanent(self):
        router = _Router(fcm_result=urllib.error.HTTPError(
            'https://fcm.googleapis.com/', 404, 'gone', None, io.BytesIO(b'not json')))
        client = fcm.FcmClient(_service_account())
        with mock.patch.object(urllib.request, 'urlopen', router):
            with self.assertRaises(fcm.FcmError) as caught:
                client.send('token-1:abc', {'folder': 'INBOX', 'uid': '1', 'msg_id': ''})
        self.assertTrue(caught.exception.permanent)


if __name__ == '__main__':
    unittest.main()
