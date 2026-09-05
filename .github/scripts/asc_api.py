#!/usr/bin/env python3
"""Shared App Store Connect API helpers for CI scripts.

Used by set-testflight-notes.py and assign-testflight-group.py, which run
from an ephemeral venv in apple.yml's upload jobs (PyJWT + cryptography are
installed at step time). Python resolves this module without any packaging
because it sits next to the entry-point scripts: sys.path[0] is the
directory of the script being run.

Auth model: App Store Connect rejects JWTs whose exp is more than 20
minutes out, and callers poll for longer than that, so every request mints
a fresh token via a caller-supplied `token_factory` (usually a closure
over `make_token`).
"""

import email.utils
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT, installed in the calling step's venv

API_BASE = "https://api.appstoreconnect.apple.com"

# App Store Connect returns a transient 5xx often enough that a single one
# has reddened an upload job whose binary was already on the store, leaving
# the build uploaded but unattached to its TestFlight group (#1407). A
# bounded retry covers that. Only calls a repeat cannot double are retried:
# GET and HEAD always, anything else on the caller's explicit say-so (see
# `idempotent` in api_request), so we never have to know whether a 5xx
# arrived before or after a mutation took effect.
RETRY_STATUSES = frozenset({429, 500, 502, 503, 504})
# A request that never reached a status code is transient on the same
# grounds (#1441): a connect timeout, a read timeout, a DNS failure or a
# reset connection all say nothing about whether the call would succeed a
# moment later. urllib raises these as URLError (whose subclass HTTPError
# must therefore be caught first) or, for a socket-level read timeout,
# as a bare TimeoutError. The `retryable` gate is the same one the status
# retry uses, so a mutation the caller has not vouched for still fails
# fast even though we cannot tell whether it reached the server.
RETRY_TRANSPORT_ERRORS = (urllib.error.URLError, TimeoutError, ConnectionError)
RETRY_ATTEMPTS = 4
RETRY_BACKOFF_SECONDS = 2.0
# Also the ceiling on a server-supplied Retry-After: ASC has no documented
# bound on that header, and these scripts run inside a poll deadline.
RETRY_BACKOFF_CAP_SECONDS = 30.0


def warn(message):
    """Emit a GitHub Actions warning annotation."""
    print(f"::warning::{message}")


def notice(message):
    """Emit a GitHub Actions notice annotation."""
    print(f"::notice::{message}")


def error(message):
    """Emit a GitHub Actions error annotation."""
    print(f"::error::{message}")


def require_env(name):
    """Return env var `name` or raise with a clear message."""
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"missing required environment variable {name}")
    return value


def make_token(key_id, issuer_id, private_key):
    """Mint a short-lived ES256 JWT for the App Store Connect API."""
    now = int(time.time())
    return jwt.encode(
        {
            "iss": issuer_id,
            "iat": now,
            "exp": now + 1200,  # 20 minutes, ASC's maximum.
            "aud": "appstoreconnect-v1",
        },
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def retry_after_seconds(headers):
    """Seconds requested by a Retry-After header, or None if absent/unusable.

    RFC 9110 allows either delta-seconds or an HTTP-date; a date already in
    the past reads as zero. Anything we cannot parse is treated as absent so
    the caller falls back to its own backoff.
    """
    value = (headers.get("Retry-After") or "").strip() if headers else ""
    if not value:
        return None
    try:
        return max(0.0, float(int(value)))
    except ValueError:
        pass
    try:
        when = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if when is None:
        return None
    return max(0.0, when.timestamp() - time.time())


def retry_delay(attempt, headers):
    """Seconds to wait after failed `attempt` (1-based), capped either way."""
    requested = retry_after_seconds(headers)
    if requested is not None:
        return min(requested, RETRY_BACKOFF_CAP_SECONDS)
    return min(
        RETRY_BACKOFF_SECONDS * (2 ** (attempt - 1)), RETRY_BACKOFF_CAP_SECONDS
    )


def api_request(method, path, token_factory, body=None, idempotent=False):
    """Call the ASC API and return the parsed JSON (or None for 204).

    `path` may be a full URL or a path relative to API_BASE. `token_factory`
    is called per request so each call carries a fresh JWT — including on a
    retry, whose backoff can otherwise outlive the 20-minute token.

    A transient refusal (RETRY_STATUSES) or a transport failure
    (RETRY_TRANSPORT_ERRORS — a connect or read timeout, a DNS failure, a
    reset connection) is retried up to RETRY_ATTEMPTS times with
    exponential backoff, honouring Retry-After when the server sends one.
    GET and HEAD are retried because they change nothing; any other method
    is retried only when the caller passes `idempotent=True` to say that
    re-sending it cannot double the effect. Everything else — 4xx other
    than 429, an unparseable body — raises as before.
    """
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    retryable = idempotent or method in ("GET", "HEAD")
    attempt = 0
    while True:
        attempt += 1
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Authorization", f"Bearer {token_factory()}")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as err:
            terminal = (
                not retryable
                or err.code not in RETRY_STATUSES
                or attempt >= RETRY_ATTEMPTS
            )
            if terminal:
                # Re-raise with the body unread: callers read err.read() for
                # the ASC error detail.
                raise
            delay = retry_delay(attempt, err.headers)
            warn(
                f"App Store Connect returned HTTP {err.code} for "
                f"{method} {path}; retrying in {delay:.0f}s "
                f"(attempt {attempt} of {RETRY_ATTEMPTS})."
            )
            time.sleep(delay)
        except RETRY_TRANSPORT_ERRORS as err:
            if not retryable or attempt >= RETRY_ATTEMPTS:
                raise
            # No response, so no Retry-After to honour.
            delay = retry_delay(attempt, None)
            warn(
                f"App Store Connect request {method} {path} failed to "
                f"complete ({err}); retrying in {delay:.0f}s "
                f"(attempt {attempt} of {RETRY_ATTEMPTS})."
            )
            time.sleep(delay)


def find_app_id(bundle_id, token_factory):
    """Return the ASC app id for `bundle_id`, or None if not found."""
    query = urllib.parse.urlencode({"filter[bundleId]": bundle_id, "limit": 1})
    result = api_request("GET", f"/v1/apps?{query}", token_factory)
    data = result.get("data") or []
    return data[0]["id"] if data else None


def find_build(app_id, build_number, token_factory):
    """Return the build resource for `app_id` + CFBundleVersion, or None."""
    query = urllib.parse.urlencode(
        {
            "filter[app]": app_id,
            "filter[version]": build_number,
            "limit": 1,
        }
    )
    result = api_request("GET", f"/v1/builds?{query}", token_factory)
    data = result.get("data") or []
    return data[0] if data else None
