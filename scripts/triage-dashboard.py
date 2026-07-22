#!/usr/bin/env python3
"""Flask app for the Cabalmail tester/fixer triage dashboard.

Companion to apple-dashboard-app.py (same chrome: refresh button with an
auto-refresh chevron menu, theme toggle, stat tiles) but pointed at GitHub
Issues instead of App Store Connect. It fixes the triage deficiencies of the
native Issues UI:

  * shows only open issues that are part of the tester/fixer cycle (bearing at
    least one lifecycle label: tester-found / accepted / fix-in-review /
    needs-retest) - closed and unrelated issues are omitted
  * each lifecycle label gets its own fixed column, so a label reads in the
    same place on every row instead of wrapping through an inline label list
  * related PRs (discovered via cross-reference events, since the fixer does
    not use closing keywords) are shown per row with their open/merged/closed
    state, linked directly - no drilling into the issue to find them
  * triage actions per row (these make real changes on GitHub): Accept adds
    the `accepted` label so the nightly fixer picks the issue up; Close...
    posts a required comment and then closes the issue as not-planned or
    completed

All GitHub data is fetched live on each refresh through `gh api graphql`
(uses your existing gh login); set GITHUB_TOKEN or GH_TOKEN to bypass the gh
CLI and call the API directly instead.

Run:

    pip install flask
    python3 scripts/triage-dashboard.py          # from anywhere in the repo
    # then open http://127.0.0.1:5058

The repo slug is read from the `origin` remote of --repo (default: the
directory containing this script's repo); override with --repo-slug. Listens
on port 5058 so it can run alongside the Apple release dashboard (5057).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import traceback
import urllib.request
from datetime import datetime, timezone

try:
    from flask import Flask, jsonify, Response, request
except ImportError:
    sys.exit("Flask is not installed. Run: pip install flask")


# Lifecycle labels, in pipeline order. Each one becomes a column.
DEFAULT_STAGES = ["tester-found", "accepted", "fix-in-review", "needs-retest"]
# Fallback colors (GitHub label colors) if the repo query can't supply one.
FALLBACK_COLORS = {
    "tester-found": "fbca04",
    "accepted": "5319e7",
    "fix-in-review": "e99695",
    "needs-retest": "0e8a16",
}

QUERY = """
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    labels(first: 100) { nodes { name color } }
    issues(states: OPEN, first: 100, after: $cursor,
           orderBy: {field: CREATED_AT, direction: DESC}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url createdAt updatedAt
        labels(first: 20) { nodes { name color } }
        timelineItems(itemTypes: [CROSS_REFERENCED_EVENT], first: 100) {
          nodes {
            ... on CrossReferencedEvent {
              source {
                ... on PullRequest { number title url state isDraft }
              }
            }
          }
        }
      }
    }
  }
}
"""

REPO_SLUG = None
STAGES = DEFAULT_STAGES
ACCEPT_LABEL = "accepted"


def detect_repo_slug(repo_path):
    """Derive owner/name from the origin remote of the given checkout."""
    try:
        url = subprocess.run(
            ["git", "-C", repo_path, "remote", "get-url", "origin"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    match = re.search(r"github\.com[:/]([^/]+)/([^/\s]+?)(?:\.git)?$", url)
    return f"{match.group(1)}/{match.group(2)}" if match else None


def graphql(variables):
    """Run QUERY against the GitHub GraphQL API and return the `data` dict.

    Prefers a token in GITHUB_TOKEN/GH_TOKEN (direct HTTPS call); otherwise
    shells out to `gh api graphql` so the user's normal gh login is used.
    """
    token = os.environ.get("GITHUB_TOKEN", "").strip() or os.environ.get("GH_TOKEN", "").strip()
    if token:
        req = urllib.request.Request(
            "https://api.github.com/graphql",
            data=json.dumps({"query": QUERY, "variables": variables}).encode(),
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
        cmd = ["gh", "api", "graphql", "-f", f"query={QUERY}"]
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


def rest(method, path, payload):
    """Call a GitHub REST endpoint (mutations), via token or the gh CLI."""
    token = os.environ.get("GITHUB_TOKEN", "").strip() or os.environ.get("GH_TOKEN", "").strip()
    if token:
        req = urllib.request.Request(
            "https://api.github.com" + path,
            data=json.dumps(payload).encode(),
            headers={"Authorization": f"bearer {token}",
                     "Content-Type": "application/json",
                     "Accept": "application/vnd.github+json"},
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp.read()
        except urllib.error.HTTPError as err:
            try:
                detail = json.load(err).get("message", "")
            except Exception:  # pylint: disable=broad-except
                detail = ""
            raise RuntimeError(f"GitHub returned HTTP {err.code}: {detail or err.reason}") from err
        return
    if not shutil.which("gh"):
        raise RuntimeError(
            "Neither GITHUB_TOKEN/GH_TOKEN is set nor is the `gh` CLI on PATH. "
            "Install gh and run `gh auth login`, or export a token."
        )
    proc = subprocess.run(
        ["gh", "api", "--method", method, path.lstrip("/"), "--input", "-"],
        input=json.dumps(payload), capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gh api failed: {proc.stderr.strip() or proc.stdout.strip()}")


def build_model():
    """Fetch open issues and shape the triage model served at /api/data."""
    owner, name = REPO_SLUG.split("/", 1)
    label_colors = dict(FALLBACK_COLORS)
    nodes, cursor, total = [], None, 0
    while True:
        data = graphql({"owner": owner, "name": name, "cursor": cursor})
        repo = data["repository"]
        for lab in repo["labels"]["nodes"]:
            label_colors[lab["name"]] = lab["color"]
        issues = repo["issues"]
        total = issues["totalCount"]
        nodes.extend(issues["nodes"])
        if not issues["pageInfo"]["hasNextPage"]:
            break
        cursor = issues["pageInfo"]["endCursor"]

    rows = []
    for node in nodes:
        labels = [(l["name"], l["color"]) for l in node["labels"]["nodes"]]
        names = [n for n, _ in labels]
        stages = [s for s in STAGES if s in names]
        if not stages:
            continue
        prs, seen = [], set()
        for item in node["timelineItems"]["nodes"]:
            src = (item or {}).get("source") or {}
            if src.get("number") and src["number"] not in seen:
                seen.add(src["number"])
                prs.append({
                    "number": src["number"],
                    "title": src.get("title", ""),
                    "url": src.get("url", ""),
                    "state": "draft" if (src.get("isDraft") and src.get("state") == "OPEN")
                             else src.get("state", "").lower(),
                })
        prs.sort(key=lambda p: p["number"])
        rows.append({
            "number": node["number"],
            "title": node["title"],
            "url": node["url"],
            "created": node["createdAt"],
            "updated": node["updatedAt"],
            "stages": stages,
            "other_labels": [{"name": n, "color": c} for n, c in labels
                             if n not in STAGES],
            "prs": prs,
        })

    counts = {s: sum(1 for r in rows if s in r["stages"]) for s in STAGES}
    return {
        "repo": REPO_SLUG,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "stages": [{"key": s, "color": label_colors.get(s, "8b8a86")} for s in STAGES],
        "accept_label": ACCEPT_LABEL,
        "issues": rows,
        "open_total": total,
        "counts": counts,
    }


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
    except Exception as exc:  # pylint: disable=broad-except
        sys.stderr.write("api/data error:\n" + traceback.format_exc())
        return jsonify({"error": str(exc)}), 200


@app.route("/api/accept", methods=["POST"])
def api_accept():
    """Add the accept label to an issue (a real GitHub change)."""
    data = request.get_json(force=True, silent=True) or {}
    number = data.get("number")
    if not isinstance(number, int):
        return jsonify({"error": "number is required."}), 200
    try:
        rest("POST", f"/repos/{REPO_SLUG}/issues/{number}/labels",
             {"labels": [ACCEPT_LABEL]})
        return jsonify({"ok": True})
    except Exception as exc:  # pylint: disable=broad-except
        sys.stderr.write("api/accept error:\n" + traceback.format_exc())
        return jsonify({"error": str(exc)}), 200


@app.route("/api/close", methods=["POST"])
def api_close():
    """Post a comment on an issue, then close it (a real GitHub change)."""
    data = request.get_json(force=True, silent=True) or {}
    number = data.get("number")
    comment = (data.get("comment") or "").strip()
    reason = data.get("reason")
    if not isinstance(number, int):
        return jsonify({"error": "number is required."}), 200
    if not comment:
        return jsonify({"error": "A comment is required to close from here."}), 200
    if reason not in ("not_planned", "completed"):
        return jsonify({"error": "reason must be not_planned or completed."}), 200
    try:
        rest("POST", f"/repos/{REPO_SLUG}/issues/{number}/comments", {"body": comment})
        rest("PATCH", f"/repos/{REPO_SLUG}/issues/{number}",
             {"state": "closed", "state_reason": reason})
        return jsonify({"ok": True})
    except Exception as exc:  # pylint: disable=broad-except
        sys.stderr.write("api/close error:\n" + traceback.format_exc())
        return jsonify({"error": str(exc)}), 200


PAGE = r"""<!DOCTYPE html>
<html lang="en" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cabalmail Triage Dashboard</title>
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
  .wrap{max-width:1220px; margin:0 auto; padding:24px 20px 64px}
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
  .stats{display:flex; gap:10px; flex-wrap:wrap; margin:18px 0 18px}
  .stat{background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:12px 16px; min-width:130px; font:inherit; color:var(--ink); text-align:left; cursor:pointer}
  .stat:hover{background:var(--surface-2)}
  .stat[aria-pressed="true"]{border-color:color-mix(in srgb,var(--accent) 55%,var(--border)); box-shadow:0 0 0 1px color-mix(in srgb,var(--accent) 55%,transparent) inset}
  .stat .n{font-size:22px; font-weight:650; letter-spacing:-0.02em}
  .stat .l{font-size:12px; color:var(--muted); margin-top:1px; display:flex; align-items:center; gap:6px}
  .dot{width:9px; height:9px; border-radius:50%; display:inline-block; flex:0 0 auto}
  .controls{display:flex; gap:10px; flex-wrap:wrap; align-items:center; margin-bottom:12px}
  .controls input{font:inherit; font-size:13px; padding:6px 10px; border-radius:8px; border:1px solid var(--border); background:var(--surface); color:var(--ink); width:280px}
  .controls label{font-size:12px; color:var(--muted)}
  table{width:100%; border-collapse:collapse; background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); overflow:hidden}
  th,td{text-align:left; padding:10px 12px; border-bottom:1px solid var(--grid); vertical-align:top}
  th{font-size:11px; text-transform:uppercase; letter-spacing:0.04em; color:var(--muted); font-weight:600; user-select:none; white-space:nowrap; vertical-align:bottom}
  th.sortable{cursor:pointer}
  th.sortable:hover{color:var(--ink-2)}
  th.stagecol, td.stagecol{text-align:center}
  td.titlecol{min-width:260px}
  tbody tr:hover{background:var(--surface-2)}
  tbody tr:last-child td{border-bottom:none}
  td.num{font-variant-numeric:tabular-nums; white-space:nowrap}
  a{color:var(--accent); text-decoration:none}
  a:hover{text-decoration:underline}
  .ititle{font-weight:600; color:var(--ink)}
  .ititle:hover{color:var(--accent)}
  .stagemark{font-size:15px; line-height:1}
  .ghlabel{display:inline-block; font-size:10.5px; font-weight:600; padding:1px 7px; border-radius:999px; border:1px solid; margin:1px 3px 1px 0; color:var(--ink-2); white-space:nowrap}
  .pill{display:inline-flex; align-items:center; gap:5px; padding:2px 8px; border-radius:999px; font-size:11.5px; font-weight:600; line-height:1.6; white-space:nowrap; border:1px solid transparent}
  .pill .ic{font-size:10px; line-height:1}
  .pill.open{background:color-mix(in srgb,var(--good) 15%,transparent); color:var(--good-ink); border-color:color-mix(in srgb,var(--good) 40%,transparent)}
  .pill.merged{background:color-mix(in srgb,var(--merged) 14%,transparent); color:var(--merged); border-color:color-mix(in srgb,var(--merged) 45%,transparent)}
  .pill.closed{background:color-mix(in srgb,var(--critical) 12%,transparent); color:var(--critical); border-color:color-mix(in srgb,var(--critical) 40%,transparent)}
  .pill.draft{background:var(--surface-2); color:var(--ink-2); border-color:var(--border)}
  .prline{display:flex; align-items:center; gap:6px; white-space:nowrap}
  .prline + .prline{margin-top:4px}
  .prnum{font-variant-numeric:tabular-nums}
  .none{color:var(--muted)}
  .abtn{font:inherit; font-size:12px; padding:4px 10px; border-radius:7px; border:1px solid var(--border); background:var(--surface); color:var(--ink-2); cursor:pointer; white-space:nowrap}
  .abtn:hover:not(:disabled){color:var(--ink); background:var(--surface-2)}
  .abtn:disabled{opacity:.45; cursor:default}
  .abtn.accept:not(:disabled){color:var(--good-ink); border-color:color-mix(in srgb,var(--good) 40%,var(--border))}
  .abtn.danger:hover:not(:disabled){color:var(--critical); border-color:color-mix(in srgb,var(--critical) 45%,var(--border)); background:var(--surface)}
  .actcell{display:flex; gap:6px}
  .modal{position:fixed; inset:0; background:rgba(0,0,0,.42); display:flex; align-items:center; justify-content:center; z-index:90}
  .modal[hidden]{display:none}
  .mbox{background:var(--surface); border:1px solid var(--border); border-radius:12px; box-shadow:0 12px 40px rgba(0,0,0,.3); padding:18px 20px; width:520px; max-width:92vw}
  .mbox h3{margin:0 0 4px; font-size:15px}
  .mtitle{color:var(--ink-2); font-size:13px; margin:0 0 12px}
  .mbox textarea{width:100%; min-height:90px; font:inherit; font-size:13px; padding:8px 10px; border-radius:8px; border:1px solid var(--border); background:var(--page); color:var(--ink); resize:vertical}
  .mrow{display:flex; gap:8px; margin-top:12px; align-items:center; flex-wrap:wrap}
  .toast{position:fixed; bottom:22px; left:50%; transform:translateX(-50%); background:#1f1f1f; color:#fff; padding:10px 16px; border-radius:9px; font-size:13px; z-index:100; box-shadow:0 8px 28px rgba(0,0,0,.32); max-width:560px}
  .toast.bad{background:var(--critical)}
  .toast[hidden]{display:none}
  .empty{color:var(--muted); padding:30px 12px; text-align:center}
  footer{margin-top:28px; color:var(--muted); font-size:12px; border-top:1px solid var(--grid); padding-top:14px}
  code{background:var(--surface-2); padding:1px 5px; border-radius:5px; font-size:12px}
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <div>
      <h1>Cabalmail · Triage Dashboard</h1>
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

  <div class="controls">
    <input id="f-q" placeholder="Filter title / number / label / PR…">
    <span class="spacer" style="flex:1"></span><label id="f-count"></label>
  </div>
  <div id="issue-table"></div>

  <footer>
    Open issues bearing at least one lifecycle label — <code>tester-found</code> →
    <code>accepted</code> → <code>fix-in-review</code> → <code>needs-retest</code> — with one
    column per label so each reads in a fixed position. Other open issues (and everything
    closed) are omitted. <b>PRs</b> are discovered from GitHub cross-reference events (the
    fixer links issues without closing keywords, so GitHub's "linked PR" field stays empty);
    a PR that merely mentions the issue also appears here. Click a stat tile to filter to
    that stage; click it again to clear. All links open in a new tab.
    <b>Accept</b> adds the <code>accepted</code> label (the nightly fixer picks it up);
    <b>Close…</b> posts your comment and then closes the issue — both are real GitHub changes.
  </footer>
</div>

<div id="closemodal" class="modal" hidden>
  <div class="mbox" role="dialog" aria-modal="true" aria-labelledby="cm-head">
    <h3 id="cm-head">Close</h3>
    <p class="mtitle" id="cm-title"></p>
    <textarea id="cm-comment" placeholder="Why is this being closed? Posted as an issue comment before closing (required)."></textarea>
    <div class="mrow">
      <button class="abtn" id="cm-cancel" type="button">Cancel</button>
      <span class="spacer" style="flex:1"></span>
      <button class="abtn danger" id="cm-notplanned" type="button">Close as not planned</button>
      <button class="abtn" id="cm-completed" type="button">Close as completed</button>
    </div>
  </div>
</div>
<div id="toast" class="toast" hidden></div>

<script>
const PR_ROLE={open:'open', merged:'merged', closed:'closed', draft:'draft'};
const PR_ICON={open:'●', merged:'⇗', closed:'✕', draft:'○'};
const INTERVALS=[{s:0,label:'Off'},{s:60,label:'1 minute'},{s:300,label:'5 minutes'},{s:900,label:'15 minutes'},{s:3600,label:'1 hour'}];
const esc=s=>(s==null?'':String(s)).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

let MODEL=null, activeStage=null, sortKey='updated', sortDir=-1, inFlight=false, intervalSec=0, timer=null;

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
    inFlight=false; icon.classList.remove('spin'); btn.disabled=false;
    const now=new Date();
    document.getElementById('updated').textContent='Updated '+now.toLocaleTimeString()+(intervalSec?` · auto-refresh every ${INTERVALS.find(i=>i.s===intervalSec).label.toLowerCase()}`:'');
  }
}
function showError(msg){ document.getElementById('error').innerHTML=`<div class="banner err"><b>Couldn't load data.</b> ${esc(msg)}`+(MODEL?' Showing the last successful result.':'')+`</div>`; }
function clearError(){ document.getElementById('error').innerHTML=''; }

