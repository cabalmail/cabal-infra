"""Tests for scripts/check-color-tokens.py.

Two things are pinned here. First, the instrument: the checker must reproduce
the ratios the tester measured off real screenshots in #1453 and #1456, so a
change to the maths that drifts from the screen is caught. Second, the
handoff: the token file under docs/1.x/design_handoff_color_tokens/ must have
no failing pairs, so a palette edit that breaks a floor fails the PR rather
than the next tester sweep.

Run from the repository root:

    python3 -m unittest discover -s scripts/tests -p "test_*.py" -v
"""
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-color-tokens.py"
HANDOFF = ROOT / "docs" / "1.x" / "design_handoff_color_tokens" / "color-tokens.json"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_color_tokens", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class InstrumentTests(unittest.TestCase):
    """The maths matches the tester's screenshot measurements."""

    def setUp(self):
        self.c = load_checker()

    def test_reported_ratios(self):
        white = (255, 255, 255)
        cases = [
            ((255, 141, 40), white, 2.31),   # #1453 shipped systemOrange
            ((166, 92, 26), white, 5.04),    # #1457 darkened 0.65
            ((140, 78, 22), white, 6.53),    # #1461 darkened 0.55
            ((255, 146, 48), (44, 44, 46), 6.24),  # #1453 dark control
            ((43, 99, 58), white, 7.12),     # #1318 accent on white
        ]
        for fg, bg, expected in cases:
            with self.subTest(fg=fg, bg=bg):
                self.assertAlmostEqual(self.c.contrast(fg, bg), expected, places=2)

    def test_chip_composite_matches_photographed_capsule(self):
        # #1461 photographed the 12% wash of (140,78,22) over white as
        # (241,234,227) and the label over it at 5.48:1.
        wash = self.c.composite((140, 78, 22), (255, 255, 255), 0.12)
        self.assertEqual(wash, (241, 234, 227))
        self.assertAlmostEqual(self.c.contrast((140, 78, 22), wash), 5.48, places=2)

    def test_oklch_round_trip_matches_react_forest(self):
        # React's Forest accent oklch(0.45 0.09 150) is the sidebar glyph the
        # tester measured as (43, 99, 58); one bit of rounding is allowed.
        rgb = self.c.parse_colour("oklch(0.45 0.09 150)")
        for got, want in zip(rgb, (43, 99, 58)):
            self.assertLessEqual(abs(got - want), 1)

    def test_watch_surface_is_dark_only(self):
        doc = {
            "surfaces": {"watch": {"light": [0, 0, 0], "dark": [0, 0, 0], "schemes": ["dark"]}},
            "tokens": {"t.fg": {"role": "text-fg", "light": [0, 0, 0], "dark": [255, 255, 255],
                                "on": ["watch"]}},
        }
        self.assertEqual(self.c.check(doc, "light"), [])
        rows = self.c.check(doc, "dark")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][-1], "pass")


class HandoffTests(unittest.TestCase):
    """The token file handed to Design clears every floor."""

    def setUp(self):
        self.c = load_checker()
        with open(HANDOFF, encoding="utf-8") as fh:
            self.doc = json.load(fh)

    def test_no_failing_pairs(self):
        failing = [row for scheme in ("light", "dark")
                   for row in self.c.check(self.doc, scheme) if row[-1] != "pass"]
        self.assertEqual(failing, [], "\n".join(str(r) for r in failing))

    def test_high_contrast_variants_clear_the_floors_too(self):
        self.c.HIGH_CONTRAST = True
        try:
            failing = [row for scheme in ("light", "dark")
                       for row in self.c.check(self.doc, scheme) if row[-1] != "pass"]
        finally:
            self.c.HIGH_CONTRAST = False
        self.assertEqual(failing, [], "\n".join(str(r) for r in failing))

    def test_forest_is_the_logo_green(self):
        tokens = self.doc["tokens"]
        for name in ("brand.forest", "accent.forest.fg", "accent.forest.fill"):
            with self.subTest(token=name):
                self.assertEqual(self.c.parse_colour(tokens[name]["light"]), (0x2E, 0x52, 0x35))
                self.assertEqual(self.c.parse_colour(tokens[name]["dark"]), (0x8D, 0xC8, 0x99))

    def test_every_family_has_all_roles(self):
        tokens = self.doc["tokens"]
        for family in ("success", "warning", "danger", "info", "flagged"):
            for role in ("fg", "fill", "on-fill", "wash"):
                self.assertIn(f"{family}.{role}", tokens)
        for name in ("ink", "oxblood", "forest", "azure", "amber", "plum"):
            for role in ("fg", "fill", "on-fill", "wash"):
                self.assertIn(f"accent.{name}.{role}", tokens)


if __name__ == "__main__":
    unittest.main()
