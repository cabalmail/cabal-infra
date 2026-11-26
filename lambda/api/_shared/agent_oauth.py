'''OAuth access tokens on /mcp: verifying the Cognito sign-in that claude.ai's
custom connectors run.

A claude.ai custom connector cannot send a static Authorization header, so it
cannot present a minted cbl_agt_ grant token. It signs the user in through the
user pool's Hosted UI instead (the cabal_mcp_client app client, PKCE, no
secret) and presents the Cognito access token it gets back. The /mcp
authorizer hands such a token to verify_access_token; docs/agent-access.md
("Connect claude.ai") has the operator view and
docs/1.x/agent-mail-access-plan.md the design.

An access token is admitted only if it is:

- an RS256 JWT whose signature checks out against one of the pool's published
  signing keys (fetched from the issuer's jwks.json and cached per container);
- issued by this pool (`iss`), as an access token (`token_use`), to the MCP
  app client (`client_id`), carrying the MCP read scope, and not expired
  (the flag scope, if the token also carries it, lets the holder add custom
  flags; see can_flag);
- if it names an audience at all, addressed to this server's /mcp URL. Cognito
  sets `aud` only under resource binding (RFC 8707), which needs managed
  login; without it the client_id and scope checks carry the binding.

The verification is local, so a token Cognito has revoked keeps working until
it expires. The app client's fifteen-minute access-token lifetime bounds that.

Standard library only, like agent_grants.py: the authorizer must not grow a
compiled dependency, and the one RSA operation it needs (PKCS #1 v1.5
signature verification, a public-key operation with nothing secret to leak
through timing) is a modular exponentiation and a byte comparison.
'''
import base64
import hashlib
import hmac
import json
import os
import re
import urllib.request

