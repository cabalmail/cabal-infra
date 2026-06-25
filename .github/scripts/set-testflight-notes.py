#!/usr/bin/env python3
#
# Set the TestFlight "What to Test" notes for a freshly-uploaded build.
#
# `altool --upload-app` (in apple.yml's upload-ios / upload-mac jobs) ships
# only the binary; it has no way to set beta release notes. This script runs
# right after that upload and writes the App Store Connect
# `betaBuildLocalizations.whatsNew` field - the text testers see as "What to
# Test" in the TestFlight app - using the App Store Connect API.
#
# Scope: prod releases only. apple.yml gates the calling step on
# `github.ref_name == 'main'`. The stage track is the developer's own and
# deliberately ships no notes.
#
# Source of the notes: the top `## [x.y.z]` section of CHANGELOG.md, flattened
# to plain text (TestFlight does not render Markdown) and truncated to App
# Store Connect's 4000-character cap for the field. A prod release cuts exactly
# one marketing version, so the whole section maps to that one TestFlight
# version; multiple builds under it would all carry the same notes.
#
# Best-effort by design: the binary is already uploaded by the time this runs,
# so any failure here (build still processing past the timeout, transient API
# error, missing config) emits a `::warning::` and exits 0 rather than turning
# a prod release red. The only thing lost on failure is the notes text, which
# can be set by hand in App Store Connect.
#
# Flow:
#   1. Mint an ES256 JWT from the .p8 key already installed at $ASC_KEY_PATH.
#      A fresh token is minted per request so polling can outlast the 20-minute
#      token lifetime ASC enforces.
#   2. Resolve the app record by bundle id.
#   3. Poll for the build (by app + CFBundleVersion) until it leaves the
#      PROCESSING state. A freshly-uploaded build may not appear for a minute,
#      so "not found yet" is treated as "keep polling".
#   4. Create or update the en-US betaBuildLocalizations record with the notes.
#
# Required env:
#   ASC_KEY_ID        App Store Connect API key id (the AuthKey_<id>.p8 id)
#   ASC_ISSUER_ID     App Store Connect API issuer id
#   ASC_KEY_PATH      Path to the decoded .p8 private key
#   BUNDLE_ID         App bundle id (e.g. com.cabalmail.Cabalmail)
#   MARKETING_VERSION CFBundleShortVersionString of the uploaded build
#   BUILD_NUMBER      CFBundleVersion of the uploaded build
#   CHANGELOG_PATH    Path to CHANGELOG.md
# Optional env:
#   ASC_LOCALE        Beta localization locale (default en-US)
#   ASC_POLL_TIMEOUT  Seconds to wait for processing (default 1200)
#   ASC_POLL_INTERVAL Seconds between polls (default 30)

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT, installed in the calling step's venv

API_BASE = "https://api.appstoreconnect.apple.com"
WHATS_NEW_MAX = 4000  # App Store Connect's hard cap on the field.


def warn(message):
    """Emit a GitHub Actions warning annotation."""
    print(f"::warning::{message}")


def notice(message):
    """Emit a GitHub Actions notice annotation."""
    print(f"::notice::{message}")


def require_env(name):
    """Return env var `name` or raise with a clear message."""
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"missing required environment variable {name}")
    return value


def make_token(key_id, issuer_id, private_key):
    """Mint a short-lived ES256 JWT for the App Store Connect API.

    A new token per request keeps polling correct: ASC rejects tokens whose
    exp is more than 20 minutes out, and processing can outlast that.
    """
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


