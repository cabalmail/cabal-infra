'''The verified `www.` fallback behind Decision 1's apex rule.

D1 makes the apex host canonical (`www.example.com` -> `example.com`), but
some publishers serve the feed only on `www.` and either 404 the apex path
or redirect every apex path to their front page. Both the fetcher and the
subscribe probe call `try_www` when the apex did not yield a feed; a feed
found on the `www.` form becomes the canonical URL ("apex when the apex
serves it"). The fetch and parse functions are parameters so each caller's
module-level stubs keep working in tests.
'''
from rss_http import FetchError  # pylint: disable=import-error
from rss_parse import ParseError  # pylint: disable=import-error
from rss_url import www_variant  # pylint: disable=import-error


def try_www(canonical, user_agent, fetch_fn, parse_fn, variant_fn=www_variant):
    '''(www_url, FetchResult, ParsedFeed) when the `www.` form of an apex
    canonical serves a feed; None when there is no such form, it cannot be
    fetched, it is not a 200, or its body is not a feed.'''
    alt = variant_fn(canonical)
    if not alt:
        return None
    try:
        result = fetch_fn(alt, user_agent=user_agent)
    except FetchError:
        return None
    if result.status != 200:
        return None
    try:
        return alt, result, parse_fn(result.body, result.content_type)
    except ParseError:
        return None
