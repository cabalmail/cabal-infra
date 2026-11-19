"""Pin android.yml's rule that Play uploads run one at a time.

Stage and main both publish to one Play app with one service account, and
Play keeps a single open edit per account: a second upload that opens its
edit invalidates the first one's, which then fails with "This Edit has been
deleted" (#2505). The remedy is a concurrency group on the upload job that is
the same for every ref. Nothing in the repository can run GitHub's scheduler,
so this reads the workflow and checks the three properties the remedy rests
on: the job that publishes holds a group, the group does not vary with the
ref, and holding it never cancels an upload already in progress.

The workflow is read as text because the scripts suites are stdlib-only (no
YAML parser). Comment lines are dropped first, so prose about a setting can
never stand in for the setting.
"""

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/android.yml"

# A job header: a key at two spaces of indent, directly under `jobs:`.
_JOB = re.compile(r"^  (?P<name>[A-Za-z0-9_-]+):\s*$")
# What publishes: the wrapper script, or the gradle task it wraps.
_PUBLISHES = re.compile(r"publish-play-bundle\.py|publishBundle")
_GROUP = re.compile(r"^      group:\s*(?P<group>\S.*?)\s*$", re.MULTILINE)
_CANCEL = re.compile(
    r"^      cancel-in-progress:\s*(?P<cancel>\S.*?)\s*$", re.MULTILINE
)


def without_comments(text):
    """The workflow minus its comment-only lines."""
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def jobs(text):
    """{job name: that job's lines as one string}, comments already removed."""
    lines = without_comments(text).splitlines()
    try:
        start = lines.index("jobs:") + 1
    except ValueError:
        return {}
    blocks, current = {}, None
    for line in lines[start:]:
        header = _JOB.match(line)
        if header:
            current = header.group("name")
            blocks[current] = []
        elif current is not None:
            blocks[current].append(line)
    return {name: "\n".join(body) for name, body in blocks.items()}


def job_concurrency(block):
    """(group, cancel-in-progress) of a job's own `concurrency:`, else None.

    Only the job-level key counts: four spaces of indent, with its two
    settings at six.
    """
    match = re.search(
        r"^    concurrency:\s*\n(?P<body>(?:      \S.*\n?)+)", block, re.MULTILINE
    )
    if not match:
        return None
    group = _GROUP.search(match.group("body"))
    cancel = _CANCEL.search(match.group("body"))
    return (
        group.group("group") if group else None,
        cancel.group("cancel") if cancel else None,
    )


class UploadConcurrencyTests(unittest.TestCase):
    def setUp(self):
        self.jobs = jobs(WORKFLOW.read_text(encoding="utf-8"))
        self.publishers = [
            name for name, block in self.jobs.items() if _PUBLISHES.search(block)
        ]

    def test_exactly_one_job_publishes(self):
        # Every publishing job needs the group; pinning that there is one
        # keeps a second from being added without it.
        self.assertEqual(self.publishers, ["upload"])

    def test_the_publishing_job_holds_a_concurrency_group(self):
        for name in self.publishers:
            settings = job_concurrency(self.jobs[name])
            self.assertIsNotNone(settings, f"job {name!r} has no concurrency")
            self.assertTrue(settings[0], f"job {name!r} names no group")

    def test_the_group_is_the_same_for_every_ref(self):
        # An expression is how a group comes to differ between stage and
        # main, which is the whole defect: the workflow's own group is
        # `android-${{ github.ref }}` and never made the two wait.
        for name in self.publishers:
            group, _ = job_concurrency(self.jobs[name]) or (None, None)
            self.assertIsNotNone(group, f"job {name!r} names no group")
            self.assertNotIn("${{", group)
            self.assertNotIn("github.", group)

    def test_a_waiting_upload_never_cancels_the_one_in_progress(self):
        # Cancelling the upload in progress would trade one failed publish
        # for another, possibly between the bundle upload and the commit.
        for name in self.publishers:
            _, cancel = job_concurrency(self.jobs[name]) or (None, None)
            self.assertEqual(cancel, "false")


class WorkflowReaderTests(unittest.TestCase):
    """The reader itself, on text small enough to check by eye."""

    SAMPLE = "\n".join(
        [
            "concurrency:",
            "  group: wf-${{ github.ref }}",
            "  cancel-in-progress: true",
            "jobs:",
            "  build:",
            "    runs-on: ubuntu-latest",
            "  # upload:",
            "  #   concurrency:",
            "  #     group: commented-out",
            "  upload:",
            "    # concurrency:",
            "    #   group: in-a-comment",
            "    concurrency:",
            "      group: one-at-a-time",
            "      cancel-in-progress: false",
            "    steps:",
            "      - run: python3 publish-play-bundle.py",
            "",
        ]
    )

    def test_jobs_are_split_at_their_headers(self):
        self.assertEqual(list(jobs(self.SAMPLE)), ["build", "upload"])

    def test_a_job_without_the_key_has_no_concurrency(self):
        self.assertIsNone(job_concurrency(jobs(self.SAMPLE)["build"]))

    def test_the_workflow_level_group_is_not_a_jobs(self):
        # `build` sits right under the workflow's own concurrency block.
        self.assertNotIn("wf-", jobs(self.SAMPLE)["build"])

    def test_the_job_level_settings_are_read(self):
        self.assertEqual(
            job_concurrency(jobs(self.SAMPLE)["upload"]),
            ("one-at-a-time", "false"),
        )

    def test_commented_out_settings_do_not_count(self):
        commented = self.SAMPLE.replace(
            "    concurrency:\n      group: one-at-a-time\n"
            "      cancel-in-progress: false\n",
            "",
        )
        self.assertIsNone(job_concurrency(jobs(commented)["upload"]))

    def test_text_with_no_jobs_key_yields_no_jobs(self):
        self.assertEqual(jobs("name: nothing\n"), {})


if __name__ == "__main__":
    unittest.main()
