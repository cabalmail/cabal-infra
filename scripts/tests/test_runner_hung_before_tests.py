"""Tests for .github/scripts/runner-hung-before-tests.py.

apple.yml's Kit simulator jobs run their test command a second time when
this script exits 0 for the first run's raw xcodebuild log (#2436). A second
run must never stand in for a run that produced a result, so these pin what
the script accepts: only the hung-runner error for the bare `xctest` runner,
in a log where no test suite or test case started. Every other failure,
including the same sentence from an app that hosts the tests, is refused.

The log fixtures are cut from real raw logs: the hung one from the four
occurrences of 2026-11-06 to 2026-11-13, with the device identifier
shortened.

Run in CI by `.github/workflows/scripts-tests.yml`. Run by hand from the
repo root:

    python3 scripts/tests/test_runner_hung_before_tests.py
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO_ROOT, ".github", "scripts", "runner-hung-before-tests.py")

_spec = importlib.util.spec_from_file_location("runner_hung_before_tests", SCRIPT)
hung = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hung)

BUILD = """\
    /usr/bin/touch -c /Users/runner/Library/Developer/Xcode/DerivedData/CabalmailKit-abc/Build/Products/Debug-iphonesimulator/CabalmailKitTests.xctest

PruneExplicitPrecompiledModules /Users/runner/Library/Developer/Xcode/DerivedData/SDKExplicitPrecompiledModules

"""
REFUSED = (
    '2026-11-13 04:42:29.507 xcodebuild[3008:13489]  iOSSimulator: <DVTiPhoneSimulator (0x7b6e7b4e00), ci-iOS, '
    'unknown class, 27.2 (24B8117), DB07C147> unable to connect to "com.apple.instruments.deviceservice.lockdown" '
    '(Error Domain=DVTiPhoneSimulatorErrorDomain Code=-1 "DTServiceHubClient failed to bless service hub for '
    'simulator ci-iOS (DB07C147)")\n')
ELAPSED = ("2026-11-13 04:50:34.186 xcodebuild[3008:12427] [MT] IDETestOperationsObserverDebug: "
           "681.817 elapsed -- Testing started completed.\n")


def failed(error):
    return "\nTesting failed:\n\t%s\n\n** TEST FAILED **\n\nTesting started\n" % error


HUNG_ERROR = "xctest (5308) encountered an error (The test runner hung before establishing connection.)"
HUNG_LOG = BUILD + REFUSED * 3 + ELAPSED + failed(HUNG_ERROR)

RAN = """\
Test Suite 'All tests' started at 2026-11-13 04:42:15.489.
Test Suite 'CabalmailKitTests.xctest' started at 2026-11-13 04:42:15.490.
Test Suite 'MailboxWatcherTests' started at 2026-11-13 04:42:15.491.
Test Case '-[CabalmailKitTests.MailboxWatcherTests testEmitsChangedForExistsExpungeFetch]' started.
"""
TEST_FAILURE = RAN + """\
/Users/runner/work/x/MailboxWatcherTests.swift:54: error: -[CabalmailKitTests.MailboxWatcherTests testEmitsChangedForExistsExpungeFetch] : failed - watcher stream stalled
Test Case '-[CabalmailKitTests.MailboxWatcherTests testEmitsChangedForExistsExpungeFetch]' failed (29.300 seconds).
Test Suite 'MailboxWatcherTests' failed at 2026-11-13 04:42:44.800.
\t Executed 1 test, with 1 failure (0 unexpected) in 29.300 (29.301) seconds
"""


class HungBeforeTestsTests(unittest.TestCase):
    """What counts as a run that never started a test."""

    def test_the_hung_runner_with_no_test_started_is_accepted(self):
        self.assertTrue(hung.hung_before_tests(HUNG_LOG))

    def test_it_does_not_depend_on_the_refusals_being_in_the_log(self):
        self.assertTrue(hung.hung_before_tests(BUILD + ELAPSED + failed(HUNG_ERROR)))

    def test_a_failed_test_is_refused(self):
        self.assertFalse(hung.hung_before_tests(BUILD + TEST_FAILURE + failed(
            "MailboxWatcherTests.testEmitsChangedForExistsExpungeFetch()")))

    def test_refusals_followed_by_tests_that_ran_are_refused(self):
        # Seen in passing and failing jobs alike: one or two refusals, then the tests run.
        self.assertFalse(hung.hung_before_tests(BUILD + REFUSED * 2 + TEST_FAILURE + failed(
            "MailboxWatcherTests.testEmitsChangedForExistsExpungeFetch()")))

    def test_a_hang_after_tests_started_is_refused(self):
        # A runner restarted mid-run prints the same error after real results.
        self.assertFalse(hung.hung_before_tests(BUILD + TEST_FAILURE + failed(HUNG_ERROR)))
        self.assertFalse(hung.hung_before_tests(BUILD + RAN + failed(HUNG_ERROR)))

    def test_any_executed_line_is_refused(self):
        log = BUILD + "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n" + failed(HUNG_ERROR)
        self.assertFalse(hung.hung_before_tests(log))

    def test_the_same_sentence_from_an_app_host_is_refused(self):
        # A real bug in the Mac app once hung the app that hosts the tests.
        self.assertFalse(hung.hung_before_tests(BUILD + failed(
            "CabalmailMac (4411) encountered an error (The test runner hung before establishing connection.)")))

    def test_another_xctest_error_is_refused(self):
        self.assertFalse(hung.hung_before_tests(BUILD + failed(
            "xctest (5308) encountered an error (Early unexpected exit, operation never finished bootstrapping - "
            "no restart will be attempted.)")))

    def test_the_sentence_inside_another_line_is_refused(self):
        # For instance a log line or a failure message quoting it.
        sentence = "xctest (1) encountered an error (The test runner hung before establishing connection.)"
        self.assertFalse(hung.hung_before_tests(BUILD + "note: seen before: " + sentence + "\n"))
        self.assertFalse(hung.hung_before_tests(BUILD + "\t" + sentence + " was the last failure\n"))

    def test_a_build_failure_and_an_empty_log_are_refused(self):
        self.assertFalse(hung.hung_before_tests(BUILD + "error: no such module 'CabalmailKit'\n** TEST FAILED **\n"))
        self.assertFalse(hung.hung_before_tests(""))


class CommandLineTests(unittest.TestCase):
    """The exit status apple.yml branches on."""

    def run_on(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".log", encoding="utf-8", delete=False) as f:
            f.write(text)
        try:
            return subprocess.run([sys.executable, SCRIPT, f.name], check=False).returncode
        finally:
            os.unlink(f.name)

    def test_exit_status_follows_the_verdict(self):
        self.assertEqual(self.run_on(HUNG_LOG), 0)
        self.assertEqual(self.run_on(BUILD + TEST_FAILURE), 1)

    def test_a_missing_log_or_no_argument_is_a_refusal(self):
        missing = subprocess.run([sys.executable, SCRIPT, "/nonexistent/xcodebuild-raw-test.log"],
                                 check=False, capture_output=True)
        self.assertEqual(missing.returncode, 1)
        bare = subprocess.run([sys.executable, SCRIPT], check=False, capture_output=True)
        self.assertEqual(bare.returncode, 1)


if __name__ == "__main__":
    unittest.main()
