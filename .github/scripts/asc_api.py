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

import json
import os
import time
import urllib.parse
import urllib.request

import jwt  # PyJWT, installed in the calling step's venv

API_BASE = "https://api.appstoreconnect.apple.com"


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


def api_request(method, path, token_factory, body=None):
    """Call the ASC API and return the parsed JSON (or None for 204).

    `path` may be a full URL or a path relative to API_BASE. `token_factory`
    is called per request so each call carries a fresh JWT.
    """
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token_factory()}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


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