# A JWT is three base64url segments. Checked before any decoding, so another
# credential shape is refused without work.
_JWT_RE = re.compile(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')
# Cognito access tokens run to about 1 KB; anything far past that is not one.
_MAX_TOKEN_LEN = 8192

# DER encoding of the SHA-256 DigestInfo prefix (RFC 8017 section 9.2, note 1).
_SHA256_DIGEST_INFO = bytes.fromhex('3031300d060960864801650304020105000420')
# Cognito signs with 2048-bit keys; refuse anything weaker a forged JWKS
# could offer.
_MIN_MODULUS_BITS = 2048

# A token whose key id is not in the cache triggers a fetch of the pool's
# signing keys, at most this often per container. Cognito rotates keys rarely,
# so this only stops a stream of junk key ids from becoming a stream of
# fetches.
JWKS_REFETCH_SECONDS = 300
_JWKS_FETCH_TIMEOUT_SECONDS = 3

_JWKS_CACHE = {'keys': {}, 'fetched_at': None}


class TokenRejected(Exception):
    '''An access token that must not be admitted. The message is a short
    reason for the log; it never contains the token.'''


def oauth_config():
    '''The values an access token must match, from the authorizer's
    environment, or None when any is unset (OAuth sign-in not configured).

    `flag_scope` is the one optional value: the scope that, on top of the read
    scope, lets a token's holder add custom flags. Unset, no token gets that.'''
    config = {
        'issuer': os.environ.get('MCP_OAUTH_ISSUER', ''),
        'client_id': os.environ.get('MCP_OAUTH_CLIENT_ID', ''),
        'scope': os.environ.get('MCP_OAUTH_SCOPE', ''),
        'resource_url': os.environ.get('MCP_RESOURCE_URL', ''),
    }
    if not all(config.values()):
        return None
    config['flag_scope'] = os.environ.get('MCP_OAUTH_FLAG_SCOPE', '')
    return config


def can_flag(claims, config):
    '''True when a verified token also carries the flag scope.'''
    flag_scope = config.get('flag_scope')
    scope = claims.get('scope')
    return bool(flag_scope) and isinstance(scope, str) and flag_scope in scope.split()


def looks_like_jwt(value):
    '''True when `value` has a JWT's shape; says nothing about its validity.'''
    return (isinstance(value, str) and len(value) <= _MAX_TOKEN_LEN
            and bool(_JWT_RE.match(value)))


def verify_access_token(token, config, now, fetch_jwks=None):
    '''Returns the claims of a valid MCP access token, or raises TokenRejected.

    `now` is epoch seconds. `fetch_jwks(url)` returns the parsed JWKS document;
    it defaults to an HTTPS fetch and is injectable for tests.'''
    if not looks_like_jwt(token):
        raise TokenRejected('not a JWT')
    header_b64, payload_b64, signature_b64 = token.split('.')
    header = _json_segment(header_b64)
    if header.get('alg') != 'RS256':
        raise TokenRejected('unsupported alg')
    kid = header.get('kid')
    if not isinstance(kid, str) or not kid:
        raise TokenRejected('no key id')

    modulus, exponent = _signing_key(kid, config['issuer'], now,
                                     fetch_jwks or _fetch_jwks)
    signing_input = f'{header_b64}.{payload_b64}'.encode('ascii')
    if not rsa_pkcs1v15_sha256_verify(modulus, exponent, signing_input,
                                      _b64url_decode(signature_b64)):
        raise TokenRejected('bad signature')

    claims = _json_segment(payload_b64)
    _check_claims(claims, config, now)
    return claims


def _check_claims(claims, config, now):
    if claims.get('iss') != config['issuer']:
        raise TokenRejected('wrong issuer')
    if claims.get('token_use') != 'access':
        raise TokenRejected('not an access token')
    if claims.get('client_id') != config['client_id']:
        raise TokenRejected('wrong client')
    expires = claims.get('exp')
    if not isinstance(expires, int) or isinstance(expires, bool) or expires <= now:
        raise TokenRejected('expired')
    scope = claims.get('scope')
    if not isinstance(scope, str) or config['scope'] not in scope.split():
        raise TokenRejected('missing scope')
    if 'aud' in claims:
        audience = claims['aud']
        audiences = audience if isinstance(audience, list) else [audience]
        if config['resource_url'] not in audiences:
            raise TokenRejected('wrong audience')
    username = claims.get('username')
    if not isinstance(username, str) or not username:
        raise TokenRejected('no username')


def session_id(claims):
    '''A stable, non-secret name for the sign-in a token came from, for the
    audit log: Cognito's origin_jti survives refreshes, jti does not.'''
    value = claims.get('origin_jti') or claims.get('jti') or ''
    return f'oauth-{value}' if isinstance(value, str) and value else 'oauth'


def rsa_pkcs1v15_sha256_verify(modulus, exponent, message, signature):
    '''RSASSA-PKCS1-v1_5 verification with SHA-256 (RFC 8017 section 8.2.2).

    Uses the encode-and-compare method the RFC specifies: rebuild the one
    valid encoded message for this digest and compare it byte for byte with
    the decrypted signature, rather than parsing the padding, which is where
    signature-forgery bugs live.'''
    if modulus.bit_length() < _MIN_MODULUS_BITS or exponent < 3:
        return False
    k = (modulus.bit_length() + 7) // 8
    if len(signature) != k:
        return False
    sig = int.from_bytes(signature, 'big')
    if sig >= modulus:
        return False
    encoded = pow(sig, exponent, modulus).to_bytes(k, 'big')
    digest_info = _SHA256_DIGEST_INFO + hashlib.sha256(message).digest()
    padding_len = k - len(digest_info) - 3
    if padding_len < 8:
        return False
    expected = b'\x00\x01' + b'\xff' * padding_len + b'\x00' + digest_info
    return hmac.compare_digest(encoded, expected)


def _signing_key(kid, issuer, now, fetch_jwks):
    '''(modulus, exponent) for `kid`, refreshing the cached JWKS when the key
    is unknown and the cache is old enough.'''
    key = _JWKS_CACHE['keys'].get(kid)
    if key is not None:
        return key
    fetched_at = _JWKS_CACHE['fetched_at']
    if fetched_at is not None and now - fetched_at < JWKS_REFETCH_SECONDS:
        raise TokenRejected('unknown key id')
    try:
        document = fetch_jwks(f'{issuer}/.well-known/jwks.json')
    except Exception as err:  # pylint: disable=broad-exception-caught
        # A failed fetch refuses this request (fail closed) and does not
        # start the refetch window, so the next request tries again.
        raise TokenRejected(f'signing keys unavailable ({type(err).__name__})') from err
    _JWKS_CACHE['keys'] = parse_jwks(document)
    _JWKS_CACHE['fetched_at'] = now
    key = _JWKS_CACHE['keys'].get(kid)
    if key is None:
        raise TokenRejected('unknown key id')
    return key


def parse_jwks(document):
    '''{kid: (modulus, exponent)} for the RSA signing keys in a JWKS document;
    entries that are not RS256 signing keys are skipped.'''
    keys = {}
    entries = document.get('keys') if isinstance(document, dict) else None
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict) or entry.get('kty') != 'RSA':
            continue
        if entry.get('use', 'sig') != 'sig' or entry.get('alg', 'RS256') != 'RS256':
            continue
        kid, n_b64, e_b64 = entry.get('kid'), entry.get('n'), entry.get('e')
        if not all(isinstance(v, str) and v for v in (kid, n_b64, e_b64)):
            continue
        try:
            keys[kid] = (int.from_bytes(_b64url_decode(n_b64), 'big'),
                         int.from_bytes(_b64url_decode(e_b64), 'big'))
        except TokenRejected:
            continue
    return keys


def reset_jwks_cache():
    '''Forgets the cached signing keys (tests).'''
    _JWKS_CACHE['keys'] = {}
    _JWKS_CACHE['fetched_at'] = None


def _fetch_jwks(url):
    if not url.startswith('https://'):
        raise ValueError('JWKS URL must be https')
    with urllib.request.urlopen(url, timeout=_JWKS_FETCH_TIMEOUT_SECONDS) as response:
        return json.loads(response.read(65536))


def _b64url_decode(segment):
    try:
        return base64.urlsafe_b64decode(segment + '=' * (-len(segment) % 4))
    except (ValueError, TypeError) as err:
        raise TokenRejected('bad encoding') from err


def _json_segment(segment):
    try:
        value = json.loads(_b64url_decode(segment))
    except (ValueError, UnicodeDecodeError) as err:
        raise TokenRejected('bad JSON') from err
    if not isinstance(value, dict):
        raise TokenRejected('bad JSON')
    return value
