#!/usr/bin/env python3
"""Generate a standalone HTML dashboard tracking Cabalmail's Apple releases.

It joins two data sources into one self-contained HTML file:

  * The repo  - CHANGELOG.md released sections, the pending changelog.d/
    fragments, and git tag/fragment dates. This is where *features* live
    (every `- Apple:` bullet) and which marketing version they shipped in.
  * App Store Connect - per app (iOS `com.cabalmail.Cabalmail` and macOS
    `com.cabalmail.CabalmailMac`): every build, its marketing version
    (CFBundleShortVersionString) and build number (CFBundleVersion, a Unix
    timestamp per apple.yml), its processing/beta state, and which
    TestFlight groups (`stage`, `prod`, external `beta`) it is attached to.

The result answers "what feature is available in which build, at which
stage, and what is Apple's status?" - a Feature matrix (feature -> stage)
and a Build ledger (build -> features), with marketing<->build version
dereferencing throughout.

Because it queries App Store Connect, run it locally where your ASC key
lives (the same key the CI upload jobs use), not from a sandbox that can't
reach api.appstoreconnect.apple.com:

    pip install pyjwt cryptography            # once
    export ASC_KEY_ID=XXXXXXXXXX
    export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    export ASC_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8
    python3 scripts/apple-release-dashboard.py \
        --out apple-dashboard.html && open apple-dashboard.html
    # --repo defaults to the checkout containing the script

`--mock <file.json>` renders from a captured/synthetic ASC payload instead
of calling the API - useful for previewing the layout or running offline.
`--dump-asc <file.json>` writes the raw normalized ASC payload alongside the
HTML (handy for sharing a snapshot or debugging).
"""

import argparse
import concurrent.futures
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

API_BASE = "https://api.appstoreconnect.apple.com"

# The two shipped Apple apps. Watch/notification-service targets share the
# iOS app record, so they are not separate dashboard columns.
APPS = [
    {"key": "ios", "label": "iOS", "bundle_id": "com.cabalmail.Cabalmail"},
    {"key": "mac", "label": "macOS", "bundle_id": "com.cabalmail.CabalmailMac"},
]

# Ordered deployment lanes. `stage` and `prod` are internal TestFlight
# groups written by assign-testflight-group.py (stage branch -> stage,
# main -> prod). `beta` is any *external* group (currently iOS only).
LANES = ["stage", "prod", "beta"]
LANE_LABEL = {"stage": "Stage", "prod": "Prod", "beta": "Beta"}

# App Store Connect beta-state enum -> (human label, status role). The role
# drives the pill color; the label is always shown, so color never carries
# meaning alone. Roles: good / warning / critical / neutral / muted.
BETA_STATE = {
    "PROCESSING": ("Processing", "neutral"),
    "PROCESSING_EXCEPTION": ("Processing failed", "critical"),
    "MISSING_EXPORT_COMPLIANCE": ("Missing export compliance", "warning"),
    "READY_FOR_BETA_TESTING": ("Ready to Test", "good"),
    "IN_BETA_TESTING": ("Testing", "good"),
    "EXPIRED": ("Expired", "muted"),
    "IN_EXPORT_COMPLIANCE_REVIEW": ("Export compliance review", "warning"),
    "READY_FOR_BETA_SUBMISSION": ("Ready to Submit", "warning"),
    "WAITING_FOR_BETA_REVIEW": ("Waiting for Review", "warning"),
    "IN_BETA_REVIEW": ("In Review", "warning"),
    "BETA_REJECTED": ("Rejected", "critical"),
}
PROCESSING_STATE = {
    "PROCESSING": ("Processing", "neutral"),
    "VALID": ("Valid", "good"),
    "FAILED": ("Failed", "critical"),
    "INVALID": ("Invalid", "critical"),
}


# --------------------------------------------------------------------------
# Repo side: CHANGELOG.md, changelog.d/ fragments, git dates.
# --------------------------------------------------------------------------

VERSION_RE = re.compile(r"^## \[(\d+\.\d+\.\d+)\](?:\s*-\s*(\S+))?")
SECTION_RE = re.compile(r"^### (.+?):?\s*$")
APPLE_RE = re.compile(r"^Apple:\s*")
BOLD_RE = re.compile(r"\*\*(.+?)\*\*")


def _clean(text):
    """Collapse a hard-wrapped bullet body to one line."""
    return re.sub(r"\s+", " ", text).strip()


def _split_summary(text):
    """Return (summary, detail): the leading **bold** phrase and the rest."""
    m = BOLD_RE.search(text)
    if m and m.start() <= 2:
        summary = m.group(1).rstrip(".")
        detail = text[m.end():].strip()
        return summary, detail
    # No bold lead: use the first sentence as the summary.
    parts = re.split(r"(?<=\.)\s", text, maxsplit=1)
    return parts[0].rstrip("."), (parts[1] if len(parts) > 1 else "")


def parse_changelog(path):
    """Parse a CHANGELOG.md file into ordered version records (newest first)."""
    with open(path, encoding="utf-8") as fh:
        return parse_changelog_text(fh.read())


def parse_changelog_text(text):
    """Parse CHANGELOG.md content into ordered version records (newest first)."""
    lines = text.splitlines()

    versions = []
    cur = None
    section = None
    bullet = None

    def flush_bullet():
        nonlocal bullet
        if bullet is not None and cur is not None:
            raw = _clean(bullet)
            is_apple = bool(APPLE_RE.match(raw))
            body = APPLE_RE.sub("", raw, count=1) if is_apple else raw
            summary, detail = _split_summary(body)
            cur["entries"].append(
                {
                    "category": section or "",
                    "apple": is_apple,
                    "summary": summary,
                    "detail": detail,
                    "text": body,
                }
            )
        bullet = None

    for line in lines:
        vm = VERSION_RE.match(line)
        if vm:
            flush_bullet()
            cur = {
                "version": vm.group(1),
                "date": vm.group(2) or "",
                "entries": [],
            }
            versions.append(cur)
            section = None
            continue
        if cur is None:
            continue
        sm = SECTION_RE.match(line)
        if sm:
            flush_bullet()
            section = sm.group(1).strip()
            continue
        if line.startswith("- "):
            flush_bullet()
            bullet = line[2:]
        elif line.startswith("  ") and bullet is not None:
            bullet += " " + line.strip()
        elif not line.strip():
            flush_bullet()
    flush_bullet()

    for v in versions:
        v["apple_entries"] = [e for e in v["entries"] if e["apple"]]
    return versions


def read_fragments(changelog_dir):
    """Read pending changelog.d/ fragments from the working tree."""
    if not os.path.isdir(changelog_dir):
        return []
    items = []
    for name in sorted(os.listdir(changelog_dir)):
        if not name.endswith(".md") or name == "README.md":
            continue
        with open(os.path.join(changelog_dir, name), encoding="utf-8") as fh:
            items.append((name, fh.read()))
    return read_fragments_items(items)


def read_fragments_items(items):
    """Build fragment records from (filename, body) pairs (FS or a git ref)."""
    frags = []
    for name, body in sorted(items):
        if not name.endswith(".md") or name == "README.md":
            continue
        stem = name[:-3]
        slug, _, category = stem.rpartition(".")
        body = re.sub(r"^-\s*", "", body.strip())
        raw = _clean(body)
        is_apple = bool(APPLE_RE.match(raw))
        text = APPLE_RE.sub("", raw, count=1) if is_apple else raw
        summary, detail = _split_summary(text)
        frags.append(
            {
                "file": name,
                "slug": slug or stem,
                "category": category,
                "apple": is_apple,
                "summary": summary,
                "detail": detail,
                "text": text,
            }
        )
    return frags


def _git(repo_root, args):
    return subprocess.run(["git", "-C", repo_root, *args], capture_output=True, text=True, check=False)


_FETCH_STATE = {"t": 0.0}


def git_fetch(repo_root, min_interval=15):
    """Best-effort, throttled `git fetch origin`. Returns True if it just ran."""
    now = time.time()
    if now - _FETCH_STATE["t"] < min_interval:
        return False
    _FETCH_STATE["t"] = now
    _git(repo_root, ["fetch", "--quiet", "origin"])
    return True


def ref_exists(repo_root, ref):
    return _git(repo_root, ["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"]).returncode == 0


def git_show(repo_root, ref, path):
    r = _git(repo_root, ["show", f"{ref}:{path}"])
    return r.stdout if r.returncode == 0 else None


def read_ref_source(repo_root, ref):
    """Return (changelog_text, [(fragment_name, body), ...]) from a git ref, or None."""
    text = git_show(repo_root, ref, "CHANGELOG.md")
    if text is None:
        return None
    listing = _git(repo_root, ["ls-tree", "--name-only", ref, "changelog.d/"])
    items = []
    for path in listing.stdout.splitlines():
        path = path.strip()
        name = os.path.basename(path)
        if not name.endswith(".md") or name == "README.md":
            continue
        body = git_show(repo_root, ref, path)
        if body is not None:
            items.append((name, body))
    return text, items