function renderAll(){
  if(!MODEL) return;
  document.getElementById('sub').textContent=`${MODEL.repo} · ${MODEL.issues.length} of ${MODEL.open_total} open issues are in the tester/fixer cycle · data ${MODEL.generated}`;
  renderStats(); renderRows();
}

function renderStats(){
  const tiles=[`<button class="stat" data-stage="" aria-pressed="${activeStage===null}"><div class="n">${MODEL.issues.length}</div><div class="l">All in cycle</div></button>`]
    .concat(MODEL.stages.map(s=>`<button class="stat" data-stage="${esc(s.key)}" aria-pressed="${activeStage===s.key}">`+
      `<div class="n">${MODEL.counts[s.key]||0}</div><div class="l"><span class="dot" style="background:#${esc(s.color)}"></span>${esc(s.key)}</div></button>`));
  const el=document.getElementById('stats');
  el.innerHTML=tiles.join('');
  el.querySelectorAll('.stat').forEach(b=>b.addEventListener('click',()=>{
    const s=b.dataset.stage||null;
    activeStage=(s===activeStage)?null:s;
    renderStats(); renderRows();
  }));
}

function th(key,label,cls){
  const sortable=key?' sortable':'';
  const a=key&&sortKey===key?(sortDir===1?' ▲':' ▼'):'';
  return `<th class="${cls||''}${sortable}"${key?` onclick="setSort('${key}')"`:''}>${esc(label)}${a}</th>`;
}
function setSort(key){ if(sortKey===key) sortDir*=-1; else {sortKey=key; sortDir=(key==='title')?1:-1;} renderRows(); }

