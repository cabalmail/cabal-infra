'''Unit tests for rss_http.fetch - the SSRF-guarded, size-capped, redirect-
bounded feed fetch. Resolution and connections are injected; no network.

    python3 lambda/api/_shared/tests/test_rss_http.py
'''
import gzip
import os
import sys
import unittest

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

import rss_http  # noqa: E402  pylint: disable=wrong-import-position


class FakeResponse:
    def __init__(self, status, headers=None, body=b''):
        self.status = status
        self._headers = {k.lower(): v for k, v in (headers or {}).items()}
        self._body = body
        self._pos = 0

    def getheader(self, name, default=None):
        return self._headers.get(name.lower(), default)

    def read(self, size=-1):
        if size is None or size < 0:
            size = len(self._body)
        chunk = self._body[self._pos:self._pos + size]
        self._pos += len(chunk)
        return chunk


class FakeConnection:
    def __init__(self, script, log):
        self.script = script
        self.log = log
        self.closed = False

    def request(self, method, target, headers=None):
        self.log.append((method, target, headers or {}))

    def getresponse(self):
        return self.script.pop(0)

    def close(self):
        self.closed = True


def make_fetch(responses, addresses=('93.184.216.34',)):
    '''fetch() bound to scripted responses; returns (call, request_log, conns).'''
    log = []
    conns = []
    script = list(responses)

    def connect(address, host, port, timeout):  # pylint: disable=unused-argument
        conn = FakeConnection(script, log)
        conns.append(conn)
        return conn

    def resolve(host, port):  # pylint: disable=unused-argument
        return list(addresses)

    def call(url, **kw):
        return rss_http.fetch(url, resolve=resolve, connect=connect, **kw)
    return call, log, conns


class AddressGuard(unittest.TestCase):

    def test_public_and_private(self):
        self.assertTrue(rss_http.is_public_address('93.184.216.34'))
        self.assertTrue(rss_http.is_public_address('2606:2800:220:1:248:1893:25c8:1946'))
        for bad in ('127.0.0.1', '10.1.2.3', '172.16.0.1', '192.168.1.1', '169.254.169.254',
                    '::1', 'fd00::1', 'fe80::1', '::ffff:10.0.0.1', '0.0.0.0', '224.0.0.1',
                    'not-an-ip'):
            self.assertFalse(rss_http.is_public_address(bad), bad)

    def test_private_resolution_refused_before_connecting(self):
        call, log, _ = make_fetch([FakeResponse(200)], addresses=('93.184.216.34', '10.0.0.5'))
        with self.assertRaises(rss_http.FetchError) as ctx:
            call('https://example.com/feed')
        self.assertEqual(ctx.exception.reason, 'blocked_address')
        self.assertEqual(log, [])

    def test_http_scheme_refused(self):
        call, _, _ = make_fetch([])
        with self.assertRaises(rss_http.FetchError) as ctx:
            call('http://example.com/feed')
        self.assertEqual(ctx.exception.reason, 'scheme')


