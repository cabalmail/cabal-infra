"""Tests for .github/scripts/play-release-notes.py.

The Play Console release notes are the *headlines* of a release's `Android:`
entries, under Google Play's 500-character cap, led by a pointer at
CHANGELOG.md. These pin the parsing (prefix scoping, headline extraction,
Markdown stripping, hard-wrap rejoin), the fallback for a release with no
Android entries, and the whole-line overrun trimming.

Run in CI by `.github/workflows/scripts-tests.yml` on pull requests and on
pushes to the named branches. Run by hand from the repo root:

    python3 scripts/tests/test_play_release_notes.py
"""

import importlib.util
import io
import os
import textwrap
import unittest
from contextlib import redirect_stderr

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_spec = importlib.util.spec_from_file_location(
    "play_release_notes",
    os.path.join(REPO_ROOT, ".github", "scripts", "play-release-notes.py"),
)
notes = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(notes)


def render_changelog(text):
    """Run the whole pipeline over a changelog body; return (notes, stderr)."""
    lines = textwrap.dedent(text).splitlines()
    err = io.StringIO()
    with redirect_stderr(err):
        out = notes.render(notes.android_headlines(notes.tokenize(notes.top_section(lines))))
    return out, err.getvalue()


CHANGELOG = """
    # Changelog

    ## [1.3.0] - 2026-08-20

    ### Added
    - Android: **First alpha - not yet for production use.** The native client
      described in the entries below lands in this release for the first time.
    - **Cached message bodies now really go away.** Lambda-side fix, not
      Android-scoped.
    - Apple: **Threaded reader.** Not for Android testers either.
    - Android: **Compose with `on-the-fly` [From](https://example.invalid).**
      Body text that must never reach the notes.

    ### Fixed
    - Apple: **Ghost row.** macOS only.

    ### Changed
    - Android: **Narrower reader margins.** Halved side padding.

    ## [1.2.3] - 2026-08-17

    ### Added
    - Android: **Older entry that must not appear.** Previous release.
"""


class TopSectionAndScoping(unittest.TestCase):
    def test_only_android_headlines_from_top_section_grouped_by_category(self):
        out, err = render_changelog(CHANGELOG)
        self.assertEqual(
            out,
            "See CHANGELOG.md for details.\n"
            "\n"
            "Added:\n"
            "- First alpha - not yet for production use\n"
            "- Compose with on-the-fly From\n"
            "\n"
            "Changed:\n"
            "- Narrower reader margins",
        )
        self.assertEqual(err, "")

    def test_fixed_heading_with_no_android_entry_is_omitted(self):
        out, _ = render_changelog(CHANGELOG)
        self.assertNotIn("Fixed:", out)

    def test_headline_accepts_colon_suffixed_heading(self):
        # Older sections spell the heading `### Added:`.
        out, _ = render_changelog(
            """
            ## [1.0.0] - 2026-01-01

            ### Added:
            - Android: **Hello.** Body.
            """
        )
        self.assertEqual(out, "See CHANGELOG.md for details.\n\nAdded:\n- Hello")

    def test_no_android_entries_gives_fallback(self):
        out, _ = render_changelog(
            """
            ## [1.0.0] - 2026-01-01

            ### Fixed
            - Apple: **Something.** Not ours.
            """
        )
        self.assertEqual(out, notes.FALLBACK_NOTES)
        self.assertLessEqual(len(out), notes.PLAY_NOTES_MAX)

    def test_headline_falls_back_to_first_sentence_without_bold(self):
        out, _ = render_changelog(
            """
            ## [1.0.0] - 2026-01-01

            ### Added
            - Android: Off-style entry with no bold. Second sentence dropped.
            """
        )
        self.assertEqual(out.splitlines()[-1], "- Off-style entry with no bold")

    def test_hard_wrapped_headline_is_rejoined(self):
        out, _ = render_changelog(
            """
            ## [1.0.0] - 2026-01-01

            ### Added
            - Android: **A headline that wraps across the
              hard-wrap boundary.** Body.
            """
        )
        self.assertEqual(out.splitlines()[-1], "- A headline that wraps across the hard-wrap boundary")

    def test_missing_version_section_raises(self):
        with self.assertRaises(RuntimeError):
            notes.top_section(["# Changelog", "nothing here"])


class Overrun(unittest.TestCase):
    def test_trims_whole_trailing_lines_and_warns(self):
        groups = [
            ("Added", ["A" * 200, "B" * 200]),
            ("Fixed", ["C" * 200]),
        ]
        err = io.StringIO()
        with redirect_stderr(err):
            out = notes.render(groups, limit=notes.PLAY_NOTES_MAX)
        self.assertLessEqual(len(out), notes.PLAY_NOTES_MAX)
        # The C bullet went, and the now-empty "Fixed:" heading with it.
        self.assertEqual(out, "See CHANGELOG.md for details.\n\nAdded:\n- " + "A" * 200 + "\n- " + "B" * 200)
        self.assertIn("::warning::", err.getvalue())
        self.assertIn("dropped 1 headline", err.getvalue())
        self.assertIn("C" * 200, err.getvalue())

    def test_never_cuts_mid_line(self):
        groups = [("Added", ["x" * 30 for _ in range(40)])]
        with redirect_stderr(io.StringIO()):
            out = notes.render(groups, limit=200)
        self.assertLessEqual(len(out), 200)
        for line in out.splitlines()[2:]:
            self.assertRegex(line, r"^(Added:|- x{30})$")

    def test_pending_android_fragments_fit_the_budget(self):
        """The pending `Android:` fragments must fit the notes without trimming.

        Simulates the collator over changelog.d/ (fragments grouped by
        category, in the collator's order) and renders the notes. A PR whose
        Android fragment pushes the pending set past Play's cap fails here,
        which is the enforcement half of the headline-budget guidance in
        changelog.d/README.md. Skips when nothing Android-scoped is pending.
        """
        frag_dir = os.path.join(REPO_ROOT, "changelog.d")
        categories = ["added", "changed", "deprecated", "removed", "fixed", "security"]
        section = ["## [9.9.9] - 2026-01-01"]
        pending = False
        for category in categories:
            names = sorted(
                n for n in os.listdir(frag_dir)
                if n.endswith(f".{category}.md") and n != "README.md"
            )
            if not names:
                continue
            section += ["", f"### {category.capitalize()}"]
            for name in names:
                with open(os.path.join(frag_dir, name), encoding="utf-8") as handle:
                    body = handle.read().strip("\n")
                pending = pending or body.startswith("- Android:")
                section.append(body)
        if not pending:
            self.skipTest("no pending Android fragments")
        out, err = render_changelog("\n".join(section))
        self.assertEqual(err, "", "pending Android headlines overrun the Play cap: " + err)
        self.assertLessEqual(len(out), notes.PLAY_NOTES_MAX)


if __name__ == "__main__":
    unittest.main()
