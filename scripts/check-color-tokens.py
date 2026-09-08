#!/usr/bin/env python3
"""Check a colour-token file against a surface table for WCAG contrast.

usage: check-color-tokens.py <tokens.json> [--scheme light|dark] [--hc] [--fail-under]

The token file is the cross-platform source of truth proposed by the colour
audit (docs/1.x/color-tokens-plan.md). Shape:

  {
    "surfaces": { "<name>": { "light": <colour>, "dark": <colour>,
                              "schemes": ["light", "dark"] }, ... },
    "tokens": {
      "<meaning>.<role>": {
        "light": <colour>, "dark": <colour>,
        "role": "text-fg" | "glyph-fg" | "on-fill" | "fill" | "wash" | "border",
        "on": ["<surface>" | "<token>" ...],   # what it is drawn over
        "floor": 4.5,                          # optional; defaults by role
        "wash_opacity": 0.12                   # role == wash only
      }
    }
  }

A surface's optional "schemes" lists the schemes it exists in (watchOS is black
in both, so it is checked against the dark values only).

A <colour> is "#rrggbb", [r, g, b] in 0-255, or "oklch(L C H)" with L in 0-1.
A token whose "on" names another token is drawn over that token's colour
(e.g. on-fill text over a fill); a wash token is composited over each of its
"on" surfaces at wash_opacity and the *result* is what foreground tokens that
name the wash are measured against.

No third-party dependencies; the WCAG maths matches the tester's instrument
(logs/contrast-1318-0829.py) so the numbers here are the numbers the screen
produces.
"""
import json
import math
import sys

HIGH_CONTRAST = False  # --hc: prefer light-hc / dark-hc values where a token has them

FLOOR_BY_ROLE = {
    "text-fg": 4.5,
    "glyph-fg": 4.5,   # glyphs are small; hold them to the text floor
    "on-fill": 4.5,
    "border": 3.0,
    "fill": 3.0,       # a fill's own edge against the surface it sits on
    "wash": 1.0,       # a wash is a background; measured through its foreground
    "large-text": 3.0,
}


def srgb_to_linear(v):
    v /= 255.0
    return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4


def linear_to_srgb(v):
    v = max(0.0, min(1.0, v))
    return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def luminance(rgb):
    r, g, b = (srgb_to_linear(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def oklch_to_rgb(L, C, H):
    """OKLCH -> sRGB 0-255 (Björn Ottosson's reference matrices)."""
    h = math.radians(H)
    a, b = C * math.cos(h), C * math.sin(h)
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    lr = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return tuple(round(linear_to_srgb(v) * 255) for v in (lr, lg, lb))


def parse_colour(spec):
    if isinstance(spec, (list, tuple)) and len(spec) == 3:
        return tuple(int(c) for c in spec)
    if isinstance(spec, str):
        s = spec.strip()
        if s.startswith("#") and len(s) == 7:
            return tuple(int(s[i:i + 2], 16) for i in (1, 3, 5))
        if s.startswith("oklch(") and s.endswith(")"):
            parts = s[6:-1].replace("%", "").split()
            L, C, H = (float(p) for p in parts[:3])
            if L > 1:
                L /= 100.0
            return oklch_to_rgb(L, C, H)
    raise ValueError(f"unparseable colour {spec!r}")


def composite(fg, bg, alpha):
    return tuple(round(alpha * f + (1 - alpha) * b) for f, b in zip(fg, bg))


def resolve(doc, scheme):
    """Return {name: rgb} for every surface and token in one scheme, with
    wash tokens expanded to one entry per surface they sit on."""
    colours = {}
    for name, surf in doc.get("surfaces", {}).items():
        if scheme in surf.get("schemes", ["light", "dark"]):
            colours[name] = parse_colour(surf[scheme])
    tokens = doc.get("tokens", {})
    # Two passes: plain tokens first, then washes that depend on surfaces.
    for name, tok in tokens.items():
        if tok.get("role") != "wash":
            key = f"{scheme}-hc" if HIGH_CONTRAST and f"{scheme}-hc" in tok else scheme
            colours[name] = parse_colour(tok[key])
    for name, tok in tokens.items():
        if tok.get("role") == "wash":
            base = parse_colour(tok[scheme])
            alpha = float(tok.get("wash_opacity", 0.12))
            for surface in tok.get("on", []):
                if surface in colours:
                    colours[f"{name}@{surface}"] = composite(base, colours[surface], alpha)
    return colours


def check(doc, scheme):
    colours = resolve(doc, scheme)
    rows = []
    for name, tok in doc.get("tokens", {}).items():
        role = tok.get("role", "text-fg")
        if role == "wash":
            continue
        floor = float(tok.get("floor", FLOOR_BY_ROLE.get(role, 4.5)))
        fg = colours[name]
        for target in tok.get("on", []):
            bgs = [(target, colours[target])] if target in colours else \
                  [(k, v) for k, v in colours.items() if k.startswith(f"{target}@")]
            if not bgs:
                if target in doc.get("surfaces", {}) or target in doc.get("tokens", {}):
                    continue  # surface or wash absent from this scheme
                rows.append((name, target, scheme, None, floor, "missing surface"))
                continue
            for bg_name, bg in bgs:
                ratio = contrast(fg, bg)
                rows.append((name, bg_name, scheme, ratio, floor,
                             "pass" if ratio >= floor else "FAIL"))
    return rows


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    global HIGH_CONTRAST
    HIGH_CONTRAST = "--hc" in argv
    schemes = ["light", "dark"]
    if "--scheme" in argv:
        schemes = [argv[argv.index("--scheme") + 1]]
    with open(path) as fh:
        doc = json.load(fh)
    failed = 0
    print(f"{'token':34s} {'over':40s} {'scheme':6s} {'ratio':>7s} {'floor':>5s}  verdict")
    for scheme in schemes:
        for name, bg, sch, ratio, floor, verdict in check(doc, scheme):
            r = f"{ratio:7.2f}" if ratio is not None else "      -"
            print(f"{name:34s} {bg:40s} {sch:6s} {r} {floor:5.1f}  {verdict}")
            if verdict != "pass":
                failed += 1
    print(f"\n{failed} failing pairs" if failed else "\nall pairs clear their floors")
    return 1 if failed and "--fail-under" in argv else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
