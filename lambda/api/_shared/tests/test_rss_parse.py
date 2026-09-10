'''Unit tests for rss_parse - JSON Feed natively, RSS/Atom through feedparser
(those cases skip when feedparser is not installed), plus item identity.

    python3 lambda/api/_shared/tests/test_rss_parse.py
'''
import importlib.util
import os
import sys
import unittest
from datetime import datetime, timezone

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

import rss_parse  # noqa: E402  pylint: disable=wrong-import-position

HAS_FEEDPARSER = importlib.util.find_spec('feedparser') is not None

JSON_FEED = b'''{
  "version": "https://jsonfeed.org/version/1.1",
  "title": "Example Feed", "home_page_url": "https://example.com/",
  "description": "d",
  "items": [
    {"id": "1", "url": "https://example.com/1", "title": "One",
     "content_html": "<p>Hi</p>", "date_published": "2024-01-02T03:04:05Z",
     "authors": [{"name": "Ann"}]},
    {"url": "https://example.com/2", "title": "Two", "content_text": "a\\nb\\n\\nc",
     "summary": "s <b>", "date_modified": "2024-01-03T00:00:00+02:00"},
    "garbage",
    {"title": "Three, no id or url", "content_html": "<p>x</p>"}
  ]
}'''

RSS = b'''<?xml version="1.0"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
     xmlns:sy="http://purl.org/rss/1.0/modules/syndication/">
<channel><title>R</title><link>https://example.com/</link><description>desc</description>
<ttl>90</ttl><sy:updatePeriod>hourly</sy:updatePeriod><sy:updateFrequency>2</sy:updateFrequency>
<item><guid>g1</guid><title>T1</title><link>https://example.com/1</link>
<pubDate>Tue, 02 Jan 2024 03:04:05 GMT</pubDate><description>sum</description>
<content:encoded><![CDATA[<p>full</p><script>alert(1)</script>]]></content:encoded></item>
<item><title>T2 no guid</title><link>https://example.com/2</link></item>
</channel></rss>'''

ATOM = b'''<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title><subtitle>sub</subtitle>
<link href="https://example.com/"/>
<entry><id>urn:1</id><title>E1</title><link href="https://example.com/e1"/>
<updated>2024-01-05T00:00:00Z</updated><author><name>Bob</name></author>
<content type="html">&lt;p&gt;body&lt;/p&gt;</content></entry></feed>'''


class JsonFeed(unittest.TestCase):

    def test_parse(self):
        feed = rss_parse.parse_feed(JSON_FEED, 'application/feed+json')
        self.assertEqual(feed.feed_type, 'json')
        self.assertEqual((feed.title, feed.site_url, feed.description), ('Example Feed', 'https://example.com/', 'd'))
        self.assertEqual(len(feed.items), 3)
        one, two, three = feed.items
        self.assertEqual((one.guid, one.author, one.content_html), ('1', 'Ann', '<p>Hi</p>'))
        self.assertEqual(one.published_at, datetime(2024, 1, 2, 3, 4, 5, tzinfo=timezone.utc))
        self.assertEqual(two.guid, 'https://example.com/2')
        self.assertEqual(two.content_html, '<p>a<br>b</p><p>c</p>')
        self.assertEqual(two.summary_html, '<p>s &lt;b&gt;</p>')
        self.assertEqual(two.updated_at, datetime(2024, 1, 2, 22, 0, tzinfo=timezone.utc))
        self.assertTrue(three.guid.startswith('sha256:'))

    def test_sniffed_without_content_type(self):
        self.assertEqual(rss_parse.parse_feed(b'  ' + JSON_FEED).feed_type, 'json')

    def test_rejects_non_feed_json_and_empty(self):
        with self.assertRaises(rss_parse.ParseError):
            rss_parse.parse_feed(b'{"version": "1"}', 'application/json')
        with self.assertRaises(rss_parse.ParseError):
            rss_parse.parse_feed(b'{not json', 'application/json')
        with self.assertRaises(rss_parse.ParseError):
            rss_parse.parse_feed(b'   ')


class Identity(unittest.TestCase):

    def test_fallback_chain(self):
        self.assertEqual(rss_parse.item_identity(' id ', 'link', 't', 'b'), 'id')
        self.assertEqual(rss_parse.item_identity('', 'link', 't', 'b'), 'link')
        hashed = rss_parse.item_identity(None, None, 't', 'b')
        self.assertTrue(hashed.startswith('sha256:'))
        self.assertEqual(hashed, rss_parse.item_identity(None, '', 't', 'b'))
        self.assertNotEqual(hashed, rss_parse.item_identity(None, None, 't', 'b2'))


@unittest.skipUnless(HAS_FEEDPARSER, 'feedparser not installed')
class RssAtom(unittest.TestCase):

    def test_rss(self):
        feed = rss_parse.parse_feed(RSS, 'application/rss+xml')
        self.assertEqual(feed.feed_type, 'rss')
        self.assertEqual((feed.title, feed.ttl_minutes, feed.sy_period, feed.sy_frequency),
                         ('R', 90, 'hourly', 2))
        first, second = feed.items
        self.assertEqual((first.guid, first.title, first.summary_html), ('g1', 'T1', 'sum'))
        self.assertIn('<p>full</p>', first.content_html)
        self.assertNotIn('<script', first.content_html)   # feedparser sanitizer stays on
        self.assertEqual(first.published_at, datetime(2024, 1, 2, 3, 4, 5, tzinfo=timezone.utc))
        self.assertEqual(second.guid, 'https://example.com/2')
        self.assertIsNone(second.published_at)

    def test_atom(self):
        feed = rss_parse.parse_feed(ATOM, 'application/atom+xml')
        self.assertEqual(feed.feed_type, 'atom')
        self.assertEqual((feed.title, feed.description, feed.site_url), ('A', 'sub', 'https://example.com/'))
        entry = feed.items[0]
        self.assertEqual((entry.guid, entry.author, entry.url), ('urn:1', 'Bob', 'https://example.com/e1'))
        self.assertEqual(entry.content_html, '<p>body</p>')
        self.assertEqual(entry.published_at, datetime(2024, 1, 5, tzinfo=timezone.utc))

    def test_garbage(self):
        with self.assertRaises(rss_parse.ParseError):
            rss_parse.parse_feed(b'<html><body>not a feed</body></html>', 'text/html')


if __name__ == '__main__':
    unittest.main()