def flatten_changelog(changelog_path):
    """Extract the top version section of CHANGELOG.md as TestFlight plain text.

    Takes everything from the first `## [x.y.z]` heading up to the next one,
    drops the version heading itself, turns `### Section` into `Section:`, and
    rejoins hard-wrapped bullets (two-space continuation indent) into single
    lines. Truncates to App Store Connect's field cap.
    """
    with open(changelog_path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    start = None
    for index, line in enumerate(lines):
        if re.match(r"^## \[\d+\.\d+\.\d+\]", line):
            start = index
            break
    if start is None:
        raise RuntimeError(f"no version section found in {changelog_path}")

    section = []
    for line in lines[start + 1:]:
        if re.match(r"^## \[\d+\.\d+\.\d+\]", line):
            break
        section.append(line)

    out = []
    current = None

    def flush():
        nonlocal current
        if current is not None:
            out.append(f"- {current}")
            current = None

    for line in section:
        if not line.strip():
            flush()
            continue
        heading = re.match(r"^### (.+)$", line)
        if heading:
            flush()
            if out and out[-1] != "":
                out.append("")
            out.append(f"{heading.group(1).strip()}:")
        elif line.startswith("- "):
            flush()
            current = line[2:].strip()
        elif line.startswith("  ") and current is not None:
            # Continuation of the current hard-wrapped bullet.
            current += " " + line.strip()
        else:
            flush()
            out.append(line.strip())
    flush()

    text = "\n".join(out).strip()
    if not text:
        raise RuntimeError("flattened changelog section is empty")
    if len(text) > WHATS_NEW_MAX:
        # Truncate on a line boundary where possible, leaving room for the marker.
        marker = "\n..."
        budget = WHATS_NEW_MAX - len(marker)
        clipped = text[:budget]
        if "\n" in clipped:
            clipped = clipped[:clipped.rfind("\n")]
        text = clipped + marker
        warn(f"Notes exceeded {WHATS_NEW_MAX} chars; truncated for App Store Connect.")
    return text


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


def wait_for_build(app_id, build_number, token_factory, timeout, interval):
    """Poll until the build leaves PROCESSING. Return its id, or None.

    Returns None (with a warning already emitted) on timeout or a terminal
    failure state, so the caller can give up gracefully.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        build = find_build(app_id, build_number, token_factory)
        if build is None:
            # Upload accepted but the build resource hasn't surfaced yet.
            time.sleep(interval)
            continue
        state = build.get("attributes", {}).get("processingState")
        if state == "VALID":
            return build["id"]
        if state in ("FAILED", "INVALID"):
            warn(f"Build {build_number} processing state is {state}; not setting notes.")
            return None
        time.sleep(interval)
    warn(
        f"Build {build_number} did not finish processing within {timeout}s; "
        "notes not set. Set them by hand in App Store Connect if needed."
    )
    return None


def set_notes(build_id, locale, notes, token_factory):
    """Create or update the betaBuildLocalizations whatsNew for the build."""
    query = urllib.parse.urlencode({"filter[locale]": locale, "limit": 1})
    existing = api_request(
        "GET",
        f"/v1/builds/{build_id}/betaBuildLocalizations?{query}",
        token_factory,
    )
    data = existing.get("data") or []
    if data:
        loc_id = data[0]["id"]
        api_request(
            "PATCH",
            f"/v1/betaBuildLocalizations/{loc_id}",
            token_factory,
            body={
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": loc_id,
                    "attributes": {"whatsNew": notes},
                }
            },
        )
        notice(f"Updated existing {locale} TestFlight notes.")
    else:
        api_request(
            "POST",
            "/v1/betaBuildLocalizations",
            token_factory,
            body={
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": locale, "whatsNew": notes},
                    "relationships": {
                        "build": {"data": {"type": "builds", "id": build_id}}
                    },
                }
            },
        )
        notice(f"Created {locale} TestFlight notes.")


def main():
    key_id = require_env("ASC_KEY_ID")
    issuer_id = require_env("ASC_ISSUER_ID")
    key_path = require_env("ASC_KEY_PATH")
    bundle_id = require_env("BUNDLE_ID")
    build_number = require_env("BUILD_NUMBER")
    changelog_path = require_env("CHANGELOG_PATH")
    require_env("MARKETING_VERSION")  # Logged for context; build lookup is by build number.

    locale = os.environ.get("ASC_LOCALE", "en-US").strip() or "en-US"
    timeout = int(os.environ.get("ASC_POLL_TIMEOUT", "1200"))
    interval = int(os.environ.get("ASC_POLL_INTERVAL", "30"))

    with open(key_path, encoding="utf-8") as handle:
        private_key = handle.read()

    def token_factory():
        return make_token(key_id, issuer_id, private_key)

    notes = flatten_changelog(changelog_path)
    print(f"TestFlight notes ({len(notes)} chars):\n{notes}\n")

    app_id = find_app_id(bundle_id, token_factory)
    if app_id is None:
        warn(f"No App Store Connect app found for bundle id {bundle_id}; notes not set.")
        return
    print(f"Resolved app {bundle_id} -> {app_id}")

    print(f"Waiting for build {build_number} to finish processing...")
    build_id = wait_for_build(app_id, build_number, token_factory, timeout, interval)
    if build_id is None:
        return

    set_notes(build_id, locale, notes, token_factory)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        # Surface the API response body; it usually pinpoints the problem.
        detail = ""
        try:
            detail = error.read().decode()
        except Exception:  # pylint: disable=broad-except
            pass
        warn(f"App Store Connect API error {error.code}: {detail or error.reason}. Notes not set.")
    except Exception as error:  # pylint: disable=broad-except
        warn(f"Could not set TestFlight notes: {error}")
    # Always exit 0: the binary is already uploaded and notes are best-effort.
    sys.exit(0)
