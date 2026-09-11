'''Feed parsing for the RSS fetcher: RSS 0.9x/1.0/2.0 and Atom through
feedparser, JSON Feed 1.x natively (docs/1.x/rss-requirements.md, D16).

The output is one flat shape regardless of input format so the fetcher and
the subscribe endpoint never see feedparser objects:

    ParsedFeed(feed_type, title, description, site_url,
               ttl_minutes, sy_period, sy_frequency, items=[ParsedItem])
    ParsedItem(guid, title, author, url, summary_html, content_html,
               published_at, updated_at)

Item identity (`guid`) falls back from the feed's id, to the item link, to a
hash of title + body, because a meaningful share of real feeds omit ids and
the fetcher's by_guid dedup must still be stable across fetches.

feedparser is imported lazily inside parse_feed so the JSON Feed path and
the pure helpers are unit-testable on a bare interpreter; the RSS/Atom
tests skip when feedparser is not installed. feedparser's HTML sanitizer
stays ON (its default): item HTML is stored as sanitized, and the clients
still render it through the same sandboxed body view they use for mail.
'''
import calendar
import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone

MAX_ITEMS_PER_FETCH = 500
_JSON_FEED_VERSION_PREFIX = 'https://jsonfeed.org/version/'


class ParseError(Exception):
    '''The body is not a feed we can read.'''


@dataclass
class ParsedItem:  # pylint: disable=too-many-instance-attributes
    '''One feed entry, format-neutral.'''
    guid: str
    title: str = ''
    author: str = ''
    url: str = ''
    summary_html: str = ''
    content_html: str = ''
    published_at: datetime = None
    updated_at: datetime = None


@dataclass
class ParsedFeed:  # pylint: disable=too-many-instance-attributes
    '''A parsed feed document.'''
    feed_type: str                      # 'rss' | 'atom' | 'json'
    title: str = ''
    description: str = ''
    site_url: str = ''
    ttl_minutes: int = 0
    sy_period: str = ''
    sy_frequency: int = 0
    items: list = field(default_factory=list)


def parse_feed(body, content_type=''):
    '''ParsedFeed from raw bytes, or ParseError.'''
    if not body or not body.strip():
        raise ParseError('empty body')
    if _looks_like_json_feed(body, content_type):
        return _parse_json_feed(body)
    return _parse_with_feedparser(body)


def item_identity(guid, link, title, body):
    '''The dedup key for an entry: its id, else its link, else a content hash.'''
    for candidate in (guid, link):
        if candidate and str(candidate).strip():
            return str(candidate).strip()[:1024]
    digest = hashlib.sha256()
    digest.update((title or '').encode('utf-8', 'replace'))
    digest.update(b'\x00')
    digest.update((body or '').encode('utf-8', 'replace'))
    return 'sha256:' + digest.hexdigest()


def _looks_like_json_feed(body, content_type):
    ctype = (content_type or '').split(';')[0].strip().lower()
    if ctype in ('application/feed+json', 'application/json'):
        return True
    head = body.lstrip()[:1]
    return head == b'{'


def _parse_json_feed(body):
    try:
        doc = json.loads(body)
    except (ValueError, UnicodeDecodeError) as err:
        raise ParseError(f'invalid JSON: {err}') from err
    if not isinstance(doc, dict) or not str(doc.get('version', '')).startswith(
            _JSON_FEED_VERSION_PREFIX):
        raise ParseError('not a JSON Feed document')
    items = []
    for raw in (doc.get('items') or [])[:MAX_ITEMS_PER_FETCH]:
        if not isinstance(raw, dict):
            continue
        content_html = raw.get('content_html') or ''
        if not content_html and raw.get('content_text'):
            content_html = _text_to_html(raw['content_text'])
        summary = raw.get('summary') or ''
        author = ''
        authors = raw.get('authors') or ([raw['author']] if raw.get('author') else [])
        if authors and isinstance(authors[0], dict):
            author = str(authors[0].get('name') or '')
        items.append(ParsedItem(
            guid=item_identity(raw.get('id'), raw.get('url'), raw.get('title'),
                               content_html or summary),
            title=str(raw.get('title') or ''),
            author=author,
            url=str(raw.get('url') or raw.get('external_url') or ''),
            summary_html=_text_to_html(summary) if summary else '',
            content_html=content_html,
            published_at=_iso_to_datetime(raw.get('date_published')),
            updated_at=_iso_to_datetime(raw.get('date_modified')),
        ))
    return ParsedFeed(
        feed_type='json',
        title=str(doc.get('title') or ''),
        description=str(doc.get('description') or ''),
        site_url=str(doc.get('home_page_url') or ''),
        items=items,
    )


