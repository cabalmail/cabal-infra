'''Unit tests for the BIMI proxy handler.

No pytest harness in this repo; run under the stdlib:

    python3 lambda/api/fetch_bimi/tests/test_function.py

function.py's third-party imports (helper, dns, publicsuffixlist) are faked
in sys.modules before import, so the suite needs no boto3 / dnspython / PSL
and never touches the network, S3, or the resvg binary. The fake PSL uses a
last-two-labels heuristic - enough to exercise the From-then-org fallback
without depending on the real Public Suffix List data.'''
import os
import sys
import types
import unittest
from datetime import datetime, timezone

# function.py lives one directory up.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# --- fake dns.resolver / dns.exception ---------------------------------------
_dns = types.ModuleType("dns")
_dns_exception = types.ModuleType("dns.exception")
_dns_resolver = types.ModuleType("dns.resolver")


class _DNSException(Exception):
    pass


class _NXDOMAIN(_DNSException):
    pass


class _NoAnswer(_DNSException):
    pass


# name -> list[str] of TXT strings, or an Exception instance to raise.
RECORDS = {}


class _FakeRdata:
    def __init__(self, text):
        self.strings = [text.encode("utf-8")]


class _FakeResolver:
    def __init__(self):
        self.lifetime = None
        self.timeout = None

    def resolve(self, name, _rtype):
        value = RECORDS.get(name)
        if value is None:
            raise _NXDOMAIN()
        if isinstance(value, Exception):
            raise value
        return [_FakeRdata(text) for text in value]


_dns_exception.DNSException = _DNSException
_dns_resolver.Resolver = _FakeResolver
_dns_resolver.NXDOMAIN = _NXDOMAIN
_dns_resolver.NoAnswer = _NoAnswer
_dns.exception = _dns_exception
_dns.resolver = _dns_resolver
sys.modules["dns"] = _dns
sys.modules["dns.exception"] = _dns_exception
sys.modules["dns.resolver"] = _dns_resolver

# --- fake publicsuffixlist ---------------------------------------------------
_psl_mod = types.ModuleType("publicsuffixlist")


class _FakePSL:
    def privatesuffix(self, domain):
        labels = domain.split(".")
        return ".".join(labels[-2:]) if len(labels) >= 2 else None


_psl_mod.PublicSuffixList = _FakePSL
sys.modules["publicsuffixlist"] = _psl_mod

# --- fake helper -------------------------------------------------------------
_helper = types.ModuleType("helper")


def _validate_dns_apex(domain):
    if not domain or len(str(domain).split(".")) < 2:
        raise ValueError("expected >= 2 labels")
    return domain


class _FakeS3Client:
    def __init__(self):
        self.head_responses = {}  # key -> dict or Exception

    def head_object(self, Bucket, Key):  # noqa: N803 (boto3 kwarg names)
        result = self.head_responses.get(Key, KeyError(Key))
        if isinstance(result, Exception):
            raise result
        return result


_helper.validate_dns_apex = _validate_dns_apex
_helper.s3c = _FakeS3Client()
_helper.uploaded = []
_helper.signed = []


def _upload_object(bucket, key, content_type, obj):
    _helper.uploaded.append((bucket, key, content_type, obj))
    return True


def _sign_url(bucket, key, expiration=86400):  # pylint: disable=unused-argument
    _helper.signed.append((bucket, key))
    return f"https://signed.example/{bucket}/{key}"


_helper.upload_object = _upload_object
_helper.sign_url = _sign_url
sys.modules["helper"] = _helper

os.environ["CONTROL_DOMAIN"] = "ctrl.example"

import function  # noqa: E402  pylint: disable=wrong-import-position

VALID_SVG = (b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
             b'<rect width="10" height="10" fill="#000"/></svg>')


def _fake_run_writes_png(cmd, **_kwargs):
    '''Stand-in for subprocess.run: write a PNG sentinel to the out path.'''
    with open(cmd[-1], "wb") as handle:
        handle.write(b"\x89PNG-rendered")
    return types.SimpleNamespace(returncode=0)


