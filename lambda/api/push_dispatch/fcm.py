'''Minimal FCM HTTP v1 client.

The v1 API is plain HTTPS JSON, so unlike apns.py no HTTP/2 stack is needed;
urllib does the transport. What the standard library lacks is the auth: FCM
authenticates with a Google service account, which means one RS256-signed JWT
(RFC 7523) exchanged at Google's OAuth token endpoint for a ~1-hour Bearer
token. The signature comes from python-rsa — a pure-python universal wheel,
the same trade apns.py made with ecdsa (see requirements.txt).

Messages are data-only and high-priority by construction: a `notification`
block would have FCM render content that must not transit Google, and the
whole design (docs/1.x/android-push-notifications.md) is a content-free wake
signal the app enriches locally. High priority is what exempts delivery from
Doze throttling, and is policy-safe here because every message produces a
user-visible notification.

One token per warm Lambda container, reused across invocations. Connections
are per-request: at one wake signal per invocation for a handful of tokens,
HTTPS connection reuse would buy nothing (the reason apns.py holds a socket
is that APNs mandates HTTP/2, not throughput).
'''
import base64
import json
import time
import urllib.error
import urllib.parse
import urllib.request

import rsa  # pylint: disable=import-error

# Google access tokens live 3600 seconds; refresh at 45 minutes so a token is
# never presented near the edge of the window (same posture as apns.py).
TOKEN_LIFETIME_SECONDS = 45 * 60

REQUEST_TIMEOUT_SECONDS = 10

# Matches the wake-signal queue's one-hour retention: a "new mail" push older
# than that is noise, not news, so FCM must not deliver it late either.
MESSAGE_TTL_SECONDS = 3600

OAUTH_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging'
JWT_BEARER_GRANT = 'urn:ietf:params:oauth:grant-type:jwt-bearer'

# v1 error codes that no redelivery can fix. UNREGISTERED is the FCM analog
# of APNs 410 (app uninstalled, token rotated away). INVALID_ARGUMENT means
# the token is malformed — the payload shape is fixed and tested, so a 400
# here indicts the token, not the request. SENDER_ID_MISMATCH means the token
# belongs to a different Firebase project (an environment misconfiguration
# that re-registration under the right client config heals); pruning is right
# because this token can never be sent to from this project.
PERMANENT_ERROR_CODES = frozenset({
    'UNREGISTERED', 'INVALID_ARGUMENT', 'SENDER_ID_MISMATCH',
})


class FcmError(Exception):
    '''A non-2xx FCM response. `permanent` marks token-level rejections the
    caller should react to by pruning the device token, not by retrying.'''

    def __init__(self, status, reason):
        super().__init__(f'FCM {status}: {reason}')
        self.status = status
        self.reason = reason
        self.permanent = status == 404 or reason in PERMANENT_ERROR_CODES


class FcmTransportError(Exception):
    '''The request never produced an FCM verdict: connect/TLS failure,
    timeout, or a failed token exchange (including a revoked or otherwise
    rejected credential — surfacing that as retryable ages it into the DLQ,
    where the operator runbook points at re-seeding SSM). Always worth an
    SQS redelivery.'''


def _b64url(data):
    '''Base64url without padding, as JWTs require.'''
    return base64.urlsafe_b64encode(data).rstrip(b'=')


def _der_field(buf, offset):
    '''Reads one DER TLV at `offset`; returns (tag, value_start, value_end).'''
    tag = buf[offset]
    length = buf[offset + 1]
    offset += 2
    if length & 0x80:
        width = length & 0x7f
        length = int.from_bytes(buf[offset:offset + width], 'big')
        offset += width
    return tag, offset, offset + length


def _pkcs1_from_pkcs8(pem):
    '''Extracts the PKCS#1 RSAPrivateKey DER from a PKCS#8 PEM.

    Google service-account keys ship as PKCS#8 ("BEGIN PRIVATE KEY"), which
    python-rsa cannot load directly — it wants the inner PKCS#1 structure.
    PKCS#8 wraps that as the OCTET STRING member of a fixed three-field
    SEQUENCE (version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING),
    so a hand-rolled walk of that one shape beats pulling in a schema-less
    pyasn1 decode: it is a dozen lines and unit-testable on a bare
    interpreter. A non-RSA key gets past this unwrap but fails loudly in
    rsa's own PKCS#1 parser.
    '''
    body = ''.join(line.strip() for line in pem.strip().splitlines()
                   if '-----' not in line)
    der = base64.b64decode(body)
    tag, cursor, outer_end = _der_field(der, 0)
    if tag != 0x30:
        raise ValueError('private key is not a DER SEQUENCE')
    while cursor < outer_end:
        tag, start, end = _der_field(der, cursor)
        if tag == 0x04:  # privateKey OCTET STRING
            return der[start:end]
        cursor = end
    raise ValueError('no private-key OCTET STRING in PKCS#8 structure')


