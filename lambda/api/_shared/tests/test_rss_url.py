'''Unit tests for rss_url.normalize_feed_url - the canonical feed-URL rules
from docs/1.x/rss-requirements.md Decision 1 (apex canonical, https only
with http upgraded, trailing-slash and query normalization).

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/_shared/tests/test_rss_url.py

The Public Suffix List oracle is injected so the rules run on a bare
interpreter; one test uses the real publicsuffixlist package when it is
installed and skips otherwise.'''
import os
import sys
import unittest

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

import rss_url  # noqa: E402  pylint: disable=wrong-import-position


def _fake_registrable(host):
    '''Apex if one label before a one-label suffix, or two before co.uk.'''
    labels = host.split('.')
    if host.endswith('.co.uk'):
        return len(labels) == 3
    return len(labels) == 2


def norm(url):
    return rss_url.normalize_feed_url(url, is_registrable=_fake_registrable)


class RequirementsExamples(unittest.TestCase):
    '''Every example in the requirements doc, under the apex-canonical ruling.'''

    def test_root_with_and_without_slash(self):
        self.assertEqual(norm('https://example.com'), 'https://example.com/')
        self.assertEqual(norm('https://example.com/'), 'https://example.com/')

    def test_www_collapses_to_apex(self):
        self.assertEqual(norm('https://www.example.com/'), 'https://example.com/')
        self.assertEqual(norm('https://example.com/'), 'https://example.com/')

    def test_other_subdomains_are_distinct(self):
        self.assertNotEqual(norm('https://web.example.com/'), norm('https://www.example.com/'))
        self.assertNotEqual(norm('https://web.example.com/'), norm('https://example.com/'))
        self.assertEqual(norm('https://web.example.com/'), 'https://web.example.com/')

    def test_two_dot_apex(self):
        self.assertEqual(norm('https://www.example.co.uk/'), 'https://example.co.uk/')
        self.assertEqual(norm('https://example.co.uk/'), 'https://example.co.uk/')

    def test_www_of_a_subdomain_is_not_collapsed(self):
        self.assertEqual(norm('https://www.web.example.com/'), 'https://www.web.example.com/')

    def test_trailing_slash_kept_as_given_but_equivalent(self):
        # Neither added nor removed (either can 404 a real feed); the two
        # forms are reconciled at lookup time through equivalent_urls().
        self.assertEqual(norm('https://example.com/dir'), 'https://example.com/dir')
        self.assertEqual(norm('https://example.com/dir/'), 'https://example.com/dir/')
        self.assertEqual(rss_url.equivalent_urls('https://example.com/dir'),
                         ['https://example.com/dir', 'https://example.com/dir/'])
        self.assertEqual(rss_url.equivalent_urls('https://example.com/dir/?a=1'),
                         ['https://example.com/dir/?a=1', 'https://example.com/dir?a=1'])
        self.assertEqual(rss_url.equivalent_urls('https://example.com/'), ['https://example.com/'])

    def test_file_like_path_untouched(self):
        self.assertEqual(norm('https://example.com/feed.xml'), 'https://example.com/feed.xml')
        self.assertEqual(norm('https://example.com/rss.php?x=1'), 'https://example.com/rss.php?x=1')
        self.assertEqual(norm('https://example.com/feeds/json'), 'https://example.com/feeds/json')

    def test_different_query_values_are_different(self):
        self.assertNotEqual(norm('https://example.com/?foo=bar'), norm('https://example.com/?foo=baz'))

    def test_query_order_normalized(self):
        self.assertEqual(norm('https://example.com/?foo=bar&bin=baz'),
                         'https://example.com/?bin=baz&foo=bar')
        self.assertEqual(norm('https://example.com/?bin=baz&foo=bar'),
                         'https://example.com/?bin=baz&foo=bar')


class SchemeRules(unittest.TestCase):

    def test_http_is_upgraded(self):
        self.assertEqual(norm('http://example.com/feed'), 'https://example.com/feed')

    def test_other_schemes_rejected(self):
        for url in ('ftp://example.com/', 'file:///etc/passwd', 'example.com/feed', ''):
            with self.assertRaises(rss_url.FeedUrlError):
                norm(url)

    def test_userinfo_rejected(self):
        with self.assertRaises(rss_url.FeedUrlError):
            norm('https://user:pw@example.com/feed')

    def test_host_case_and_default_port(self):
        self.assertEqual(norm('HTTPS://Example.COM:443/Feed'), 'https://example.com/Feed')
        self.assertEqual(norm('https://example.com:8443/feed'), 'https://example.com:8443/feed')

    def test_fragment_dropped_blank_query_kept(self):
        self.assertEqual(norm('https://example.com/feed#top'), 'https://example.com/feed')
        self.assertEqual(norm('https://example.com/feed/?a='), 'https://example.com/feed/?a=')

    def test_bare_host_rejected(self):
        with self.assertRaises(rss_url.FeedUrlError):
            norm('https://localhost/feed')


@unittest.skipUnless(_has_psl := __import__('importlib').util.find_spec('publicsuffixlist'),
                     'publicsuffixlist not installed')
class RealPublicSuffixList(unittest.TestCase):

    def test_real_oracle(self):
        self.assertEqual(rss_url.normalize_feed_url('https://www.example.co.uk/'),
                         'https://example.co.uk/')
        self.assertEqual(rss_url.normalize_feed_url('https://www.blog.example.com/'),
                         'https://www.blog.example.com/')
        # github.io is a public suffix: user.github.io is itself an apex.
        self.assertEqual(rss_url.normalize_feed_url('https://www.user.github.io/feed.xml'),
                         'https://user.github.io/feed.xml')


if __name__ == '__main__':
    unittest.main()
