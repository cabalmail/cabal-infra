'''Unit tests for rss_discover - feed autodiscovery from a web page.

    python3 lambda/api/_shared/tests/test_rss_discover.py
'''
import os
import sys
import unittest

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

import rss_discover  # noqa: E402  pylint: disable=wrong-import-position

PAGE = b'''<!DOCTYPE html><html><head><title>x</title>
<link rel="stylesheet" href="/a.css">
<link rel="alternate" type="application/rss+xml" title="Posts" href="/feed/">
<LINK REL="alternate" TYPE="application/atom+xml; charset=utf-8" HREF="https://cdn.example.com/atom.xml">
<link rel="alternate" type="application/feed+json" href="feed.json">
<link rel="alternate" type="application/rss+xml" href="/feed/">
</head><body><link rel="alternate" type="application/rss+xml" href="/ignored-in-body"></body></html>'''


class Discover(unittest.TestCase):

    def test_links_in_order_deduplicated_and_absolute(self):
        links = rss_discover.discover_feed_links(PAGE, 'https://example.com/blog/post')
        self.assertEqual(links, [
            ('https://example.com/feed/', 'rss', 'Posts'),
            ('https://cdn.example.com/atom.xml', 'atom', ''),
            ('https://example.com/blog/feed.json', 'json', ''),
        ])

    def test_looks_like_html(self):
        self.assertTrue(rss_discover.looks_like_html(b'<rss/>', 'text/html; charset=utf-8'))
        self.assertTrue(rss_discover.looks_like_html(b'\n  <!DOCTYPE HTML><html>', ''))
        self.assertFalse(rss_discover.looks_like_html(b'<?xml version="1.0"?><rss/>', 'application/rss+xml'))

    def test_broken_markup_does_not_raise(self):
        self.assertEqual(rss_discover.discover_feed_links(b'<html><head><link rel="alternate" type="application/rss+xml" href=', 'https://x.test/'), [])


if __name__ == '__main__':
    unittest.main()