def _parse_with_feedparser(body):
    import feedparser  # pylint: disable=import-outside-toplevel,import-error
    parsed = feedparser.parse(body)
    entries = parsed.get('entries') or []
    if parsed.get('bozo') and not entries and not parsed.get('feed'):
        raise ParseError(f'unparseable feed: {parsed.get("bozo_exception")}')
    version = str(parsed.get('version') or '')
    if not version and not entries:
        raise ParseError('not a recognizable RSS or Atom document')
    meta = parsed.get('feed') or {}
    items = [_convert_entry(entry) for entry in entries[:MAX_ITEMS_PER_FETCH]]
    return ParsedFeed(
        feed_type='atom' if version.startswith('atom') else 'rss',
        title=str(meta.get('title') or ''),
        description=str(meta.get('subtitle') or meta.get('description') or ''),
        site_url=str(meta.get('link') or ''),
        ttl_minutes=_as_int(meta.get('ttl')),
        sy_period=str(meta.get('sy_updateperiod') or ''),
        sy_frequency=_as_int(meta.get('sy_updatefrequency')),
        items=items,
    )


def _convert_entry(entry):
    content_html = ''
    for block in entry.get('content') or []:
        value = block.get('value') or ''
        if value and (not content_html or 'html' in str(block.get('type', ''))):
            content_html = value
    summary = entry.get('summary') or ''
    if summary == content_html:
        summary = ''
    # Identity from the body as the publisher wrote it, before any image is
    # folded in, so a feed without guids keeps stable ids across this change.
    guid = item_identity(entry.get('id'), entry.get('link'), entry.get('title'),
                         content_html or summary)
    image = _attached_image(entry)
    if image and '<img' not in (content_html or summary):
        # NASA's Image of the Day and many podcast-style feeds carry the
        # picture as an enclosure or media:content and only prose in the
        # body; readers show it inline, so the body gets it too.
        content_html = f'<p><img src="{_attr(image)}" alt=""></p>' + (content_html or summary)
    return ParsedItem(
        guid=guid,
        title=str(entry.get('title') or ''),
        author=str(entry.get('author') or ''),
        url=str(entry.get('link') or ''),
        summary_html=summary,
        content_html=content_html,
        published_at=_struct_to_datetime(entry.get('published_parsed')
                                         or entry.get('updated_parsed')),
        updated_at=_struct_to_datetime(entry.get('updated_parsed')),
    )


def _attached_image(entry):
    '''The first image the entry attaches outside its body: an `enclosure`
    with an image type, a `media:content` of medium image (or image type),
    or a `media:thumbnail`. Empty when there is none.'''
    for enclosure in entry.get('enclosures') or []:
        if str(enclosure.get('type') or '').startswith('image/') and enclosure.get('href'):
            return str(enclosure['href'])
    for media in entry.get('media_content') or []:
        url = media.get('url') or ''
        media_type = str(media.get('type') or '')
        is_image = media.get('medium') == 'image' or media_type.startswith('image/')
        if url and is_image:
            return str(url)
    for thumb in entry.get('media_thumbnail') or []:
        if thumb.get('url'):
            return str(thumb['url'])
    return ''


def _attr(value):
    '''Escapes a URL for an HTML attribute.'''
    return (value.replace('&', '&amp;').replace('"', '&quot;')
            .replace('<', '&lt;').replace('>', '&gt;'))


def _struct_to_datetime(struct):
    if not struct:
        return None
    try:
        return datetime.fromtimestamp(calendar.timegm(struct), tz=timezone.utc)
    except (TypeError, ValueError, OverflowError):
        return None


def _iso_to_datetime(value):
    if not value:
        return None
    text = str(value).strip()
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    try:
        when = datetime.fromisoformat(text)
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.astimezone(timezone.utc)


def _text_to_html(text):
    escaped = (str(text).replace('&', '&amp;').replace('<', '&lt;')
               .replace('>', '&gt;'))
    return '<p>' + escaped.replace('\n\n', '</p><p>').replace('\n', '<br>') + '</p>'


def _as_int(value):
    try:
        return max(0, int(float(value)))
    except (TypeError, ValueError):
        return 0