function prCell(r){
  if(!r.prs.length) return '<span class="none">—</span>';
  return r.prs.map(p=>`<div class="prline">`+
    `<a class="prnum" href="${esc(p.url)}" target="_blank" rel="noopener" title="${esc(p.title)}">#${p.number}</a>`+
    `<span class="pill ${PR_ROLE[p.state]||'draft'}"><span class="ic">${PR_ICON[p.state]||'○'}</span>${esc(p.state)}</span>`+
    `</div>`).join('');
}
function actCell(r){
  const accepted=r.stages.includes(MODEL.accept_label);
  return `<div class="actcell">`+
    `<button class="abtn accept" type="button" ${accepted
      ?'disabled title="Already accepted"'
      :`onclick="acceptIssue(${r.number},this)" title="Add the ${esc(MODEL.accept_label)} label — queues the nightly fixer"`}>Accept</button>`+
    `<button class="abtn danger" type="button" onclick="openCloseModal(${r.number})" title="Comment on and close this issue">Close…</button>`+
    `</div>`;
}
function renderRows(){
  if(!MODEL) return;
  const q=document.getElementById('f-q').value.trim().toLowerCase();
  let rows=MODEL.issues.slice();
  if(activeStage) rows=rows.filter(r=>r.stages.includes(activeStage));
  if(q) rows=rows.filter(r=>(
    '#'+r.number+' '+r.title+' '+r.stages.join(' ')+' '+
    r.other_labels.map(l=>l.name).join(' ')+' '+
    r.prs.map(p=>'#'+p.number+' '+p.title+' '+p.state).join(' ')
  ).toLowerCase().includes(q));
  rows.sort((a,b)=>{ let x=a[sortKey],y=b[sortKey]; if(sortKey==='number'){x=+x;y=+y;} if(x<y) return -1*sortDir; if(x>y) return 1*sortDir; return 0; });
  document.getElementById('f-count').textContent=`${rows.length} issue${rows.length!==1?'s':''}`;
  const head=`<tr>${th('number','#','')}${th('title','Title','')}${th('created','Age','')}${th('updated','Updated','')}`+
    MODEL.stages.map(s=>th(null,s.key,'stagecol')).join('')+
    `<th>Labels</th><th>PRs</th><th>Actions</th></tr>`;
  const body=rows.map(r=>`<tr>
    <td class="num"><a href="${esc(r.url)}" target="_blank" rel="noopener">#${r.number}</a></td>
    <td class="titlecol"><a class="ititle" href="${esc(r.url)}" target="_blank" rel="noopener">${esc(r.title)}</a></td>
    <td class="num" title="opened ${esc(r.created)}">${ago(r.created)}</td>
    <td class="num" title="${esc(r.updated)}">${ago(r.updated)}</td>
    ${MODEL.stages.map(s=>`<td class="stagecol">${r.stages.includes(s.key)?`<span class="stagemark" style="color:color-mix(in srgb,#${esc(s.color)} 55%,var(--ink))" title="${esc(s.key)}">✓</span>`:''}</td>`).join('')}
    <td>${r.other_labels.map(l=>`<span class="ghlabel" style="border-color:#${esc(l.color)}; background:color-mix(in srgb,#${esc(l.color)} 18%,transparent)">${esc(l.name)}</span>`).join('')||'<span class="none">—</span>'}</td>
    <td>${prCell(r)}</td>
    <td>${actCell(r)}</td>
  </tr>`).join('');
  const cols=7+MODEL.stages.length;
  document.getElementById('issue-table').innerHTML=`<table><thead>${head}</thead><tbody>`+
    (rows.length?body:`<tr><td colspan="${cols}" class="empty">No open issues match.</td></tr>`)+`</tbody></table>`;
}

