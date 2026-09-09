'''Guarded HTTP fetch for the RSS fetcher and feed autodiscovery
(docs/1.x/rss-implementation-plan.md, phase 2).

The fetcher runs INSIDE the VPC, so a user-supplied URL is a server-side
request-forgery vector until proven otherwise. Every hop, including each
redirect, is checked before a socket opens:

  * https only (D1) - a redirect to http is refused;
  * the host is resolved here and every address must be globally routable
    (no loopback, link-local, RFC 1918, ULA, multicast, reserved, or
    IPv4-mapped forms), and the connection is made to THAT address with the
    host name carried for SNI and the Host header, so a DNS answer cannot
    change between the check and the connect;
  * at most MAX_REDIRECTS hops;
  * a hard per-operation timeout and an overall deadline;
  * a response-size cap enforced while streaming, before and after gzip
    (a gzip bomb is capped on the decompressed side too).

Conditional GET is the politeness floor (D9): the caller passes the prior
ETag / Last-Modified and a 304 comes back as a FetchResult with no body.
Two concessions to how publishers actually behave (verified against a
Cloudflare-fronted feed on stage, 2026-09-09): a weak validator (W/"x",
which Cloudflare substitutes for the origin's strong "x" on compressed
responses) is sent back in its strong form, because origins compare the
string literally and never match the weak one; and when an ETag is known,
If-Modified-Since is NOT sent alongside it, because some origins stamp
Last-Modified with the request time and then fail the whole conditional
on the stale date even though RFC 7232 says the ETag should decide.
Cache-Control max-age and Retry-After are surfaced so the cadence logic
can honour them as floors.

Dependency-injectable for tests: `resolve` (host -> addresses) and
`connect` (address, host, port, timeout -> http.client connection).
'''
import http.client
import ipaddress
import re
import socket
import ssl
import time
import zlib
from dataclasses import dataclass, field
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone
from urllib.parse import urljoin, urlsplit

MAX_REDIRECTS = 5
DEFAULT_MAX_BYTES = 5 * 1024 * 1024
DEFAULT_TIMEOUT_SECONDS = 20
DEFAULT_DEADLINE_SECONDS = 60
_CHUNK = 64 * 1024
_MAX_AGE_RE = re.compile(r'(?:^|[,\s])max-age\s*=\s*(\d+)', re.IGNORECASE)


class FetchError(Exception):
    '''The fetch could not complete. `reason` is a short machine-friendly
    code (blocked_address, too_large, timeout, redirect_loop, ...) that
    lands in the feed's last_error.'''

    def __init__(self, reason, detail=''):
        super().__init__(f'{reason}: {detail}' if detail else reason)
        self.reason = reason
        self.detail = detail


@dataclass
class FetchResult:  # pylint: disable=too-many-instance-attributes
    '''One completed HTTP exchange (after redirects).'''
    status: int
    url: str                              # the URL that answered
    body: bytes = b''
    content_type: str = ''
    etag: str = ''
    last_modified: str = ''
    max_age_seconds: int = 0
    retry_after_seconds: int = 0
    permanent_redirect_to: str = ''       # set when the FIRST hop was 301/308
    hops: list = field(default_factory=list)


def is_public_address(address):
    '''True when `address` (a string) is a globally routable unicast IP.'''
    try:
        addr = ipaddress.ip_address(address)
    except ValueError:
        return False
    if addr.version == 6 and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    return addr.is_global and not addr.is_multicast


def strong_etag(etag):
    '''`etag` without a weak-validator prefix. If-None-Match already uses
    weak comparison, so the strong form can only match where the weak one
    should have; it is what literal-comparing origins expect.'''
    etag = (etag or '').strip()
    return etag[2:] if etag.startswith('W/') else etag


def default_resolve(host, port):
    '''All IP address strings `host` resolves to, in getaddrinfo order.'''
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as err:
        raise FetchError('dns', str(err)) from err
    return [info[4][0] for info in infos]


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    '''HTTPS to a pre-resolved address while presenting `server_hostname`
    for SNI and certificate validation.'''

    def __init__(self, address, server_hostname, port, timeout, context):
        super().__init__(address, port=port, timeout=timeout, context=context)
        self._server_hostname = server_hostname

    def connect(self):
        sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock = self._context.wrap_socket(  # pylint: disable=attribute-defined-outside-init
            sock, server_hostname=self._server_hostname)


def default_connect(address, host, port, timeout):
    '''An https connection to `address` validating the certificate for `host`.'''
    context = ssl.create_default_context()
    return _PinnedHTTPSConnection(address, host, port, timeout, context)