def _error_code(err):
    '''Maps an HTTPError body onto the error code the taxonomy keys on: the
    FcmError detail's errorCode when present, else the google.rpc status
    string. The OAuth token endpoint uses a different grammar — a bare
    string under "error" ("invalid_grant") — which is returned as-is; those
    responses only ever feed transport-error messages, never the
    prune/retry split.'''
    try:
        body = err.read().decode()
    except (OSError, ValueError):
        return ''
    try:
        error = json.loads(body or '{}').get('error') or {}
    except ValueError:
        return ''
    if isinstance(error, str):
        return error
    if not isinstance(error, dict):
        return ''
    for detail in error.get('details') or []:
        if isinstance(detail, dict) and detail.get('errorCode'):
            return detail['errorCode']
    return error.get('status') or ''


class FcmClient:  # pylint: disable=too-few-public-methods
    '''Sends data-only pushes for one Firebase project using service-account
    auth. `send` is deliberately the whole surface.

    Raises ValueError from the constructor when the service-account JSON is
    unusable (not JSON, missing fields, non-RSA key); the caller treats that
    as "not configured" rather than letting it poison the queue.'''

    def __init__(self, service_account_json):
        try:
            info = json.loads(service_account_json)
        except ValueError as err:
            raise ValueError(f'service account is not JSON: {err}') from err
        try:
            self.project_id = info['project_id']
            self.client_email = info['client_email']
            private_key = info['private_key']
        except KeyError as err:
            raise ValueError(f'service account missing field {err}') from err
        self.token_uri = info.get('token_uri') or 'https://oauth2.googleapis.com/token'
        self.signing_key = rsa.PrivateKey.load_pkcs1(
            _pkcs1_from_pkcs8(private_key), format='DER')
        self.token = (None, 0)  # (access token, obtained-at epoch seconds)

    def _access_token(self):
        '''Returns a cached Bearer token, re-exchanging after TOKEN_LIFETIME.

        The exchange is the documented RFC 7523 flow (signed assertion at the
        token endpoint). Google also accepts self-signed JWTs directly for
        many Cloud APIs, which would drop this round trip; that variant is
        untested against FCM, so the exchange stays until someone verifies it
        (docs/1.x/android-push-notifications.md, open questions).'''
        now = int(time.time())
        token, obtained_at = self.token
        if token and now - obtained_at < TOKEN_LIFETIME_SECONDS:
            return token
        header = _b64url(json.dumps({'alg': 'RS256', 'typ': 'JWT'}).encode())
        claims = _b64url(json.dumps({
            'iss': self.client_email,
            'scope': OAUTH_SCOPE,
            'aud': self.token_uri,
            'iat': now,
            'exp': now + 3600,
        }).encode())
        signing_input = header + b'.' + claims
        signature = rsa.sign(signing_input, self.signing_key, 'SHA-256')
        form = urllib.parse.urlencode({
            'grant_type': JWT_BEARER_GRANT,
            'assertion': (signing_input + b'.' + _b64url(signature)).decode(),
        }).encode()
        request = urllib.request.Request(
            self.token_uri, data=form,
            headers={'Content-Type': 'application/x-www-form-urlencoded'})
        try:
            with urllib.request.urlopen(
                    request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                grant = json.loads(response.read().decode())
        except urllib.error.HTTPError as err:
            # A 400/401 here is a credential problem (revoked key, clock
            # skew), not a token problem — never a prune signal.
            raise FcmTransportError(
                f'token exchange failed: HTTP {err.code} {_error_code(err)}') from err
        except (OSError, ValueError) as err:
            raise FcmTransportError(f'token exchange failed: {err}') from err
        token = grant.get('access_token')
        if not token:
            raise FcmTransportError('token exchange returned no access_token')
        self.token = (token, now)
        return token

    def send(self, device_token, data):
        '''Sends one data-only, high-priority message. Returns None on
        success, raises FcmError (permanent or not) on an FCM verdict, and
        raises FcmTransportError when no verdict was obtained.

        `data` values must all be strings — FCM rejects anything else.'''
        payload = json.dumps({'message': {
            'token': device_token,
            'data': data,
            'android': {
                'priority': 'HIGH',
                'ttl': f'{MESSAGE_TTL_SECONDS}s',
            },
        }}).encode()
        request = urllib.request.Request(
            f'https://fcm.googleapis.com/v1/projects/{self.project_id}/messages:send',
            data=payload,
            headers={
                'Authorization': f'Bearer {self._access_token()}',
                'Content-Type': 'application/json',
            })
        try:
            with urllib.request.urlopen(
                    request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                response.read()
        except urllib.error.HTTPError as err:
            raise FcmError(err.code, _error_code(err)) from err
        except OSError as err:
            raise FcmTransportError(str(err)) from err