# A fragment's authored date is the commit that added it, which never changes
# once it exists - so memoize across the many /api/data refreshes a running
# server serves (same rationale as _LANDING_CACHE below). Keyed by file name;
# only found dates are cached, so a fragment queried before it lands is
# retried on the next refresh.
_FRAG_DATE_CACHE = {}


def git_dates(repo_root, fragments, ref=None):
    """Best-effort git facts.

    Returns (frag_dates, tag_dates):
      frag_dates[file] = date (YYYY-MM-DD) the fragment was authored
      tag_dates[tag]   = date of each version tag
    """
    frag_dates = {}
    tag_dates = {}

    def run(args):
        return subprocess.run(
            ["git", "-C", repo_root, *args],
            capture_output=True, text=True, check=False,
        ).stdout.strip()

    if not os.path.isdir(os.path.join(repo_root, ".git")):
        return frag_dates, tag_dates

    refarg = [ref] if ref else []
    for frag in fragments:
        key = (os.path.abspath(repo_root), ref or "", frag["file"])
        if key in _FRAG_DATE_CACHE:
            frag_dates[frag["file"]] = _FRAG_DATE_CACHE[key]
            continue
        path = f"changelog.d/{frag['file']}"
        out = run(["log", *refarg, "--diff-filter=A", "--follow", "--format=%cs", "-1", "--", path])
        if out:
            frag_dates[frag["file"]] = _FRAG_DATE_CACHE[key] = out.splitlines()[0]

    out = run(["for-each-ref", "--format=%(refname:short)\t%(creatordate:short)", "refs/tags"])
    for row in out.splitlines():
        if "\t" in row:
            tag, date = row.split("\t", 1)
            tag_dates[tag.strip()] = date.strip()
    return frag_dates, tag_dates


# --------------------------------------------------------------------------
# App Store Connect side.
# --------------------------------------------------------------------------

def make_token(key_id, issuer_id, private_key):
    import jwt  # PyJWT
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api_get(path, token_factory):
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token_factory()}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else {}


def api_get_all(path, token_factory, max_pages=20):
    """GET with pagination; concatenates `data` and merges `included`."""
    data, included = [], []
    page, url = 0, path
    while url and page < max_pages:
        payload = api_get(url, token_factory)
        data.extend(payload.get("data") or [])
        included.extend(payload.get("included") or [])
        url = (payload.get("links") or {}).get("next")
        page += 1
    return data, included


def _parse_iso(ts):
    """Parse an ASC ISO-8601 timestamp; None on failure. (Python < 3.11
    fromisoformat rejects a trailing Z, which ASC sometimes uses.)"""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Build-ledger cache. Most of the ledger is immutable history: an expired
# build never changes again, and a live build's states and group membership
# only churn in the weeks right after upload (processing, review, CI/manual
# group attachment). So keep every normalized build ever seen (in memory and
# on disk), refetch only pages young enough to still change, and serve the
# rest from cache. Expiry for cached builds is derived locally from
# expirationDate rather than refetched.
#
# Known staleness (accepted): a build older than VOLATILE_DAYS that is
# manually expired early, or mutated outside this app (e.g. a group attach
# in App Store Connect's UI), keeps its cached state until its natural
# expirationDate passes. Attaches made through this dashboard's own
# /api/assign are covered - it calls invalidate_build().
# --------------------------------------------------------------------------

# 14 days keeps each app's refetch inside one 200-build page at the current
# upload rate (~8/day iOS). States settle much faster than this in practice:
# processing takes minutes-hours, CI attaches groups right after processing,
# and external beta review returns within a few days of submission.
VOLATILE_DAYS = 14
# Schema 2: discards caches written while the builds-page include still fed
# groups/states - an ASC outage poisoned those with blank values.
CACHE_SCHEMA = 2
CACHE_ENABLED = True   # False = always refetch the full history
CACHE_DIR = None       # set by main() / the server app; None disables the disk cache

_LEDGER_MEM = {}   # bundle_id -> {build_id: normalized build dict}


def _cache_path(bundle_id):
    return os.path.join(CACHE_DIR, f"builds-{bundle_id}.json") if CACHE_DIR else None


def load_ledger_cache(bundle_id):
    """Previously seen builds for one app: memory first, then disk."""
    if not CACHE_ENABLED:
        return {}
    if bundle_id in _LEDGER_MEM:
        return _LEDGER_MEM[bundle_id]
    path = _cache_path(bundle_id)
    if path and os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                blob = json.load(fh)
            if blob.get("schema") == CACHE_SCHEMA:
                _LEDGER_MEM[bundle_id] = blob.get("builds") or {}
                return _LEDGER_MEM[bundle_id]
        except (OSError, ValueError):
            pass
    return {}


def save_ledger_cache(bundle_id, builds_by_id):
    if not CACHE_ENABLED:
        return
    _LEDGER_MEM[bundle_id] = builds_by_id
    path = _cache_path(bundle_id)
    if not path:
        return
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"schema": CACHE_SCHEMA, "builds": builds_by_id}, fh)
        os.replace(tmp, path)
    except OSError as err:
        sys.stderr.write(f"  ledger cache not saved ({err}); refreshes still work\n")


def invalidate_build(build_id):
    """Mark one build dirty in every app's cache so the next refresh pages far
    enough back to refetch it. Marking (not deleting) keeps the cached copy as
    a fallback and tells the pager how deep it must go."""
    for bundle_id, builds in _LEDGER_MEM.items():
        if build_id in builds:
            builds[build_id]["_dirty"] = True
            save_ledger_cache(bundle_id, builds)


# bundle_id -> ASC app record id. App ids are immutable, so resolving one is
# a once-per-process lookup, not a per-refresh round trip.
_APP_ID_CACHE = {}


def resolve_app_id(bundle_id, token_factory):
    """Resolve a bundle id to its ASC app id (cached; None if not found)."""
    if bundle_id in _APP_ID_CACHE:
        return _APP_ID_CACHE[bundle_id]
    # ASC prefix-matches filter[bundleId], so `com.cabalmail.Cabalmail` also
    # returns `com.cabalmail.CabalmailMac`. Match the bundle id exactly.
    q = urllib.parse.urlencode({"filter[bundleId]": bundle_id, "limit": 200})
    apps = api_get(f"/v1/apps?{q}", token_factory).get("data") or []
    match = next(
        (a for a in apps if a.get("attributes", {}).get("bundleId") == bundle_id),
        None,
    )
    if match is None:
        return None
    _APP_ID_CACHE[bundle_id] = match["id"]
    return match["id"]


def _fetch_build_pages(app_id, cached, token_factory, max_pages=40):
    """Fetch build pages newest-first, stopping once further pages can only
    repeat settled history: every build on the current page is already cached
    and the page reaches back past the volatile window. With an empty cache
    this walks the full history (the seed fetch)."""
    # JSON:API sparse fieldsets: fields[builds] must list the RELATIONSHIP names
    # too, or ASC omits the relationship linkage from each build (the `included`
    # array comes back, but nothing ties a build to its version / beta detail /
    # groups). Listing only attributes was the bug behind blank columns.
    #
    # buildBetaDetail and betaGroups are deliberately NOT included: the
    # builds-page include mechanism proved unreliable for both (the beta
    # detail linkage was omitted for ~75% of builds on every refresh, and
    # the betaGroups linkage came back empty for every build in some
    # sessions). States come from the batched /v1/buildBetaDetails query;
    # group membership comes from each group's own builds relationship
    # (fetch_group_membership). The page response is much smaller for it.
    url = (
        f"/v1/builds?filter[app]={app_id}"
        "&sort=-uploadedDate&limit=200"
        "&include=preReleaseVersion"
        "&fields[builds]=version,uploadedDate,processingState,expired,expirationDate,"
        "preReleaseVersion"
        "&fields[preReleaseVersions]=version,platform"
    )
    cutoff = datetime.now(timezone.utc) - timedelta(days=VOLATILE_DAYS)
    dirty = {bid for bid, b in cached.items() if b.get("_dirty")}
    data, included, pages = [], [], 0
    while url and pages < max_pages:
        payload = api_get(url, token_factory)
        page_data = payload.get("data") or []
        data.extend(page_data)
        included.extend(payload.get("included") or [])
        url = (payload.get("links") or {}).get("next")
        pages += 1
        dirty -= {b["id"] for b in page_data}
        if cached and page_data and not dirty:
            # Pages are newest-first, so the page's last build is its oldest.
            oldest = _parse_iso(page_data[-1].get("attributes", {}).get("uploadedDate", ""))
            if (oldest and oldest < cutoff
                    and all(b["id"] in cached for b in page_data)):
                url = None
    if url:
        sys.stderr.write(
            f"  builds fetch hit the {max_pages}-page cap; history beyond it is "
            "missing from this refresh (served from cache once seeded)\n"
        )
    return data, included, pages


