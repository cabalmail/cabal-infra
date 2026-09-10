'''Canonical feed-URL normalizer for the RSS reader (docs/1.x/rss-requirements.md,
Decision 1 and its 2026-09-09 revision).

Two users who type "the same" feed differently must land on ONE shared feed
row, so every URL is reduced to a canonical form before the by_canonical
lookup. The rules, in the order they are applied:

  scheme     http is upgraded to https (the fetch fails cleanly if the feed
             is not actually served over https); anything else is rejected.
  host       lower-cased; a default port is dropped; a leading "www." is
             dropped ONLY when what follows is a registrable apex
             (www.example.com -> example.com, www.example.co.uk ->
             example.co.uk) - other subdomains are distinct feeds. The apex
             form is canonical (operator decision 2026-09-09).
  path       empty -> "/" (the one place a slash is canonical: right
             after the host and port). Everywhere else the path is kept
             EXACTLY as given - operator ruling 2026-09-09: only the server
             knows whether /dir and /dir/ name the same object, and either
             edit can turn a working feed URL into a 404 (a publisher whose
             /feeds/json 404s as /feeds/json/ was hit on stage). If a
             publisher considers two forms equivalent it redirects, and the
             subscribe path canonicalizes the permanent-redirect target.
  query      parameters sorted by (name, value); different parameters are
             different feeds. Blank values are kept.
  fragment   dropped.

<guid> values are NOT passed through this module - they are opaque item
identity, not URLs (the requirements' explicit exception).

The apex test needs the Public Suffix List. `publicsuffixlist` is imported
lazily so the pure rules are unit-testable on a bare interpreter with an
injected suffix oracle; production callers use the default.
'''
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

_MAX_URL_LENGTH = 2048
_psl = None  # pylint: disable=invalid-name


class FeedUrlError(ValueError):
    '''A URL that cannot be a Cabalmail feed. The message is user-facing.'''


def _default_is_registrable(host):
    '''True when `host` is a registrable apex (example.com, example.co.uk)
    according to the bundled Public Suffix List.'''
    global _psl  # pylint: disable=global-statement
    if _psl is None:
        from publicsuffixlist import PublicSuffixList  # pylint: disable=import-outside-toplevel,import-error
        _psl = PublicSuffixList()
    return _psl.privatesuffix(host) == host


def normalize_feed_url(url, is_registrable=None):
    '''Returns the canonical https form of `url` or raises FeedUrlError.

    `is_registrable(host) -> bool` may be injected (tests); the default
    consults the Public Suffix List.'''
    if not isinstance(url, str):
        raise FeedUrlError('Feed URL must be a string.')
    url = url.strip()
    if not url:
        raise FeedUrlError('Feed URL is empty.')
    if len(url) > _MAX_URL_LENGTH:
        raise FeedUrlError('Feed URL is too long.')
    parts = urlsplit(url)
    scheme = parts.scheme.lower()
    if scheme not in ('http', 'https'):
        raise FeedUrlError('Only https feed URLs are supported.')
    if parts.username or parts.password:
        raise FeedUrlError('Credentials in the feed URL are not supported; '
                           'add them as feed credentials instead.')
    host = (parts.hostname or '').rstrip('.')
    if not host or '.' not in host:
        raise FeedUrlError('Feed URL needs a fully qualified host name.')
    try:
        port = parts.port
    except ValueError as err:
        raise FeedUrlError('Feed URL has an invalid port.') from err
    host = _collapse_www(host, is_registrable or _default_is_registrable)
    netloc = host if port in (None, 443) else f'{host}:{port}'
    path = _normalize_path(parts.path)
    query = _normalize_query(parts.query)
    return urlunsplit(('https', netloc, path, query, ''))


def _collapse_www(host, is_registrable):
    if host.startswith('www.'):
        bare = host[4:]
        if bare and is_registrable(bare):
            return bare
    return host


def _normalize_path(path):
    return path or '/'



def _normalize_query(query):
    if not query:
        return ''
    pairs = parse_qsl(query, keep_blank_values=True)
    return urlencode(sorted(pairs))
