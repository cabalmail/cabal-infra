'''Unit tests for the MCP OAuth sign-in: Cognito access-token verification
(agent_oauth.py) and its path through the /mcp REQUEST authorizer
(authorize_agent).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_agent_oauth.py

Tokens are signed in the test with a throwaway RSA key generated at import
from a fixed seed (stdlib only, so no key material is checked in), and the
pool's JWKS endpoint is a fake, so the suite needs no network or AWS access.
The properties pinned here are the ones the authorizer's admission rests on:
the signature must verify against a published pool key, the token must be an
access token for the MCP app client with the MCP scope and unexpired, and a
token that passes gets exactly Phase A's read-only, INBOX-only grant.'''
import base64
import hashlib
import importlib.util
import json
import os
import random
import sys
import types
import unittest

os.environ.setdefault('AWS_REGION', 'us-east-1')

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_SHARED_DIR = os.path.dirname(_TESTS_DIR)
_API_DIR = os.path.dirname(_SHARED_DIR)
sys.path.insert(0, _SHARED_DIR)

# --- fake boto3 (only what agent_grants imports) -----------------------------

if 'boto3' not in sys.modules:
    _boto3 = types.ModuleType('boto3')
    _boto3.resource = lambda _name, **_kw: types.SimpleNamespace(
        Table=lambda _n: types.SimpleNamespace())
    _boto3.client = lambda _name, **_kw: types.SimpleNamespace()
    _boto3.session = types.SimpleNamespace(Config=lambda **_kw: None)
    sys.modules['boto3'] = _boto3
if 'boto3.dynamodb.conditions' not in sys.modules:
    _conditions = types.ModuleType('boto3.dynamodb.conditions')
    _conditions.Key = lambda name: name
    _dynamodb = types.ModuleType('boto3.dynamodb')
    _dynamodb.conditions = _conditions
    sys.modules['boto3.dynamodb'] = _dynamodb
    sys.modules['boto3.dynamodb.conditions'] = _conditions

import agent_grants  # noqa: E402  pylint: disable=wrong-import-position
import agent_oauth  # noqa: E402  pylint: disable=wrong-import-position


