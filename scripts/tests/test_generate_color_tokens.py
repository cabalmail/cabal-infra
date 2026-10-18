"""Tests for scripts/generate-color-tokens.py's Apple catalog output.

actool has no (watch idiom, contrast high) slot: an entry carrying that pair
is never assigned, so it draws nothing and costs one "unassigned child"
warning per colour set on every build of the Kit (#1841 — 66 of them). The
generator used to emit one unconditionally, so the rule is pinned here on the
generated file map rather than on the tree, which test_check_color_tokens.py
already holds to the generator via --check.

Run from the repository root:

    python3 -m unittest discover -s scripts/tests -p "test_*.py" -v
"""
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts" / "generate-color-tokens.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_color_tokens", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def generated_colorsets():
    """Every generated `*.colorset/Contents.json`, as (path, parsed) pairs."""
    gen = load_generator()
    with open(gen.TOKENS, encoding="utf-8") as fh:
        doc = json.load(fh)
    return [(rel, json.loads(content)) for rel, content in gen.generate(doc).items()
            if rel.parent.suffix == ".colorset"]


class AppleCatalogTests(unittest.TestCase):
    def test_no_unassignable_watch_high_contrast_entry(self):
        offenders = []
        for rel, contents in generated_colorsets():
            for colour in contents.get("colors", []):
                appearances = colour.get("appearances", [])
                high = any(a.get("appearance") == "contrast" and a.get("value") == "high"
                           for a in appearances)
                if colour.get("idiom") == "watch" and high:
                    offenders.append(str(rel))
        self.assertEqual(offenders, [],
                         "watch-idiom high-contrast entries are unassignable and warn on every "
                         f"build: {len(offenders)} colour set(s)")

    def test_watch_entry_is_still_generated(self):
        """The negative control: dropping the high-contrast entry must not
        drop the watch idiom itself, which is what the watch actually draws.
        Only the Kit's token catalog carries a watch entry per colour set;
        the app targets' AccentColor sets are universal."""
        colorsets = [pair for pair in generated_colorsets()
                     if "ColorTokens.xcassets" in str(pair[0])]
        self.assertTrue(colorsets, "no token colorsets were generated")
        for rel, contents in colorsets:
            idioms = [c.get("idiom") for c in contents.get("colors", [])]
            self.assertIn("watch", idioms, f"{rel} lost its watch entry")


if __name__ == "__main__":
    unittest.main()