/* ---------- triage actions ---------- */
let toastTimer=null, closeTarget=null;
function toast(msg, bad){
  const t=document.getElementById('toast'); t.textContent=msg; t.classList.toggle('bad', !!bad); t.hidden=false;
  if(toastTimer) clearTimeout(toastTimer); toastTimer=setTimeout(()=>{ t.hidden=true; }, bad?7000:3500);
}
function postJSON(url, payload){
  return fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
    .then(r=>r.json()).catch(e=>({error:String(e)}));
}
async function acceptIssue(n, btn){
  btn.disabled=true;
  const d=await postJSON('/api/accept',{number:n});
  if(d && d.ok){ toast(`Accepted #${n} — queued for the fixer.`); await fetchData(); }
  else { toast('Accept failed: '+((d&&d.error)||'unknown error'), true); btn.disabled=false; }
}
function openCloseModal(n){
  closeTarget=n;
  const r=MODEL.issues.find(i=>i.number===n);
  document.getElementById('cm-head').textContent=`Close #${n}`;
  document.getElementById('cm-title').textContent=r?r.title:'';
  const ta=document.getElementById('cm-comment'); ta.value='';
  updateCloseButtons();
  document.getElementById('closemodal').hidden=false;
  ta.focus();
}
function hideCloseModal(){ document.getElementById('closemodal').hidden=true; closeTarget=null; }
function updateCloseButtons(){
  const has=document.getElementById('cm-comment').value.trim().length>0;
  document.getElementById('cm-notplanned').disabled=!has;
  document.getElementById('cm-completed').disabled=!has;
}
async function submitClose(reason){
  const n=closeTarget, comment=document.getElementById('cm-comment').value.trim();
  if(n==null || !comment) return;
  const btns=[document.getElementById('cm-notplanned'),document.getElementById('cm-completed'),document.getElementById('cm-cancel')];
  btns.forEach(b=>b.disabled=true);
  const d=await postJSON('/api/close',{number:n, comment, reason});
  btns.forEach(b=>b.disabled=false); updateCloseButtons();
  if(d && d.ok){ hideCloseModal(); toast(`Closed #${n} as ${reason==='not_planned'?'not planned':'completed'}.`); await fetchData(); }
  else { toast('Close failed: '+((d&&d.error)||'unknown error'), true); }
}
document.getElementById('cm-comment').addEventListener('input', updateCloseButtons);
document.getElementById('cm-cancel').addEventListener('click', hideCloseModal);
document.getElementById('cm-notplanned').addEventListener('click',()=>submitClose('not_planned'));
document.getElementById('cm-completed').addEventListener('click',()=>submitClose('completed'));
document.getElementById('closemodal').addEventListener('click',e=>{ if(e.target===e.currentTarget) hideCloseModal(); });
document.addEventListener('keydown',e=>{ if(e.key==='Escape' && !document.getElementById('closemodal').hidden) hideCloseModal(); });

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
document.getElementById('f-q').addEventListener('input', renderRows);
renderIntervalMenu(); fetchData();
</script>
</body>
</html>
"""


def main():
    global REPO_SLUG, STAGES, ACCEPT_LABEL
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="Path to a checkout whose origin remote names the GitHub repo "
                         "(default: this script's repo)")
    ap.add_argument("--repo-slug", help="GitHub owner/name (overrides --repo detection)")
    ap.add_argument("--stages", default=",".join(DEFAULT_STAGES),
                    help="Comma-separated lifecycle labels, in column order "
                         f"(default: {','.join(DEFAULT_STAGES)})")
    ap.add_argument("--accept-label", default=ACCEPT_LABEL,
                    help=f"Label the Accept button adds (default: {ACCEPT_LABEL})")
    ap.add_argument("--host", default="127.0.0.1", help="Bind host (default 127.0.0.1)")
    ap.add_argument("--port", type=int, default=5058,
                    help="Bind port (default 5058; the Apple dashboard uses 5057)")
    args = ap.parse_args()

    REPO_SLUG = args.repo_slug or detect_repo_slug(args.repo)
    if not REPO_SLUG:
        sys.exit("Could not determine the GitHub repo from the origin remote; pass --repo-slug owner/name.")
    STAGES = [s.strip() for s in args.stages.split(",") if s.strip()]
    ACCEPT_LABEL = args.accept_label

    sys.stderr.write(f"Serving Cabalmail triage dashboard on http://{args.host}:{args.port}  (repo: {REPO_SLUG})\n")
    sys.stderr.write(f"Lifecycle columns: {', '.join(STAGES)}\n")
    app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
