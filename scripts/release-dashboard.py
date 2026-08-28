#!/usr/bin/env python3
"""Flask app for the Cabalmail release dashboard.

Companion to apple-dashboard-app.py (5057) and triage-dashboard.py (5058) with
the same chrome (refresh button with an auto-refresh chevron menu, theme
toggle, stat tiles), pointed at the stage -> prod release cycle. It exists
because the GitHub Actions tab hides runs that are waiting for approval below
the fold or on page 2, which is how approvals get missed and releases stack up.

What it shows, top to bottom:

  * every workflow run in the repo currently `waiting` on an environment
    approval gate - fully paginated, so a run can never hide on page 2 - with
    a per-run Approve button (uses the same pending_deployments API the
    Actions tab uses; GitHub still decides whether you may approve)
  * the release in flight, derived statelessly from what GitHub reports:
      - no release PR open: the pending changelog.d/ fragments on
        origin/stage, grouped by category (what the next release would say),
        and Promote buttons for a patch / minor / major bump. Promote is
        held - buttons disabled, pending issues listed - while any open
        tester/fixer-cycle issue has a claimed fix merged on stage but not
        yet released: code the tester hasn't signed off on shouldn't ride to
        prod. Closing the issue (the retest pass does this) releases the
        hold.
      - promote running: the live promote.sh log
      - release PR open: its checks, and a Merge button that arms once the
        checks are green (review the diff on github.com - this dashboard
        deliberately doesn't render diffs)
  * the last release: the deploy workflows the merge actually triggered -
    path filtering already happened on GitHub's side, so a release that
    touched nothing under apple/ simply has no apple.yml run to wait for -
    tracked to completion against the GitHub release that release.yml creates
  * recent releases, linked to github.com

Promote runs the repo's own scripts/promote.sh (all its guards apply), but in
a private clone under --workdir rather than your working checkout, so the
dashboard never competes with whatever branch you have checked out. The clone
is force-reset to origin/stage before every promote; nothing of yours lives
there. Promote, Merge, and Approve make real changes (a push to stage, a merge
to main, a prod deploy approval) and each asks for confirmation; everything
else is read-only polling.

All GitHub data is fetched live on each refresh through `gh api` (uses your
existing gh login); set GITHUB_TOKEN or GH_TOKEN to bypass the gh CLI and call
the API directly instead.

Run:

    pip install flask
    python3 scripts/release-dashboard.py         # from anywhere in the repo
    # then open http://127.0.0.1:5059

The repo slug is read from the `origin` remote of --repo (default: the
directory containing this script's repo); override with --repo-slug. Listens
on port 5059 so it can run alongside the Apple release dashboard (5057) and
the triage dashboard (5058).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import traceback
import urllib.error
import urllib.request
from datetime import datetime, timezone

try:
    from flask import Flask, jsonify, Response, request
except ImportError:
    sys.exit("Flask is not installed. Run: pip install flask")


# Keep a Changelog section order - matches scripts/collate-changelog.sh.
CATEGORIES = ["added", "changed", "deprecated", "removed", "fixed", "security"]

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")

# One query for everything GitHub-side that isn't the Actions API: the pending
# fragments as they exist on origin/stage (read from GitHub, not the local
# checkout, so the dashboard never needs the working tree to be current),
# recent tags (to preview what patch/minor/major would produce), the open and
# most recent merged stage->main PRs, and recent releases.
QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    fragments: object(expression: "stage:changelog.d") {
      ... on Tree { entries { name object { ... on Blob { text } } } }
    }
    tags: refs(refPrefix: "refs/tags/", first: 50,
               orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
      nodes { name }
    }
    open_prs: pullRequests(baseRefName: "main", headRefName: "stage",
                           states: [OPEN], first: 1) {
      nodes {
        number title url mergeable mergeStateStatus
        commits(last: 1) {
          nodes {
            commit {
              oid
              statusCheckRollup {
                state
                contexts(first: 100) {
                  nodes {
                    __typename
                    ... on CheckRun { name status conclusion detailsUrl }
                    ... on StatusContext { context state targetUrl }
                  }
                }
              }
            }
          }
        }
      }
    }
    merged_prs: pullRequests(baseRefName: "main", headRefName: "stage",
                             states: [MERGED], first: 1,
                             orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes { number title url mergedAt mergeCommit { oid } }
    }
    releases(first: 15, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes { tagName name url createdAt publishedAt isLatest isDraft isPrerelease }
    }
  }
}
"""

# The tester/fixer lifecycle labels (the same set scripts/triage-dashboard.py
# puts on its board). An open issue bearing any of these is still in the
# cycle; if a merged stage PR claims to fix it and that merge hasn't reached
# main, the release gate holds Promote until the issue is closed.
LIFECYCLE_LABELS = {"needs-verification", "tester-found", "verified",
                    "verify-blocked", "accepted", "fix-in-review",
                    "needs-retest"}

# Open issues, paged; filtered to LIFECYCLE_LABELS client-side (the GraphQL
# labels argument can't express "any of these").
ISSUES_QUERY = """
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 100, after: $cursor,
           orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes { number title url labels(first: 20) { nodes { name } } }
    }
  }
}
"""

# Merged stage PRs, newest first - the population that can have put an
# issue's fix onto stage. Paged until the numbers fall below the oldest
# issue on the board (issues and PRs share one number sequence, and a PR
# fixing an issue is always created, so numbered, after it).
STAGE_PR_QUERY = """
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(baseRefName: "stage", states: [MERGED], first: 100,
                 after: $cursor,
                 orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url mergedAt headRefName body
        mergeCommit { oid }
        closingIssuesReferences(first: 20) { nodes { number } }
      }
    }
  }
}
"""
# Safety cap on the PR scan (pages of 100), same as the triage dashboard's;
# only reached if a lifecycle-labelled issue is very old.
PR_SCAN_MAX_PAGES = 25

# A fix-intent phrase: address/fix/close/resolve within a few words of one or
# more `#N`s ("Addresses #1217", "fixes issue #12 and #34"). See
# claimed_issues() for why this is narrower than a bare-mention scan.
FIX_CLAIM_RE = re.compile(
    r"\b(?:address(?:es|ed|ing)?|fix(?:es|ed|ing)?|clos(?:es?|ed|ing)|"
    r"resolv(?:es?|ed|ing))\b[^#\n]{0,30}((?:#\d+[,;\s]*(?:and\s+)?)+)",
    re.IGNORECASE)

REPO_SLUG = None
REPO_PATH = None
WORKDIR = None

# State of the one promote allowed at a time. Everything else on this
# dashboard is stateless (derived from GitHub on each refresh); this is the
# single exception, because the promote subprocess lives here.
PROMOTE_LOCK = threading.Lock()
PROMOTE = {"running": False, "spec": None, "version": None, "log": [],
           "ok": None, "started": None, "finished": None}
PROMOTE_LOG_CAP = 800


def utcnow():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def detect_repo_slug(repo_path):
    """Derive owner/name from the origin remote of the given checkout."""
    url = origin_url(repo_path)
    if not url:
        return None
    match = re.search(r"github\.com[:/]([^/]+)/([^/\s]+?)(?:\.git)?$", url)
    return f"{match.group(1)}/{match.group(2)}" if match else None


