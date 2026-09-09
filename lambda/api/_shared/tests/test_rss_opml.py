'''Unit tests for rss_opml (parse + build, with Feedly / NetNewsWire /
Reeder-shaped fixtures) and the /rss_opml_import and /rss_opml_export
endpoints. defusedxml is required by parse_opml; those cases skip when it
is not installed, the build and endpoint-export cases run regardless.

    python3 lambda/api/_shared/tests/test_rss_opml.py
'''
import importlib.util
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rss_api_fakes as fx  # noqa: E402  pylint: disable=wrong-import-position

import rss_opml  # noqa: E402  pylint: disable=wrong-import-position
import rss_url  # noqa: E402  pylint: disable=wrong-import-position
import rss_subscribe_core as core  # noqa: E402  pylint: disable=wrong-import-position

HAS_DEFUSED = importlib.util.find_spec('defusedxml') is not None
USER = 'alice'

FEEDLY = '''<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0"><head><title>Alice subscriptions in feedly Cloud</title></head><body>
  <outline text="Tech" title="Tech">
    <outline type="rss" text="Rust Blog" title="Rust Blog" xmlUrl="https://blog.rust-lang.org/feed.xml" htmlUrl="https://blog.rust-lang.org/"/>
    <outline text="Apple" title="Apple">
      <outline type="rss" text="Daring Fireball" title="Daring Fireball" xmlUrl="http://daringfireball.net/feeds/json" htmlUrl="https://daringfireball.net/"/>
    </outline>
  </outline>
  <outline type="rss" text="xkcd" title="xkcd.com" xmlUrl="https://xkcd.com/atom.xml" htmlUrl="https://xkcd.com/"/>
  <outline type="rss" text="dupe" xmlUrl="https://xkcd.com/atom.xml"/>
  <outline type="rss" text="bad" xmlUrl="ftp://nope/feed"/>
</body></opml>'''

NETNEWSWIRE = '''<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.1"><head><title>Subscriptions-OnMyMac.opml</title></head><body>
<outline text="News" title="News">
<outline text="AWS News Blog" title="AWS News Blog" description="" type="rss" version="RSS" htmlUrl="https://aws.amazon.com/blogs/aws/" xmlUrl="https://aws.amazon.com/blogs/aws/feed/"/>
</outline>
</body></opml>'''

REEDER_LOWER = '''<opml version="2.0"><head/><body>
<outline text="Comics"><outline text="xkcd" type="rss" xmlurl="https://xkcd.com/atom.xml" htmlurl="https://xkcd.com/"/></outline>
</body></opml>'''


def call(module, **kw):
    response = module.handler(fx.event(USER, **kw), None)
    return response['statusCode'], json.loads(response['body'])


@unittest.skipUnless(HAS_DEFUSED, 'defusedxml not installed')
class Parse(unittest.TestCase):

    def test_feedly_nested_folders_dedup_and_order(self):
        entries = rss_opml.parse_opml(FEEDLY)
        self.assertEqual([(e['xml_url'], e['folder_path']) for e in entries], [
            ('https://blog.rust-lang.org/feed.xml', ['Tech']),
            ('http://daringfireball.net/feeds/json', ['Tech', 'Apple']),
            ('https://xkcd.com/atom.xml', []),
            ('ftp://nope/feed', []),
        ])
        self.assertEqual(entries[2]['title'], 'xkcd')
        self.assertEqual(entries[0]['html_url'], 'https://blog.rust-lang.org/')

    def test_netnewswire_and_lowercase_attributes(self):
        self.assertEqual(rss_opml.parse_opml(NETNEWSWIRE)[0]['folder_path'], ['News'])
        entry = rss_opml.parse_opml(REEDER_LOWER)[0]
        self.assertEqual((entry['xml_url'], entry['html_url'], entry['folder_path']),
                         ('https://xkcd.com/atom.xml', 'https://xkcd.com/', ['Comics']))

    def test_rejects_non_opml_empty_and_entities(self):
        for doc in ('', '   ', '<rss/>', '<opml version="2.0"><head/></opml>', 'not xml at all'):
            with self.assertRaises(rss_opml.OpmlError):
                rss_opml.parse_opml(doc)
        bomb = '<!DOCTYPE x [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;">]><opml><body><outline text="&b;"/></body></opml>'
        with self.assertRaises(rss_opml.OpmlError):
            rss_opml.parse_opml(bomb)


class Build(unittest.TestCase):

    def test_nested_outlines_and_escaping(self):
        folders = [{'folder_id': 'a', 'parent_folder_id': '', 'name': 'Tech & Co', 'display_order': 0},
                   {'folder_id': 'b', 'parent_folder_id': 'a', 'name': 'Apple', 'display_order': 0}]
        subs = [{'subscription_id': 's1', 'feed_id': 'f1', 'folder_id': 'b', 'custom_title': '',
                 'feed': {'title': 'Daring "Fireball"', 'canonical_url': 'https://daringfireball.net/feeds/json',
                          'site_url': 'https://daringfireball.net/'}},
                {'subscription_id': 's2', 'feed_id': 'f2', 'folder_id': '', 'custom_title': 'My xkcd',
                 'feed': {'title': 'xkcd.com', 'canonical_url': 'https://xkcd.com/atom.xml', 'site_url': ''}}]
        text = rss_opml.build_opml(folders, subs)
        self.assertIn('<outline text="Tech &amp; Co" title="Tech &amp; Co">', text)
        self.assertIn("text='Daring \"Fireball\"'", text)
        self.assertIn('xmlUrl="https://daringfireball.net/feeds/json" htmlUrl="https://daringfireball.net/"/>', text)
        self.assertIn('<outline text="My xkcd" title="My xkcd" type="rss" xmlUrl="https://xkcd.com/atom.xml"/>', text)
        self.assertLess(text.index('Tech &amp; Co'), text.index('Apple'))
        self.assertLess(text.index('Apple'), text.index('Daring'))
        if HAS_DEFUSED:
            entries = rss_opml.parse_opml(text)
            self.assertEqual([(e['title'], e['folder_path']) for e in entries],
                             [('Daring "Fireball"', ['Tech & Co', 'Apple']), ('My xkcd', [])])


