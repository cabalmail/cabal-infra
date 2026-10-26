#!/usr/bin/env python3
#
# Decide whether a push to main may skip apple.yml's test jobs.
#
# main receives only stage promotions, merged as merge commits, so a main
# push's tree is the stage tip's, and the release PR's apple.yml run has
# already tested that tree, with every test leg the push would run (a PR
# into main keeps kit-test's visionOS leg). Running the suite again on the
# push re-tests nothing new: it holds about five macOS runners and puts ten
# minutes in front of the prod upload.
#
# apple.yml's promotion-verdict job runs this on main pushes. It writes
# `tested=true` to $GITHUB_OUTPUT only when it can show all of:
#
#   - the pushed commit is a merge commit,
#   - its tree is its second parent's (the stage tip's) tree, and
#   - an apple.yml pull_request run from `stage` on that second parent
#     concluded success, with every job in REQUIRED_JOBS succeeding in its
#     latest attempt.
#
# Anything else, an API error included, writes `tested=false`, and the push
# runs the full suite. The script never fails the job: when it cannot tell,
# the answer is to test again. The uploads that follow archive every app
# either way, so a skipped suite never means an unbuilt app.
#
# Required env:
#   GITHUB_REPOSITORY  owner/repo
#   GITHUB_SHA         the pushed commit
#   GITHUB_OUTPUT      step output file
#   GH_TOKEN           read by `gh`; needs actions: read and contents: read
# Optional env:
#   GITHUB_STEP_SUMMARY  the verdict and its reason are appended here
#   APPLE_WORKFLOW       workflow file to look up runs of (default apple.yml)

import json
import os
import subprocess
import sys

# The legs a main push runs before `approval`, by job display name, plus
# the gate that sums a run up. A rename in apple.yml must be mirrored here;
# until it is, no release-PR run matches and main pushes test in full,
# which is slow but never wrong.
REQUIRED_JOBS = (
    "Test CabalmailKit (macOS)",
    "Test CabalmailKit (iOS)",
    "Test CabalmailKit (visionOS)",
    "Test app layer (macOS)",
    "Test app layer (iOS)",
    "apple-gate",
)


def decide(push_sha, get_commit, get_runs, get_jobs):
    """Return (tested, reason) for the push of `push_sha`.

    The three getters wrap the GitHub API so tests can fake it:
    get_commit(sha) returns a commit object (`parents`, `commit.tree.sha`),
    get_runs(sha) the workflow's runs on that head SHA, newest first, and
    get_jobs(run_id) the jobs of a run's latest attempt.
    """
    push = get_commit(push_sha)
    parents = push.get("parents") or []
    if len(parents) != 2:
        return False, f"{push_sha[:8]} is not a two-parent merge commit"
    stage_sha = parents[1]["sha"]
    stage_tip = get_commit(stage_sha)
    if push["commit"]["tree"]["sha"] != stage_tip["commit"]["tree"]["sha"]:
        return False, f"the tree of {push_sha[:8]} differs from its second parent {stage_sha[:8]}'s"

    candidates = [
        run
        for run in get_runs(stage_sha)
        if run.get("event") == "pull_request"
        and run.get("head_branch") == "stage"
        and run.get("head_sha") == stage_sha
        and run.get("conclusion") == "success"
    ]
    if not candidates:
        return False, f"no successful release-PR run on {stage_sha[:8]}"

    shortfall = None
    for run in candidates:
        results = {job["name"]: job.get("conclusion") for job in get_jobs(run["id"])}
        missing = [name for name in REQUIRED_JOBS if results.get(name) != "success"]
        if not missing:
            return True, f"release-PR run {run.get('html_url', run['id'])} passed every required leg on this tree"
        if shortfall is None:
            shortfall = (run, missing)
    run, missing = shortfall
    return False, f"release-PR run {run.get('html_url', run['id'])} did not pass {', '.join(missing)}"


def gh_json(path):
    """GET a REST path through `gh api` and parse the JSON."""
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def write(env_name, text):
    path = os.environ.get(env_name)
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text)


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ["GITHUB_SHA"]
    workflow = os.environ.get("APPLE_WORKFLOW", "apple.yml")
    try:
        tested, reason = decide(
            sha,
            lambda s: gh_json(f"repos/{repo}/commits/{s}"),
            lambda s: gh_json(
                f"repos/{repo}/actions/workflows/{workflow}/runs?head_sha={s}&event=pull_request&per_page=50"
            ).get("workflow_runs", []),
            lambda run_id: gh_json(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100").get("jobs", []),
        )
    except (subprocess.CalledProcessError, KeyError, ValueError, TypeError) as err:
        detail = err.stderr.strip() if isinstance(err, subprocess.CalledProcessError) else repr(err)
        print(f"::warning::[promotion-verdict] lookup failed, so this push tests in full: {detail}")
        tested, reason = False, "the lookup failed"

    verdict = "true" if tested else "false"
    print(f"[promotion-verdict] tested={verdict}: {reason}")
    write("GITHUB_OUTPUT", f"tested={verdict}\n")
    if tested:
        write("GITHUB_STEP_SUMMARY", f"Test jobs skipped: {reason}.\n")
    else:
        write("GITHUB_STEP_SUMMARY", f"Full test suite: {reason}.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