def _normalize_build(b, inc, groups):
    """Flatten one JSON:API build resource into the dashboard's build dict."""
    attrs = b.get("attributes", {})
    rels = b.get("relationships", {})

    prv = (rels.get("preReleaseVersion") or {}).get("data")
    marketing = ""
    platform = ""
    if prv:
        pr = inc.get(("preReleaseVersions", prv["id"]))
        if pr:
            marketing = pr["attributes"].get("version", "")
            platform = pr["attributes"].get("platform", "")

    # A buildBetaDetail shares its build's id, so fall back to the build id
    # if the relationship linkage is absent for any reason.
    bbd = (rels.get("buildBetaDetail") or {}).get("data")
    det = inc.get(("buildBetaDetails", bbd["id"] if bbd else b["id"]))
    internal_state = external_state = ""
    if det:
        internal_state = det["attributes"].get("internalBuildState", "") or ""
        external_state = det["attributes"].get("externalBuildState", "") or ""

    group_ids = [g["id"] for g in (rels.get("betaGroups") or {}).get("data") or []]
    group_names = [groups.get(gid, {}).get("name", "") for gid in group_ids]
    lanes = classify_lanes(group_ids, groups)

    return {
        "id": b["id"],
        "build_number": attrs.get("version", ""),
        "uploaded": attrs.get("uploadedDate", ""),
        "processing_state": attrs.get("processingState", ""),
        "expired": bool(attrs.get("expired")),
        "expiration": attrs.get("expirationDate", ""),
        "beta_detail_missing": False,
        "marketing_version": marketing,
        "platform": platform,
        "internal_state": internal_state,
        "external_state": external_state,
        "groups": [g for g in group_names if g],
        "lanes": lanes,
    }


def fetch_app(app, token_factory):
    """Return a normalized dict of builds + groups for one app record."""
    bundle_id = app["bundle_id"]
    app_id = resolve_app_id(bundle_id, token_factory)
    if app_id is None:
        return {"found": False, "groups": [], "builds": []}

    def get_groups_and_membership():
        data, _ = api_get_all(
            f"/v1/apps/{app_id}/betaGroups?limit=200"
            "&fields[betaGroups]=name,isInternalGroup",
            token_factory,
        )
        membership = fetch_group_membership([g["id"] for g in data], token_factory)
        return data, membership

    cached = load_ledger_cache(bundle_id)

    # The groups/membership chain and the builds pages are independent;
    # overlap them.
    t0 = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        groups_future = pool.submit(get_groups_and_membership)
        builds_data, included, pages = _fetch_build_pages(app_id, cached, token_factory)
        pages_secs = time.monotonic() - t0
        groups_data, membership = groups_future.result()

    groups = {
        g["id"]: {
            "id": g["id"],
            "name": g["attributes"].get("name", ""),
            "internal": bool(g["attributes"].get("isInternalGroup")),
        }
        for g in groups_data
    }

    inc = {(r["type"], r["id"]): r for r in included}
    fetched = {b["id"]: _normalize_build(b, inc, groups) for b in builds_data}

    # Merge with settled history; refetched builds win. A cached build outside
    # the refetch window can only change by expiring, which is derivable
    # locally from its expirationDate.
    now = datetime.now(timezone.utc)
    merged = dict(cached)
    merged.update(fetched)
    for bid, b in merged.items():
        if bid not in fetched and not b["expired"]:
            exp = _parse_iso(b.get("expiration", ""))
            if exp and exp < now:
                b["expired"] = True
    # Group membership is authoritative per refresh and covers the whole
    # ledger, cached builds included - it both heals any stale cached groups
    # and picks up out-of-band attaches on builds outside the refetch window.
    # If the membership query failed, refetched builds inherit their cached
    # groups instead: the builds page itself carries no group linkage.
    if membership is not None:
        for bid, b in merged.items():
            gids = membership.get(bid, [])
            names = [groups[g]["name"] for g in gids if g in groups]
            b["groups"] = [n for n in names if n]
            b["lanes"] = classify_lanes(gids, groups)
    else:
        for bid in fetched:
            prev = cached.get(bid)
            if prev:
                merged[bid]["groups"] = prev.get("groups", [])
                merged[bid]["lanes"] = prev.get("lanes", [])
    builds = sorted(merged.values(), key=lambda b: b["uploaded"] or "", reverse=True)
    sys.stderr.write(
        f"  {app['label']}: {len(fetched)} builds fetched ({pages} page"
        f"{'s' if pages != 1 else ''}, {pages_secs:.1f}s), "
        f"{len(merged) - len(fetched)} from cache, "
        + (f"membership for {len(membership)} builds"
           if membership is not None else "membership unavailable")
        + "\n"
    )

    # Beta states come from /v1/buildBetaDetails (batched, parallel chunks;
    # see the include note in _fetch_build_pages). The recovery set spans
    # the WHOLE ledger, cached builds included, so a cached build whose
    # states were lost to an ASC flake is re-queried every refresh until it
    # heals. Per build:
    #   - answered by the query: authoritative, use it;
    #   - in a failed/empty chunk: no information - carry the cached states
    #     if there are any, else leave blank and unflagged (the status
    #     falls back to the processing state);
    #   - absent from an authoritative answer: genuinely in the ripening
    #     gap between processingState=VALID and Ready to Test, which the
    #     status functions surface as "Not yet testable".
    missing = [b for b in builds if not b["internal_state"] and not b["expired"]]
    if missing:
        t1 = time.monotonic()
        details, failed = fetch_beta_details_by_build(
            [b["id"] for b in missing], token_factory
        )
        recovered = carried = unknown = 0
        for b in missing:
            prev = cached.get(b["id"])
            if b["id"] in details:
                b["internal_state"], b["external_state"] = details[b["id"]]
                b["beta_detail_missing"] = False
                recovered += 1
            elif b["id"] in failed:
                if prev and prev.get("internal_state"):
                    b["internal_state"] = prev["internal_state"]
                    b["external_state"] = prev.get("external_state", "")
                    carried += 1
                else:
                    unknown += 1
            else:
                b["beta_detail_missing"] = True
        absent = len(missing) - recovered - carried - unknown
        sys.stderr.write(
            f"  {app['label']} beta details ({time.monotonic() - t1:.1f}s): "
            f"{recovered} by direct query, {carried} carried from cache, "
            f"{absent} not yet surfaced"
            + (f", {unknown} unknown (query failed)" if unknown else "")
            + "\n"
        )
    save_ledger_cache(bundle_id, merged)
    return {"found": True, "app_id": app_id, "groups": list(groups.values()), "builds": builds}


def fetch_beta_details_by_build(build_ids, token_factory, chunk=50):
    """Fetch buildBetaDetails directly, batched via filter[build].

    Returns (details, failed_ids). details maps build_id ->
    (internal_state, external_state) from chunks that answered
    authoritatively; a build absent from those chunks genuinely has no
    beta detail resource yet. failed_ids holds the builds whose chunk
    errored twice or came back entirely empty - ASC intermittently
    answers these queries with an empty 200 - and means NO INFORMATION,
    not absence. A buildBetaDetail shares its build's id, so details
    keys straight off det["id"].
    """
    def one(ids):
        q = (
            f"/v1/buildBetaDetails?filter[build]={','.join(ids)}"
            "&fields[buildBetaDetails]=internalBuildState,externalBuildState"
            "&limit=200"
        )
        for attempt in (0, 1):
            try:
                data, _ = api_get_all(q, token_factory)
            except (urllib.error.HTTPError, urllib.error.URLError) as err:
                data = None
                reason = err
            else:
                # A whole chunk with zero details is indistinguishable from
                # the known ASC flake; treat it like a failure.
                if data or not ids:
                    return data
                reason = "empty response"
            if attempt == 0:
                time.sleep(1)
        sys.stderr.write(
            f"  buildBetaDetails chunk of {len(ids)} failed twice ({reason}); "
            "treating those statuses as unknown\n"
        )
        return None

    chunks = [build_ids[i:i + chunk] for i in range(0, len(build_ids), chunk)]
    details, failed = {}, set()
    if not chunks:
        return details, failed
    # The chunks are independent; run them concurrently.
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(chunks))) as pool:
        for ids, data in zip(chunks, pool.map(one, chunks)):
            if data is None:
                failed.update(ids)
                continue
            for det in data:
                attrs = det.get("attributes", {})
                details[det["id"]] = (
                    attrs.get("internalBuildState", "") or "",
                    attrs.get("externalBuildState", "") or "",
                )
    return details, failed