@unittest.skipUnless(HAS_DEFUSED, 'defusedxml not installed')
class ImportEndpoint(unittest.TestCase):

    def test_additive_import_creates_folders_and_feeds(self):
        tables = fx.reset_tables()
        mod = fx.load_handler('rss_opml_import')
        core.FETCH_QUEUE_URL = 'https://sqs/queue'
        # The real normalizer with a stand-in suffix oracle: the fixture's
        # ftp:// entry must be rejected the way production rejects it.
        core.normalize_feed_url = lambda url: rss_url.normalize_feed_url(
            url, is_registrable=lambda host: host.count('.') == 1)
        # xkcd already exists as a shared feed the caller follows.
        tables['cabal-rss-feed'].rows[('fx',)] = {'feed_id': 'fx', 'canonical_url': 'https://xkcd.com/atom.xml',
                                                   'owner_key': '~shared', 'due_shard': 'active', 'subscriber_count': 1}
        tables['cabal-rss-subscription'].rows[(USER, 'sx')] = {'user': USER, 'subscription_id': 'sx', 'feed_id': 'fx',
                                                                'folder_id': '~root', 'folder_key': '~root#sx'}
        tables['cabal-rss-folder'].rows[(USER, 'tech')] = {'user': USER, 'folder_id': 'tech', 'name': 'Tech'}
        status, body = call(mod, body={'opml': FEEDLY})
        self.assertEqual(status, 200)
        self.assertEqual((body['created'], body['existing'], body['folders_created']), (2, 1, 1))
        self.assertEqual([f['code'] for f in body['failed']], ['invalid_url'])
        feeds = {r['canonical_url']: r for r in tables['cabal-rss-feed'].rows.values()}
        self.assertEqual(feeds['https://daringfireball.net/feeds/json']['title'], 'Daring Fireball')
        self.assertEqual(feeds['https://daringfireball.net/feeds/json']['subscriber_count'], 1)
        self.assertEqual(len(fx.SQS.sent), 2)                       # the two new feeds were enqueued
        subs = {r['feed_id']: r for r in tables['cabal-rss-subscription'].rows.values()}
        rust = feeds['https://blog.rust-lang.org/feed.xml']
        self.assertEqual(subs[rust['feed_id']]['folder_id'], 'tech')  # reused the existing Tech folder
        apple = next(r for r in tables['cabal-rss-folder'].rows.values() if r['name'] == 'Apple')
        self.assertEqual(apple['parent_folder_id'], 'tech')
        self.assertEqual(subs[feeds['https://daringfireball.net/feeds/json']['feed_id']]['folder_id'],
                         apple['folder_id'])
        # No probe on import: nothing fetched.
        status, body = call(mod, body={'opml': '<rss/>'})
        self.assertEqual((status, body['code']), (400, 'invalid_opml'))
        self.assertEqual(call(mod, body={'opml': FEEDLY, 'folder_id': 'nope'})[0], 404)

    def test_import_under_a_folder(self):
        tables = fx.reset_tables()
        mod = fx.load_handler('rss_opml_import')
        core.normalize_feed_url = lambda url: rss_url.normalize_feed_url(
            url, is_registrable=lambda host: host.count('.') == 1)
        tables['cabal-rss-folder'].rows[(USER, 'imp')] = {'user': USER, 'folder_id': 'imp', 'name': 'Imported'}
        status, body = call(mod, body={'opml': NETNEWSWIRE, 'folder_id': 'imp'})
        self.assertEqual((status, body['created'], body['folders_created']), (200, 1, 1))
        news = next(r for r in tables['cabal-rss-folder'].rows.values() if r['name'] == 'News')
        self.assertEqual(news['parent_folder_id'], 'imp')


class ExportEndpoint(unittest.TestCase):

    def test_export(self):
        tables = fx.reset_tables()
        mod = fx.load_handler('rss_opml_export')
        tables['cabal-rss-feed'].rows[('f1',)] = {'feed_id': 'f1', 'canonical_url': 'https://xkcd.com/atom.xml',
                                                   'title': 'xkcd.com', 'site_url': 'https://xkcd.com/', 'due_shard': 'active'}
        tables['cabal-rss-folder'].rows[(USER, 'c')] = {'user': USER, 'folder_id': 'c', 'name': 'Comics'}
        tables['cabal-rss-subscription'].rows[(USER, 's1')] = {'user': USER, 'subscription_id': 's1', 'feed_id': 'f1',
                                                                'folder_id': 'c', 'folder_key': 'c#s1'}
        status, body = call(mod)
        self.assertEqual(status, 200)
        self.assertTrue(body['filename'].startswith('cabalmail-feeds-') and body['filename'].endswith('.opml'))
        self.assertIn('<outline text="Comics" title="Comics">', body['opml'])
        self.assertIn('xmlUrl="https://xkcd.com/atom.xml" htmlUrl="https://xkcd.com/"/>', body['opml'])


if __name__ == '__main__':
    unittest.main()
