"""Tests for .github/scripts/apple-promotion-verdict.py.

A main push skips apple.yml's test jobs only when the script can show that
the release PR's run already passed every required leg on the same tree.
These pin each way that proof can fail (not a merge, a different tree, no
run, a red run, a run of the wrong kind, a run missing a leg) to a full
re-test, and pin that a lookup error also means a full re-test rather than
a failed job.

Run in CI by `.github/workflows/scripts-tests.yml`. Run by hand from the
repo root:

    python3 scripts/tests/test_apple_promotion_verdict.py
"""

import importlib.util
import io
import os
import re
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_spec = importlib.util.spec_from_file_location(
    "apple_promotion_verdict",
    os.path.join(REPO_ROOT, ".github", "scripts", "apple-promotion-verdict.py"),
)
verdict = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verdict)

MERGE = "0be7316c" + "0" * 32
MAIN_BEFORE = "b9f987b0" + "0" * 32
STAGE_TIP = "3ea56647" + "0" * 32
TREE = "f43f41dc" + "0" * 32


def commit(parents, tree=TREE):
    return {"parents": [{"sha": p} for p in parents], "commit": {"tree": {"sha": tree}}}


def run(run_id, **overrides):
    fields = {
        "id": run_id,
        "event": "pull_request",
        "head_branch": "stage",
        "head_sha": STAGE_TIP,
        "conclusion": "success",
        "html_url": f"https://github.invalid/runs/{run_id}",
    }
    fields.update(overrides)
    return fields


def jobs(*, drop=(), failed=()):
    names = list(verdict.REQUIRED_JOBS) + ["Build CabalmailVision (visionOS)", "approval"]
    return [
        {"name": name, "conclusion": "failure" if name in failed else "success"}
        for name in names
        if name not in drop
    ]


def decide(commits=None, runs=None, jobs_by_run=None):
    commits = commits or {MERGE: commit([MAIN_BEFORE, STAGE_TIP]), STAGE_TIP: commit([MAIN_BEFORE])}
    runs = [run(1)] if runs is None else runs
    jobs_by_run = jobs_by_run or {1: jobs()}
    return verdict.decide(
        MERGE,
        lambda sha: commits[sha],
        lambda sha: [r for r in runs if r["head_sha"] == sha],
        lambda run_id: jobs_by_run[run_id],
    )


class DecideTests(unittest.TestCase):
    def test_a_promotion_whose_release_pr_run_passed_every_leg_skips(self):
        tested, reason = decide()
        self.assertTrue(tested)
        self.assertIn("https://github.invalid/runs/1", reason)

    def test_a_push_that_is_not_a_merge_tests_in_full(self):
        tested, reason = decide(commits={MERGE: commit([MAIN_BEFORE])})
        self.assertFalse(tested)
        self.assertIn("not a two-parent merge", reason)

    def test_a_merge_whose_tree_differs_from_the_stage_tip_tests_in_full(self):
        commits = {
            MERGE: commit([MAIN_BEFORE, STAGE_TIP]),
            STAGE_TIP: commit([MAIN_BEFORE], tree="1" * 40),
        }
        tested, reason = decide(commits=commits)
        self.assertFalse(tested)
        self.assertIn("differs", reason)

    def test_no_run_on_the_stage_tip_tests_in_full(self):
        tested, reason = decide(runs=[])
        self.assertFalse(tested)
        self.assertIn("no successful release-PR run", reason)

    def test_a_red_or_cancelled_run_does_not_count(self):
        for conclusion in ("failure", "cancelled", None):
            with self.subTest(conclusion=conclusion):
                tested, _ = decide(runs=[run(1, conclusion=conclusion)])
                self.assertFalse(tested)

    def test_the_stage_push_run_on_the_same_commit_does_not_count(self):
        # A push run is not the release PR's run: its kit-test matrix and
        # job set differ, and the proof is about the PR run.
        tested, _ = decide(runs=[run(1, event="push")])
        self.assertFalse(tested)

    def test_a_run_from_another_branch_does_not_count(self):
        tested, _ = decide(runs=[run(1, head_branch="fixer/some-branch")])
        self.assertFalse(tested)

    def test_a_green_run_missing_a_required_leg_tests_in_full(self):
        # A PR into stage drops kit-test's visionOS leg and still concludes
        # success, so a green conclusion alone is not the proof.
        tested, reason = decide(jobs_by_run={1: jobs(drop=("Test CabalmailKit (visionOS)",))})
        self.assertFalse(tested)
        self.assertIn("Test CabalmailKit (visionOS)", reason)

    def test_a_required_leg_that_did_not_succeed_tests_in_full(self):
        tested, reason = decide(jobs_by_run={1: jobs(failed=("Test app layer (iOS)",))})
        self.assertFalse(tested)
        self.assertIn("Test app layer (iOS)", reason)

    def test_an_older_complete_run_counts_when_the_newest_is_short(self):
        runs = [run(2), run(1)]
        jobs_by_run = {2: jobs(drop=("apple-gate",)), 1: jobs()}
        tested, reason = decide(runs=runs, jobs_by_run=jobs_by_run)
        self.assertTrue(tested)
        self.assertIn("runs/1", reason)

    def test_the_shortfall_reported_is_the_newest_runs(self):
        runs = [run(2), run(1)]
        jobs_by_run = {2: jobs(drop=("apple-gate",)), 1: jobs(drop=("Test app layer (macOS)",))}
        tested, reason = decide(runs=runs, jobs_by_run=jobs_by_run)
        self.assertFalse(tested)
        self.assertIn("runs/2", reason)
        self.assertIn("apple-gate", reason)


