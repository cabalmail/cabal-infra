"""Regression tests for the dashboard's git facts (issue #922).

`git_dates` and `feature_landings` used to gate on a `.git` *directory*, so in
a linked worktree — where `.git` is a file holding a gitdir pointer — both
returned empty and the dashboard rendered with no fragment dates and every
feature `furthest: none`, silently and with exit 0.

Run in CI by `.github/workflows/scripts-tests.yml` on pull requests and on
pushes to the named branches. Run by hand from the repo root:

    python3 scripts/tests/test_apple_release_dashboard_git.py
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_spec = importlib.util.spec_from_file_location(
    "apple_release_dashboard",
    os.path.join(REPO_ROOT, "scripts", "apple-release-dashboard.py"),
)
dashboard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dashboard)


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, text=True)


class GitFactsInAWorktreeTests(unittest.TestCase):
    """A scratch repo with one changelog fragment, read from both a full
    checkout and a linked worktree off the same repo."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.checkout = os.path.join(cls._tmp.name, "checkout")
        os.makedirs(os.path.join(cls.checkout, "changelog.d"))
        git(cls._tmp.name, "init", "-q", "-b", "stage", cls.checkout)
        git(cls.checkout, "config", "user.email", "fixer@example.com")
        git(cls.checkout, "config", "user.name", "Fixer")
        cls.fragment = "worktree-git-facts.fixed.md"
        with open(os.path.join(cls.checkout, "changelog.d", cls.fragment), "w") as handle:
            handle.write("- Apple: **Worktree git facts.** Read them from a linked worktree.\n")
        git(cls.checkout, "add", "-A")
        git(cls.checkout, "commit", "-q", "-m", "Worktree git facts")
        git(cls.checkout, "tag", "0.0.1")
        cls.worktree = os.path.join(cls._tmp.name, "wt")
        git(cls.checkout, "worktree", "add", "-q", "--detach", cls.worktree)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        # Both functions memoize per (repo, ref, key); a hit from the checkout
        # would mask an empty answer from the worktree.
        dashboard._FRAG_DATE_CACHE.clear()
        dashboard._LANDING_CACHE.clear()

    def test_the_worktree_is_recognised_as_a_repo(self):
        self.assertTrue(os.path.isfile(os.path.join(self.worktree, ".git")),
                        "a linked worktree's .git is a file, not a directory")
        self.assertTrue(dashboard.is_git_repo(self.worktree))
        self.assertTrue(dashboard.is_git_repo(self.checkout))

    def test_a_non_repo_directory_still_yields_no_git_facts(self):
        outside = os.path.join(self._tmp.name, "not-a-repo")
        os.makedirs(outside, exist_ok=True)
        self.assertFalse(dashboard.is_git_repo(outside))

    def test_fragment_and_tag_dates_come_back_from_a_worktree(self):
        fragments = [{"file": self.fragment}]
        expected = dashboard.git_dates(self.checkout, fragments)

        frag_dates, tag_dates = dashboard.git_dates(self.worktree, fragments)

        self.assertEqual(frag_dates, expected[0])
        self.assertIn(self.fragment, frag_dates)
        self.assertIn("0.0.1", tag_dates)

    def test_feature_landings_come_back_from_a_worktree(self):
        summaries = ["Worktree git facts."]
        landings = dashboard.feature_landings(self.worktree, summaries)

        self.assertIn(summaries[0], landings)
        self.assertIsInstance(landings[summaries[0]], int)


if __name__ == "__main__":
    unittest.main(verbosity=2)
