'''Resolve a sender domain's BIMI logo, rasterize it to a PNG, cache the
PNG in S3, and return a presigned URL (or {"url": null}).

The endpoint is a defensive proxy. It never hands the client a third-party
URL: it discovers the logo via DNS, fetches and validates the SVG itself,
rasterizes it to PNG with a bundled `resvg` binary, and serves a presigned
URL for the cached render. Rasterization is load-bearing - SwiftUI's
AsyncImage cannot decode SVG, so the Apple clients only ever see a PNG.

Any failure (no record, bad record, unreachable/oversized/invalid SVG,
render error) resolves to {"url": null}; the clients draw an initials
avatar in that case. The handler never raises.
'''
import json
import logging
import os
import subprocess
import tempfile
import time
import urllib.request
from datetime import datetime, timezone
from urllib.error import URLError
from xml.etree import ElementTree as ET

import dns.exception  # pylint: disable=import-error
import dns.resolver  # pylint: disable=import-error
from publicsuffixlist import PublicSuffixList  # pylint: disable=import-error
import helper  # pylint: disable=import-error

CONTROL_DOMAIN = os.environ.get("CONTROL_DOMAIN", "")
# Reuse the existing per-user message-cache bucket: the Lambda role already
# grants Get/PutObject on cache.<control_domain>/*, so no new bucket or IAM.
CACHE_BUCKET = f"cache.{CONTROL_DOMAIN}"
# The bundled static resvg binary ships at the zip root (/var/task/resvg).
RESVG_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resvg")

RENDER_PX = 96                       # display size at ~@3x; logos are square
CACHE_TTL_SECONDS = 24 * 3600        # re-render at most daily per domain
SVG_MAX_BYTES = 32 * 1024            # reject larger payloads, unread
HTTP_TIMEOUT_SECONDS = 5
RENDER_TIMEOUT_SECONDS = 10
DNS_TOTAL_BUDGET_SECONDS = 5.0       # wall-clock cap across both scope queries

# SVG elements never allowed in a BIMI logo (SVG Tiny PS element allowlist is
# stricter than this, but these are the ones that carry script/active or
# off-document content and therefore matter for safety). Compared on the XML
# local name, so namespace prefixes do not matter.
_FORBIDDEN_ELEMENTS = frozenset({"script", "foreignobject", "image", "use",
                                 "a", "animate", "set", "iframe"})
_HREF_ATTRS = ("href", "{http://www.w3.org/1999/xlink}href")

# Lazily built so importing the module (e.g. under test) costs nothing and
# does not require the bundled PSL snapshot to be present.
_PSL = None


def _resolver():
    '''A resolver bounded per the application-surface-hardening plan: lifetime
    caps total time across retries for a single query, timeout caps one query.'''
    resolver = dns.resolver.Resolver()
    resolver.lifetime = 5
    resolver.timeout = 2
    return resolver


def _candidate_domains(from_domain):
    '''The names to try `default._bimi.<name>` at, in order: the exact From
    domain first, then the PSL organizational domain. Real senders publish at
    the From subdomain (USPS Informed Delivery's logo is there, and
    default._bimi.usps.com is an unrelated SPF string), so the From domain
    must be tried first. The org domain is the one BIMI fallback; nothing
    above it is ever queried.'''
    global _PSL  # pylint: disable=global-statement
    if _PSL is None:
        _PSL = PublicSuffixList()
    candidates = [from_domain]
    org = _PSL.privatesuffix(from_domain)
    if org and org != from_domain:
        candidates.append(org)
    return candidates


def _txt_value(rdata):
    '''Reassemble a TXT rdata into one string. A long record is published as
    several <=255-byte chunks that concatenate with no separator.'''
    return b"".join(rdata.strings).decode("utf-8", "replace")


def _parse_bimi_logo_url(txt):
    '''Return the `l=` logo URL from a BIMI TXT record, or None when the record
    is not a usable BIMI record. Tolerant of tag order and unknown tags; never
    indexes a positional field, so a non-BIMI TXT (an SPF string) is just
    "not BIMI here", not a crash.'''
    tags = {}
    for part in txt.split(";"):
        key, sep, value = part.strip().partition("=")
        if sep:
            tags[key.strip().lower()] = value.strip()
    if tags.get("v", "").upper() != "BIMI1":
        return None
    logo = tags.get("l", "")
    # BIMI requires https for the logo; also blocks file:/data:/http SSRF-ish
    # schemes before we ever fetch.
    if not logo.lower().startswith("https://"):
        return None
    return logo


def _lookup_logo_url(resolver, candidates, deadline):
    '''Query default._bimi at each candidate scope until one yields a usable
    BIMI logo URL. Returns the URL or None. A non-BIMI TXT at a scope falls
    through to the next; a transient DNS error stops the walk (a slower NS will
    not get faster one suffix up) and resolves to None.'''
    for domain in candidates:
        if time.monotonic() >= deadline:
            break
        try:
            answer = resolver.resolve(f"default._bimi.{domain}", "TXT")
        except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer):
            continue
        except dns.exception.DNSException:
            break
        for rdata in answer:
            logo = _parse_bimi_logo_url(_txt_value(rdata))
            if logo:
                return logo
    return None


