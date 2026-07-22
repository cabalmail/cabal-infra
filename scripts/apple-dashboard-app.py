#!/usr/bin/env python3
"""Flask app for the Cabalmail Apple release dashboard.

Interactive/server version of apple-release-dashboard.py. It reuses that
script as the data engine (repo parsing + App Store Connect querying) and adds:

  * a web server serving the dashboard at /
  * GET /api/data - re-queries the repo + App Store Connect live (this is what
    the Refresh button hits)
  * a Refresh button with a chevron menu for an auto-refresh interval
    (Off / 10s / 1m / 2m / 5m / 15m)
  * a Platform filter in the Build ledger (in addition to App and Lane)

The Feature matrix is per-feature: every Apple feature - a pending
changelog.d/ fragment or a released CHANGELOG entry - shows, per app, the
Stage / Prod / Beta build that contains it and Apple's status there. A pending
fragment on the stage branch is built and testable in the stage group (under
the last marketing version) even though it has not been cut to prod, so it
shows a Stage build and no Prod/Beta - "released to stage, not to prod".

The data engine file must sit next to this one; override with --engine PATH.

Run:

    pip install flask pyjwt cryptography
    export ASC_KEY_ID=XXXXXXXXXX
    export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    export ASC_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8
    python3 scripts/apple-dashboard-app.py --repo .   # from the repo root
    # then open http://127.0.0.1:5057

--mock <file.json> serves a captured/synthetic ASC payload (offline preview).
A short auto-refresh interval means frequent live App Store Connect calls, so
mind ASC rate limits if you leave 10s running for long stretches.
"""

import argparse
import importlib.util
import json
import os
import sys
import traceback

try:
    from flask import Flask, jsonify, Response, request
except ImportError:
    sys.exit("Flask is not installed. Run: pip install flask pyjwt cryptography")

import urllib.error