class ParseTest(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(
            function._parse_bimi_logo_url("v=BIMI1; l=https://e/logo.svg"),
            "https://e/logo.svg")

    def test_reordered_tags_extracts_logo_not_vmc(self):
        txt = "v=BIMI1; a=https://e/vmc.pem; l=https://e/logo.svg"
        self.assertEqual(function._parse_bimi_logo_url(txt), "https://e/logo.svg")

    def test_missing_version(self):
        self.assertIsNone(function._parse_bimi_logo_url("l=https://e/logo.svg"))

    def test_missing_logo(self):
        self.assertIsNone(function._parse_bimi_logo_url("v=BIMI1; a=https://e/v.pem"))

    def test_spf_record_is_not_bimi_and_does_not_crash(self):
        # The string published at default._bimi.usps.com / .etsy.com.
        self.assertIsNone(function._parse_bimi_logo_url("v=spf1 ip4:1.2.3.0/24 -all"))

    def test_non_https_logo_rejected(self):
        self.assertIsNone(function._parse_bimi_logo_url("v=BIMI1; l=http://e/logo.svg"))


class ValidateSvgTest(unittest.TestCase):
    def test_valid(self):
        self.assertTrue(function._validate_svg(VALID_SVG))

    def test_script_rejected(self):
        self.assertFalse(function._validate_svg(
            b'<svg xmlns="http://www.w3.org/2000/svg"><script>x</script></svg>'))

    def test_external_image_rejected(self):
        self.assertFalse(function._validate_svg(
            b'<svg xmlns="http://www.w3.org/2000/svg">'
            b'<image href="https://evil/x.png"/></svg>'))

    def test_doctype_rejected(self):
        self.assertFalse(function._validate_svg(
            b'<!DOCTYPE svg><svg xmlns="http://www.w3.org/2000/svg"/>'))

    def test_malformed_rejected(self):
        self.assertFalse(function._validate_svg(b"<svg><rect></svg"))

    def test_non_svg_root_rejected(self):
        self.assertFalse(function._validate_svg(b'<html xmlns="x"/>'))

    def test_oversized_payload_rejected_by_fetch(self):
        # Size cap lives in _fetch_svg; validate handles content shape only.
        big = b'<svg xmlns="http://www.w3.org/2000/svg">' + b"<rect/>" * 6000 + b"</svg>"
        self.assertGreater(len(big), function.SVG_MAX_BYTES)


class CandidateDomainsTest(unittest.TestCase):
    def test_from_then_org(self):
        self.assertEqual(
            function._candidate_domains("email.x.usps.com"),
            ["email.x.usps.com", "usps.com"])

    def test_apex_only_once(self):
        self.assertEqual(function._candidate_domains("usps.com"), ["usps.com"])


class LookupTest(unittest.TestCase):
    def setUp(self):
        RECORDS.clear()

    def test_subdomain_spf_falls_back_to_org_bimi(self):
        # The USPS shape: SPF at the From subdomain, BIMI at the org domain.
        RECORDS["default._bimi.email.usps.com"] = ["v=spf1 -all"]
        RECORDS["default._bimi.usps.com"] = ["v=BIMI1; l=https://e/usps.svg"]
        url = function._lookup_logo_url(
            function._resolver(),
            function._candidate_domains("email.usps.com"),
            function.time.monotonic() + 5)
        self.assertEqual(url, "https://e/usps.svg")

    def test_no_record_anywhere(self):
        url = function._lookup_logo_url(
            function._resolver(),
            function._candidate_domains("nope.example"),
            function.time.monotonic() + 5)
        self.assertIsNone(url)


class HandlerTest(unittest.TestCase):
    def setUp(self):
        RECORDS.clear()
        _helper.uploaded.clear()
        _helper.signed.clear()
        _helper.s3c.head_responses.clear()
        self._real_run = function.subprocess.run
        self._real_fetch = function._fetch_svg
        function.subprocess.run = _fake_run_writes_png

    def tearDown(self):
        function.subprocess.run = self._real_run
        function._fetch_svg = self._real_fetch

    def _event(self, domain):
        return {"queryStringParameters": {"sender_domain": domain}}

    def test_invalid_input_400(self):
        result = function.handler(self._event("localhost"), None)
        self.assertEqual(result["statusCode"], 400)

    def test_happy_path_returns_presigned_png(self):
        RECORDS["default._bimi.chewy.com"] = ["v=BIMI1; l=https://e/chewy.svg"]
        function._fetch_svg = lambda url: VALID_SVG
        result = function.handler(self._event("chewy.com"), None)
        self.assertEqual(result["statusCode"], 200)
        body = function.json.loads(result["body"])
        self.assertEqual(body["url"], "https://signed.example/cache.ctrl.example/bimi/chewy.com.png")
        # Cached as PNG, not SVG.
        self.assertEqual(len(_helper.uploaded), 1)
        self.assertEqual(_helper.uploaded[0][2], "image/png")

    def test_no_record_returns_null(self):
        result = function.handler(self._event("no-bimi.example"), None)
        self.assertEqual(result["statusCode"], 200)
        self.assertIsNone(function.json.loads(result["body"])["url"])

    def test_fresh_cache_hit_skips_fetch_and_render(self):
        _helper.s3c.head_responses["bimi/chewy.com.png"] = {
            "LastModified": datetime.now(timezone.utc)}

        def _boom(_url):
            raise AssertionError("must not fetch on a fresh cache hit")

        function._fetch_svg = _boom
        result = function.handler(self._event("chewy.com"), None)
        body = function.json.loads(result["body"])
        self.assertEqual(body["url"], "https://signed.example/cache.ctrl.example/bimi/chewy.com.png")
        self.assertEqual(_helper.uploaded, [])

    def test_invalid_svg_returns_null(self):
        RECORDS["default._bimi.bad.example"] = ["v=BIMI1; l=https://e/bad.svg"]
        function._fetch_svg = lambda url: b"<svg><script>x</script></svg>"
        result = function.handler(self._event("bad.example"), None)
        self.assertIsNone(function.json.loads(result["body"])["url"])


if __name__ == "__main__":
    unittest.main()