def fetch_group_membership(group_ids, token_factory):
    """Map build_id -> [group_id] via each group's ids-only builds relationship.

    Queried from the group side because the builds-page include=betaGroups
    linkage proved unreliable (empty for every build in some sessions). This
    also covers builds outside the refetch window, so attaches and detaches
    on old builds show up on the next refresh regardless of the cache.
    Returns None if any group query fails, so the caller keeps existing
    groups rather than wiping them."""
    if not group_ids:
        return {}

    def one(gid):
        for attempt in (0, 1):
            try:
                data, _ = api_get_all(
                    f"/v1/betaGroups/{gid}/relationships/builds?limit=200",
                    token_factory,
                )
                return [b["id"] for b in data]
            except (urllib.error.HTTPError, urllib.error.URLError):
                if attempt == 0:
                    time.sleep(1)
                else:
                    raise
        return []

    try:
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(2, len(group_ids))
        ) as pool:
            results = list(pool.map(one, group_ids))
    except (urllib.error.HTTPError, urllib.error.URLError) as err:
        code = getattr(err, "code", None) or getattr(err, "reason", err)
        sys.stderr.write(
            f"  group membership query failed twice ({code}); "
            "keeping previously known groups\n"
        )
        return None
    out = {}
    for gid, ids in zip(group_ids, results):
        for bid in ids:
            out.setdefault(bid, []).append(gid)
    if not out:
        # Every group answering empty is indistinguishable from the ASC
        # flake (CI attaches each upload to a group, so a truly empty
        # membership across all groups is implausible). No information.
        sys.stderr.write(
            "  group membership came back empty for every group; "
            "keeping previously known groups\n"
        )
        return None
    return out


def classify_lanes(group_ids, groups):
    """Map a build's groups to lane keys (stage/prod/beta)."""
    lanes = set()
    for gid in group_ids:
        g = groups.get(gid)
        if not g:
            continue
        name = g["name"].strip().lower()
        if name == "stage":
            lanes.add("stage")
        elif name == "prod":
            lanes.add("prod")
        elif not g["internal"]:
            lanes.add("beta")
    return sorted(lanes, key=LANES.index)


def fetch_asc():
    key_id = os.environ.get("ASC_KEY_ID", "").strip()
    issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
    key_path = os.environ.get("ASC_KEY_PATH", "").strip()
    missing = [n for n, v in (
        ("ASC_KEY_ID", key_id), ("ASC_ISSUER_ID", issuer_id), ("ASC_KEY_PATH", key_path)
    ) if not v]
    if missing:
        sys.exit(
            "Missing App Store Connect credentials: " + ", ".join(missing) +
            ".\nSet them in the environment (see the header of this file) or pass "
            "--mock <file.json> to render without calling the API."
        )
    with open(os.path.expanduser(key_path), encoding="utf-8") as fh:
        private_key = fh.read()

    def token_factory():
        return make_token(key_id, issuer_id, private_key)

    labels = ", ".join(f"{a['label']} ({a['bundle_id']})" for a in APPS)
    sys.stderr.write(f"Querying App Store Connect for {labels}...\n")
    # The apps are independent; fetch them concurrently.
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(APPS)) as pool:
        futures = {app["key"]: pool.submit(fetch_app, app, token_factory) for app in APPS}
        return {key: f.result() for key, f in futures.items()}


def make_token_factory():
    """Return a token_factory from env creds, or None if any are missing."""
    key_id = os.environ.get("ASC_KEY_ID", "").strip()
    issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
    key_path = os.environ.get("ASC_KEY_PATH", "").strip()
    if not (key_id and issuer_id and key_path):
        return None
    with open(os.path.expanduser(key_path), encoding="utf-8") as fh:
        private_key = fh.read()
    return lambda: make_token(key_id, issuer_id, private_key)


def asc_request(method, path, token_factory, body=None):
    """Call the App Store Connect API and return parsed JSON (or None for 204).

    Raises urllib.error.HTTPError on non-2xx so callers can surface the body.
    """
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token_factory()}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def assign_build_to_group(build_id, group_id, token_factory):
    """Attach a build to a beta (test) group - the build -> betaGroups direction,
    the same call apple.yml's assign-testflight-group.py uses. Idempotent: adding
    a build already in the group is a no-op success."""
    asc_request(
        "POST",
        f"/v1/builds/{build_id}/relationships/betaGroups",
        token_factory,
        body={"data": [{"type": "betaGroups", "id": group_id}]},
    )


# --------------------------------------------------------------------------
# Join repo features with ASC builds.
# --------------------------------------------------------------------------

def build_number_date(build_number):
    """apple.yml sets CFBundleVersion = `date -u +%s`; dereference to a date."""
    try:
        ts = int(build_number)
    except (TypeError, ValueError):
        return ""
    if ts < 1_000_000_000 or ts > 4_000_000_000:
        return ""
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


PLATFORM_LABEL = {"IOS": "iOS", "MAC_OS": "macOS", "VISION_OS": "visionOS", "TV_OS": "tvOS"}


def pretty_platform(platform):
    return PLATFORM_LABEL.get(platform, platform or "")


# External beta states that actually mean something for the Beta lane. Any other
# externalBuildState (e.g. READY_FOR_BETA_SUBMISSION, the default for a build
# never submitted to external review) is noise and must not override the
# internal "Testing" signal.
MEANINGFUL_EXTERNAL = {
    "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_REJECTED", "IN_BETA_TESTING",
}


def _proc_status(build):
    return PROCESSING_STATE.get(
        build["processing_state"], (build["processing_state"] or "Unknown", "neutral")
    )


def _internal_or_processing(build):
    """Internal beta state - what App Store Connect's add-a-build dialog shows
    (Ready to Test / Testing / ...). A VALID build with no beta detail at all
    is in TestFlight's hidden pre-Ready gap: it processed fine but cannot be
    added to a test group yet."""
    st = BETA_STATE.get(build["internal_state"])
    if st:
        return st
    if build.get("beta_detail_missing") and build["processing_state"] == "VALID":
        return ("Not yet testable", "warning")
    return _proc_status(build)


def internal_status(build):
    """Status as it applies to an internal group (stage/prod)."""
    if build["expired"]:
        return ("Expired", "muted")
    return _internal_or_processing(build)


def external_status(build):
    """Status as it applies to the external (beta) group."""
    if build["expired"]:
        return ("Expired", "muted")
    return BETA_STATE.get(build["external_state"]) or ("Not submitted", "muted")


def overall_status(build):
    """Best single status for a build in the ledger: a meaningful external
    (beta-review/testing) state wins; else the internal state; else processing."""
    if build["expired"]:
        return ("Expired", "muted")
    if build["external_state"] in MEANINGFUL_EXTERNAL:
        return BETA_STATE[build["external_state"]]
    return _internal_or_processing(build)


def lane_summary(builds, version, app_key):
    """For (version, app), the furthest-lane build + status in each lane.
    Stage/Prod read the internal state; Beta reads the external state."""
    vbuilds = [b for b in builds if b["marketing_version"] == version]
    result = {}
    for lane in LANES:
        in_lane = [b for b in vbuilds if lane in b["lanes"]]
        if not in_lane:
            continue
        b = sorted(in_lane, key=lambda x: x["uploaded"], reverse=True)[0]
        label, role = external_status(b) if lane == "beta" else internal_status(b)
        result[lane] = {
            "build_number": b["build_number"],
            "uploaded": b["uploaded"],
            "status_label": label,
            "status_role": role,
        }
    return result


def _int_build(bn):
    try:
        return int(bn)
    except (TypeError, ValueError):
        return None


def lane_cell(build, lane):
    """Render one lane cell for a build: build number + lane-appropriate status."""
    label, role = external_status(build) if lane == "beta" else internal_status(build)
    return {
        "build_number": build["build_number"],
        "uploaded": build["uploaded"],
        "status_label": label,
        "status_role": role,
    }


def first_build_in_lane_after(builds, lane, ts):
    """The earliest build in `lane` whose build number (a Unix time) >= ts."""
    cand = [
        b for b in builds
        if lane in b["lanes"] and (_int_build(b["build_number"]) or 0) >= ts
    ]
    if not cand:
        return None
    return min(cand, key=lambda b: _int_build(b["build_number"]) or 0)


def first_build_any_after(builds, ts):
    """Earliest build carrying the feature regardless of test-group membership -
    i.e. the first build produced after the entry merged to the branch. A build
    can exist (merged to `stage` branch, uploaded, processed) before App Store
    Connect has attached it to any test group."""
    cand = [b for b in builds if (_int_build(b["build_number"]) or 0) >= ts]
    if not cand:
        return None
    return min(cand, key=lambda b: _int_build(b["build_number"]) or 0)