class Exchange(unittest.TestCase):

    def test_conditional_headers_and_identity(self):
        call, log, conns = make_fetch([FakeResponse(304, {'ETag': '"v2"'})])
        result = call('https://example.com/feed', etag='"v1"', last_modified='Mon, 01 Jan 2024 00:00:00 GMT',
                      user_agent='Cabalmail-Feedbot/1 (+https://www.x.test/feedbot.html)')
        self.assertEqual(result.status, 304)
        self.assertEqual(result.body, b'')
        headers = log[0][2]
        self.assertEqual(headers['If-None-Match'], '"v1"')
        # With an ETag in hand the date is withheld: origins that stamp
        # Last-Modified per request would otherwise fail the conditional.
        self.assertNotIn('If-Modified-Since', headers)
        self.assertEqual(headers['Host'], 'example.com')
        self.assertIn('Feedbot', headers['User-Agent'])
        self.assertTrue(conns[0].closed)

    def test_weak_etag_sent_strong(self):
        call, log, _ = make_fetch([FakeResponse(304)])
        call('https://example.com/feed', etag='W/"abc"')
        self.assertEqual(log[0][2]['If-None-Match'], '"abc"')
        self.assertEqual(rss_http.strong_etag(' W/"x" '), '"x"')
        self.assertEqual(rss_http.strong_etag('"x"'), '"x"')
        self.assertEqual(rss_http.strong_etag(''), '')

    def test_last_modified_used_only_without_etag(self):
        call, log, _ = make_fetch([FakeResponse(304)])
        call('https://example.com/feed', last_modified='Mon, 01 Jan 2024 00:00:00 GMT')
        self.assertEqual(log[0][2]['If-Modified-Since'], 'Mon, 01 Jan 2024 00:00:00 GMT')
        self.assertNotIn('If-None-Match', log[0][2])

    def test_body_and_hints(self):
        call, _, _ = make_fetch([FakeResponse(200, {
            'Content-Type': 'application/rss+xml', 'ETag': '"e"',
            'Last-Modified': 'Tue, 02 Jan 2024 00:00:00 GMT',
            'Cache-Control': 'public, max-age=1800', 'Retry-After': '120'}, b'<rss/>')])
        result = call('https://example.com/feed.xml?b=2&a=1')
        self.assertEqual(result.body, b'<rss/>')
        self.assertEqual(result.etag, '"e"')
        self.assertEqual(result.max_age_seconds, 1800)
        self.assertEqual(result.retry_after_seconds, 120)
        self.assertEqual(result.hops, [('https://example.com/feed.xml?b=2&a=1', 200)])

    def test_gzip_inflated(self):
        payload = gzip.compress(b'<feed>ok</feed>')
        call, _, _ = make_fetch([FakeResponse(200, {'Content-Encoding': 'gzip'}, payload)])
        self.assertEqual(call('https://example.com/feed').body, b'<feed>ok</feed>')

    def test_size_cap_raw_and_inflated(self):
        call, _, _ = make_fetch([FakeResponse(200, {}, b'x' * 1001)])
        with self.assertRaises(rss_http.FetchError) as ctx:
            call('https://example.com/feed', max_bytes=1000)
        self.assertEqual(ctx.exception.reason, 'too_large')
        bomb = gzip.compress(b'\x00' * 100_000)
        call, _, _ = make_fetch([FakeResponse(200, {'Content-Encoding': 'gzip'}, bomb)])
        with self.assertRaises(rss_http.FetchError) as ctx:
            call('https://example.com/feed', max_bytes=10_000)
        self.assertEqual(ctx.exception.reason, 'too_large')


class Redirects(unittest.TestCase):

    def test_permanent_first_hop_recorded(self):
        call, log, _ = make_fetch([
            FakeResponse(301, {'Location': '/feed/'}),
            FakeResponse(302, {'Location': 'https://cdn.example.com/feed.xml'}),
            FakeResponse(200, {}, b'ok')])
        result = call('https://example.com/feed')
        self.assertEqual(result.status, 200)
        self.assertEqual(result.url, 'https://cdn.example.com/feed.xml')
        self.assertEqual(result.permanent_redirect_to, 'https://example.com/feed/')
        self.assertEqual([t for _, t, _ in log], ['/feed', '/feed/', '/feed.xml'])
        self.assertEqual(log[2][2]['Host'], 'cdn.example.com')

    def test_temporary_first_hop_not_recorded(self):
        call, _, _ = make_fetch([FakeResponse(302, {'Location': '/x'}), FakeResponse(200)])
        self.assertEqual(call('https://example.com/feed').permanent_redirect_to, '')

    def test_redirect_to_http_refused(self):
        call, _, _ = make_fetch([FakeResponse(301, {'Location': 'http://example.com/feed'})])
        with self.assertRaises(rss_http.FetchError) as ctx:
            call('https://example.com/feed')
        self.assertEqual(ctx.exception.reason, 'scheme')

    def test_too_many_redirects(self):
        call, _, _ = make_fetch([FakeResponse(302, {'Location': '/loop'})] * 10)
        with self.assertRaises(rss_http.FetchError) as ctx:
            call('https://example.com/loop')
        self.assertEqual(ctx.exception.reason, 'redirect_loop')


class HeaderParsing(unittest.TestCase):

    def test_retry_after_http_date_in_future(self):
        seconds = rss_http._parse_retry_after('Fri, 31 Dec 2999 23:59:59 GMT')  # pylint: disable=protected-access
        self.assertGreater(seconds, 1_000_000)
        self.assertEqual(rss_http._parse_retry_after('garbage'), 0)  # pylint: disable=protected-access
        self.assertEqual(rss_http._parse_retry_after('Mon, 01 Jan 2001 00:00:00 GMT'), 0)  # pylint: disable=protected-access

    def test_max_age(self):
        self.assertEqual(rss_http._parse_max_age('no-cache, max-age=0'), 0)  # pylint: disable=protected-access
        self.assertEqual(rss_http._parse_max_age('s-maxage=10, max-age=600'), 600)  # pylint: disable=protected-access
        self.assertEqual(rss_http._parse_max_age(None), 0)  # pylint: disable=protected-access


if __name__ == '__main__':
    unittest.main()
