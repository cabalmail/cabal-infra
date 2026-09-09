'''Feed autodiscovery for /rss_subscribe: when the URL a user pastes is a web
page rather than a feed, find the feeds the page advertises through
<link rel="alternate" type="application/rss+xml|atom+xml|feed+json" href=...>
(RSS Autodiscovery, the convention every blog platform follows).

Stdlib html.parser only; tolerant of broken markup because it stops caring
after </head> and never needs a tree.
'''
from html.parser import HTMLParser
from urllib.parse import urljoin

FEED_TYPES = {
    'application/rss+xml': 'rss',
    'application/atom+xml': 'atom',
    'application/feed+json': 'json',
    'application/json': 'json',
}
_MAX_HTML_BYTES = 512 * 1024


class _LinkCollector(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []
        self.done = False

    def handle_starttag(self, tag, attrs):
        if self.done:
            return
        if tag == 'body':
            self.done = True
            return
        if tag != 'link':
            return
        attr = {k.lower(): (v or '') for k, v in attrs}
        rel = attr.get('rel', '').lower().split()
        ctype = attr.get('type', '').lower().split(';')[0].strip()
        if 'alternate' in rel and ctype in FEED_TYPES and attr.get('href'):
            self.links.append((attr['href'], FEED_TYPES[ctype], attr.get('title', '')))

    def handle_endtag(self, tag):
        if tag == 'head':
            self.done = True

    def error(self, message):  # pragma: no cover - HTMLParser hook
        '''Surface a parser error as ValueError (caught by the caller).'''
        raise ValueError(message)


def looks_like_html(body, content_type=''):
    '''True when the response is a web page rather than a feed document.'''
    ctype = (content_type or '').split(';')[0].strip().lower()
    if ctype in ('text/html', 'application/xhtml+xml'):
        return True
    head = body[:2048].lstrip().lower()
    return head.startswith(b'<!doctype html') or head.startswith(b'<html')


def discover_feed_links(body, base_url):
    '''[(absolute_url, feed_type, title)] in document order, de-duplicated.'''
    text = body[:_MAX_HTML_BYTES].decode('utf-8', 'replace')
    collector = _LinkCollector()
    try:
        collector.feed(text)
    except (ValueError, AssertionError):
        pass
    seen, out = set(), []
    for href, ftype, title in collector.links:
        absolute = urljoin(base_url, href.strip())
        if absolute not in seen:
            seen.add(absolute)
            out.append((absolute, ftype, title))
    return out