def _fetch_svg(url):
    '''Fetch the logo SVG with a hard timeout and a size cap, refusing
    redirects (a BIMI `l=` is a direct https asset; following 3xx to an
    arbitrary host would be an SSRF foothold). Returns bytes or None.'''
    opener = urllib.request.build_opener(_NoRedirect())
    request = urllib.request.Request(url, headers={"User-Agent": "cabalmail-bimi"})
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            # Read one byte past the cap so an exactly-cap payload is kept but
            # anything larger is rejected without buffering the whole body.
            data = response.read(SVG_MAX_BYTES + 1)
    except (URLError, OSError):
        return None
    if len(data) > SVG_MAX_BYTES:
        return None
    return data


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    '''Refuse all redirects; a 3xx becomes an HTTPError the caller treats as
    "no logo".'''

    def redirect_request(self, *args, **kwargs):  # pylint: disable=unused-argument
        return None


def _validate_svg(data):
    '''True only for a well-formed SVG with no script/active/off-document
    content. Rejects DOCTYPE/entities outright (no XXE or entity-expansion
    against the validator), requires an <svg> root, and forbids the active /
    external-reference element set.'''
    if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        return False
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return False
    if _local_name(root.tag) != "svg":
        return False
    for element in root.iter():
        if _local_name(element.tag) in _FORBIDDEN_ELEMENTS:
            return False
        for attr in _HREF_ATTRS:
            value = element.get(attr)
            # Only in-document references (#id) are allowed; anything with a
            # scheme or protocol-relative host is external.
            if value and not value.startswith("#"):
                return False
    return True


def _local_name(tag):
    '''Strip any `{namespace}` prefix ElementTree prepends, lowercased.'''
    if isinstance(tag, str) and "}" in tag:
        tag = tag.rsplit("}", 1)[1]
    return tag.lower() if isinstance(tag, str) else ""


def _rasterize(svg_bytes):
    '''Render the validated SVG to a square PNG with the bundled resvg binary.
    Runs in a /tmp workspace (/var/task is read-only). Returns PNG bytes or
    None on any render failure.'''
    with tempfile.TemporaryDirectory() as workdir:
        svg_path = os.path.join(workdir, "in.svg")
        png_path = os.path.join(workdir, "out.png")
        with open(svg_path, "wb") as handle:
            handle.write(svg_bytes)
        try:
            subprocess.run(
                [RESVG_BIN, "--width", str(RENDER_PX), "--height", str(RENDER_PX),
                 svg_path, png_path],
                check=True, capture_output=True, timeout=RENDER_TIMEOUT_SECONDS)
            with open(png_path, "rb") as handle:
                return handle.read()
        except (subprocess.SubprocessError, OSError) as err:
            logging.error("resvg render failed: %s", err)
            return None


def _cache_key(domain):
    return f"bimi/{domain}.png"


def _fresh_cached_url(key):
    '''Presigned URL for the cached PNG if it exists and is younger than the
    TTL, else None (miss or stale -> re-render).'''
    try:
        head = helper.s3c.head_object(Bucket=CACHE_BUCKET, Key=key)
    except Exception:  # pylint: disable=broad-exception-caught
        return None
    age = (datetime.now(timezone.utc) - head["LastModified"]).total_seconds()
    if age > CACHE_TTL_SECONDS:
        return None
    return helper.sign_url(CACHE_BUCKET, key)


def _resolve_png_url(sender_domain):
    '''Full pipeline: serve a fresh cache hit, else discover -> fetch ->
    validate -> rasterize -> cache -> presign. Returns a URL or None. Keyed by
    the queried sender domain (matches the gateway cache key).'''
    key = _cache_key(sender_domain)
    cached = _fresh_cached_url(key)
    if cached:
        return cached

    resolver = _resolver()
    deadline = time.monotonic() + DNS_TOTAL_BUDGET_SECONDS
    logo_url = _lookup_logo_url(resolver, _candidate_domains(sender_domain), deadline)
    if not logo_url:
        return None

    svg = _fetch_svg(logo_url)
    if not svg or not _validate_svg(svg):
        return None

    png = _rasterize(svg)
    if not png:
        return None

    helper.upload_object(CACHE_BUCKET, key, "image/png", png)
    return helper.sign_url(CACHE_BUCKET, key)


def _response(status, body):
    return {"statusCode": status, "body": json.dumps(body)}


def handler(event, _context):
    '''API entry point. Returns {"url": <presigned png url>} or {"url": null}.'''
    query_string = event.get("queryStringParameters") or {}
    try:
        sender_domain = helper.validate_dns_apex(query_string.get("sender_domain"))
    except ValueError as err:
        return _response(400, {"status": f"Invalid input: {err}"})

    try:
        url = _resolve_png_url(sender_domain)
    except Exception as err:  # pylint: disable=broad-exception-caught
        # Defensive: a BIMI lookup must never 5xx. Degrade to the no-logo
        # signal and let the client draw its initials avatar.
        logging.error("fetch_bimi unexpected error for %s: %s", sender_domain, err)
        url = None
    return _response(200, {"url": url})
