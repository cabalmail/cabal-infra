"""Regression tests for the release dashboard's fix-claim scan.

`claimed_issues` decides which merged stage PRs hold Promote, so a false
positive disables releasing. Its regex used to allow any 30 non-`#`
characters between the fix verb and the issue refs, which read prose about
an issue's *lifecycle* as a fix claim: PR #2065, a docs-only change whose
body said "#1911 closed on 2026-10-17, with #2060 and #2061 filed from it"
(issues filed, the opposite of fixed), held Promote on both issues. The
negative cases below are real phrases from merged stage PRs that matched
the old gap and must not match; the positive cases are the claim shapes
the fixer and humans actually write, which must keep matching.

Run in CI by `.github/workflows/scripts-tests.yml` on pull requests and on
pushes to the named branches. Run by hand from the repo root:

    python3 scripts/tests/test_release_dashboard_claims.py
"""

import importlib.util
import os
import sys
import types
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load_dashboard():
    """Load release-dashboard.py, stubbing flask if it isn't installed.

    The CI runner is stdlib-only and the dashboard exits at import when
    flask is missing; the pieces under test here never touch it.
    """
    try:
        import flask  # noqa: F401  pylint: disable=unused-import
    except ImportError:
        flask = types.ModuleType("flask")

        class _Flask:  # minimal surface the module touches at import time
            def __init__(self, _name):
                pass

            def route(self, *_args, **_kwargs):
                def deco(fn):
                    return fn
                return deco

        flask.Flask = _Flask
        flask.jsonify = lambda *a, **k: None
        flask.Response = object
        flask.request = object()
        sys.modules["flask"] = flask
    spec = importlib.util.spec_from_file_location(
        "release_dashboard",
        os.path.join(REPO_ROOT, "scripts", "release-dashboard.py"),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dashboard = _load_dashboard()


def pr_node(body="", head="claude/feature-branch", closing=()):
    """A merged-PR GraphQL node shaped like STAGE_PR_QUERY returns."""
    return {
        "body": body,
        "headRefName": head,
        "closingIssuesReferences": {"nodes": [{"number": n} for n in closing]},
    }


class FixClaimTests(unittest.TestCase):
    """The claim shapes people actually write must keep counting."""

    def claims(self, body):
        return dashboard.claimed_issues(pr_node(body=body))

    def test_plain_fixes(self):
        self.assertEqual(self.claims("Quieted the warning.\n\nFixes #1911."), {1911})

    def test_fix_for(self):
        self.assertEqual(self.claims("fix for #1908, from workstream 1.6"), {1908})

    def test_fixes_issue_list(self):
        self.assertEqual(self.claims("fixes issue #12 and #34"), {12, 34})

    def test_comma_separated_list(self):
        self.assertEqual(self.claims("Fixes #1970, #1989, #1995 and #1996."),
                         {1970, 1989, 1995, 1996})

    def test_addresses_one_per_line(self):
        self.assertEqual(self.claims("Addresses #1820\nAddresses #1823"), {1820, 1823})

    def test_colon_after_verb(self):
        self.assertEqual(self.claims("Fixed: #77"), {77})

    def test_closing_references(self):
        self.assertEqual(dashboard.claimed_issues(pr_node(closing=(5,))), {5})

    def test_fixer_branch(self):
        self.assertEqual(
            dashboard.claimed_issues(pr_node(head="fixer/123-sidebar-crash")), {123})


class LifecycleProseTests(unittest.TestCase):
    """Prose about issues near a fix verb is not a claim.

    Every body here matched the old 30-character gap and would have held
    Promote; each must now claim nothing. If a change to FIX_CLAIM_RE
    re-widens the gap, these fail.
    """

    def claims(self, body):
        return dashboard.claimed_issues(pr_node(body=body))

    def test_issues_filed_from_a_closed_one(self):
        # PR #2065, the docs-only PR that held Promote on #2060/#2061.
        body = ("the Progress table and Status lines record PR 2's stage check "
                "(#1911 closed on 2026-10-17, with #2060 and #2061 filed from it) "
                "and PR 6's stage proof, which passed.")
        self.assertEqual(self.claims(body), set())

    def test_not_fixed_here(self):
        # PR #1997's bug inventory.
        self.assertEqual(
            self.claims("Bugs found, not fixed here: #1995 (visionOS Mail tab)."),
            set())

    def test_closed_as_ui_state(self):
        # PR #2017/#2009: "closed" describing windows, not an issue.
        self.assertEqual(
            self.claims("both work with every main window closed (#1162)."),
            set())

    def test_closed_then_unrelated_ref(self):
        # PR #1907: a closed issue handing work to another.
        self.assertEqual(
            self.claims("Part 2 of #1815 (closed; #1839 handed it to 1.6)."),
            set())

    def test_bare_mention(self):
        self.assertEqual(self.claims("same class as #1191, filed separately"), set())


if __name__ == "__main__":
    unittest.main()
