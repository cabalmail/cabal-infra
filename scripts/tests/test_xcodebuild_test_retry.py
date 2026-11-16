"""Tests for .github/scripts/xcodebuild-test.sh.

apple.yml's Kit simulator jobs run their test command through this wrapper,
which runs it once more when the test runner never connected (#2436). These
pin the wrapper around that decision (the decision itself is
runner-hung-before-tests.py, with its own suite): the command is run again
only for that failure and only with --retry-hung-runner, never more than
once, and the step's exit status is always that of the last run, so a second
run can not turn a failure green or hide one.

The wrapper runs for real, with a fake test command whose outcome per call
comes from a plan, and a fake `xcbeautify` (cat) first on PATH. Needs `bash`
and `python3`. Run in CI by `.github/workflows/scripts-tests.yml`. Run by
hand from the repo root:

    python3 scripts/tests/test_xcodebuild_test_retry.py
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO_ROOT, ".github", "scripts", "xcodebuild-test.sh")

# Each call takes the next line of the plan: what to print and how to exit.
FAKE_COMMAND = r"""#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_STATE"
n=$(( $(cat "$state/calls") + 1 ))
echo "$n" > "$state/calls"
echo "args: $*"
case "$(sed -n "${n}p" "$state/plan")" in
  pass)
    echo "Test Suite 'All tests' started at 2026-11-13 04:42:15.489."
    echo "	 Executed 3 tests, with 0 failures (0 unexpected) in 2.221 (2.238) seconds"
    echo "** TEST SUCCEEDED **" ;;
  fail)
    echo "Test Suite 'All tests' started at 2026-11-13 04:42:15.489."
    echo "	 Executed 3 tests, with 1 failure (0 unexpected) in 2.221 (2.238) seconds"
    echo "** TEST FAILED **" >&2
    exit 65 ;;
  hung)
    echo "Testing failed:"
    echo "	xctest (5308) encountered an error (The test runner hung before establishing connection.)" >&2
    echo "** TEST FAILED **"
    exit 65 ;;
  hung-but-green)
    echo "	xctest (5308) encountered an error (The test runner hung before establishing connection.)"
    exit 0 ;;
  *)
    echo "fake command: no plan for call $n" >&2
    exit 64 ;;
esac
"""


class Run:
    """One run of the wrapper: exit status, output, calls made, logs left."""

    def __init__(self, plan, retry=True):
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = os.path.join(tmp, "bin")
            os.mkdir(bin_dir)
            command = os.path.join(bin_dir, "fake-xcodebuild")
            beautify = os.path.join(bin_dir, "xcbeautify")
            for path, body in ((command, FAKE_COMMAND), (beautify, "#!/usr/bin/env bash\nexec cat\n")):
                with open(path, "w", encoding="utf-8") as f:
                    f.write(body)
                os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
            with open(os.path.join(tmp, "calls"), "w", encoding="utf-8") as f:
                f.write("0")
            with open(os.path.join(tmp, "plan"), "w", encoding="utf-8") as f:
                f.write("".join(step + "\n" for step in plan))
            raw = os.path.join(tmp, "xcodebuild-raw-test.log")
            env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"], FAKE_STATE=tmp)
            args = ["bash", SCRIPT] + (["--retry-hung-runner"] if retry else []) + [raw, command, "test", "-scheme", "S"]
            done = subprocess.run(args, env=env, capture_output=True, text=True, timeout=60, check=False)
            self.status = done.returncode
            self.log = done.stdout + done.stderr
            with open(os.path.join(tmp, "calls"), encoding="utf-8") as f:
                self.calls = int(f.read())
            self.raw = self.read(raw)
            self.first_try = self.read(os.path.join(tmp, "xcodebuild-raw-test-first-try.log"))

    @staticmethod
    def read(path):
        if not os.path.exists(path):
            return None
        with open(path, encoding="utf-8") as f:
            return f.read()


class XcodebuildTestRetryTests(unittest.TestCase):
    """When the command is run again, and what the step then reports."""

    def setUp(self):
        for tool in ("bash", "python3"):
            if shutil.which(tool) is None:
                raise AssertionError("%s is not on PATH; these tests run the real script" % tool)

    def test_a_passing_run_is_run_once(self):
        run = Run(["pass"])
        self.assertEqual((run.status, run.calls), (0, 1), run.log)
        self.assertIn("args: test -scheme S", run.raw)
        self.assertIn("TEST SUCCEEDED", run.log)
        self.assertIsNone(run.first_try)

    def test_a_failed_test_is_not_run_again(self):
        run = Run(["fail", "pass"])
        self.assertEqual((run.status, run.calls), (65, 1), run.log)
        self.assertNotIn("::warning", run.log)

    def test_a_runner_that_never_connected_gets_one_more_run(self):
        run = Run(["hung", "pass"])
        self.assertEqual((run.status, run.calls), (0, 2), run.log)
        self.assertIn("::warning title=Test runner never connected::", run.log)
        # Both runs' raw output survives, stderr included, for the failure dump.
        self.assertIn("hung before establishing connection", run.first_try)
        self.assertIn("TEST SUCCEEDED", run.raw)
        self.assertNotIn("hung before establishing connection", run.raw)

    def test_the_second_runs_failure_is_the_steps_failure(self):
        run = Run(["hung", "fail", "pass"])
        self.assertEqual((run.status, run.calls), (65, 2), run.log)
        self.assertIn("1 failure", run.raw)

    def test_a_second_hang_is_not_run_a_third_time(self):
        run = Run(["hung", "hung", "pass"])
        self.assertEqual((run.status, run.calls), (65, 2), run.log)
        self.assertEqual(run.log.count("::warning"), 1)

    def test_without_the_flag_nothing_is_run_again(self):
        run = Run(["hung", "pass"], retry=False)
        self.assertEqual((run.status, run.calls), (65, 1), run.log)
        self.assertNotIn("::warning", run.log)

    def test_a_run_that_exited_zero_is_never_run_again(self):
        run = Run(["hung-but-green", "fail"])
        self.assertEqual((run.status, run.calls), (0, 1), run.log)


if __name__ == "__main__":
    unittest.main()