class WorkflowContractTests(unittest.TestCase):
    """REQUIRED_JOBS names jobs by display name, so a rename in apple.yml
    would quietly stop every promotion from matching. That fails safe (main
    pushes test in full), but these turn the slowdown into a red PR."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REPO_ROOT, ".github", "workflows", "apple.yml"), encoding="utf-8") as handle:
            cls.workflow = handle.read()

    def job_block(self, job_id):
        match = re.search(rf"^  {re.escape(job_id)}:\n(.*?)(?=^  \S)", self.workflow, re.M | re.S)
        self.assertIsNotNone(match, f"apple.yml has no {job_id} job")
        return match.group(1)

    def test_the_kit_test_legs_are_named_by_platform(self):
        block = self.job_block("kit-test")
        self.assertIn("name: Test CabalmailKit (${{ matrix.platform }})", block)

    def test_a_release_pr_runs_every_kit_test_platform(self):
        # Only a PR into a branch other than main drops the visionOS leg;
        # a release PR's run must carry it or no promotion can skip.
        block = self.job_block("kit-test")
        matrix = re.search(r"^\s+platform: \$\{\{ (.*) \}\}$", block, re.M)
        self.assertIsNotNone(matrix, "kit-test has no one-line platform matrix")
        expression = matrix.group(1)
        self.assertIn("github.event_name == 'pull_request' && github.base_ref != 'main'", expression)
        self.assertIn("""'["macOS","iOS","visionOS"]'""", expression)
        for name in verdict.REQUIRED_JOBS:
            if name.startswith("Test CabalmailKit ("):
                platform = name[len("Test CabalmailKit ("):-1]
                self.assertIn(f'"{platform}"', expression.split("||")[-1])

    def test_the_app_layer_suites_keep_their_names(self):
        self.assertIn("name: Test app layer (macOS)", self.job_block("app-test"))
        self.assertIn("name: Test app layer (iOS)", self.job_block("ios-app-test"))

    def test_the_gate_is_named_by_its_job_id(self):
        self.assertNotRegex(self.job_block("apple-gate"), r"^    name:")

    def test_every_required_job_is_accounted_for(self):
        covered = {
            "Test CabalmailKit (macOS)",
            "Test CabalmailKit (iOS)",
            "Test CabalmailKit (visionOS)",
            "Test app layer (macOS)",
            "Test app layer (iOS)",
            "apple-gate",
        }
        self.assertEqual(set(verdict.REQUIRED_JOBS), covered)


class MainTests(unittest.TestCase):
    def run_main(self, gh_json):
        with tempfile.TemporaryDirectory() as tmp:
            output = os.path.join(tmp, "output")
            summary = os.path.join(tmp, "summary")
            env = {
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_SHA": MERGE,
                "GITHUB_OUTPUT": output,
                "GITHUB_STEP_SUMMARY": summary,
            }
            stdout = io.StringIO()
            with mock.patch.dict(os.environ, env), mock.patch.object(verdict, "gh_json", gh_json), redirect_stdout(stdout):
                status = verdict.main()
            with open(output, encoding="utf-8") as handle:
                return status, handle.read(), stdout.getvalue()

    def test_a_lookup_error_writes_false_and_exits_zero(self):
        def failing(path):
            raise subprocess.CalledProcessError(1, ["gh", "api", path], stderr="HTTP 502")

        status, output, stdout = self.run_main(failing)
        self.assertEqual(status, 0)
        self.assertEqual(output, "tested=false\n")
        self.assertIn("::warning::", stdout)
        self.assertIn("HTTP 502", stdout)

    def test_an_unexpected_payload_writes_false_and_exits_zero(self):
        status, output, _ = self.run_main(lambda path: {})
        self.assertEqual(status, 0)
        self.assertEqual(output, "tested=false\n")

    def test_main_reads_the_api_paths_it_should(self):
        responses = {
            f"repos/owner/repo/commits/{MERGE}": commit([MAIN_BEFORE, STAGE_TIP]),
            f"repos/owner/repo/commits/{STAGE_TIP}": commit([MAIN_BEFORE]),
            f"repos/owner/repo/actions/workflows/apple.yml/runs?head_sha={STAGE_TIP}&event=pull_request&per_page=50": {
                "workflow_runs": [run(7)]
            },
            "repos/owner/repo/actions/runs/7/jobs?per_page=100": {"jobs": jobs()},
        }
        status, output, _ = self.run_main(lambda path: responses[path])
        self.assertEqual(status, 0)
        self.assertEqual(output, "tested=true\n")


if __name__ == "__main__":
    unittest.main()