# Internal states under which adding the build to a test group can't work:
# the delivery is broken, or TestFlight still owes a step (processing, export
# compliance) that the plain build->betaGroups POST cannot complete. External
# review states are NOT here - a build waiting on / rejected from external
# review is still fully attachable to internal groups.
UNATTACHABLE_INTERNAL = {
    "PROCESSING", "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE",
    "IN_EXPORT_COMPLIANCE_REVIEW", "EXPIRED",
}


def attachable(build):
    """Whether attaching this build to a TestFlight group can succeed.

    Unknown states (no beta detail recovered, but not confirmed missing)
    stay attachable - a failed attempt surfaces its own error, which beats
    falsely locking the control."""
    if build["expired"]:
        return False
    if build["processing_state"] and build["processing_state"] != "VALID":
        return False
    if build.get("beta_detail_missing"):
        return False
    return build["internal_state"] not in UNATTACHABLE_INTERNAL


def built_status(build):
    """Status for the 'Built' cell: the build exists, independent of groups."""
    if build["expired"]:
        return ("Expired", "muted")
    if build["processing_state"] == "VALID":
        return ("Built", "neutral")
    return PROCESSING_STATE.get(
        build["processing_state"], (build["processing_state"] or "Unknown", "neutral")
    )


def built_cell(build):
    label, role = built_status(build)
    return {
        "build_number": build["build_number"],
        "uploaded": build["uploaded"],
        "status_label": label,
        "status_role": role,
    }


# Display/progress order. `built` = a build carries it (merged to the stage
# BRANCH); stage/prod/beta = attached to that TestFlight GROUP.
CELL_LANES = ["built", "stage", "prod", "beta"]


def fragment_lanes(app_builds, land_ts):
    """Per-feature cells: the first build that carried it (`built`, any group)
    and the first build in each test group (`stage`/`prod`/`beta`). A feature
    merged to the stage branch but not yet attached to any group shows a `built`
    build with the group lanes empty."""
    lanes = {}
    if not land_ts:
        return lanes
    b0 = first_build_any_after(app_builds, land_ts)
    if b0:
        lanes["built"] = built_cell(b0)
    for lane in LANES:
        b = first_build_in_lane_after(app_builds, lane, land_ts)
        if b:
            lanes[lane] = lane_cell(b, lane)
    return lanes


def _furthest(lanes_by_app):
    best = -1
    for lanes in lanes_by_app.values():
        for i, lane in enumerate(CELL_LANES):
            if lane in lanes:
                best = max(best, i)
    return CELL_LANES[best] if best >= 0 else "none"


# Landing times are immutable once an entry has merged, so memoize across the
# many /api/data refreshes a running server serves.
_LANDING_CACHE = {}


def _pickaxe_landing(repo_root, summary, ref=None):
    """Unix time an entry's text first landed on the branch (first-parent).

    Works for pending fragments AND collated CHANGELOG entries: the same bold
    summary text first appears in the changelog.d/ fragment (when the PR merges
    to stage) and only later moves into CHANGELOG.md at release, so the earliest
    first-parent commit that added the text is the stage-landing moment.
    """
    phrase = re.sub(r"\s+", " ", summary or "").strip()
    refarg = [ref] if ref else []
    for cand in (phrase, phrase[:40].rstrip()):
        if not cand:
            continue
        out = _git(
            repo_root,
            ["log", *refarg, "--first-parent", "--reverse", "-S", cand,
             "--format=%ct", "--", "CHANGELOG.md", "changelog.d"],
        ).stdout.strip().splitlines()
        if out:
            try:
                return int(out[0])
            except ValueError:
                pass
    return None


def feature_landings(repo_root, summaries, ref=None):
    """Map each feature summary -> Unix stage-landing time (best effort)."""
    out = {}
    if not os.path.isdir(os.path.join(repo_root, ".git")):
        return out
    for s in summaries:
        if not s:
            continue
        key = (os.path.abspath(repo_root), ref or "", s)
        if key in _LANDING_CACHE:
            out[s] = _LANDING_CACHE[key]
            continue
        ts = _pickaxe_landing(repo_root, s, ref)
        if ts is not None:
            _LANDING_CACHE[key] = ts
            out[s] = ts
    return out


def assemble(repo_versions, fragments, frag_dates, landings, tag_dates, asc):
    apps = [a["key"] for a in APPS]
    builds_by_app = {a: asc.get(a, {}).get("builds", []) for a in apps}
    asc_versions = {a: {b["marketing_version"] for b in builds_by_app[a]} for a in apps}

    # Unified feature list. Every feature - pending fragment or released entry -
    # carries per-app Stage/Prod/Beta cells naming the build that contains it.
    features = []

    # Every feature's Stage/Prod/Beta cells are the FIRST build in each lane
    # that carried it, i.e. the earliest build in that group whose build number
    # (a Unix timestamp) is >= when the entry landed on stage. This is uniform
    # for pending and released entries and correctly puts a released feature's
    # first stage build under whatever marketing version was current then - not
    # the newest build of the version it was eventually cut into.
    def feature_cells(land):
        lanes = {a: fragment_lanes(builds_by_app[a], land) for a in apps}
        return lanes, _furthest(lanes)

    # Pending fragments: merged to stage, not yet cut to a version / prod.
    for f in fragments:
        if not f["apple"]:
            continue
        land = landings.get(f["summary"])
        lanes, furthest = feature_cells(land)
        features.append({
            "summary": f["summary"], "detail": f["detail"], "category": f["category"],
            "origin": "pending", "version": None,
            "date": frag_dates.get(f["file"], ""), "land": land,
            "lanes": lanes, "furthest": furthest,
        })

    # Released entries, grouped by the version they were collated into.
    version_rows = []
    for v in repo_versions:
        has_apple = bool(v["apple_entries"])
        in_asc = any(v["version"] in asc_versions[a] for a in apps)
        if not (has_apple or in_asc):
            continue
        vdate = v["date"] or tag_dates.get(v["version"], "")
        version_rows.append({
            "version": v["version"], "date": vdate,
            "features": [{"summary": e["summary"], "detail": e["detail"], "category": e["category"]}
                         for e in v["apple_entries"]],
            "lanes": {a: lane_summary(builds_by_app[a], v["version"], a) for a in apps},  # legacy
        })
        for e in v["apple_entries"]:
            land = landings.get(e["summary"])
            lanes, furthest = feature_cells(land)
            features.append({
                "summary": e["summary"], "detail": e["detail"], "category": e["category"],
                "origin": "released", "version": v["version"], "date": vdate, "land": land,
                "lanes": lanes, "furthest": furthest,
            })

    pending = [f for f in features if f["origin"] == "pending"]
    released = [f for f in features if f["origin"] == "released"]

    # Legacy shape kept for the static generator template.
    inflight = [
        {"summary": f["summary"], "detail": f["detail"], "category": f["category"],
         "file": f["file"], "added": frag_dates.get(f["file"], "")}
        for f in fragments if f["apple"]
    ]

    # Build ledger: every build across both apps, newest upload first.
    ledger = []
    for a in APPS:
        for b in asc.get(a["key"], {}).get("builds", []):
            label, role = overall_status(b)
            ledger.append(
                {
                    "id": b.get("id", ""),
                    "app": a["label"],
                    "app_key": a["key"],
                    "platform": pretty_platform(b.get("platform", "")),
                    "marketing_version": b["marketing_version"],
                    "build_number": b["build_number"],
                    "build_date": build_number_date(b["build_number"]),
                    "uploaded": b["uploaded"],
                    "processing_state": b["processing_state"],
                    "status_label": label,
                    "status_role": role,
                    "lanes": b["lanes"],
                    "groups": b["groups"],
                    "expired": b["expired"],
                    "expires": b.get("expiration", ""),
                    "attachable": attachable(b),
                }
            )
    ledger.sort(key=lambda x: x["uploaded"] or "", reverse=True)

    found = {a["key"]: asc.get(a["key"], {}).get("found", False) for a in APPS}
    return {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "apps": [{"key": a["key"], "label": a["label"], "bundle_id": a["bundle_id"]} for a in APPS],
        "found": found,
        "groups": {a: asc.get(a, {}).get("groups", []) for a in apps},
        "features": features,
        "inflight": inflight,          # legacy (static template)
        "versions": version_rows,      # legacy (static template)
        "ledger": ledger,
        "counts": {
            "features": len(features),
            # Pending fragments (merged to the stage branch, not yet cut to prod).
            "stage_group": sum(1 for f in pending if f["furthest"] == "stage"),
            "built_ungrouped": sum(1 for f in pending if f["furthest"] == "built"),
            "pending_unbuilt": sum(1 for f in pending if f["furthest"] == "none"),
            # Released features currently visible in a TestFlight group.
            "in_prod": sum(1 for f in released if f["furthest"] in ("prod", "beta")),
            "in_beta": sum(1 for f in released if f["furthest"] == "beta"),
            "builds": len(ledger),
            "inflight": len(inflight),               # legacy
            "versions": len(version_rows),           # legacy
        },
    }