def _load(name):
    spec = importlib.util.spec_from_file_location(
        f'{name}_oauth_test_function', os.path.join(_API_DIR, name, 'function.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


authorize_agent = _load('authorize_agent')

NOW = 1_800_000_000
ISSUER = 'https://cognito-idp.us-east-1.amazonaws.com/us-east-1_TestPool'
CLIENT_ID = 'mcpclient0000000000000000'
SCOPE = 'cabal-mcp/mail.read'
RESOURCE = 'https://abc123.execute-api.us-east-1.amazonaws.com/prod/mcp'
CONFIG = {'issuer': ISSUER, 'client_id': CLIENT_ID, 'scope': SCOPE,
          'resource_url': RESOURCE}
ENV = {'MCP_OAUTH_ISSUER': ISSUER, 'MCP_OAUTH_CLIENT_ID': CLIENT_ID,
       'MCP_OAUTH_SCOPE': SCOPE, 'MCP_RESOURCE_URL': RESOURCE}

# --- a throwaway RSA key -----------------------------------------------------

_SMALL_PRIMES = [p for p in range(3, 2000)
                 if all(p % d for d in range(2, int(p ** 0.5) + 1))]


def _is_probable_prime(n, rng):
    if any(n % p == 0 for p in _SMALL_PRIMES):
        return n in _SMALL_PRIMES
    d, s = n - 1, 0
    while d % 2 == 0:
        d //= 2
        s += 1
    for _ in range(24):
        x = pow(rng.randrange(2, n - 2), d, n)
        if x in (1, n - 1):
            continue
        for _ in range(s - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def _prime(bits, rng):
    while True:
        candidate = rng.getrandbits(bits) | (3 << (bits - 2)) | 1
        if _is_probable_prime(candidate, rng):
            return candidate


def _rsa_key(seed, bits=2048):
    rng = random.Random(seed)
    e = 65537
    while True:
        p, q = _prime(bits // 2, rng), _prime(bits // 2, rng)
        phi = (p - 1) * (q - 1)
        if p != q and phi % e:
            return p * q, e, pow(e, -1, phi)


N, E, D = _rsa_key(20261125)
OTHER_N, _, OTHER_D = _rsa_key(4242)


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def _b64_int(value):
    return _b64(value.to_bytes((value.bit_length() + 7) // 8, 'big'))


def _sign(message, n=N, d=D):
    k = (n.bit_length() + 7) // 8
    digest_info = (bytes.fromhex('3031300d060960864801650304020105000420')
                   + hashlib.sha256(message).digest())
    encoded = b'\x00\x01' + b'\xff' * (k - len(digest_info) - 3) + b'\x00' + digest_info
    return pow(int.from_bytes(encoded, 'big'), d, n).to_bytes(k, 'big')


def _claims(**overrides):
    claims = {
        'sub': '11111111-2222-3333-4444-555555555555',
        'iss': ISSUER,
        'client_id': CLIENT_ID,
        'origin_jti': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        'event_id': 'ffffffff-0000-1111-2222-333333333333',
        'token_use': 'access',
        'scope': SCOPE,
        'auth_time': NOW - 60,
        'exp': NOW + 900,
        'iat': NOW - 60,
        'jti': '99999999-8888-7777-6666-555555555555',
        'username': 'alice',
    }
    claims.update(overrides)
    return {k: v for k, v in claims.items() if v is not None}


def _token(claims=None, header=None, n=N, d=D):
    header = header if header is not None else {'kid': 'key-1', 'alg': 'RS256'}
    signing_input = (f'{_b64(json.dumps(header).encode())}.'
                     f'{_b64(json.dumps(claims if claims is not None else _claims()).encode())}')
    return f'{signing_input}.{_b64(_sign(signing_input.encode(), n, d))}'


JWKS = {'keys': [
    {'alg': 'RS256', 'e': _b64_int(E), 'kid': 'key-1', 'kty': 'RSA',
     'n': _b64_int(N), 'use': 'sig'},
]}


class _FakeJwks:
    def __init__(self, document=None, fail=False):
        self.document = document if document is not None else JWKS
        self.fail = fail
        self.urls = []

    def __call__(self, url):
        self.urls.append(url)
        if self.fail:
            raise OSError('connection refused')
        return self.document


class _OAuthCase(unittest.TestCase):
    def setUp(self):
        agent_oauth.reset_jwks_cache()
        self.addCleanup(agent_oauth.reset_jwks_cache)

    def verify(self, token, now=NOW, fetch=None):
        return agent_oauth.verify_access_token(token, CONFIG, now, fetch or _FakeJwks())

    def assertRejected(self, token, reason, **kwargs):  # pylint: disable=invalid-name
        with self.assertRaises(agent_oauth.TokenRejected) as raised:
            self.verify(token, **kwargs)
        self.assertEqual(str(raised.exception), reason)


# --- RSA signature verification ----------------------------------------------

class SignatureTests(unittest.TestCase):
    def test_valid_signature(self):
        self.assertTrue(agent_oauth.rsa_pkcs1v15_sha256_verify(N, E, b'hello', _sign(b'hello')))

    def test_other_message_or_key_fails(self):
        self.assertFalse(agent_oauth.rsa_pkcs1v15_sha256_verify(N, E, b'hellp', _sign(b'hello')))
        self.assertFalse(agent_oauth.rsa_pkcs1v15_sha256_verify(
            N, E, b'hello', _sign(b'hello', OTHER_N, OTHER_D)))

    def test_malformed_signatures_fail(self):
        good = _sign(b'hello')
        for signature in (b'', good[:-1], b'\x00' + good, N.to_bytes(256, 'big'),
                          (N + 1).to_bytes(256, 'big'), b'\xff' * 256):
            self.assertFalse(agent_oauth.rsa_pkcs1v15_sha256_verify(N, E, b'hello', signature))

    def test_encoding_must_match_exactly(self):
        # A signature over the right digest with the wrong padding byte, or
        # without the DigestInfo wrapper, must not pass.
        k = 256
        digest = hashlib.sha256(b'hello').digest()
        bare = b'\x00\x01' + b'\xff' * (k - len(digest) - 3) + b'\x00' + digest
        info = bytes.fromhex('3031300d060960864801650304020105000420') + digest
        wrong_pad = b'\x00\x01' + b'\xfe' * (k - len(info) - 3) + b'\x00' + info
        for encoded in (bare, wrong_pad):
            signature = pow(int.from_bytes(encoded, 'big'), D, N).to_bytes(k, 'big')
            self.assertFalse(agent_oauth.rsa_pkcs1v15_sha256_verify(N, E, b'hello', signature))

    def test_weak_keys_are_refused(self):
        small_n, small_e, small_d = _rsa_key(7, bits=1024)
        self.assertFalse(agent_oauth.rsa_pkcs1v15_sha256_verify(
            small_n, small_e, b'hello', _sign(b'hello', small_n, small_d)))
        self.assertFalse(agent_oauth.rsa_pkcs1v15_sha256_verify(N, 1, b'hello', _sign(b'hello')))


# --- access-token verification -----------------------------------------------

class VerifyTests(_OAuthCase):
    def test_valid_token(self):
        claims = self.verify(_token())
        self.assertEqual(claims['username'], 'alice')

    def test_shape(self):
        self.assertTrue(agent_oauth.looks_like_jwt(_token()))
        for value in (None, '', 'cbl_agt_' + 'a' * 43, 'a.b', 'a.b.c.d', 'a.b.c=',
                      'a.' + 'b' * 9000 + '.c'):
            self.assertFalse(agent_oauth.looks_like_jwt(value))

    def test_only_rs256(self):
        for header in ({'kid': 'key-1', 'alg': 'none'}, {'kid': 'key-1', 'alg': 'HS256'},
                       {'kid': 'key-1'}):
            self.assertRejected(_token(header=header), 'unsupported alg')
        self.assertRejected(_token(header={'alg': 'RS256'}), 'no key id')

    def test_signature_must_verify(self):
        self.assertRejected(_token(n=OTHER_N, d=OTHER_D), 'bad signature')
        head, _, sig = _token().split('.')
        forged = _b64(json.dumps(_claims(username='mallory')).encode())
        self.assertRejected(f'{head}.{forged}.{sig}', 'bad signature')

    def test_claims(self):
        cases = [
            (_claims(iss='https://cognito-idp.us-east-1.amazonaws.com/us-east-1_Other'),
             'wrong issuer'),
            (_claims(token_use='id'), 'not an access token'),
            (_claims(client_id='someotherclient'), 'wrong client'),
            (_claims(exp=NOW), 'expired'),
            (_claims(exp=None), 'expired'),
            (_claims(exp=str(NOW + 900)), 'expired'),
            (_claims(scope='openid email'), 'missing scope'),
            (_claims(scope='cabal-mcp/mail.readwrite'), 'missing scope'),
            (_claims(scope=None), 'missing scope'),
            (_claims(aud='https://abc123.execute-api.us-east-1.amazonaws.com/prod/other'),
             'wrong audience'),
            (_claims(username=''), 'no username'),
            (_claims(username=None), 'no username'),
        ]
        for claims, reason in cases:
            with self.subTest(reason=reason, claims=claims):
                self.assertRejected(_token(claims), reason)

    def test_scope_among_others_and_bound_audience_pass(self):
        self.verify(_token(_claims(scope=f'openid {SCOPE}')))
        self.verify(_token(_claims(aud=RESOURCE)))
        self.verify(_token(_claims(aud=['https://other.example', RESOURCE])))

    def test_session_id_survives_refresh(self):
        self.assertEqual(agent_oauth.session_id(_claims()),
                         'oauth-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
        self.assertEqual(agent_oauth.session_id(_claims(origin_jti=None)),
                         'oauth-99999999-8888-7777-6666-555555555555')
        self.assertEqual(agent_oauth.session_id({}), 'oauth')

    def test_config_from_environment(self):
        saved = {k: os.environ.pop(k, None) for k in ENV}
        self.addCleanup(lambda: [os.environ.pop(k, None) for k in ENV]
                        and [os.environ.__setitem__(k, v) for k, v in saved.items() if v])
        self.assertIsNone(agent_oauth.oauth_config())
        os.environ.update({k: v for k, v in ENV.items() if k != 'MCP_RESOURCE_URL'})
        self.assertIsNone(agent_oauth.oauth_config())
        os.environ['MCP_RESOURCE_URL'] = RESOURCE
        self.assertEqual(agent_oauth.oauth_config(), CONFIG)


class JwksTests(_OAuthCase):
    def test_keys_are_fetched_once_and_cached(self):
        fetch = _FakeJwks()
        self.verify(_token(), fetch=fetch)
        self.verify(_token(), fetch=fetch)
        self.assertEqual(fetch.urls, [f'{ISSUER}/.well-known/jwks.json'])

    def test_unknown_key_id_refetches_at_most_once_per_window(self):
        fetch = _FakeJwks()
        self.verify(_token(), fetch=fetch)
        stray = _token(header={'kid': 'key-2', 'alg': 'RS256'})
        self.assertRejected(stray, 'unknown key id', fetch=fetch)
        self.assertEqual(len(fetch.urls), 1)
        self.assertRejected(stray, 'unknown key id', fetch=fetch,
                            now=NOW + agent_oauth.JWKS_REFETCH_SECONDS)
        self.assertEqual(len(fetch.urls), 2)

    def test_rotated_key_is_picked_up(self):
        self.verify(_token(), fetch=_FakeJwks())
        rotated = {'keys': JWKS['keys'] + [
            {'alg': 'RS256', 'e': _b64_int(E), 'kid': 'key-2', 'kty': 'RSA',
             'n': _b64_int(OTHER_N), 'use': 'sig'}]}
        token = _token(header={'kid': 'key-2', 'alg': 'RS256'}, n=OTHER_N, d=OTHER_D)
        self.verify(token, now=NOW + agent_oauth.JWKS_REFETCH_SECONDS,
                    fetch=_FakeJwks(rotated))

    def test_fetch_failure_fails_closed_and_retries_next_time(self):
        self.assertRejected(_token(), 'signing keys unavailable (OSError)',
                            fetch=_FakeJwks(fail=True))
        self.verify(_token(), fetch=_FakeJwks())

    def test_parse_skips_keys_that_are_not_rs256_signing_keys(self):
        keys = agent_oauth.parse_jwks({'keys': [
            {'kty': 'EC', 'kid': 'ec', 'crv': 'P-256', 'x': 'AA', 'y': 'AA'},
            {'kty': 'RSA', 'kid': 'enc', 'use': 'enc', 'n': _b64_int(N), 'e': _b64_int(E)},
            {'kty': 'RSA', 'kid': 'ps', 'alg': 'PS256', 'n': _b64_int(N), 'e': _b64_int(E)},
            {'kty': 'RSA', 'kid': 'nokey'},
            'junk',
            {'kty': 'RSA', 'kid': 'ok', 'n': _b64_int(N), 'e': _b64_int(E)},
        ]})
        self.assertEqual(keys, {'ok': (N, E)})
        self.assertEqual(agent_oauth.parse_jwks('junk'), {})
        self.assertEqual(agent_oauth.parse_jwks({'keys': 'junk'}), {})


# --- the authorizer ----------------------------------------------------------

def _authorizer_event(header_value):
    return {
        'type': 'REQUEST',
        'methodArn': 'arn:aws:execute-api:us-east-1:111111111111:abc123/prod/POST/mcp',
        'headers': {'Authorization': header_value} if header_value is not None else {},
    }


class _ForbiddenTable:
    '''A grants table that fails the test if the OAuth path touches it.'''
    def __getattr__(self, name):
        raise AssertionError(f'OAuth tokens must not touch cabal-agent-grants ({name})')


class AuthorizerOAuthTests(_OAuthCase):
    def setUp(self):
        super().setUp()
        saved_env = {k: os.environ.get(k) for k in ENV}
        os.environ.update(ENV)
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None
                                 else os.environ.__setitem__(k, v)
                                 for k, v in saved_env.items()])
        agent_grants._TABLE_CACHE['table'] = _ForbiddenTable()  # pylint: disable=protected-access
        self.addCleanup(agent_grants._TABLE_CACHE.clear)  # pylint: disable=protected-access
        saved_time = authorize_agent.time
        authorize_agent.time = types.SimpleNamespace(time=lambda: NOW)
        self.addCleanup(setattr, authorize_agent, 'time', saved_time)
        saved_fetch = agent_oauth._fetch_jwks  # pylint: disable=protected-access
        self.fetch = _FakeJwks()
        agent_oauth._fetch_jwks = self.fetch  # pylint: disable=protected-access
        self.addCleanup(setattr, agent_oauth, '_fetch_jwks', saved_fetch)
        self.lines = []
        authorize_agent.print = self.lines.append
        self.addCleanup(delattr, authorize_agent, 'print')

    def _refused(self, event):
        with self.assertRaises(Exception) as raised:
            authorize_agent.handler(event, None)
        self.assertEqual(str(raised.exception), 'Unauthorized')

    def test_valid_token_gets_phase_a_scope(self):
        policy = authorize_agent.handler(_authorizer_event(f'Bearer {_token()}'), None)
        self.assertEqual(policy['principalId'], 'alice')
        (statement,) = policy['policyDocument']['Statement']
        self.assertEqual(statement['Effect'], 'Allow')
        self.assertEqual(statement['Resource'],
                         'arn:aws:execute-api:us-east-1:111111111111:abc123/prod/POST/mcp')
        self.assertEqual(policy['context'], {
            'user': 'alice',
            'grant_id': 'oauth-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
            'access': 'read_only',
            'folders': 'INBOX'})
        for value in policy['context'].values():
            self.assertIsInstance(value, str)

    def test_invalid_token_is_refused_and_the_log_names_no_token(self):
        token = _token(_claims(client_id='someotherclient'))
        self._refused(_authorizer_event(f'Bearer {token}'))
        self.assertEqual(self.lines, ['[authorize_agent] refused oauth token reason=wrong client'])
        self.assertFalse(any(token.split('.')[2] in line for line in self.lines))

    def test_refused_when_oauth_is_not_configured(self):
        os.environ.pop('MCP_OAUTH_CLIENT_ID')
        self._refused(_authorizer_event(f'Bearer {_token()}'))
        self.assertEqual(self.fetch.urls, [])

    def test_other_shapes_are_refused_without_a_fetch(self):
        for value in (None, '', 'Bearer', f'Basic {_token()}', 'Bearer not-a-token',
                      'Bearer a.b'):
            self._refused(_authorizer_event(value))
        self.assertEqual(self.fetch.urls, [])


if __name__ == '__main__':
    unittest.main()
