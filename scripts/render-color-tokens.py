#!/usr/bin/env python3
"""Render the colour-token file as Claude Design preview cards.

usage: render-color-tokens.py <tokens.json> <out-dir>

Writes one self-contained HTML card per token family into <out-dir>/colors/,
each starting with the `@dsCard` marker the Design System pane indexes. Every
card shows the light and dark value side by side with the worst contrast
ratio the checker (scripts/check-color-tokens.py) finds for it, so Design sees
the same numbers the acceptance test will apply.
"""
import html
import importlib.util
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("checker", HERE / "check-color-tokens.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

CSS = """
<style>
  body { margin: 0; font: 13px/1.4 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; color: #222; background: #fff; }
  h1 { font-size: 15px; margin: 0 0 4px; }
  p.lede { margin: 0 0 12px; color: #555; max-width: 70ch; }
  .schemes { display: grid; grid-template-columns: 1fr 1fr; gap: 0; }
  .scheme { padding: 14px 16px; }
  .scheme.light { background: #ffffff; color: #1c1c1e; }
  .scheme.dark { background: #1c1c1e; color: #f2f2f7; }
  .scheme h2 { font-size: 11px; letter-spacing: .08em; text-transform: uppercase; margin: 0 0 10px; opacity: .6; }
  .row { display: grid; grid-template-columns: 34px 1fr auto; gap: 10px; align-items: center; padding: 5px 0; }
  .sw { width: 34px; height: 24px; border-radius: 6px; box-shadow: inset 0 0 0 1px rgba(127,127,127,.35); }
  .name { font-weight: 600; }
  .val { font-family: ui-monospace, Menlo, monospace; font-size: 11px; opacity: .75; }
  .ratio { font-family: ui-monospace, Menlo, monospace; font-size: 11px; white-space: nowrap; }
  .pass { color: #1f7a3a; } .dark .pass { color: #79c289; }
  .fail { color: #b3261e; font-weight: 700; } .dark .fail { color: #ffb4ab; }
  .demo { margin-top: 6px; display: flex; gap: 8px; flex-wrap: wrap; }
  .chip { padding: 2px 9px; border-radius: 999px; font-size: 11px; font-weight: 600; }
  .pill { padding: 4px 12px; border-radius: 8px; font-size: 12px; font-weight: 600; }
  .note { font-size: 11px; opacity: .7; margin: 2px 0 8px 44px; }
  .status { font-size: 10px; padding: 1px 6px; border-radius: 4px; background: rgba(127,127,127,.18); margin-left: 6px; font-weight: 500; }
</style>
"""


def hexs(rgb):
    return "#%02x%02x%02x" % tuple(rgb)


def card(title, lede, body):
    return (f'<!-- @dsCard group="Colors" -->\n<!doctype html><html><head><meta charset="utf-8">'
            f'<title>{html.escape(title)}</title>{CSS}</head><body>'
            f'<div style="padding:14px 16px 0"><h1>{html.escape(title)}</h1><p class="lede">{html.escape(lede)}</p></div>'
            f'{body}</body></html>\n')


def worst(rows, name):
    mine = [r for r in rows if r[0] == name and r[3] is not None]
    if not mine:
        return None
    return min(mine, key=lambda r: r[3])


def token_row(doc, name, scheme, rows, colours):
    tok = doc["tokens"][name]
    rgb = colours.get(name) or checker.parse_colour(tok[scheme])
    w = worst(rows, name)
    ratio = ""
    if w:
        cls = "pass" if w[5] == "pass" else "fail"
        ratio = f'<span class="ratio {cls}">{w[3]:.2f}:1 on {html.escape(w[1])}</span>'
    status = f'<span class="status">{tok["status"]}</span>' if tok.get("status") else ""
    return (f'<div class="row"><div class="sw" style="background:{hexs(rgb)}"></div>'
            f'<div><span class="name">{html.escape(name)}</span>{status}<br><span class="val">{html.escape(str(tok[scheme]))} · {hexs(rgb)}</span></div>'
            f'{ratio}</div>')


def scheme_panel(doc, names, scheme, demo=None):
    rows = checker.check(doc, scheme)
    colours = checker.resolve(doc, scheme)
    out = [f'<div class="scheme {scheme}"><h2>{scheme}</h2>']
    for n in names:
        out.append(token_row(doc, n, scheme, rows, colours))
        if demo:
            out.append(demo(doc, n, scheme, colours))
    out.append("</div>")
    return "".join(out)


def family_demo(doc, name, scheme, colours):
    """For a `.fg` token, show the text on its wash and the fill with on-fill."""
    if not name.endswith(".fg"):
        return ""
    fam = name[:-3]
    fg = hexs(colours[name])
    fill = colours.get(f"{fam}.fill")
    on = colours.get(f"{fam}.on-fill")
    wash_key = next((k for k in colours if k.startswith(f"{fam}.wash@apple-form")), None)
    parts = []
    if wash_key:
        parts.append(f'<span class="chip" style="color:{fg};background:{hexs(colours[wash_key])}">SPF pass</span>')
    parts.append(f'<span class="chip" style="color:{fg}">&#9679; {html.escape(fam)} text</span>')
    if fill and on:
        parts.append(f'<span class="pill" style="background:{hexs(fill)};color:{hexs(on)}">Action</span>')
    return f'<div class="demo" style="margin-left:44px">{"".join(parts)}</div>'


def surfaces_card(doc):
    body = ['<div class="schemes">']
    for scheme in ("light", "dark"):
        body.append(f'<div class="scheme {scheme}"><h2>{scheme}</h2>')
        for name, s in doc["surfaces"].items():
            if scheme not in s.get("schemes", ["light", "dark"]):
                continue
            rgb = checker.parse_colour(s[scheme])
            body.append(f'<div class="row"><div class="sw" style="background:{hexs(rgb)}"></div>'
                        f'<div><span class="name">{html.escape(name)}</span><br><span class="val">{hexs(rgb)}</span></div></div>'
                        f'<div class="note">{html.escape(s.get("note", ""))}</div>')
        body.append("</div>")
    body.append("</div>")
    return card("Surfaces", "The backgrounds every foreground token is measured against. Not tokens; do not change.", "".join(body))


def main(argv):
    doc = json.load(open(argv[1]))
    out = pathlib.Path(argv[2]) / "colors"
    out.mkdir(parents=True, exist_ok=True)
    tokens = doc["tokens"]
    fams = {
        "brand": (["brand.forest"], "Forest Green, the logo colour. Fixed. The Forest accent adopts it; every other green must read as distinct from it."),
        "accents": ([n for n in tokens if n.startswith("accent.")], "The user-selectable accent, six choices. Unread, selected, links and primary actions are roles of the accent, not separate colours. Amber light and Oxblood dark carry candidates because the current values fail as text."),
        "semantic": ([n for n in tokens if n.split(".")[0] in ("success", "warning", "danger", "info", "flagged")], "Semantic states, each with fg, fill, on-fill, wash. Success must not read as Forest; flagged is gold, not the warning orange; danger is the only red."),
        "flags": ([n for n in tokens if n.startswith("flag.")], "The user's custom flag colours by name. Fills only (dots and swatches beside their name), 3:1 non-text floor. Names are user data."),
        "swatches": ([n for n in tokens if n.startswith("swatch.")], "Sender and address identity avatars with initials. Decorative; only swatch.ink over each swatch is measured."),
    }
    demo = {"accents": family_demo, "semantic": family_demo}
    for fam, (names, lede) in fams.items():
        body = '<div class="schemes">' + scheme_panel(doc, names, "light", demo.get(fam)) + scheme_panel(doc, names, "dark", demo.get(fam)) + "</div>"
        (out / f"{fam}.html").write_text(card(f"Colour tokens: {fam}", lede, body), encoding="utf-8")
    (out / "surfaces.html").write_text(surfaces_card(doc), encoding="utf-8")
    print("wrote", sorted(p.name for p in out.iterdir()))


if __name__ == "__main__":
    main(sys.argv)