# --------------------------------------------------------------------------
# Render.
# --------------------------------------------------------------------------

def render_html(model):
    data_json = json.dumps(model)
    tmpl = HTML_TEMPLATE.replace("/*__DATA__*/", data_json)
    return tmpl


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cabalmail Apple Release Dashboard</title>
<style>
  :root{
    color-scheme: light dark;
    --page:#f9f9f7; --surface:#fcfcfb; --surface-2:#f2f1ec;
    --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
    --grid:#e1e0d9; --line:#c3c2b7; --border:rgba(11,11,11,0.10);
    --ios:#2a78d6; --mac:#eb6834;
    --good:#0ca30c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b; --neutral:#8b8a86;
    --good-ink:#006300;
    --radius:10px;
  }
  :root[data-theme="dark"]{
    --page:#0d0d0d; --surface:#1a1a19; --surface-2:#242422;
    --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --line:#383835; --border:rgba(255,255,255,0.10);
    --ios:#3987e5; --mac:#d95926;
    --good:#0ca30c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b; --neutral:#9a998f;
    --good-ink:#0ca30c;
  }
  @media (prefers-color-scheme: dark){
    :root[data-theme="auto"]{
      --page:#0d0d0d; --surface:#1a1a19; --surface-2:#242422;
      --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
      --grid:#2c2c2a; --line:#383835; --border:rgba(255,255,255,0.10);
      --ios:#3987e5; --mac:#d95926; --neutral:#9a998f; --good-ink:#0ca30c;
    }
  }
  *{box-sizing:border-box}
  html,body{margin:0}
  body{
    background:var(--page); color:var(--ink);
    font-family:system-ui,-apple-system,"Segoe UI",sans-serif;
    font-size:14px; line-height:1.5; -webkit-font-smoothing:antialiased;
  }
  .wrap{max-width:1220px; margin:0 auto; padding:24px 20px 64px}
  header.top{display:flex; align-items:flex-start; gap:16px; flex-wrap:wrap; margin-bottom:4px}
  h1{font-size:20px; margin:0; font-weight:650; letter-spacing:-0.01em}
  .sub{color:var(--ink-2); font-size:13px; margin:2px 0 0}
  .spacer{flex:1}
  .themebtn{
    border:1px solid var(--border); background:var(--surface); color:var(--ink-2);
    border-radius:8px; padding:6px 12px; font:inherit; font-size:12px; cursor:pointer;
  }
  .themebtn:hover{color:var(--ink)}
  .stats{display:flex; gap:10px; flex-wrap:wrap; margin:18px 0 20px}
  .stat{
    background:var(--surface); border:1px solid var(--border); border-radius:var(--radius);
    padding:12px 16px; min-width:120px;
  }
  .stat .n{font-size:22px; font-weight:650; letter-spacing:-0.02em}
  .stat .l{font-size:12px; color:var(--muted); margin-top:1px}
  .tabs{display:flex; gap:4px; border-bottom:1px solid var(--grid); margin-bottom:18px}
  .tab{
    border:none; background:none; color:var(--ink-2); font:inherit; font-size:14px;
    padding:9px 14px; cursor:pointer; border-bottom:2px solid transparent; margin-bottom:-1px;
  }
  .tab[aria-selected="true"]{color:var(--ink); border-bottom-color:var(--ios); font-weight:600}
  .tab:hover{color:var(--ink)}
  .panel{display:none}
  .panel.active{display:block}

  .legend{display:flex; gap:14px; flex-wrap:wrap; align-items:center; margin:0 0 16px; font-size:12px; color:var(--ink-2)}
  .legend .pill{margin-right:2px}
  .apptag{display:inline-flex; align-items:center; gap:6px; font-weight:600}
  .dot{width:9px; height:9px; border-radius:50%; display:inline-block}
  .dot.ios{background:var(--ios)} .dot.mac{background:var(--mac)}

  /* status pills */
  .pill{
    display:inline-flex; align-items:center; gap:5px; padding:2px 8px; border-radius:999px;
    font-size:11.5px; font-weight:600; line-height:1.6; white-space:nowrap;
    border:1px solid transparent;
  }
  .pill .ic{font-size:10px; line-height:1}
  .pill.good{background:color-mix(in srgb,var(--good) 15%,transparent); color:var(--good-ink); border-color:color-mix(in srgb,var(--good) 40%,transparent)}
  .pill.warning{background:color-mix(in srgb,var(--warning) 22%,transparent); color:var(--ink); border-color:color-mix(in srgb,var(--warning) 55%,transparent)}
  .pill.serious{background:color-mix(in srgb,var(--serious) 22%,transparent); color:var(--ink); border-color:color-mix(in srgb,var(--serious) 55%,transparent)}
  .pill.critical{background:color-mix(in srgb,var(--critical) 16%,transparent); color:var(--critical); border-color:color-mix(in srgb,var(--critical) 45%,transparent)}
  .pill.neutral{background:var(--surface-2); color:var(--ink-2); border-color:var(--border)}
  .pill.muted{background:transparent; color:var(--muted); border-color:var(--border)}
  :root[data-theme="dark"] .pill.warning, :root[data-theme="dark"] .pill.serious{color:#0b0b0b}
  @media (prefers-color-scheme: dark){
    :root[data-theme="auto"] .pill.warning, :root[data-theme="auto"] .pill.serious{color:#0b0b0b}
  }

  /* feature matrix */
  .vgroup{
    background:var(--surface); border:1px solid var(--border); border-radius:var(--radius);
    margin-bottom:14px; overflow:hidden;
  }
  .vhead{
    display:flex; justify-content:space-between; align-items:center; gap:18px;
    padding:13px 16px; cursor:pointer; border-bottom:1px solid transparent;
  }
  .vgroup.open .vhead{border-bottom-color:var(--grid)}
  .vhead:hover{background:var(--surface-2)}
  .vtitle{display:flex; align-items:baseline; gap:9px; white-space:nowrap; flex:0 0 auto}
  .vnum{font-size:16px; font-weight:650; letter-spacing:-0.01em}
  .vdate{font-size:12px; color:var(--muted); font-variant-numeric:tabular-nums; white-space:nowrap}
  .vcount{font-size:12px; color:var(--muted); white-space:nowrap}
  .lanes{display:flex; gap:18px; flex-wrap:wrap; justify-content:flex-end; flex:1 1 auto}
  .laneapp{display:flex; gap:6px; align-items:center}
  .lanecol{display:flex; flex-direction:column; gap:3px; align-items:flex-start; min-width:96px}
  .lanelabel{font-size:10px; text-transform:uppercase; letter-spacing:0.05em; color:var(--muted)}
  .lanebuild{font-size:10.5px; color:var(--muted); font-variant-numeric:tabular-nums}
  .lane-none{color:var(--muted); font-size:12px}
  .flist{padding:6px 16px 14px; display:none}
  .vgroup.open .flist{display:block}
  .frow{padding:9px 0; border-top:1px solid var(--grid); display:flex; gap:10px; align-items:baseline}
  .frow:first-child{border-top:none}
  .fcat{
    font-size:10px; text-transform:uppercase; letter-spacing:0.04em; color:var(--muted);
    min-width:74px; padding-top:2px;
  }
  .fsummary{font-weight:600}
  .fdetail{color:var(--ink-2); font-weight:400}
  .caret{display:inline-block; width:12px; color:var(--muted); transition:transform .12s; font-size:11px}
  .vgroup.open .caret{transform:rotate(90deg)}

  .badge-flight{background:color-mix(in srgb,var(--ios) 16%,transparent); color:var(--ios); border:1px solid color-mix(in srgb,var(--ios) 40%,transparent); border-radius:999px; padding:2px 9px; font-size:11px; font-weight:600}

  /* ledger table */
  .controls{display:flex; gap:10px; flex-wrap:wrap; align-items:center; margin-bottom:12px}
  .controls select, .controls input{
    font:inherit; font-size:13px; padding:6px 10px; border-radius:8px;
    border:1px solid var(--border); background:var(--surface); color:var(--ink);
  }
  .controls label{font-size:12px; color:var(--muted)}
  table{width:100%; border-collapse:collapse; background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); overflow:hidden}
  th,td{text-align:left; padding:10px 12px; border-bottom:1px solid var(--grid); vertical-align:middle}
  th{font-size:11px; text-transform:uppercase; letter-spacing:0.04em; color:var(--muted); font-weight:600; cursor:pointer; user-select:none; white-space:nowrap}
  th:hover{color:var(--ink-2)}
  tbody tr:hover{background:var(--surface-2)}
  tbody tr:last-child td{border-bottom:none}
  td.num{font-variant-numeric:tabular-nums}
  .mono{font-variant-numeric:tabular-nums}
  .grp{display:inline-block; font-size:10.5px; font-weight:600; padding:1px 7px; border-radius:6px; border:1px solid var(--border); margin-right:4px; color:var(--ink-2)}
  .grp.stage{border-color:color-mix(in srgb,var(--ios) 40%,transparent)}
  .grp.prod{border-color:color-mix(in srgb,var(--good) 45%,transparent)}
  .grp.beta{border-color:color-mix(in srgb,var(--mac) 45%,transparent)}
  .apppill{display:inline-flex; align-items:center; gap:6px; font-weight:600; font-size:12.5px}
  .expnote{font-size:10.5px; color:var(--muted); font-variant-numeric:tabular-nums; margin-top:2px}
  .empty{color:var(--muted); padding:30px 12px; text-align:center}
  .notfound{background:color-mix(in srgb,var(--critical) 10%,transparent); border:1px solid color-mix(in srgb,var(--critical) 35%,transparent); border-radius:var(--radius); padding:12px 16px; margin-bottom:16px; font-size:13px}
  footer{margin-top:28px; color:var(--muted); font-size:12px; border-top:1px solid var(--grid); padding-top:14px}
  code{background:var(--surface-2); padding:1px 5px; border-radius:5px; font-size:12px}
  a{color:var(--ios)}
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <div>
      <h1>Cabalmail · Apple Release Dashboard</h1>
      <p class="sub" id="sub"></p>
    </div>
    <div class="spacer"></div>
    <button class="themebtn" id="themebtn" type="button">Theme: Auto</button>
  </header>

  <div id="demo"></div>
  <div id="notfound"></div>
  <div class="stats" id="stats"></div>

  <div class="legend" id="legend">
    <span class="apptag"><span class="dot ios"></span>iOS</span>
    <span class="apptag"><span class="dot mac"></span>macOS</span>
    <span style="width:1px;height:14px;background:var(--grid)"></span>
    <span><span class="pill good"><span class="ic">●</span>Testing</span></span>
    <span><span class="pill warning"><span class="ic">▲</span>Waiting for Review</span></span>
    <span><span class="pill neutral"><span class="ic">○</span>Processing</span></span>
    <span><span class="pill critical"><span class="ic">✕</span>Rejected / Failed</span></span>
    <span><span class="pill muted"><span class="ic">–</span>Expired</span></span>
  </div>

  <div class="tabs" role="tablist">
    <button class="tab" role="tab" aria-selected="true" data-tab="features">Feature matrix</button>
    <button class="tab" role="tab" aria-selected="false" data-tab="ledger">Build ledger</button>
  </div>

  <section class="panel active" id="panel-features" role="tabpanel"></section>
  <section class="panel" id="panel-ledger" role="tabpanel"></section>

  <footer id="footer"></footer>
</div>

<script type="application/json" id="model">/*__DATA__*/</script>
<script>
const MODEL = JSON.parse(document.getElementById('model').textContent);
const LANES = ["stage","prod","beta"];
const LANE_LABEL = {stage:"Stage", prod:"Prod", beta:"Beta"};
const ROLE_ICON = {good:"●", warning:"▲", serious:"◆", critical:"✕", neutral:"○", muted:"–"};
const esc = s => (s==null?"":String(s)).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

function pill(label, role){
  return `<span class="pill ${role}"><span class="ic">${ROLE_ICON[role]||"○"}</span>${esc(label)}</span>`;
}

/* ---------- header / stats ---------- */
document.getElementById('sub').textContent =
  `iOS ${MODEL.apps[0].bundle_id} · macOS ${MODEL.apps[1].bundle_id} · generated ${MODEL.generated}`;

if(MODEL.demo){
  document.getElementById('demo').innerHTML =
    `<div class="notfound" style="background:color-mix(in srgb,var(--warning) 16%,transparent);border-color:color-mix(in srgb,var(--warning) 45%,transparent)">`+
    `<b>Preview / sample data.</b> Feature and version content is real (from your repo's CHANGELOG.md and changelog.d/), but the `+
    `Stage/Prod/Beta build numbers and Apple statuses shown here are synthetic. Run the generator with your App Store Connect `+
    `credentials (no <code>--mock</code>) for live status.</div>`;
}
const nf = [];
MODEL.apps.forEach(a=>{ if(!MODEL.found[a.key]) nf.push(a.label+" ("+a.bundle_id+")"); });
if(nf.length){
  document.getElementById('notfound').innerHTML =
    `<div class="notfound">⚠ No App Store Connect app record resolved for: ${esc(nf.join(', '))}. `+
    `Build/status columns for it will be empty. Check the bundle id or that the API key has access.</div>`;
}

document.getElementById('stats').innerHTML = [
  ['In-flight (unreleased)', MODEL.counts.inflight],
  ['Released Apple features', MODEL.counts.features],
  ['Versions tracked', MODEL.counts.versions],
  ['Builds in App Store Connect', MODEL.counts.builds],
].map(([l,n])=>`<div class="stat"><div class="n">${n}</div><div class="l">${l}</div></div>`).join('');

/* ---------- feature matrix ---------- */
function laneCell(app, laneData){
  const cols = LANES.map(l=>{
    const d = laneData[l];
    if(!d){
      // Beta lane may not exist for macOS at all — show a subtle dash.
      return `<div class="lanecol"><span class="lanelabel">${LANE_LABEL[l]}</span><span class="lane-none">—</span></div>`;
    }
    return `<div class="lanecol">`+
      `<span class="lanelabel">${LANE_LABEL[l]}</span>`+
      pill(d.status_label, d.status_role)+
      `<span class="lanebuild">#${esc(d.build_number)}</span>`+
      `</div>`;
  }).join('');
  return `<div class="laneapp"><span class="dot ${app}"></span></div>`+
         `<div style="display:flex;gap:10px">${cols}</div>`;
}

function renderFeatures(){
  const p = document.getElementById('panel-features');
  let html = '';

  if(MODEL.inflight.length){
    html += `<div class="vgroup inflight open" data-vg>`+
      `<div class="vhead" onclick="this.parentNode.classList.toggle('open')">`+
        `<div class="vtitle"><span class="caret">▶</span><span class="vnum">In-flight</span>`+
          `<span class="vcount">${MODEL.inflight.length} unreleased fragment${MODEL.inflight.length!==1?'s':''}</span></div>`+
        `<span class="badge-flight">changelog.d/ · not yet in a version</span>`+
      `</div><div class="flist">`+
        MODEL.inflight.map(f=>featureRow(f, f.added?('added '+f.added):'')).join('')+
      `</div></div>`;
  }

  MODEL.versions.forEach((v,i)=>{
    const laneHtml = MODEL.apps.map(a=>{
      const ld = v.lanes[a.key]||{};
      const cols = LANES.map(l=>{
        const d = ld[l];
        if(!d) return `<div class="lanecol"><span class="lanelabel">${LANE_LABEL[l]}</span><span class="lane-none">—</span></div>`;
        return `<div class="lanecol"><span class="lanelabel">${LANE_LABEL[l]}</span>`+
          pill(d.status_label,d.status_role)+`<span class="lanebuild">#${esc(d.build_number)}</span></div>`;
      }).join('');
      return `<div class="laneapp"><span class="dot ${a.key}" title="${a.label}"></span>${cols}</div>`;
    }).join('');

    const open = i===0 ? 'open' : '';
    html += `<div class="vgroup ${open}" data-vg>`+
      `<div class="vhead" onclick="this.parentNode.classList.toggle('open')">`+
        `<div class="vtitle"><span class="caret">▶</span><span class="vnum">${esc(v.version)}</span>`+
          `<span class="vdate">${esc(v.date)}</span>`+
          `<span class="vcount">· ${v.features.length} Apple feature${v.features.length!==1?'s':''}</span></div>`+
        `<div class="lanes">${laneHtml}</div>`+
      `</div>`+
      `<div class="flist">`+
        (v.features.length? v.features.map(f=>featureRow(f,'')).join('')
          : `<div class="frow"><span class="fdetail">No Apple-scoped changelog entries in this version (builds present in App Store Connect).</span></div>`)+
      `</div></div>`;
  });

  p.innerHTML = html || `<div class="empty">No Apple features found.</div>`;
}

function featureRow(f, meta){
  return `<div class="frow">`+
    `<span class="fcat">${esc(f.category||'')}</span>`+
    `<span><span class="fsummary">${esc(f.summary)}</span>`+
      (f.detail?` <span class="fdetail">— ${esc(f.detail)}</span>`:'')+
      (meta?` <span class="lanebuild">· ${esc(meta)}</span>`:'')+
    `</span></div>`;
}

/* ---------- build ledger ---------- */
let sortKey='uploaded', sortDir=-1;
function renderLedger(){
  const p = document.getElementById('panel-ledger');
  const appF = document.getElementById('f-app')?document.getElementById('f-app').value:'all';
  const laneF = document.getElementById('f-lane')?document.getElementById('f-lane').value:'all';
  const q = document.getElementById('f-q')?document.getElementById('f-q').value.trim().toLowerCase():'';

  let rows = MODEL.ledger.slice();
  if(appF!=='all') rows = rows.filter(r=>r.app_key===appF);
  if(laneF!=='all') rows = rows.filter(r=>r.lanes.includes(laneF));
  if(q) rows = rows.filter(r=>(r.marketing_version+' '+r.build_number+' '+r.status_label+' '+r.groups.join(' ')).toLowerCase().includes(q));

  rows.sort((a,b)=>{
    let x=a[sortKey], y=b[sortKey];
    if(sortKey==='build_number'){x=+x||0;y=+y||0;}
    if(x<y) return -1*sortDir; if(x>y) return 1*sortDir; return 0;
  });

  const controls = `<div class="controls">
    <label>App <select id="f-app" onchange="renderLedger()">
      <option value="all">All</option><option value="ios">iOS</option><option value="mac">macOS</option></select></label>
    <label>Lane <select id="f-lane" onchange="renderLedger()">
      <option value="all">Any</option>${LANES.map(l=>`<option value="${l}">${LANE_LABEL[l]}</option>`).join('')}</select></label>
    <input id="f-q" placeholder="Filter version / build / status…" oninput="renderLedger()">
    <span class="spacer" style="flex:1"></span>
    <label style="align-self:center">${rows.length} build${rows.length!==1?'s':''}</label>
  </div>`;

  const head = `<tr>
    ${th('app','App')}${th('marketing_version','Marketing')}${th('build_number','Build #')}
    ${th('build_date','Build # → date')}${th('uploaded','Uploaded')}${th('status_label','Apple status')}
    <th>Groups</th></tr>`;

  const body = rows.map(r=>`<tr>
    <td><span class="apppill"><span class="dot ${r.app_key}"></span>${esc(r.app)}</span></td>
    <td class="mono"><b>${esc(r.marketing_version||'—')}</b></td>
    <td class="num mono">${esc(r.build_number)}</td>
    <td class="num mono" style="color:var(--ink-2)">${esc(r.build_date||'—')}</td>
    <td class="num mono" style="color:var(--ink-2)">${esc((r.uploaded||'').replace('T',' ').replace(/:\d\dZ?$/,'').replace('Z',''))||'—'}</td>
    <td>${pill(r.status_label,r.status_role)}${expNote(r)}</td>
    <td>${r.lanes.length? r.lanes.map(l=>`<span class="grp ${l}">${LANE_LABEL[l]}</span>`).join('') : '<span class="lane-none">—</span>'}</td>
  </tr>`).join('');

  p.innerHTML = controls + `<table><thead>${head}</thead><tbody>`+
    (rows.length?body:`<tr><td colspan="7" class="empty">No builds match.</td></tr>`)+`</tbody></table>`;

  // restore control values after re-render
  if(document.getElementById('f-app')) document.getElementById('f-app').value=appF;
  if(document.getElementById('f-lane')) document.getElementById('f-lane').value=laneF;
  if(document.getElementById('f-q')){const el=document.getElementById('f-q'); el.value=q; }
}
function th(key,label){
  const arrow = sortKey===key?(sortDir===1?' ▲':' ▼'):'';
  return `<th onclick="setSort('${key}')">${label}${arrow}</th>`;
}
function setSort(key){ if(sortKey===key) sortDir*=-1; else {sortKey=key; sortDir=1;} renderLedger(); }
function expNote(r){
  if(r.expired || !r.expires) return '';
  const days = Math.ceil((new Date(r.expires) - Date.now())/86400000);
  if(!isFinite(days) || days < 0) return '';
  return `<div class="expnote">expires in ${days}d</div>`;
}

/* ---------- tabs ---------- */
document.querySelectorAll('.tab').forEach(t=>t.addEventListener('click',()=>{
  document.querySelectorAll('.tab').forEach(x=>x.setAttribute('aria-selected', x===t));
  document.getElementById('panel-features').classList.toggle('active', t.dataset.tab==='features');
  document.getElementById('panel-ledger').classList.toggle('active', t.dataset.tab==='ledger');
}));

/* ---------- theme ---------- */
const tb = document.getElementById('themebtn');
const modes=['auto','light','dark']; let mi=0;
tb.addEventListener('click',()=>{ mi=(mi+1)%3; document.documentElement.dataset.theme=modes[mi];
  tb.textContent='Theme: '+modes[mi][0].toUpperCase()+modes[mi].slice(1); });

document.getElementById('footer').innerHTML =
  `Marketing version = <code>CFBundleShortVersionString</code> (from CHANGELOG.md). `+
  `Build # = <code>CFBundleVersion</code>, a Unix timestamp set by <code>apple.yml</code> (<code>date -u +%s</code>) — dereferenced to a date in the ledger. `+
  `Lanes: <b>Stage</b>/<b>Prod</b> are internal TestFlight groups (stage→stage, main→prod); <b>Beta</b> is an external group. `+
  `Apple status is the App Store Connect build beta state at generation time — what the add-a-build dialog shows. `+
  `<b>Not yet testable</b> = the build processed (Valid) but TestFlight hasn't surfaced it for testing yet; it can't be added to a test group until it flips to Ready to Test.`;

renderFeatures();
renderLedger();
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="Path to the cabal-infra repo root (default: the checkout containing this script)")
    ap.add_argument("--out", default="apple-dashboard.html", help="Output HTML path")
    ap.add_argument("--mock", help="Render from a captured/synthetic ASC JSON file instead of the API")
    ap.add_argument("--dump-asc", help="Write the normalized ASC payload to this JSON path")
    ap.add_argument("--ref", default="origin/stage",
                    help="Git ref to read the stage branch from (default: origin/stage; 'local' = working tree)")
    ap.add_argument("--no-fetch", action="store_true", help="Don't git-fetch before reading the ref")
    ap.add_argument("--cache-dir", default="~/.cache/cabalmail-apple-dashboard",
                    help="Directory for the settled-builds disk cache (default: %(default)s)")
    ap.add_argument("--no-asc-cache", action="store_true",
                    help="Disable the builds cache; refetch the full history from App Store Connect")
    args = ap.parse_args()

    global CACHE_DIR, CACHE_ENABLED  # pylint: disable=global-statement
    CACHE_ENABLED = not args.no_asc_cache
    CACHE_DIR = os.path.expanduser(args.cache_dir) if CACHE_ENABLED else None

    repo = os.path.abspath(os.path.expanduser(args.repo))
    ref = None
    if args.ref and args.ref != "local":
        if not args.no_fetch:
            git_fetch(repo)
        if ref_exists(repo, args.ref):
            src = read_ref_source(repo, args.ref)
            if src is not None:
                text, items = src
                versions = parse_changelog_text(text)
                fragments = read_fragments_items(items)
                ref = args.ref
    if ref is None:
        changelog_path = os.path.join(repo, "CHANGELOG.md")
        if not os.path.isfile(changelog_path):
            sys.exit(f"CHANGELOG.md not found under --repo {repo!r}")
        versions = parse_changelog(changelog_path)
        fragments = read_fragments(os.path.join(repo, "changelog.d"))

    frag_dates, tag_dates = git_dates(repo, fragments, ref)
    summaries = [f["summary"] for f in fragments if f["apple"]]
    summaries += [e["summary"] for v in versions for e in v["apple_entries"]]
    landings = feature_landings(repo, summaries, ref)

    demo = False
    if args.mock:
        with open(args.mock, encoding="utf-8") as fh:
            asc = json.load(fh)
        demo = True
    else:
        asc = fetch_asc()

    if args.dump_asc:
        with open(args.dump_asc, "w", encoding="utf-8") as fh:
            json.dump(asc, fh, indent=2)
        sys.stderr.write(f"Wrote normalized ASC payload to {args.dump_asc}\n")

    model = assemble(versions, fragments, frag_dates, landings, tag_dates, asc)
    model["demo"] = demo
    html_out = render_html(model)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(html_out)
    sys.stderr.write(
        f"Wrote {args.out}: {model['counts']['features']} released Apple features across "
        f"{model['counts']['versions']} versions, {model['counts']['inflight']} in-flight, "
        f"{model['counts']['builds']} builds.\n"
    )


if __name__ == "__main__":
    main()