def load_engine(explicit):
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [c for c in (explicit, os.path.join(here, "apple-release-dashboard.py")) if c]
    for path in candidates:
        if os.path.isfile(path):
            spec = importlib.util.spec_from_file_location("apple_dash_engine", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    sys.exit(
        "Could not find the data engine 'apple-release-dashboard.py' next to this "
        "app. Put both files in the same directory, or pass --engine PATH."
    )


ENGINE = None
REPO_ROOT = "."
MOCK_PATH = None
REF = "origin/stage"   # authoritative branch to track; "local" = working tree
FETCH = True


def _load_source():
    """Return (versions, fragments, ref, source_label).

    Tracks REF (e.g. origin/stage) so freshly-merged work shows even if the
    local checkout is behind; falls back to the working tree if the ref is
    unavailable (no network / not a git repo)."""
    if REF and REF != "local":
        if FETCH:
            ENGINE.git_fetch(REPO_ROOT)
        if ENGINE.ref_exists(REPO_ROOT, REF):
            src = ENGINE.read_ref_source(REPO_ROOT, REF)
            if src is not None:
                text, items = src
                return (ENGINE.parse_changelog_text(text),
                        ENGINE.read_fragments_items(items), REF, REF)
    changelog_path = os.path.join(REPO_ROOT, "CHANGELOG.md")
    if not os.path.isfile(changelog_path):
        raise RuntimeError(f"CHANGELOG.md not found under --repo {REPO_ROOT!r}")
    return (ENGINE.parse_changelog(changelog_path),
            ENGINE.read_fragments(os.path.join(REPO_ROOT, "changelog.d")),
            None, "local working tree")


def build_model():
    versions, fragments, ref, source_label = _load_source()
    frag_dates, _frag_land, tag_dates = ENGINE.git_dates(REPO_ROOT, fragments, ref)
    summaries = [f["summary"] for f in fragments if f["apple"]]
    summaries += [e["summary"] for v in versions for e in v["apple_entries"]]
    landings = ENGINE.feature_landings(REPO_ROOT, summaries, ref)

    if MOCK_PATH:
        with open(MOCK_PATH, encoding="utf-8") as fh:
            asc = json.load(fh)
        demo = True
    else:
        missing = [
            k for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")
            if not os.environ.get(k, "").strip()
        ]
        if missing:
            raise RuntimeError(
                "Missing App Store Connect credentials: " + ", ".join(missing) +
                ". Set them in the environment, or start the app with --mock <file.json>."
            )
        asc = ENGINE.fetch_asc()
        demo = False

    model = ENGINE.assemble(versions, fragments, frag_dates, landings, tag_dates, asc)
    model["demo"] = demo
    model["source"] = source_label
    return model


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


@app.route("/api/assign", methods=["POST"])
def api_assign():
    """Attach a build to a TestFlight group (a real App Store Connect change)."""
    if MOCK_PATH:
        return jsonify({"error": "Running with --mock; group assignment is disabled."}), 200
    data = request.get_json(force=True, silent=True) or {}
    build_id, group_id = data.get("build_id"), data.get("group_id")
    if not build_id or not group_id:
        return jsonify({"error": "build_id and group_id are required."}), 200
    token_factory = ENGINE.make_token_factory()
    if token_factory is None:
        return jsonify({"error": "App Store Connect credentials are not set."}), 200
    try:
        ENGINE.assign_build_to_group(build_id, group_id, token_factory)
        return jsonify({"ok": True})
    except urllib.error.HTTPError as err:
        detail = ""
        try:
            detail = err.read().decode()
        except Exception:  # pylint: disable=broad-except
            pass
        sys.stderr.write(f"api/assign HTTP {err.code}: {detail or err.reason}\n")
        return jsonify({"error": f"App Store Connect returned HTTP {err.code}: {detail or err.reason}"}), 200
    except Exception as exc:  # pylint: disable=broad-except
        sys.stderr.write("api/assign error:\n" + traceback.format_exc())
        return jsonify({"error": str(exc)}), 200


PAGE = r"""<!DOCTYPE html>
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
    --good-ink:#006300; --radius:10px;
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
  .rbtn.chev.active{color:var(--ios); border-color:color-mix(in srgb,var(--ios) 45%,var(--border))}
  .rbtn:disabled{opacity:.6; cursor:default}
  .rbtn .intlbl{font-size:11.5px; color:var(--ios); font-weight:600; font-variant-numeric:tabular-nums}
  .spin{animation:spin .8s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  .rmenu{position:absolute; top:38px; right:0; min-width:170px; z-index:30; background:var(--surface); border:1px solid var(--border); border-radius:10px; box-shadow:0 8px 28px rgba(0,0,0,.18); padding:5px}
  .rmenu[hidden]{display:none}
  .rmenu-head{font-size:11px; text-transform:uppercase; letter-spacing:0.04em; color:var(--muted); padding:7px 10px 5px}
  .rmenu-item{display:flex; align-items:center; gap:9px; width:100%; text-align:left; border:none; background:none; font:inherit; font-size:13.5px; color:var(--ink); padding:8px 10px; border-radius:7px; cursor:pointer}
  .rmenu-item:hover{background:var(--surface-2)}
  .rmenu-item .chk{width:15px; color:var(--ios); font-size:12px}
  .rmenu-item[aria-selected="true"]{font-weight:600}
  .stats{display:flex; gap:10px; flex-wrap:wrap; margin:18px 0 18px}
  .stat{background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:12px 16px; min-width:130px}
  .stat .n{font-size:22px; font-weight:650; letter-spacing:-0.02em}
  .stat .l{font-size:12px; color:var(--muted); margin-top:1px}
  .tabs{display:flex; gap:4px; border-bottom:1px solid var(--grid); margin-bottom:18px}
  .tab{border:none; background:none; color:var(--ink-2); font:inherit; font-size:14px; padding:9px 14px; cursor:pointer; border-bottom:2px solid transparent; margin-bottom:-1px}
  .tab[aria-selected="true"]{color:var(--ink); border-bottom-color:var(--ios); font-weight:600}
  .tab:hover{color:var(--ink)}
  .panel{display:none} .panel.active{display:block}
  .gbar{display:flex; align-items:center; gap:10px; flex-wrap:wrap; background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:10px 14px; margin:0 0 14px}
  .gbar-label{font-size:12px; font-weight:600; color:var(--ink-2)}
  .gbar input{font:inherit; font-size:13px; padding:6px 10px; border-radius:8px; border:1px solid var(--border); background:var(--page); color:var(--ink); width:190px; font-variant-numeric:tabular-nums}
  .gbar-clear{border:1px solid var(--border); background:var(--surface); color:var(--ink-2); border-radius:7px; padding:5px 10px; font:inherit; font-size:12px; cursor:pointer}
  .gbar-clear:hover{color:var(--ink)}
  .gbar-note{font-size:12px; color:var(--muted)}
  .gbar-note.bad{color:var(--critical)}
  .lcell.hot .lbuild{color:var(--ios); font-weight:700}
  .lcell.hot{background:color-mix(in srgb,var(--ios) 12%,transparent); border-radius:6px; margin:-2px -4px; padding:2px 4px}
  .banner{border-radius:var(--radius); padding:12px 16px; margin-bottom:16px; font-size:13px}
  .banner.warn{background:color-mix(in srgb,var(--warning) 16%,transparent); border:1px solid color-mix(in srgb,var(--warning) 45%,transparent)}
  .banner.err{background:color-mix(in srgb,var(--critical) 12%,transparent); border:1px solid color-mix(in srgb,var(--critical) 40%,transparent); color:var(--critical)}
  .legend{display:flex; gap:14px; flex-wrap:wrap; align-items:center; margin:0 0 16px; font-size:12px; color:var(--ink-2)}
  .apptag{display:inline-flex; align-items:center; gap:6px; font-weight:600}
  .dot{width:9px; height:9px; border-radius:50%; display:inline-block; flex:0 0 auto}
  .dot.ios{background:var(--ios)} .dot.mac{background:var(--mac)}
  .pill{display:inline-flex; align-items:center; gap:5px; padding:2px 8px; border-radius:999px; font-size:11.5px; font-weight:600; line-height:1.6; white-space:nowrap; border:1px solid transparent}
  .pill .ic{font-size:10px; line-height:1}
  .pill.good{background:color-mix(in srgb,var(--good) 15%,transparent); color:var(--good-ink); border-color:color-mix(in srgb,var(--good) 40%,transparent)}
  .pill.warning{background:color-mix(in srgb,var(--warning) 22%,transparent); color:var(--ink); border-color:color-mix(in srgb,var(--warning) 55%,transparent)}
  .pill.serious{background:color-mix(in srgb,var(--serious) 22%,transparent); color:var(--ink); border-color:color-mix(in srgb,var(--serious) 55%,transparent)}
  .pill.critical{background:color-mix(in srgb,var(--critical) 16%,transparent); color:var(--critical); border-color:color-mix(in srgb,var(--critical) 45%,transparent)}
  .pill.neutral{background:var(--surface-2); color:var(--ink-2); border-color:var(--border)}
  .pill.muted{background:transparent; color:var(--muted); border-color:var(--border)}
  :root[data-theme="dark"] .pill.warning, :root[data-theme="dark"] .pill.serious{color:#0b0b0b}
  @media (prefers-color-scheme: dark){:root[data-theme="auto"] .pill.warning, :root[data-theme="auto"] .pill.serious{color:#0b0b0b}}
  .vgroup{background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); margin-bottom:14px; overflow:hidden}
  .vhead{display:flex; justify-content:space-between; align-items:center; gap:18px; padding:13px 16px; cursor:pointer; border-bottom:1px solid transparent}
  .vgroup.open .vhead{border-bottom-color:var(--grid)}
  .vhead:hover{background:var(--surface-2)}
  .vtitle{display:flex; align-items:baseline; gap:9px; white-space:nowrap; flex-wrap:wrap}
  .vnum{font-size:16px; font-weight:650; letter-spacing:-0.01em}
  .vdate{font-size:12px; color:var(--muted); font-variant-numeric:tabular-nums}
  .vcount{font-size:12px; color:var(--muted)}
  .caret{display:inline-block; width:12px; color:var(--muted); transition:transform .12s; font-size:11px}
  .vgroup.open .caret{transform:rotate(90deg)}
  .badge-flight{background:color-mix(in srgb,var(--ios) 16%,transparent); color:var(--ios); border:1px solid color-mix(in srgb,var(--ios) 40%,transparent); border-radius:999px; padding:2px 9px; font-size:11px; font-weight:600; white-space:nowrap}
  .flist{padding:2px 16px 12px; display:none}
  .vgroup.open .flist{display:block}
  .frow2{padding:11px 0; border-top:1px solid var(--grid); display:flex; gap:12px; align-items:flex-start}
  .frow2:first-child{border-top:none}
  .fcat{font-size:10px; text-transform:uppercase; letter-spacing:0.04em; color:var(--muted); min-width:70px; padding-top:3px; flex:0 0 auto}
  .fbody{flex:1; min-width:0; display:flex; flex-direction:column; gap:8px}
  .fsummary{font-weight:600} .fdetail{color:var(--ink-2)}
  .fstrip{display:flex; flex-direction:column; gap:5px; background:var(--surface-2); border-radius:8px; padding:8px 10px}
  .lrow{display:flex; align-items:center; gap:9px}
  .lcells{display:grid; grid-template-columns:repeat(4, minmax(118px,1fr)); gap:8px; flex:1}
  .lcell{display:flex; align-items:center; gap:6px; min-width:0}
  .llabel{font-size:9.5px; text-transform:uppercase; letter-spacing:0.05em; color:var(--muted); width:40px; flex:0 0 auto}
  .lbuild{font-size:10.5px; color:var(--muted); font-variant-numeric:tabular-nums}
  .lane-none{color:var(--muted); font-size:12px}
  .controls{display:flex; gap:10px; flex-wrap:wrap; align-items:center; margin-bottom:12px}
  .controls select, .controls input{font:inherit; font-size:13px; padding:6px 10px; border-radius:8px; border:1px solid var(--border); background:var(--surface); color:var(--ink)}
  .controls label{font-size:12px; color:var(--muted)}
  table{width:100%; border-collapse:collapse; background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); overflow:hidden}
  th,td{text-align:left; padding:10px 12px; border-bottom:1px solid var(--grid); vertical-align:middle}
  th{font-size:11px; text-transform:uppercase; letter-spacing:0.04em; color:var(--muted); font-weight:600; cursor:pointer; user-select:none; white-space:nowrap}
  th:hover{color:var(--ink-2)}
  tbody tr:hover{background:var(--surface-2)}
  tbody tr:last-child td{border-bottom:none}
  .mono{font-variant-numeric:tabular-nums} td.num{font-variant-numeric:tabular-nums}
  .grp{display:inline-block; font-size:10.5px; font-weight:600; padding:1px 7px; border-radius:6px; border:1px solid var(--border); margin-right:4px; color:var(--ink-2)}
  .grp.stage{border-color:color-mix(in srgb,var(--ios) 40%,transparent)}
  .grp.prod{border-color:color-mix(in srgb,var(--good) 45%,transparent)}
  .grp.beta{border-color:color-mix(in srgb,var(--mac) 45%,transparent)}
  .apppill{display:inline-flex; align-items:center; gap:6px; font-weight:600; font-size:12.5px}
  .assign{font:inherit; font-size:12px; padding:3px 7px; border-radius:6px; border:1px solid var(--border); background:var(--surface); color:var(--ink-2); max-width:140px; cursor:pointer}
  .assign:hover{color:var(--ink)}
  .assign:disabled{opacity:.5; cursor:default}
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
      <h1>Cabalmail · Apple Release Dashboard</h1>
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

  <div id="demo"></div>
  <div id="error"></div>
  <div id="notfound"></div>
  <div class="stats" id="stats"></div>

  <div class="legend">
    <span class="apptag"><span class="dot ios"></span>iOS</span>
    <span class="apptag"><span class="dot mac"></span>macOS</span>
    <span style="width:1px;height:14px;background:var(--grid)"></span>
    <span><span class="pill good"><span class="ic">●</span>Testing</span></span>
    <span><span class="pill warning"><span class="ic">▲</span>Waiting for Review</span></span>
    <span><span class="pill neutral"><span class="ic">○</span>Processing</span></span>
    <span><span class="pill critical"><span class="ic">✕</span>Rejected / Failed</span></span>
    <span><span class="pill muted"><span class="ic">–</span>Expired</span></span>
  </div>

  <div class="gbar">
    <span class="gbar-label">Build&nbsp;#&nbsp;≥</span>
    <input id="g-build" inputmode="numeric" placeholder="e.g. 1784586217 — this build or newer">
    <button class="gbar-clear" id="g-clear" hidden>clear</button>
    <span class="gbar-note" id="g-note">Applies to both tabs. Enter the build a feature first shipped in to see every build that should carry it.</span>
  </div>

  <div class="tabs" role="tablist">
    <button class="tab" role="tab" aria-selected="true" data-tab="features">Feature matrix</button>
    <button class="tab" role="tab" aria-selected="false" data-tab="ledger">Build ledger</button>
  </div>

  <section class="panel active" id="panel-features" role="tabpanel"></section>
  <section class="panel" id="panel-ledger" role="tabpanel"></section>

  <footer id="footer"></footer>
</div>
<div id="toast" class="toast" hidden></div>

<script>
const LANES=["stage","prod","beta"];
const CELL_LANES=["built","stage","prod","beta"];
const LANE_LABEL={built:"Built", stage:"Stage", prod:"Prod", beta:"Beta"};
const ROLE_ICON={good:"●", warning:"▲", serious:"◆", critical:"✕", neutral:"○", muted:"–"};
const INTERVALS=[{s:0,label:"Off"},{s:10,label:"10 seconds"},{s:60,label:"1 minute"},{s:120,label:"2 minutes"},{s:300,label:"5 minutes"},{s:900,label:"15 minutes"}];
const esc=s=>(s==null?"":String(s)).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const pill=(label,role)=>`<span class="pill ${role}"><span class="ic">${ROLE_ICON[role]||"○"}</span>${esc(label)}</span>`;

let MODEL=null, sortKey='uploaded', sortDir=-1, ledgerShellBuilt=false, openGroups=null, inFlight=false, intervalSec=0, timer=null, gBuild=null;

/* ---------- global build-number floor (applies to both tabs) ---------- */
function buildToDate(ts){ if(!(ts>=1e9 && ts<=4e9)) return ''; const d=new Date(ts*1000); return d.toISOString().slice(0,16).replace('T',' ')+' UTC'; }
function applyGlobal(){
  const el=document.getElementById('g-build'), v=el.value.trim(), note=document.getElementById('g-note');
  document.getElementById('g-clear').toggleAttribute('hidden', !v);
  if(!v){ gBuild=null; note.className='gbar-note'; note.textContent='Applies to both tabs. Enter the build a feature first shipped in to see every build that should carry it.'; }
  else if(/^\d+$/.test(v)){ gBuild=parseInt(v,10); const d=buildToDate(gBuild); note.className='gbar-note'; note.textContent='Showing this build and newer'+(d?` · #${gBuild} = ${d}`:''); }
  else { gBuild=null; note.className='gbar-note bad'; note.textContent='Enter a numeric build number.'; }
  if(MODEL){ renderFeatures(); if(ledgerShellBuilt) renderLedgerRows(); }
}
function featureMeetsFloor(f){
  if(gBuild==null) return true;
  for(const a of MODEL.apps){ const ld=f.lanes[a.key]||{}; for(const l of CELL_LANES){ const d=ld[l]; if(d && (+d.build_number||0)>=gBuild) return true; } }
  return false;
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
  document.getElementById('sub').textContent=`iOS ${MODEL.apps[0].bundle_id} · macOS ${MODEL.apps[1].bundle_id} · stage source: ${MODEL.source||'—'} · data ${MODEL.generated}`;
  document.getElementById('demo').innerHTML=MODEL.demo?`<div class="banner warn"><b>Preview / sample data.</b> Feature and version content is real (from the repo), but the Stage/Prod/Beta build numbers and Apple statuses are synthetic (served with --mock).</div>`:'';
  const nf=[]; MODEL.apps.forEach(a=>{ if(!MODEL.found[a.key]) nf.push(a.label+' ('+a.bundle_id+')'); });
  document.getElementById('notfound').innerHTML=nf.length?`<div class="banner err">⚠ No App Store Connect app resolved for: ${esc(nf.join(', '))}.</div>`:'';

  const c=MODEL.counts, tiles=[['In stage group', c.stage_group],['In prod', c.in_prod],['In beta', c.in_beta],['Builds tracked', c.builds]];
  if(c.built_ungrouped) tiles.splice(1,0,['Built · awaiting group', c.built_ungrouped]);
  if(c.pending_unbuilt) tiles.push(['On stage · no build yet', c.pending_unbuilt]);
  document.getElementById('stats').innerHTML=tiles.map(([l,n])=>`<div class="stat"><div class="n">${n}</div><div class="l">${l}</div></div>`).join('');

  if(openGroups===null){ openGroups=new Set(['pending']); const f=MODEL.features.find(x=>x.origin==='released'); if(f) openGroups.add('v:'+f.version); }
  renderFeatures(); renderLedger();

  document.getElementById('footer').innerHTML=
    `<b>Built</b> = the first build that carried the feature (merged to the <code>stage</code> <i>branch</i>, uploaded to App Store Connect) — it can exist before Apple attaches it to any test group. <b>Stage/Prod/Beta</b> = the first build attached to that TestFlight <i>group</i>. Each cell is the earliest build whose number (a Unix timestamp, <code>date -u +%s</code>) is ≥ when the entry landed on <code>stage</code> (recovered from git); every build from there onward carries it. A feature's first stage build can sit under an earlier marketing version than the one it was cut into. Prod happens only when a version is cut to <code>main</code>; beta is assigned manually. (If a feature's true first build has aged out of TestFlight, the earliest build still in App Store Connect is shown.)`;
}

/* ---------- feature matrix (per-feature lanes) ---------- */
function laneStrip(f){
  return MODEL.apps.map(a=>{
    const ld=f.lanes[a.key]||{};
    const cells=CELL_LANES.map(l=>{
      const d=ld[l];
      const inner=d?(pill(d.status_label,d.status_role)+`<span class="lbuild">#${esc(d.build_number)}</span>`):`<span class="lane-none">—</span>`;
      const hot=(d && gBuild!=null && (+d.build_number||0)>=gBuild)?' hot':'';
      return `<div class="lcell${hot}"><span class="llabel">${LANE_LABEL[l]}</span>${inner}</div>`;
    }).join('');
    return `<div class="lrow"><span class="dot ${a.key}" title="${a.label}"></span><div class="lcells">${cells}</div></div>`;
  }).join('');
}
function featureRow(f){
  return `<div class="frow2"><span class="fcat">${esc(f.category||'')}</span><div class="fbody">`+
    `<div><span class="fsummary">${esc(f.summary)}</span>${f.detail?` <span class="fdetail">— ${esc(f.detail)}</span>`:''}</div>`+
    `<div class="fstrip">${laneStrip(f)}</div></div></div>`;
}
function renderFeatures(){
  const p=document.getElementById('panel-features');
  const sections=[]; let cur=null;
  MODEL.features.forEach(f=>{
    if(!featureMeetsFloor(f)) return;
    const key=f.origin==='pending'?'pending':('v:'+f.version);
    if(!cur||cur.key!==key){ cur={key, origin:f.origin, version:f.version, date:f.date, items:[]}; sections.push(cur); }
    cur.items.push(f);
  });
  p.innerHTML = sections.length ? sections.map(s=>{
    const isOpen=openGroups.has(s.key)?'open':'';
    const head = s.origin==='pending'
      ? `<div class="vtitle"><span class="caret">▶</span><span class="vnum">On the stage branch</span><span class="vcount">${s.items.length} feature${s.items.length!==1?'s':''} · not yet cut to prod</span></div><span class="badge-flight">changelog.d/ · merged, not yet released</span>`
      : `<div class="vtitle"><span class="caret">▶</span><span class="vnum">${esc(s.version)}</span><span class="vdate">${esc(s.date)}</span><span class="vcount">· ${s.items.length} feature${s.items.length!==1?'s':''}</span></div>`;
    return `<div class="vgroup ${isOpen}" data-key="${esc(s.key)}"><div class="vhead">${head}</div>`+
      `<div class="flist">${s.items.map(featureRow).join('')}</div></div>`;
  }).join('') : `<div class="empty">No features first shipped in build ${gBuild!=null?'#'+gBuild:'—'} or newer.</div>`;
  p.querySelectorAll('.vgroup').forEach(g=>g.querySelector('.vhead').addEventListener('click',()=>{
    const k=g.dataset.key; if(openGroups.has(k)) openGroups.delete(k); else openGroups.add(k); g.classList.toggle('open');
  }));
}

/* ---------- build ledger ---------- */
function platformOptions(){ const set=new Set(); MODEL.ledger.forEach(r=>{ if(r.platform) set.add(r.platform); });
  return ['<option value="all">Any</option>'].concat([...set].sort().map(p=>`<option value="${esc(p)}">${esc(p)}</option>`)).join(''); }
function renderLedger(){
  if(!ledgerShellBuilt){
    document.getElementById('panel-ledger').innerHTML=`<div class="controls">
      <label>App <select id="f-app"><option value="all">All</option><option value="ios">iOS</option><option value="mac">macOS</option></select></label>
      <label>Platform <select id="f-plat">${platformOptions()}</select></label>
      <label>Lane <select id="f-lane"><option value="all">Any</option>${LANES.map(l=>`<option value="${l}">${LANE_LABEL[l]}</option>`).join('')}</select></label>
      <input id="f-q" placeholder="Filter platform / version / build / status…">
      <span class="spacer" style="flex:1"></span><label id="f-count" style="align-self:center"></label>
    </div><div id="ledger-table"></div>`;
    ['f-app','f-plat','f-lane'].forEach(id=>document.getElementById(id).addEventListener('change', renderLedgerRows));
    document.getElementById('f-q').addEventListener('input', renderLedgerRows);
    ledgerShellBuilt=true;
  }
  renderLedgerRows();
}
function th(key,label){ const a=sortKey===key?(sortDir===1?' ▲':' ▼'):''; return `<th onclick="setSort('${key}')">${label}${a}</th>`; }
function setSort(key){ if(sortKey===key) sortDir*=-1; else {sortKey=key; sortDir=1;} renderLedgerRows(); }
function renderLedgerRows(){
  if(!MODEL) return;
  const appF=document.getElementById('f-app').value, platF=document.getElementById('f-plat').value, laneF=document.getElementById('f-lane').value, q=document.getElementById('f-q').value.trim().toLowerCase();
  let rows=MODEL.ledger.slice();
  if(gBuild!=null) rows=rows.filter(r=>(+r.build_number||0)>=gBuild);
  if(appF!=='all') rows=rows.filter(r=>r.app_key===appF);
  if(platF!=='all') rows=rows.filter(r=>r.platform===platF);
  if(laneF!=='all') rows=rows.filter(r=>r.lanes.includes(laneF));
  if(q) rows=rows.filter(r=>(r.platform+' '+r.marketing_version+' '+r.build_number+' '+r.status_label+' '+r.groups.join(' ')).toLowerCase().includes(q));
  rows.sort((a,b)=>{ let x=a[sortKey],y=b[sortKey]; if(sortKey==='build_number'){x=+x||0;y=+y||0;} if(x<y) return -1*sortDir; if(x>y) return 1*sortDir; return 0; });
  document.getElementById('f-count').textContent=`${rows.length} build${rows.length!==1?'s':''}`;
  const head=`<tr>${th('app','App')}${th('platform','Platform')}${th('marketing_version','Marketing')}${th('build_number','Build #')}${th('build_date','Build # → date')}${th('uploaded','Uploaded')}${th('status_label','Apple status')}<th>Groups</th><th>Assign</th></tr>`;
  const body=rows.map(r=>`<tr>
    <td><span class="apppill"><span class="dot ${r.app_key}"></span>${esc(r.app)}</span></td>
    <td style="color:var(--ink-2)">${esc(r.platform||'—')}</td>
    <td class="mono"><b>${esc(r.marketing_version||'—')}</b></td>
    <td class="num mono">${esc(r.build_number)}</td>
    <td class="num mono" style="color:var(--ink-2)">${esc(r.build_date||'—')}</td>
    <td class="num mono" style="color:var(--ink-2)">${esc((r.uploaded||'').replace('T',' ').replace(/:\d\dZ?$/,'').replace('Z',''))||'—'}</td>
    <td>${pill(r.status_label,r.status_role)}</td>
    <td>${r.lanes.length? r.lanes.map(l=>`<span class="grp ${l}">${LANE_LABEL[l]}</span>`).join('') : '<span class="lane-none">—</span>'}</td>
    <td>${assignSelect(r)}</td>
  </tr>`).join('');
  document.getElementById('ledger-table').innerHTML=`<table><thead>${head}</thead><tbody>`+(rows.length?body:`<tr><td colspan="9" class="empty">No builds match.</td></tr>`)+`</tbody></table>`;
}

/* ---------- assign a build to a TestFlight group ---------- */
function assignSelect(r){
  if(MODEL.demo || !r.id) return '<span class="lane-none">—</span>';
  const groups=(MODEL.groups&&MODEL.groups[r.app_key])||[];
  const avail=groups.filter(g=>g.id && !r.groups.includes(g.name));
  if(!avail.length) return '<span class="lane-none">—</span>';
  return `<select class="assign" data-build="${esc(r.id)}" onchange="assignBuild(this)" title="Add this build to a TestFlight group">`+
    `<option value="">＋ add to…</option>`+
    avail.map(g=>`<option value="${esc(g.id)}" data-name="${esc(g.name)}">${esc(g.name)}${g.internal?'':' · external'}</option>`).join('')+
    `</select>`;
}
let toastTimer=null;
function toast(msg, bad){
  const t=document.getElementById('toast'); t.textContent=msg; t.classList.toggle('bad', !!bad); t.hidden=false;
  if(toastTimer) clearTimeout(toastTimer); toastTimer=setTimeout(()=>{ t.hidden=true; }, bad?7000:3500);
}
async function assignBuild(sel){
  const gid=sel.value; if(!gid) return;
  const gname=sel.options[sel.selectedIndex].dataset.name||'group';
  const bid=sel.dataset.build; sel.selectedIndex=0;
  if(!confirm(`Add this build to the “${gname}” group in App Store Connect?\n\nThis makes a real change to your TestFlight distribution.`)) return;
  sel.disabled=true;
  try{
    const res=await fetch('/api/assign',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({build_id:bid, group_id:gid})});
    const d=await res.json();
    if(d && d.ok){ toast(`Added build to “${gname}”. Refreshing…`); await fetchData(); }
    else { toast('Assign failed: '+((d&&d.error)||'unknown error'), true); sel.disabled=false; }
  }catch(e){ toast('Assign failed: '+e, true); sel.disabled=false; }
}

/* ---------- tabs / theme ---------- */
document.querySelectorAll('.tab').forEach(t=>t.addEventListener('click',()=>{
  document.querySelectorAll('.tab').forEach(x=>x.setAttribute('aria-selected', x===t));
  document.getElementById('panel-features').classList.toggle('active', t.dataset.tab==='features');
  document.getElementById('panel-ledger').classList.toggle('active', t.dataset.tab==='ledger');
}));
const tb=document.getElementById('themebtn'); const modes=['auto','light','dark']; let mi=0;
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
  const short={0:'',10:'10s',60:'1m',120:'2m',300:'5m',900:'15m'};
  document.getElementById('int-label').textContent=short[sec]||''; chev.classList.toggle('active', sec>0); renderIntervalMenu();
}
document.getElementById('g-build').addEventListener('input', applyGlobal);
document.getElementById('g-clear').addEventListener('click',()=>{ document.getElementById('g-build').value=''; applyGlobal(); });
renderIntervalMenu(); fetchData();
</script>
</body>
</html>
"""


def main():
    global ENGINE, REPO_ROOT, MOCK_PATH, REF, FETCH
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".", help="Path to the cabal-infra repo root (default: cwd)")
    ap.add_argument("--engine", help="Path to apple-release-dashboard.py (default: next to this file)")
    ap.add_argument("--mock", help="Serve a captured/synthetic ASC JSON file instead of calling the API")
    ap.add_argument("--ref", default="origin/stage",
                    help="Git ref to read the stage branch from (default: origin/stage). "
                         "Use 'local' to read the working tree instead.")
    ap.add_argument("--no-fetch", action="store_true",
                    help="Don't `git fetch` before reading the ref (use whatever's already fetched)")
    ap.add_argument("--host", default="127.0.0.1", help="Bind host (default 127.0.0.1)")
    ap.add_argument("--port", type=int, default=5057, help="Bind port (default 5057)")
    args = ap.parse_args()

    ENGINE = load_engine(args.engine)
    REPO_ROOT = os.path.abspath(os.path.expanduser(args.repo))
    MOCK_PATH = os.path.abspath(os.path.expanduser(args.mock)) if args.mock else None
    REF = args.ref
    FETCH = not args.no_fetch

    sys.stderr.write(f"Serving Cabalmail Apple dashboard on http://{args.host}:{args.port}  (repo: {REPO_ROOT})\n")
    sys.stderr.write(f"Stage source: {REF}{' (fetch each refresh)' if (FETCH and REF != 'local') else ''}\n")
    if MOCK_PATH:
        sys.stderr.write(f"Using mock ASC data: {MOCK_PATH}\n")
    app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