def fetch(url, etag='', last_modified='', user_agent='Cabalmail-Feedbot/1',  # pylint: disable=too-many-arguments,too-many-positional-arguments,too-many-locals
          max_bytes=DEFAULT_MAX_BYTES, timeout=DEFAULT_TIMEOUT_SECONDS,
          deadline=DEFAULT_DEADLINE_SECONDS, resolve=default_resolve,
          connect=default_connect, accept='application/rss+xml, '
          'application/atom+xml, application/feed+json, application/xml;q=0.9, '
          'text/xml;q=0.9, application/json;q=0.8, text/html;q=0.5, */*;q=0.1'):
    '''GET `url` with the guards described in the module docstring.

    Returns a FetchResult for any final 2xx/3xx-exhausted/4xx/5xx status;
    raises FetchError when no HTTP exchange could complete (blocked address,
    DNS failure, timeout, oversize body, too many redirects, TLS failure).'''
    started = time.monotonic()
    current = url
    permanent_to = ''
    hops = []
    for hop in range(MAX_REDIRECTS + 1):
        remaining = deadline - (time.monotonic() - started)
        if remaining <= 0:
            raise FetchError('timeout', 'overall deadline exceeded')
        host, port, target = _check_url(current)
        address = _pick_address(resolve(host, port))
        response, conn = _exchange(connect, address, host, port, target, current,
                                   etag, last_modified, user_agent, accept,
                                   min(timeout, remaining))
        try:
            hops.append((current, response.status))
            location = response.getheader('Location')
            if response.status in (301, 302, 303, 307, 308) and location:
                if hop == 0 and response.status in (301, 308):
                    permanent_to = urljoin(current, location)
                current = urljoin(current, location)
                continue
            body = _read_capped(response, max_bytes) if response.status == 200 else b''
        finally:
            conn.close()
        return _result(response, current, body, permanent_to, hops)
    raise FetchError('redirect_loop', f'more than {MAX_REDIRECTS} redirects')


def _result(response, url, body, permanent_to, hops):
    header = response.getheader
    return FetchResult(
        status=response.status, url=url, body=body,
        content_type=header('Content-Type', '') or '',
        etag=header('ETag', '') or '',
        last_modified=header('Last-Modified', '') or '',
        max_age_seconds=_parse_max_age(header('Cache-Control', '')),
        retry_after_seconds=_parse_retry_after(header('Retry-After', '')),
        permanent_redirect_to=permanent_to, hops=hops)


def _check_url(url):
    parts = urlsplit(url)
    if parts.scheme.lower() != 'https':
        raise FetchError('scheme', 'only https is fetched')
    host = (parts.hostname or '').rstrip('.')
    if not host:
        raise FetchError('url', 'no host')
    port = parts.port or 443
    target = parts.path or '/'
    if parts.query:
        target += '?' + parts.query
    return host, port, target


def _pick_address(addresses):
    if not addresses:
        raise FetchError('dns', 'no addresses')
    for address in addresses:
        if not is_public_address(address):
            raise FetchError('blocked_address', address)
    return addresses[0]


def _exchange(connect, address, host, port, target, url, etag, last_modified,  # pylint: disable=too-many-arguments,too-many-positional-arguments
              user_agent, accept, timeout):
    headers = {
        'Host': host if port == 443 else f'{host}:{port}',
        'User-Agent': user_agent,
        'Accept': accept,
        'Accept-Encoding': 'gzip',
    }
    if etag:
        headers['If-None-Match'] = strong_etag(etag)
    elif last_modified:
        headers['If-Modified-Since'] = last_modified
    try:
        conn = connect(address, host, port, timeout)
    except OSError as err:
        raise FetchError('connection', str(err)) from err
    try:
        conn.request('GET', target, headers=headers)
        response = conn.getresponse()
    except socket.timeout as err:
        conn.close()
        raise FetchError('timeout', url) from err
    except (ssl.SSLError, ssl.CertificateError) as err:
        conn.close()
        raise FetchError('tls', str(err)) from err
    except (OSError, http.client.HTTPException) as err:
        conn.close()
        raise FetchError('connection', str(err)) from err
    return response, conn


def _read_capped(response, max_bytes):
    '''The body, gzip-inflated if so encoded, or FetchError('too_large').'''
    gzipped = (response.getheader('Content-Encoding', '') or '').lower() == 'gzip'
    raw = bytearray()
    while True:
        chunk = response.read(_CHUNK)
        if not chunk:
            break
        raw.extend(chunk)
        if len(raw) > max_bytes:
            raise FetchError('too_large', f'more than {max_bytes} bytes')
    if not gzipped:
        return bytes(raw)
    inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = inflater.decompress(bytes(raw), max_bytes + 1)
    except zlib.error as err:
        raise FetchError('decode', f'bad gzip: {err}') from err
    if len(out) > max_bytes or inflater.unconsumed_tail:
        raise FetchError('too_large', 'decompressed body exceeds cap')
    return out


def _parse_max_age(cache_control):
    match = _MAX_AGE_RE.search(cache_control or '')
    return int(match.group(1)) if match else 0


def _parse_retry_after(value):
    value = (value or '').strip()
    if not value:
        return 0
    if value.isdigit():
        return int(value)
    try:
        when = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return 0
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return max(0, int((when - datetime.now(timezone.utc)).total_seconds()))