def origin_url(repo_path):
    try:
        return subprocess.run(
            ["git", "-C", repo_path, "remote", "get-url", "origin"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def graphql(query, variables):
    """Run a GraphQL query against the GitHub API and return the `data` dict.

    Prefers a token in GITHUB_TOKEN/GH_TOKEN (direct HTTPS call); otherwise
    shells out to `gh api graphql` so the user's normal gh login is used.
    """
    token = os.environ.get("GITHUB_TOKEN", "").strip() or os.environ.get("GH_TOKEN", "").strip()
    if token:
        req = urllib.request.Request(
            "https://api.github.com/graphql",
            data=json.dumps({"query": query, "variables": variables}).encode(),
            headers={"Authorization": f"bearer {token}",
                     "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    else:
        if not shutil.which("gh"):
            raise RuntimeError(
                "Neither GITHUB_TOKEN/GH_TOKEN is set nor is the `gh` CLI on PATH. "
                "Install gh and run `gh auth login`, or export a token."
            )
        cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
        for key, value in variables.items():
            if value is not None:
                cmd += ["-f", f"{key}={value}"]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"gh api graphql failed: {proc.stderr.strip() or proc.stdout.strip()}")
        payload = json.loads(proc.stdout)
    if payload.get("errors"):
        raise RuntimeError("GraphQL error: " + "; ".join(
            e.get("message", str(e)) for e in payload["errors"]))
    return payload["data"]


def rest(method, path, payload=None):
    """Call a GitHub REST endpoint and return the parsed JSON body (or None).

    Same token-or-gh-CLI arrangement as graphql().
    """
    token = os.environ.get("GITHUB_TOKEN", "").strip() or os.environ.get("GH_TOKEN", "").strip()
    if token:
        req = urllib.request.Request(
            "https://api.github.com" + path,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Authorization": f"bearer {token}",
                     "Content-Type": "application/json",
                     "Accept": "application/vnd.github+json"},
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
        except urllib.error.HTTPError as err:
            try:
                detail = json.load(err).get("message", "")
            except Exception:  # pylint: disable=broad-except
                detail = ""
            raise RuntimeError(f"GitHub returned HTTP {err.code}: {detail or err.reason}") from err
        text = body.decode("utf-8", "replace").strip() if body else ""
        return json.loads(text) if text else None
    if not shutil.which("gh"):
        raise RuntimeError(
            "Neither GITHUB_TOKEN/GH_TOKEN is set nor is the `gh` CLI on PATH. "
            "Install gh and run `gh auth login`, or export a token."
        )
    cmd = ["gh", "api", "--method", method, path.lstrip("/")]
    if payload is not None:
        cmd += ["--input", "-"]
    proc = subprocess.run(
        cmd, input=json.dumps(payload) if payload is not None else None,
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gh api failed: {proc.stderr.strip() or proc.stdout.strip()}")
    out = proc.stdout.strip()
    return json.loads(out) if out else None


# --------------------------------------------------------------------------
# Model assembly (read-only)
# --------------------------------------------------------------------------

def parse_fragments(tree):
    """Shape stage:changelog.d tree entries into fragment dicts."""
    frags = []
    for entry in (tree or {}).get("entries") or []:
        name = entry.get("name", "")
        if not name.endswith(".md") or name == "README.md":
            continue
        slug, _, category = name[:-3].rpartition(".")
        if not slug or category not in CATEGORIES:
            continue
        text = ((entry.get("object") or {}).get("text")) or ""
        frags.append({"file": name, "slug": slug, "category": category,
                      "body": text.strip()})
    frags.sort(key=lambda f: (CATEGORIES.index(f["category"]), f["slug"]))
    return frags


def next_versions(tag_names):
    """Preview what patch/minor/major would produce, from the latest semver tag.

    Advisory only - promote.sh recomputes the version itself after a fresh
    `git fetch --tags`, so this can only disagree with the real outcome if a
    tag lands between the preview and the click.
    """
    versions = []
    for tag in tag_names:
        match = SEMVER_RE.match(tag)
        if match:
            versions.append(tuple(int(g) for g in match.groups()))
    if not versions:
        return None
    major, minor, patch = max(versions)
    return {"latest": f"{major}.{minor}.{patch}",
            "patch": f"{major}.{minor}.{patch + 1}",
            "minor": f"{major}.{minor + 1}.0",
            "major": f"{major + 1}.0.0"}


def shape_open_pr(node):
    if not node:
        return None
    commits = node.get("commits", {}).get("nodes") or []
    commit = (commits[0].get("commit") if commits else None) or {}
    rollup = commit.get("statusCheckRollup") or {}
    checks = []
    for ctx in (rollup.get("contexts") or {}).get("nodes") or []:
        if ctx.get("__typename") == "CheckRun":
            checks.append({"name": ctx.get("name") or "",
                           "status": (ctx.get("status") or "").lower(),
                           "conclusion": (ctx.get("conclusion") or "").lower(),
                           "url": ctx.get("detailsUrl") or ""})
        elif ctx.get("__typename") == "StatusContext":
            state = (ctx.get("state") or "").lower()
            checks.append({"name": ctx.get("context") or "",
                           "status": "completed" if state in ("success", "failure", "error") else "in_progress",
                           "conclusion": state,
                           "url": ctx.get("targetUrl") or ""})
    checks.sort(key=lambda c: c["name"].lower())
    return {"number": node["number"], "title": node["title"], "url": node["url"],
            "sha": commit.get("oid"),
            "mergeable": node.get("mergeable"),
            "merge_state": node.get("mergeStateStatus"),
            "checks_state": rollup.get("state"),
            "checks": checks}


def shape_run(run):
    return {"id": run.get("id"),
            "name": run.get("name") or run.get("path") or "",
            "title": run.get("display_title") or "",
            "status": run.get("status") or "",
            "conclusion": run.get("conclusion") or "",
            "url": run.get("html_url") or "",
            "branch": run.get("head_branch") or "",
            "event": run.get("event") or "",
            "created": run.get("created_at") or "",
            "sha": run.get("head_sha") or ""}


def runs_for_sha(sha):
    """The repo's own workflow runs that the push of `sha` triggered.

    Two filters, both on properties GitHub reports rather than a hand-kept
    workflow list (which would drift as workflows are added):

      * event == push: a head_sha match alone is not enough - issue-event
        runs (claude.yml) execute against the default branch tip, so they
        carry main's head SHA without being part of the release.
      * an in-house path: GitHub-managed workflows (pages, default-setup
        CodeQL) live under dynamic/, not .github/workflows/, and are noise
        next to the release's own deploys.

    Everything that survives is one of the push-to-main workflows (app.yml /
    apple.yml / infra.yml / logo-assets.yml / release.yml), and only when the
    release's diff matched its path filter.
    """
    data = rest("GET", f"/repos/{REPO_SLUG}/actions/runs?head_sha={sha}&per_page=100")
    runs = [shape_run(r) for r in (data or {}).get("workflow_runs") or []
            if r.get("event") == "push"
            and (r.get("path") or "").startswith(".github/workflows/")]
    runs.sort(key=lambda r: r["name"].lower())
    return runs


def fetch_waiting_runs():
    """Every run waiting on an environment gate, with its pending approvals.

    Fully paginated - runs hiding on page 2 of the Actions tab are the whole
    reason this dashboard exists.
    """
    raw, page = [], 1
    while True:
        data = rest("GET", f"/repos/{REPO_SLUG}/actions/runs"
                           f"?status=waiting&per_page=100&page={page}") or {}
        batch = data.get("workflow_runs") or []
        raw.extend(batch)
        if not batch or len(raw) >= data.get("total_count", 0) or page >= 10:
            break
        page += 1
    out = []
    for run in raw:
        shaped = shape_run(run)
        try:
            pending = rest("GET", f"/repos/{REPO_SLUG}/actions/runs/{run['id']}/pending_deployments") or []
        except RuntimeError:
            pending = []
        shaped["pending"] = [
            {"id": (p.get("environment") or {}).get("id"),
             "name": (p.get("environment") or {}).get("name") or "",
             "can_approve": bool(p.get("current_user_can_approve"))}
            for p in pending]
        out.append(shaped)
    out.sort(key=lambda r: r["created"], reverse=True)
    return out


def shape_last_release(node, releases):
    """The most recently merged stage->main PR, with the runs its merge triggered."""
    if not node:
        return None
    match = re.search(r"\b(\d+\.\d+\.\d+)\b", node.get("title") or "")
    version = match.group(1) if match else None
    sha = (node.get("mergeCommit") or {}).get("oid")
    runs = runs_for_sha(sha) if sha else []
    release = next((r for r in releases if version and r["tag"] == version), None)
    return {"version": version,
            "pr": {"number": node["number"], "title": node["title"], "url": node["url"]},
            "merged": node.get("mergedAt"),
            "sha": sha,
            "runs": runs,
            "release": release}


def claimed_issues(node):
    """Issue numbers a merged PR claims to FIX.

    Deliberately narrower than the triage dashboard's reference union: a bare
    `#N` mention is very often context ("same class as #1191", "filed as
    #1222 rather than folded in"), and a match here disables the Promote
    buttons, so only a fix claim counts:

      * a `fixer/N-...` head branch (the fixer's convention),
      * GitHub closing references (a human's `Fixes #N` keyword),
      * a fix-intent phrase in the body (the fixer's "Addresses #N").
    """
    refs = {n["number"] for n in (node.get("closingIssuesReferences") or {}).get("nodes", [])}
    for run in FIX_CLAIM_RE.findall(node.get("body") or ""):
        refs.update(int(n) for n in re.findall(r"#(\d+)", run))
    match = re.match(r"fixer/(\d+)-", node.get("headRefName") or "")
    if match:
        refs.add(int(match.group(1)))
    return refs


def fetch_lifecycle_issues(owner, name):
    """Open issues currently in the tester/fixer cycle, with their cycle labels."""
    out, cursor = [], None
    while True:
        data = graphql(ISSUES_QUERY, {"owner": owner, "name": name, "cursor": cursor})
        issues = data["repository"]["issues"]
        for node in issues["nodes"]:
            cycle = [lab["name"] for lab in node["labels"]["nodes"]
                     if lab["name"] in LIFECYCLE_LABELS]
            if cycle:
                out.append({"number": node["number"], "title": node["title"],
                            "url": node["url"], "labels": cycle})
        if not issues["pageInfo"]["hasNextPage"]:
            return out
        cursor = issues["pageInfo"]["endCursor"]


def scan_stage_prs(owner, name, wanted):
    """Map issue number -> merged stage PRs claiming to fix it.

    Pages newest-first, stopping once the PR numbers drop below the smallest
    wanted issue number (nothing older can be its fix). Returns the map and
    whether the page cap cut the scan short.
    """
    found = {}
    if not wanted:
        return found, False
    floor, cursor, pages = min(wanted), None, 0
    while True:
        data = graphql(STAGE_PR_QUERY, {"owner": owner, "name": name, "cursor": cursor})
        prs = data["repository"]["pullRequests"]
        pages += 1
        for node in prs["nodes"]:
            for issue in claimed_issues(node) & wanted:
                found.setdefault(issue, []).append(
                    {"number": node["number"], "title": node["title"],
                     "url": node["url"], "merged": node.get("mergedAt") or "",
                     "oid": ((node.get("mergeCommit") or {}).get("oid")) or ""})
        numbers = [n["number"] for n in prs["nodes"]]
        if not prs["pageInfo"]["hasNextPage"] or (numbers and min(numbers) < floor):
            return found, False
        if pages >= PR_SCAN_MAX_PAGES:
            return found, True
        cursor = prs["pageInfo"]["endCursor"]


def pending_fixes(owner, name):
    """The release gate: open lifecycle issues whose claimed fix is merged on
    stage but not yet in main.

    Released-vs-pending is decided per merge commit with the compare API.
    main only ever advances by merging stage, so a stage merge commit that is
    not an ancestor of main (compare status "ahead"/"diverged") hasn't
    shipped, while "behind"/"identical" means a past release carried it.
    """
    issues = fetch_lifecycle_issues(owner, name)
    prs_by_issue, truncated = scan_stage_prs(
        owner, name, {i["number"] for i in issues})
    shipped = {}
    for prs in prs_by_issue.values():
        for pr in prs:
            oid = pr["oid"]
            if oid and oid not in shipped:
                cmp = rest("GET", f"/repos/{REPO_SLUG}/compare/main...{oid}") or {}
                shipped[oid] = cmp.get("status") in ("behind", "identical")
    blocked = []
    for issue in issues:
        pending = [pr for pr in prs_by_issue.get(issue["number"], [])
                   if pr["oid"] and not shipped.get(pr["oid"])]
        if pending:
            blocked.append(dict(issue, prs=pending))
    return {"issues": blocked, "truncated": truncated}


def promote_snapshot():
    with PROMOTE_LOCK:
        return {key: (list(val) if isinstance(val, list) else val)
                for key, val in PROMOTE.items()}


def build_model():
    owner, name = REPO_SLUG.split("/", 1)
    data = graphql(QUERY, {"owner": owner, "name": name})
    repo = data["repository"]

    releases = [{"tag": n.get("tagName") or "",
                 "name": n.get("name") or "",
                 "url": n.get("url") or "",
                 "published": n.get("publishedAt") or n.get("createdAt") or "",
                 "latest": bool(n.get("isLatest")),
                 "draft": bool(n.get("isDraft")),
                 "prerelease": bool(n.get("isPrerelease"))}
                for n in repo["releases"]["nodes"]]

    open_nodes = repo["open_prs"]["nodes"]
    merged_nodes = repo["merged_prs"]["nodes"]
    last = shape_last_release(merged_nodes[0] if merged_nodes else None, releases)
    waiting = fetch_waiting_runs()
    if last:
        for run in waiting:
            run["release_run"] = run["sha"] == last["sha"]

    return {
        "repo": REPO_SLUG,
        "generated": utcnow(),
        "fragments": parse_fragments(repo["fragments"]),
        "pending": pending_fixes(owner, name),
        "next": next_versions([n["name"] for n in repo["tags"]["nodes"]]),
        "promote": promote_snapshot(),
        "pr": shape_open_pr(open_nodes[0] if open_nodes else None),
        "last": last,
        "waiting": waiting,
        "releases": releases,
    }


# --------------------------------------------------------------------------
# Promote (a real release trigger)
# --------------------------------------------------------------------------

def plog(line):
    with PROMOTE_LOCK:
        PROMOTE["log"].append(line)
        if len(PROMOTE["log"]) > PROMOTE_LOG_CAP:
            del PROMOTE["log"][:len(PROMOTE["log"]) - PROMOTE_LOG_CAP]


def git_in(clone, *args):
    proc = subprocess.run(["git", "-C", clone, *args],
                          capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: "
                           f"{proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


def ensure_release_clone():
    """A private clone pinned to origin/stage, so promote never touches (or
    depends on the branch state of) the operator's working checkout. Only the
    dashboard writes here, and every promote starts by force-resetting it, so
    the hard reset/clean can never eat anyone's work."""
    clone = os.path.join(WORKDIR, "repo")
    if not os.path.isdir(os.path.join(clone, ".git")):
        url = origin_url(REPO_PATH)
        if not url:
            raise RuntimeError(f"could not read the origin remote of {REPO_PATH}")
        plog(f"[dashboard] cloning {url} into {clone} (first promote from this dashboard)")
        os.makedirs(WORKDIR, exist_ok=True)
        proc = subprocess.run(["git", "clone", "--quiet", url, clone],
                              capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"git clone failed: {proc.stderr.strip()}")
    plog("[dashboard] resetting the release clone to origin/stage")
    git_in(clone, "fetch", "--tags", "--prune", "--quiet", "origin")
    git_in(clone, "checkout", "-q", "-B", "stage", "origin/stage")
    git_in(clone, "reset", "--hard", "-q", "origin/stage")
    git_in(clone, "clean", "-fdq")
    return clone


def run_promote(spec):
    """Thread target: run the clone's own promote.sh (so its guards and its
    collator always match the stage being released) and stream its output."""
    ok = False
    try:
        clone = ensure_release_clone()
        script = os.path.join(clone, "scripts", "promote.sh")
        if not os.path.isfile(script):
            raise RuntimeError("scripts/promote.sh not found in the release clone")
        cmd = ["bash", script, spec, "--yes"]
        with open(script, encoding="utf-8") as handle:
            if "--no-watch" in handle.read():
                cmd.append("--no-watch")
            else:
                plog("[dashboard] note: this promote.sh predates --no-watch, so its "
                     "check-watch output follows; the dashboard tracks checks itself.")
        plog("[dashboard] running: promote.sh " + " ".join(cmd[2:]))
        with subprocess.Popen(cmd, cwd=clone, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True) as proc:
            for line in proc.stdout:
                line = line.rstrip("\n")
                plog(line)
                match = re.search(r"bump \w+: [0-9.]+ -> ([0-9.]+)", line)
                if match:
                    with PROMOTE_LOCK:
                        PROMOTE["version"] = match.group(1)
            returncode = proc.wait()
        ok = returncode == 0
        plog(f"[dashboard] promote.sh exited {returncode}")
    except Exception as exc:  # pylint: disable=broad-except
        plog(f"[dashboard] ERROR: {exc}")
    finally:
        with PROMOTE_LOCK:
            PROMOTE["running"] = False
            PROMOTE["ok"] = ok
            PROMOTE["finished"] = utcnow()


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------

app = Flask(__name__)


@app.route("/")
def index():
    return Response(PAGE, mimetype="text/html")


@app.route("/favicon.ico")
def favicon():
    return Response(status=204)


@app.route("/api/data")
def api_data():
    try:
        return jsonify(build_model())
    except Exception:  # pylint: disable=broad-except
        sys.stderr.write("api/data error:\n" + traceback.format_exc())
        return jsonify({"error": "An internal error has occurred."}), 200


@app.route("/api/promote", methods=["POST"])
def api_promote():
    """Start promote.sh in the release clone (a real push to stage + a PR)."""
    data = request.get_json(force=True, silent=True) or {}
    spec = data.get("spec")
    if spec not in ("patch", "minor", "major") and not (
            isinstance(spec, str) and SEMVER_RE.match(spec)):
        return jsonify({"error": "spec must be patch, minor, major, or x.y.z."}), 200
    with PROMOTE_LOCK:
        if PROMOTE["running"]:
            return jsonify({"error": "A promote is already running."}), 200
        PROMOTE.update({"running": True, "spec": spec, "log": [], "ok": None,
                        "version": spec if SEMVER_RE.match(spec) else None,
                        "started": utcnow(), "finished": None})
    threading.Thread(target=run_promote, args=(spec,), daemon=True).start()
    return jsonify({"ok": True})


@app.route("/api/merge", methods=["POST"])
def api_merge():
    """Merge the release PR into main (a real merge; prod deploys follow)."""
    data = request.get_json(force=True, silent=True) or {}
    number = data.get("number")
    if not isinstance(number, int):
        return jsonify({"error": "number is required."}), 200
    try:
        rest("PUT", f"/repos/{REPO_SLUG}/pulls/{number}/merge",
             {"merge_method": "merge"})
        return jsonify({"ok": True})
    except RuntimeError as err:
        # GitHub's refusal (checks changed, branch protection, conflict) is the
        # useful part of this error; pass it through.
        return jsonify({"error": str(err)}), 200
    except Exception:  # pylint: disable=broad-except
        sys.stderr.write("api/merge error:\n" + traceback.format_exc())
        return jsonify({"error": "An internal error has occurred."}), 200


@app.route("/api/approve", methods=["POST"])
def api_approve():
    """Approve a run's pending environment deployments (a real approval)."""
    data = request.get_json(force=True, silent=True) or {}
    run_id = data.get("run_id")
    if not isinstance(run_id, int):
        return jsonify({"error": "run_id is required."}), 200
    try:
        pending = rest("GET", f"/repos/{REPO_SLUG}/actions/runs/{run_id}/pending_deployments") or []
        env_ids = [(p.get("environment") or {}).get("id")
                   for p in pending if p.get("current_user_can_approve")]
        env_ids = [e for e in env_ids if e is not None]
        if not env_ids:
            return jsonify({"error": "GitHub reports no pending environment you can "
                                     "approve on this run (it may have just been "
                                     "approved, or you are not a required reviewer)."}), 200
        rest("POST", f"/repos/{REPO_SLUG}/actions/runs/{run_id}/pending_deployments",
             {"environment_ids": env_ids, "state": "approved",
              "comment": "Approved from the release dashboard"})
        return jsonify({"ok": True})
    except RuntimeError as err:
        return jsonify({"error": str(err)}), 200
    except Exception:  # pylint: disable=broad-except
        sys.stderr.write("api/approve error:\n" + traceback.format_exc())
        return jsonify({"error": "An internal error has occurred."}), 200


PAGE = r"""<!DOCTYPE html>
<html lang="en" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cabalmail Release Dashboard</title>
<style>
  :root{
    color-scheme: light dark;
    --page:#f9f9f7; --surface:#fcfcfb; --surface-2:#f2f1ec;
    --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
    --grid:#e1e0d9; --line:#c3c2b7; --border:rgba(11,11,11,0.10);
    --accent:#2a78d6;
    --good:#0ca30c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b; --neutral:#8b8a86;
    --merged:#8250df;
    --good-ink:#006300; --radius:10px;
  }
  :root[data-theme="dark"]{
    --page:#0d0d0d; --surface:#1a1a19; --surface-2:#242422;
    --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --line:#383835; --border:rgba(255,255,255,0.10);
    --accent:#3987e5;
    --good:#0ca30c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b; --neutral:#9a998f;
    --merged:#986ee2;
    --good-ink:#0ca30c;
  }
  @media (prefers-color-scheme: dark){
    :root[data-theme="auto"]{
      --page:#0d0d0d; --surface:#1a1a19; --surface-2:#242422;
      --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
      --grid:#2c2c2a; --line:#383835; --border:rgba(255,255,255,0.10);
      --accent:#3987e5; --neutral:#9a998f; --merged:#986ee2; --good-ink:#0ca30c;
    }
  }
  *{box-sizing:border-box} html,body{margin:0}
  body{background:var(--page); color:var(--ink); font-family:system-ui,-apple-system,"Segoe UI",sans-serif; font-size:14px; line-height:1.5; -webkit-font-smoothing:antialiased}
  .wrap{max-width:80%; margin:0 auto; padding:24px 20px 64px}
  header.top{display:flex; align-items:flex-start; gap:16px; flex-wrap:wrap; margin-bottom:4px}
  h1{font-size:20px; margin:0; font-weight:650; letter-spacing:-0.01em}
  .sub{color:var(--ink-2); font-size:13px; margin:2px 0 0}
  .updated{color:var(--muted); font-size:12px; margin:3px 0 0; font-variant-numeric:tabular-nums}
  .spacer{flex:1}
  .toolbar{display:flex; align-items:center; gap:8px}
  .themebtn{border:1px solid var(--border); background:var(--surface); color:var(--ink-2); border-radius:8px; padding:7px 12px; font:inherit; font-size:12px; cursor:pointer; height:34px}
  .themebtn:hover{color:var(--ink)}
  .refresh{display:inline-flex; position:relative}
  .rbtn{border:1px solid var(--border); background:var(--surface); color:var(--ink-2); height:34px; display:inline-flex; align-items:center; gap:6px; cursor:pointer; font:inherit; padding:0 11px}
  .rbtn:hover{color:var(--ink); background:var(--surface-2)}
  .rbtn svg{display:block}
  .rbtn.main{border-radius:8px 0 0 8px; border-right:none}
  .rbtn.chev{border-radius:0 8px 8px 0; padding:0 8px}
  .rbtn.chev.active{color:var(--accent); border-color:color-mix(in srgb,var(--accent) 45%,var(--border))}
  .rbtn:disabled{opacity:.6; cursor:default}
  .rbtn .intlbl{font-size:11.5px; color:var(--accent); font-weight:600; font-variant-numeric:tabular-nums}
  .spin{animation:spin .8s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  .rmenu{position:absolute; top:38px; right:0; min-width:170px; z-index:30; background:var(--surface); border:1px solid var(--border); border-radius:10px; box-shadow:0 8px 28px rgba(0,0,0,.18); padding:5px}
  .rmenu[hidden]{display:none}
  .rmenu-head{font-size:11px; text-transform:uppercase; letter-spacing:0.04em; color:var(--muted); padding:7px 10px 5px}
  .rmenu-item{display:flex; align-items:center; gap:9px; width:100%; text-align:left; border:none; background:none; font:inherit; font-size:13.5px; color:var(--ink); padding:8px 10px; border-radius:7px; cursor:pointer}
  .rmenu-item:hover{background:var(--surface-2)}
  .rmenu-item .chk{width:15px; color:var(--accent); font-size:12px}
  .rmenu-item[aria-selected="true"]{font-weight:600}
  .banner{border-radius:var(--radius); padding:12px 16px; margin-bottom:16px; font-size:13px}
  .banner.err{background:color-mix(in srgb,var(--critical) 12%,transparent); border:1px solid color-mix(in srgb,var(--critical) 40%,transparent); color:var(--critical)}
  .banner.warn{background:color-mix(in srgb,var(--warning) 13%,transparent); border:1px solid color-mix(in srgb,var(--warning) 50%,transparent); color:var(--ink)}
  .banner ul{margin:8px 0 0; padding-left:20px}
  .banner li{margin:0 0 4px}
  .banner li:last-child{margin-bottom:0}
  .stats{display:flex; gap:10px; flex-wrap:wrap; margin:18px 0 18px}
  .stat{background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:12px 16px; min-width:150px}
  .stat .n{font-size:22px; font-weight:650; letter-spacing:-0.02em}
  .stat .l{font-size:12px; color:var(--muted); margin-top:1px; display:flex; align-items:center; gap:6px}
  .stat.alert{border-color:color-mix(in srgb,var(--warning) 60%,var(--border)); box-shadow:0 0 0 1px color-mix(in srgb,var(--warning) 55%,transparent) inset}
  .card{background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:16px 18px; margin-bottom:18px}
  .card h2{font-size:13px; text-transform:uppercase; letter-spacing:0.05em; color:var(--muted); margin:0 0 12px; font-weight:650; display:flex; align-items:center; gap:10px}
  .card.attn{border-color:color-mix(in srgb,var(--warning) 60%,var(--border))}
  .cardrow{display:flex; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:10px}
  table{width:100%; border-collapse:collapse; background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); overflow:hidden}
  th,td{text-align:left; padding:9px 12px; border-bottom:1px solid var(--grid); vertical-align:top}
  th{font-size:11px; text-transform:uppercase; letter-spacing:0.04em; color:var(--muted); font-weight:600; white-space:nowrap}
  tbody tr:hover{background:var(--surface-2)}
  tbody tr:last-child td{border-bottom:none}
  td.num{font-variant-numeric:tabular-nums; white-space:nowrap}
  a{color:var(--accent); text-decoration:none}
  a:hover{text-decoration:underline}
  .pill{display:inline-flex; align-items:center; gap:5px; padding:2px 8px; border-radius:999px; font-size:11.5px; font-weight:600; line-height:1.6; white-space:nowrap; border:1px solid transparent}
  .pill.good{background:color-mix(in srgb,var(--good) 15%,transparent); color:var(--good-ink); border-color:color-mix(in srgb,var(--good) 40%,transparent)}
  .pill.warn{background:color-mix(in srgb,var(--warning) 18%,transparent); color:var(--ink); border-color:color-mix(in srgb,var(--warning) 50%,transparent)}
  .pill.bad{background:color-mix(in srgb,var(--critical) 12%,transparent); color:var(--critical); border-color:color-mix(in srgb,var(--critical) 40%,transparent)}
  .pill.info{background:color-mix(in srgb,var(--accent) 12%,transparent); color:var(--accent); border-color:color-mix(in srgb,var(--accent) 40%,transparent)}
  .pill.neutral{background:var(--surface-2); color:var(--ink-2); border-color:var(--border)}
  .pill.merged{background:color-mix(in srgb,var(--merged) 14%,transparent); color:var(--merged); border-color:color-mix(in srgb,var(--merged) 45%,transparent)}
  .abtn{font:inherit; font-size:12px; padding:4px 10px; border-radius:7px; border:1px solid var(--border); background:var(--surface); color:var(--ink-2); cursor:pointer; white-space:nowrap}
  .abtn:hover:not(:disabled){color:var(--ink); background:var(--surface-2)}
  .abtn:disabled{opacity:.45; cursor:default}
  .abtn.go:not(:disabled){color:var(--good-ink); border-color:color-mix(in srgb,var(--good) 45%,var(--border))}
  .abtn.big{font-size:13px; padding:8px 14px; font-weight:600}
  .fragcat{margin:0 0 12px}
  .fragcat h3{font-size:12px; margin:0 0 6px; text-transform:capitalize; display:flex; align-items:center; gap:8px}
  .frag{border-left:3px solid var(--grid); padding:2px 0 2px 12px; margin:0 0 8px; font-size:13px; color:var(--ink-2)}
  .frag .slug{color:var(--muted); font-size:11px; display:block; margin-bottom:1px}
  .frag ul{margin:0; padding-left:18px}
  .frag ul ul{margin-top:2px}
  .frag li{margin:0 0 3px}
  .frag li:last-child{margin-bottom:0}
  .frag b{color:var(--ink)}
  .promoterow{display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-top:14px; padding-top:12px; border-top:1px solid var(--grid)}
  .promoterow .hint{color:var(--muted); font-size:12px}
  .logbox{font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; line-height:1.55; background:var(--page); border:1px solid var(--border); border-radius:8px; padding:10px 12px; max-height:340px; overflow:auto; white-space:pre-wrap; word-break:break-word}
  details.plog{margin-top:12px}
  details.plog summary{cursor:pointer; font-size:12px; color:var(--muted)}
  .none{color:var(--muted)}
  .modal{position:fixed; inset:0; background:rgba(0,0,0,.42); display:flex; align-items:center; justify-content:center; z-index:90}
  .modal[hidden]{display:none}
  .mbox{background:var(--surface); border:1px solid var(--border); border-radius:12px; box-shadow:0 12px 40px rgba(0,0,0,.3); padding:18px 20px; width:560px; max-width:92vw}
  .mbox h3{margin:0 0 8px; font-size:15px}
  .mbody{color:var(--ink-2); font-size:13px}
  .mbody ul{margin:8px 0; padding-left:20px}
  .mrow{display:flex; gap:8px; margin-top:14px; align-items:center}
  .toast{position:fixed; bottom:22px; left:50%; transform:translateX(-50%); background:#1f1f1f; color:#fff; padding:10px 16px; border-radius:9px; font-size:13px; z-index:100; box-shadow:0 8px 28px rgba(0,0,0,.32); max-width:560px}
  .toast.bad{background:var(--critical)}
  .toast[hidden]{display:none}
  .empty{color:var(--muted); padding:22px 12px; text-align:center}
  footer{margin-top:28px; color:var(--muted); font-size:12px; border-top:1px solid var(--grid); padding-top:14px}
  code{background:var(--surface-2); padding:1px 5px; border-radius:5px; font-size:12px}
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <div>
      <h1>Cabalmail · Release Dashboard</h1>
      <p class="sub" id="sub">Loading…</p>
      <p class="updated" id="updated"></p>
    </div>
    <div class="spacer"></div>
    <div class="toolbar">
      <div class="refresh">
        <button class="rbtn main" id="refresh-btn" type="button" title="Refresh now">
          <svg id="refresh-icon" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>
          <span class="intlbl" id="int-label"></span>
        </button>
        <button class="rbtn chev" id="refresh-chev" type="button" title="Auto-refresh interval" aria-haspopup="true" aria-expanded="false">
          <svg width="10" height="10" viewBox="0 0 24 24" fill="currentColor"><path d="M12 15.5 5 8.5h14z"/></svg>
        </button>
        <div class="rmenu" id="refresh-menu" role="menu" hidden><div class="rmenu-head">Refresh interval</div><div id="rmenu-items"></div></div>
      </div>
      <button class="themebtn" id="themebtn" type="button">Theme: Auto</button>
    </div>
  </header>

  <div id="error"></div>
  <div class="stats" id="stats"></div>
  <div id="waiting"></div>
  <div id="flight"></div>
  <div id="lastrel"></div>
  <div id="releases"></div>

  <footer>
    The release cycle, derived live from GitHub on every refresh — nothing here is cached
    or stored. <b>Waiting for approval</b> lists <i>every</i> run paused on an environment
    gate, across all pages of the Actions tab, so a run can never hide below the fold;
    Approve uses the same API as the Actions tab (GitHub still enforces who may approve).
    <b>Release in flight</b> walks the cycle: pending <code>changelog.d/</code> fragments
    (read from <code>origin/stage</code>) → <b>Promote</b>, held while any open
    tester/fixer-cycle issue has a claimed fix (a <code>fixer/N-…</code> branch, a closing
    reference, or an "Addresses&nbsp;#N"-style mention) merged on stage but not yet in main —
    closing the issue, which the tester's retest pass does, releases the hold — which runs
    <code>scripts/promote.sh</code> with all its guards in a private clone pinned to
    stage (never your working checkout) → the stage→main PR with its checks →
    <b>Merge</b>, armed once checks are green (review the diff on GitHub first — this
    page deliberately shows no diffs). <b>Last release</b> tracks the deploy workflows
    the merge actually triggered — path filtering happens on GitHub's side, so a release
    that changed nothing under <code>apple/</code> simply has no <code>apple.yml</code>
    run here — until every run concludes and <code>release.yml</code> has published the
    GitHub release. Only the repo's own push-triggered workflows count: GitHub-managed
    runs (pages, default-setup CodeQL) and issue-triggered automation on the same
    commit are excluded. Promote, Merge, and Approve are real changes (a push to stage, a
    merge to main, a prod deploy) and each asks for confirmation; everything else is
    read-only. While something is in flight the page re-polls itself every few seconds
    regardless of the refresh-interval setting.
  </footer>
</div>

<div id="cfmmodal" class="modal" hidden>
  <div class="mbox" role="dialog" aria-modal="true" aria-labelledby="cfm-head">
    <h3 id="cfm-head"></h3>
    <div class="mbody" id="cfm-body"></div>
    <div class="mrow">
      <button class="abtn" id="cfm-cancel" type="button">Cancel</button>
      <span class="spacer" style="flex:1"></span>
      <button class="abtn go" id="cfm-go" type="button"></button>
    </div>
  </div>
</div>
<div id="toast" class="toast" hidden></div>

<script>
const INTERVALS=[{s:0,label:'Off'},{s:60,label:'1 minute'},{s:300,label:'5 minutes'},{s:900,label:'15 minutes'},{s:3600,label:'1 hour'}];
const CATS=['added','changed','deprecated','removed','fixed','security'];
const esc=s=>(s==null?'':String(s)).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

let MODEL=null, inFlight=false, intervalSec=0, timer=null, autoTimer=null, lastFetch=0;

/* Minimal Markdown for changelog fragments - the house style only uses
   bullets (with two-space continuation lines and one sub-bullet level),
   **bold**, *italic*, `code`, and [links](https://...), so a full renderer
   would be a dependency for nothing. Everything is HTML-escaped first. */
function mdInline(s){
  s=esc(s);
  const codes=[];
  s=s.replace(/`([^`]+)`/g,(_,c)=>{ codes.push(c); return '\u0000'+(codes.length-1)+'\u0000'; });
  s=s.replace(/\*\*([^*]+)\*\*/g,'<b>$1</b>');
  s=s.replace(/\*([^*]+)\*/g,'<i>$1</i>');
  s=s.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g,'<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s.replace(/\u0000(\d+)\u0000/g,(_,i)=>'<code>'+codes[+i]+'</code>');
}
function mdFragment(body){
  // "- " at column 0 starts an item, indented "- " a sub-item; any other line
  // is a hard-wrap continuation of whatever item came last.
  const items=[];
  for(const raw of body.split('\n')){
    const m=raw.match(/^(\s*)- (.*)$/);
    if(m && !m[1].length){ items.push({text:m[2], subs:[]}); }
    else if(m && items.length){ items[items.length-1].subs.push(m[2]); }
    else if(items.length){
      const it=items[items.length-1];
      if(it.subs.length) it.subs[it.subs.length-1]+=' '+raw.trim();
      else it.text+=' '+raw.trim();
    }
    else items.push({text:raw, subs:[]});
  }
  return '<ul>'+items.map(it=>'<li>'+mdInline(it.text)+
    (it.subs.length?'<ul>'+it.subs.map(s=>'<li>'+mdInline(s)+'</li>').join('')+'</ul>':'')+
    '</li>').join('')+'</ul>';
}

function ago(iso){
  const ms=Date.now()-new Date(iso).getTime();
  if(!isFinite(ms)) return '—';
  const d=Math.floor(ms/86400000);
  if(d>=1) return d+'d';
  const h=Math.floor(ms/3600000);
  if(h>=1) return h+'h';
  return Math.max(1,Math.floor(ms/60000))+'m';
}

async function fetchData(){
  if(inFlight) return; inFlight=true;
  const icon=document.getElementById('refresh-icon'), btn=document.getElementById('refresh-btn');
  icon.classList.add('spin'); btn.disabled=true;
  try{
    const res=await fetch('/api/data', {cache:'no-store'});
    const data=await res.json();
    if(data && data.error){ showError(data.error); } else { MODEL=data; clearError(); renderAll(); }
  }catch(e){ showError(String(e)); }
  finally{
    inFlight=false; lastFetch=Date.now(); icon.classList.remove('spin'); btn.disabled=false;
    const now=new Date();
    document.getElementById('updated').textContent='Updated '+now.toLocaleTimeString()+(intervalSec?` · auto-refresh every ${INTERVALS.find(i=>i.s===intervalSec).label.toLowerCase()}`:'');
    scheduleAuto();
  }
}
function showError(msg){ document.getElementById('error').innerHTML=`<div class="banner err"><b>Couldn't load data.</b> ${esc(msg)}`+(MODEL?' Showing the last successful result.':'')+`</div>`; }
function clearError(){ document.getElementById('error').innerHTML=''; }

/* Re-poll on our own while something is moving, independent of the user's
   interval setting: 3s during a promote, 10s while checks run, approvals
   wait, or deploy workflows are unfinished. */
function busy(m){
  if(!m) return 0;
  if(m.promote && m.promote.running) return 3;
  if((m.waiting||[]).length) return 10;
  if(m.pr && m.pr.checks_state!=='SUCCESS' && m.pr.checks_state!=='FAILURE' && m.pr.checks_state!=='ERROR') return 10;
  const l=m.last;
  if(l){
    if((l.runs||[]).some(r=>r.status!=='completed')) return 10;
    const fresh=l.merged && (Date.now()-new Date(l.merged).getTime())<3600000;
    if(fresh && (!l.release || !(l.runs||[]).length)) return 10;
  }
  return 0;
}
function scheduleAuto(){
  if(autoTimer){ clearTimeout(autoTimer); autoTimer=null; }
  const sec=busy(MODEL);
  if(sec && (intervalSec===0 || intervalSec>sec)) autoTimer=setTimeout(fetchData, sec*1000);
}

/* ---------- pills ---------- */
function runPill(r){
  if(r.status==='waiting') return '<span class="pill warn">awaiting approval</span>';
  if(r.status==='queued'||r.status==='requested'||r.status==='pending') return '<span class="pill info">queued</span>';
  if(r.status==='in_progress') return '<span class="pill info">running</span>';
  const c=r.conclusion;
  if(c==='success') return '<span class="pill good">success</span>';
  if(c==='skipped') return '<span class="pill neutral">skipped</span>';
  if(c==='cancelled') return '<span class="pill neutral">cancelled</span>';
  if(c==='action_required') return '<span class="pill warn">action required</span>';
  if(c) return `<span class="pill bad">${esc(c.replace(/_/g,' '))}</span>`;
  return `<span class="pill neutral">${esc(r.status||'?')}</span>`;
}
function checkPill(c){
  if(c.status!=='completed') return '<span class="pill info">running</span>';
  if(c.conclusion==='success') return '<span class="pill good">pass</span>';
  if(c.conclusion==='skipped'||c.conclusion==='neutral') return '<span class="pill neutral">skipped</span>';
  return `<span class="pill bad">${esc(c.conclusion||'?')}</span>`;
}

/* ---------- phase derivation (client-side, from observable state) ---------- */
function lastPhase(l){
  if(!l) return null;
  const runs=l.runs||[];
  if(runs.some(r=>r.status==='waiting')) return {key:'waiting', word:'awaiting approval', pill:'warn'};
  if(runs.some(r=>r.status!=='completed')) return {key:'deploying', word:'deploying', pill:'info'};
  const fresh=l.merged && (Date.now()-new Date(l.merged).getTime())<3600000;
  if(!runs.length && fresh) return {key:'starting', word:'workflows starting…', pill:'info'};
  const failed=runs.some(r=>!['success','skipped','cancelled'].includes(r.conclusion));
  if(failed) return {key:'failed', word:'needs attention', pill:'bad'};
  if(l.release) return {key:'done', word:'released', pill:'good'};
  if(fresh) return {key:'finishing', word:'publishing release…', pill:'info'};
  return {key:'done', word:'complete', pill:'good'};
}
function phaseSummary(m){
  if(m.promote && m.promote.running) return `promoting ${m.promote.spec}…`;
  if(m.pr){
    const s=m.pr.checks_state;
    const word=s==='SUCCESS'?'checks green — ready to merge':(s==='FAILURE'||s==='ERROR')?'checks failing':'checks running';
    return `release PR #${m.pr.number} open — ${word}`;
  }
  const lp=lastPhase(m.last);
  if(lp && lp.key!=='done') return `${m.last.version||('PR #'+m.last.pr.number)} ${lp.word}`;
  const n=(m.fragments||[]).length;
  const pend=((m.pending||{}).issues||[]).length;
  if(pend) return `promote held — ${pend} open issue${pend!==1?'s':''} with unreleased fixes on stage`;
  return `${n} pending fragment${n!==1?'s':''} · nothing in flight`;
}

function renderAll(){
  if(!MODEL) return;
  document.getElementById('sub').textContent=`${MODEL.repo} · ${phaseSummary(MODEL)} · data ${MODEL.generated}`;
  renderStats(); renderWaiting(); renderFlight(); renderLast(); renderReleases();
}

function renderStats(){
  const m=MODEL, lp=lastPhase(m.last);
  const prVal=m.pr?('#'+m.pr.number):'—';
  const prNote=m.pr?(m.pr.checks_state==='SUCCESS'?'checks green':(m.pr.checks_state==='FAILURE'||m.pr.checks_state==='ERROR')?'checks failing':'checks running'):'no release PR';
  const wait=(m.waiting||[]).length;
  document.getElementById('stats').innerHTML=
    `<div class="stat"><div class="n">${(m.fragments||[]).length}</div><div class="l">pending fragments</div></div>`+
    `<div class="stat"><div class="n">${esc(prVal)}</div><div class="l">release PR · ${esc(prNote)}</div></div>`+
    `<div class="stat${wait?' alert':''}"><div class="n">${wait}</div><div class="l">runs awaiting approval</div></div>`+
    `<div class="stat"><div class="n">${esc(m.last&&m.last.version?m.last.version:'—')}</div><div class="l">last release · ${esc(lp?lp.word:'none found')}</div></div>`;
}

/* ---------- waiting-for-approval (global, the original painpoint) ---------- */
function approveBtn(r){
  const can=(r.pending||[]).some(p=>p.can_approve);
  const envs=(r.pending||[]).map(p=>p.name).join(', ');
  return `<button class="abtn go" type="button" ${can?`onclick="askApprove(${r.id})"`:'disabled'} title="${can?`Approve the pending deployment (${esc(envs)})`:'GitHub reports you cannot approve this run'}">Approve…</button>`;
}
function renderWaiting(){
  const runs=MODEL.waiting||[];
  const el=document.getElementById('waiting');
  if(!runs.length){ el.innerHTML=''; return; }
  el.innerHTML=`<div class="card attn"><h2>Waiting for approval <span class="pill warn">${runs.length} run${runs.length!==1?'s':''}</span></h2>
    <table><thead><tr><th>Workflow</th><th>Run</th><th>Branch</th><th>Event</th><th>Age</th><th>Environment</th><th></th></tr></thead><tbody>`+
    runs.map(r=>`<tr>
      <td><b>${esc(r.name)}</b>${r.release_run?' <span class="pill merged">this release</span>':''}</td>
      <td><a href="${esc(r.url)}" target="_blank" rel="noopener">${esc(r.title)||'run '+r.id}</a></td>
      <td class="num">${esc(r.branch)}</td>
      <td class="num">${esc(r.event)}</td>
      <td class="num" title="${esc(r.created)}">${ago(r.created)}</td>
      <td>${(r.pending||[]).map(p=>`<span class="pill warn">${esc(p.name)}</span>`).join(' ')||'<span class="none">—</span>'}</td>
      <td>${approveBtn(r)}</td>
    </tr>`).join('')+`</tbody></table></div>`;
}

/* ---------- release in flight ---------- */
function promoteLogHtml(p, open){
  const log=(p.log||[]).join('\n');
  if(!log) return '';
  if(open) return `<div class="logbox" id="plog">${esc(log)}</div>`;
  return `<details class="plog"><summary>promote log (${p.ok===false?'failed':'finished'} ${esc(p.finished||'')})</summary><div class="logbox">${esc(log)}</div></details>`;
}
function renderFlight(){
  const m=MODEL, p=m.promote||{}, el=document.getElementById('flight');
  let inner='';
  if(p.running){
    inner=`<h2>Release in flight <span class="pill info">promoting ${esc(p.spec)}${p.version?' → '+esc(p.version):''}</span></h2>`+
      promoteLogHtml(p, true);
  } else if(m.pr){
    const pr=m.pr;
    const green=pr.checks_state==='SUCCESS';
    const conflicted=pr.mergeable==='CONFLICTING';
    const why=conflicted?'The PR has merge conflicts':!green?'Checks must pass first':'';
    inner=`<h2>Release in flight <span class="pill ${green?'good':(pr.checks_state==='FAILURE'||pr.checks_state==='ERROR')?'bad':'info'}">${green?'ready to merge':(pr.checks_state==='FAILURE'||pr.checks_state==='ERROR')?'checks failing':'checks running'}</span></h2>
      <div class="cardrow">
        <b>${esc(pr.title)}</b>
        <a href="${esc(pr.url)}" target="_blank" rel="noopener">#${pr.number}</a>
        <a href="${esc(pr.url)}/files" target="_blank" rel="noopener">review the diff ↗</a>
        <span class="spacer"></span>
        <button class="abtn go big" type="button" ${green&&!conflicted?`onclick="askMerge(${pr.number})"`:`disabled title="${esc(why)}"`}>Merge to main…</button>
      </div>`+
      (pr.merge_state==='BLOCKED'?`<div class="cardrow"><span class="pill warn">blocked</span><span class="none">GitHub reports the PR as blocked (branch protection); the merge may be refused.</span></div>`:'')+
      `<table><thead><tr><th>Check</th><th>Status</th></tr></thead><tbody>`+
      (pr.checks||[]).map(c=>`<tr><td>${c.url?`<a href="${esc(c.url)}" target="_blank" rel="noopener">${esc(c.name)}</a>`:esc(c.name)}</td><td>${checkPill(c)}</td></tr>`).join('')+
      ((pr.checks||[]).length?'':'<tr><td colspan="2" class="empty">No checks registered yet (they can lag PR creation by a few seconds).</td></tr>')+
      `</tbody></table>`+
      promoteLogHtml(p, false);
  } else {
    const frags=m.fragments||[], nxt=m.next||null;
    const byCat=CATS.map(c=>[c,frags.filter(f=>f.category===c)]).filter(([,fs])=>fs.length);
    const fragHtml=byCat.length?byCat.map(([c,fs])=>`<div class="fragcat"><h3>${esc(c)} <span class="pill neutral">${fs.length}</span></h3>`+
        fs.map(f=>`<div class="frag"><span class="slug">${esc(f.file)}</span>${mdFragment(f.body)}</div>`).join('')+`</div>`).join('')
      :`<div class="empty">No pending fragments on origin/stage — nothing to release.</div>`;
    const pend=(m.pending||{}).issues||[];
    const canPromote=frags.length>0 && !pend.length;
    const holdWhy=pend.length?`Held — ${pend.length} open issue${pend.length!==1?'s have':' has'} unreleased fixes on stage (see above)`:'No pending fragments — nothing to release';
    const btn=(spec)=>`<button class="abtn go big" type="button" ${canPromote?`onclick="askPromote('${spec}')"`:`disabled title="${esc(holdWhy)}"`}>${spec[0].toUpperCase()+spec.slice(1)}${nxt?` → ${esc(nxt[spec])}`:''}</button>`;
    const gateHtml=(pend.length?`<div class="banner warn"><b>Promote is held.</b> Stage carries merged fixes for ${pend.length} open issue${pend.length!==1?'s':''} the tester hasn't signed off on; releasing now would ship ${pend.length!==1?'them':'it'} to prod unretested. The hold clears when the issue${pend.length!==1?'s close':' closes'} (the retest pass does this).<ul>`+
        pend.map(i=>`<li><a href="${esc(i.url)}" target="_blank" rel="noopener">#${i.number}</a> ${esc(i.title)} ${(i.labels||[]).map(l=>`<span class="pill warn">${esc(l)}</span>`).join(' ')} — fix merged in ${(i.prs||[]).map(p=>`<a href="${esc(p.url)}" target="_blank" rel="noopener">PR #${p.number}</a>`).join(', ')}</li>`).join('')+
        `</ul></div>`:'')+
      ((m.pending||{}).truncated?`<div class="banner warn">The fix-PR scan hit its page cap, so the hold list may be incomplete — check the triage dashboard before promoting.</div>`:'');
    inner=`<h2>Release in flight <span class="pill ${pend.length?'warn':'neutral'}">${pend.length?'promote held — issues awaiting close':'none — next release preview'}</span></h2>`+gateHtml+fragHtml+
      `<div class="promoterow">${btn('patch')}${btn('minor')}${btn('major')}<span class="hint">${nxt?`latest tag ${esc(nxt.latest)} · `:''}runs promote.sh in the dashboard's private stage clone: collate → commit → push stage → open the stage→main PR</span></div>`+
      (p.ok===false?`<div class="banner err" style="margin-top:12px"><b>The last promote failed.</b> See the log below.</div>`:'')+
      promoteLogHtml(p, false);
  }
  el.innerHTML=`<div class="card">${inner}</div>`;
  const lb=document.getElementById('plog'); if(lb) lb.scrollTop=lb.scrollHeight;
}

/* ---------- last release ---------- */
function renderLast(){
  const l=MODEL.last, el=document.getElementById('lastrel');
  if(!l){ el.innerHTML=''; return; }
  const lp=lastPhase(l);
  const runs=l.runs||[];
  const waitingIds=new Set((MODEL.waiting||[]).map(r=>r.id));
  const rows=runs.map(r=>{
    const w=(MODEL.waiting||[]).find(x=>x.id===r.id);
    return `<tr>
      <td><b>${esc(r.name)}</b></td>
      <td><a href="${esc(r.url)}" target="_blank" rel="noopener">${esc(r.title)||'run '+r.id}</a></td>
      <td>${runPill(r)}</td>
      <td class="num" title="${esc(r.created)}">${ago(r.created)}</td>
      <td>${r.status==='waiting'?(w?approveBtn(w):'<span class="none">approve above</span>'):''}</td>
    </tr>`;}).join('');
  el.innerHTML=`<div class="card${lp.key==='waiting'?' attn':''}"><h2>Last release ${l.version?'· '+esc(l.version):''} <span class="pill ${lp.pill}">${esc(lp.word)}</span></h2>
    <div class="cardrow">
      <a href="${esc(l.pr.url)}" target="_blank" rel="noopener">PR #${l.pr.number}</a>
      <span class="none">merged ${ago(l.merged)} ago</span>
      ${l.release?`<a href="${esc(l.release.url)}" target="_blank" rel="noopener">GitHub release ↗</a>`:'<span class="none">no GitHub release yet</span>'}
    </div>
    <table><thead><tr><th>Workflow</th><th>Run</th><th>Status</th><th>Age</th><th></th></tr></thead><tbody>`+
    (rows||`<tr><td colspan="5" class="empty">No workflow runs registered for the merge commit yet.</td></tr>`)+
    `</tbody></table></div>`;
}

/* ---------- recent releases ---------- */
function renderReleases(){
  const rels=MODEL.releases||[], el=document.getElementById('releases');
  el.innerHTML=`<div class="card"><h2>Recent releases</h2>
    <table><thead><tr><th>Version</th><th>Name</th><th>Published</th><th></th></tr></thead><tbody>`+
    (rels.length?rels.map(r=>`<tr>
      <td class="num"><a href="${esc(r.url)}" target="_blank" rel="noopener">${esc(r.tag)}</a></td>
      <td>${esc(r.name)||'<span class="none">—</span>'}</td>
      <td class="num" title="${esc(r.published)}">${ago(r.published)} ago</td>
      <td>${r.latest?'<span class="pill good">latest</span>':''}${r.draft?' <span class="pill neutral">draft</span>':''}${r.prerelease?' <span class="pill warn">pre-release</span>':''}</td>
    </tr>`).join(''):`<tr><td colspan="4" class="empty">No releases found.</td></tr>`)+
    `</tbody></table></div>`;
}

/* ---------- actions (all confirmed; all real changes on GitHub) ---------- */
let toastTimer=null, cfmAction=null;
function toast(msg, bad){
  const t=document.getElementById('toast'); t.textContent=msg; t.classList.toggle('bad', !!bad); t.hidden=false;
  if(toastTimer) clearTimeout(toastTimer); toastTimer=setTimeout(()=>{ t.hidden=true; }, bad?8000:3500);
}
function postJSON(url, payload){
  return fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
    .then(r=>r.json()).catch(e=>({error:String(e)}));
}
function confirmDialog(head, bodyHtml, goLabel, action){
  cfmAction=action;
  document.getElementById('cfm-head').textContent=head;
  document.getElementById('cfm-body').innerHTML=bodyHtml;
  document.getElementById('cfm-go').textContent=goLabel;
  document.getElementById('cfm-go').disabled=false;
  document.getElementById('cfmmodal').hidden=false;
}
function hideCfm(){ document.getElementById('cfmmodal').hidden=true; cfmAction=null; }
document.getElementById('cfm-cancel').addEventListener('click', hideCfm);
document.getElementById('cfmmodal').addEventListener('click',e=>{ if(e.target===e.currentTarget) hideCfm(); });
document.addEventListener('keydown',e=>{ if(e.key==='Escape' && !document.getElementById('cfmmodal').hidden) hideCfm(); });
document.getElementById('cfm-go').addEventListener('click', async ()=>{
  if(!cfmAction) return;
  document.getElementById('cfm-go').disabled=true;
  await cfmAction();
  hideCfm();
});

function askPromote(spec){
  const m=MODEL, ver=m.next?m.next[spec]:null, n=(m.fragments||[]).length;
  const counts=CATS.map(c=>[c,(m.fragments||[]).filter(f=>f.category===c).length]).filter(([,k])=>k)
    .map(([c,k])=>`${k} ${c}`).join(', ');
  confirmDialog(`Promote ${spec}${ver?` → ${ver}`:''}?`,
    `<p>Runs <code>promote.sh ${esc(spec)} --yes</code> in the dashboard's private stage clone. This immediately:</p>
     <ul><li>collates ${n} fragment${n!==1?'s':''} (${esc(counts)}) into CHANGELOG.md</li>
     <li>commits on <code>stage</code> and <b>pushes to origin</b></li>
     <li>opens (or reuses) the stage→main PR</li></ul>
     <p>promote.sh recomputes the version after a fresh tag fetch, so the number can differ from the preview if a tag just landed. Merging to main stays a separate step.</p>`,
    `Promote ${spec}`, async ()=>{
      const d=await postJSON('/api/promote',{spec});
      if(d && d.ok){ toast(`Promote ${spec} started.`); await fetchData(); }
      else toast('Promote failed to start: '+((d&&d.error)||'unknown error'), true);
    });
}
function askMerge(number){
  confirmDialog(`Merge release PR #${number} into main?`,
    `<p>Merges <code>stage</code> into <code>main</code> (merge commit). The prod deploy
     workflows start immediately and will pause at their <code>gate-prod</code> approval,
     which then appears here for you to approve.</p>
     <p>Have you reviewed the diff on GitHub?</p>`,
    'Merge to main', async ()=>{
      const d=await postJSON('/api/merge',{number});
      if(d && d.ok){ toast(`Merged #${number} — deploy workflows starting.`); await fetchData(); }
      else toast('Merge failed: '+((d&&d.error)||'unknown error'), true);
    });
}
function askApprove(runId){
  const r=(MODEL.waiting||[]).find(x=>x.id===runId);
  const envs=r?(r.pending||[]).filter(p=>p.can_approve).map(p=>esc(p.name)).join(', '):'';
  confirmDialog(`Approve ${r?r.name:'run '+runId}?`,
    `<p>Approves the pending deployment${envs.includes(',')?'s':''} to <b>${envs||'?'}</b> for
     <a href="${r?esc(r.url):'#'}" target="_blank" rel="noopener">${r?esc(r.title)||('run '+runId):('run '+runId)}</a>
     (branch <code>${r?esc(r.branch):'?'}</code>). The workflow continues immediately.</p>`,
    'Approve deployment', async ()=>{
      const d=await postJSON('/api/approve',{run_id:runId});
      if(d && d.ok){ toast('Approved — the workflow is continuing.'); await fetchData(); }
      else toast('Approve failed: '+((d&&d.error)||'unknown error'), true);
    });
}

/* ---------- theme ---------- */
const tb=document.getElementById('themebtn'); const modes=['auto','light','dark'];
let mi=Math.max(0, modes.indexOf(new URLSearchParams(location.search).get('theme')));
document.documentElement.dataset.theme=modes[mi]; tb.textContent='Theme: '+modes[mi][0].toUpperCase()+modes[mi].slice(1);
tb.addEventListener('click',()=>{ mi=(mi+1)%3; document.documentElement.dataset.theme=modes[mi]; tb.textContent='Theme: '+modes[mi][0].toUpperCase()+modes[mi].slice(1); });

/* ---------- refresh + interval ---------- */
const menu=document.getElementById('refresh-menu'), chev=document.getElementById('refresh-chev');
document.getElementById('refresh-btn').addEventListener('click', fetchData);
chev.addEventListener('click',e=>{ e.stopPropagation(); const show=menu.hasAttribute('hidden'); menu.toggleAttribute('hidden', !show); chev.setAttribute('aria-expanded', String(show)); });
document.addEventListener('click',()=>{ menu.setAttribute('hidden',''); chev.setAttribute('aria-expanded','false'); });
menu.addEventListener('click',e=>e.stopPropagation());
function renderIntervalMenu(){
  document.getElementById('rmenu-items').innerHTML=INTERVALS.map(i=>`<button class="rmenu-item" role="menuitemradio" data-int="${i.s}" aria-selected="${i.s===intervalSec}"><span class="chk">${i.s===intervalSec?'✓':''}</span>${i.label}</button>`).join('');
  document.querySelectorAll('.rmenu-item').forEach(b=>b.addEventListener('click',()=>{ setIntervalSec(parseInt(b.dataset.int,10)); menu.setAttribute('hidden',''); chev.setAttribute('aria-expanded','false'); }));
}
function setIntervalSec(sec){
  intervalSec=sec; if(timer){ clearInterval(timer); timer=null; } if(sec>0){ timer=setInterval(fetchData, sec*1000); }
  const short={0:'',60:'1m',300:'5m',900:'15m',3600:'1h'};
  document.getElementById('int-label').textContent=short[sec]||''; chev.classList.toggle('active', sec>0); renderIntervalMenu();
}
/* Refresh when the tab regains focus, throttled to once per 15s so rapid
   window-switching does not hammer the GitHub API. */
function focusRefresh(){ if(!document.hidden && Date.now()-lastFetch>15000) fetchData(); }
document.addEventListener('visibilitychange', focusRefresh);
window.addEventListener('focus', focusRefresh);

renderIntervalMenu(); fetchData();
</script>
</body>
</html>
"""


def main():
    global REPO_SLUG, REPO_PATH, WORKDIR
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="Path to a checkout whose origin remote names the GitHub repo "
                         "(default: this script's repo)")
    ap.add_argument("--repo-slug", help="GitHub owner/name (overrides --repo detection)")
    ap.add_argument("--workdir", default=os.path.expanduser("~/.cache/cabalmail-release-dashboard"),
                    help="Directory for the dashboard's private stage clone used by "
                         "Promote (default: ~/.cache/cabalmail-release-dashboard)")
    ap.add_argument("--host", default="127.0.0.1", help="Bind host (default 127.0.0.1)")
    ap.add_argument("--port", type=int, default=5059,
                    help="Bind port (default 5059; Apple dashboard 5057, triage 5058)")
    args = ap.parse_args()

    REPO_PATH = args.repo
    WORKDIR = args.workdir
    REPO_SLUG = args.repo_slug or detect_repo_slug(args.repo)
    if not REPO_SLUG:
        sys.exit("Could not determine the GitHub repo from the origin remote; pass --repo-slug owner/name.")

    sys.stderr.write(f"Serving Cabalmail release dashboard on http://{args.host}:{args.port}  "
                     f"(repo: {REPO_SLUG}; promote clone: {os.path.join(WORKDIR, 'repo')})\n")
    app.run(host=args.host, port=args.port, debug=False, threaded=True)


if __name__ == "__main__":
    main()
