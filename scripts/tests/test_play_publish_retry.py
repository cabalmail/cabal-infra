"""Regression tests for .github/scripts/publish-play-bundle.py.

A single 503 from `androidpublisher.googleapis.com` failed the Android
stage deploy after the bundle had been built and signed (issue #1442):
`android.yml` ran a bare `./gradlew publishBundle` with no retry anywhere
on the path, and `gradle-play-publisher` 4.1.1 exposes no retry setting to
turn on, so there was nothing to configure.

The retry therefore wraps the invocation, and wrapping it is what makes
these tests worth having: `publishBundle` creates a Play edit, uploads
into it and commits it, so re-running one that already committed publishes
the bundle twice. The decision under test is the pair — transient *and*
provably uncommitted — and the tests that matter most are the ones where
one half is true and the wrapper still refuses.

REPORTED_FAILURE below is the real log from run 33799621091, verbatim,
which is also what keeps the transience rule honest: the edit id in that
log contains the digits `503`, so a naive substring search reports a
transient refusal on a run that had none.

Run in CI by `.github/workflows/scripts-tests.yml`. By hand from the repo
root:

    python3 scripts/tests/test_play_publish_retry.py
"""

import importlib.util
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS = os.path.join(REPO_ROOT, ".github", "scripts")

_spec = importlib.util.spec_from_file_location(
    "publish_play_bundle", os.path.join(SCRIPTS, "publish-play-bundle.py")
)
publish_play_bundle = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(publish_play_bundle)
module = publish_play_bundle


#: Run 33799621091, `Upload to Play Console` / `Build and publish signed
#: bundle`, timestamps and job prefixes stripped. Nothing else is edited.
REPORTED_FAILURE = """\
> Task :app:buildReleasePreBundle
> Task :app:mergeReleaseComposeMapping
> Task :app:compileReleaseArtProfile
> Task :app:packageReleaseBundle
> Task :app:signReleaseBundle
> Task :app:produceReleaseBundleIdeListingFile
> Task :app:createReleaseBundleListingFileRedirect

> Task :app:publishReleaseBundle
Starting App Bundle upload: /home/runner/work/cabal-infra/cabal-infra/android/app/build/outputs/bundle/release/app-release.aab

> Task :app:publishReleaseBundle FAILED
> Task :commitEditForComDotCabalmailDotAndroid SKIPPED

[Incubating] Problems report is available at: file:///home/runner/work/cabal-infra/cabal-infra/android/build/reports/problems/problems-report.html

FAILURE: Build failed with an exception.
89 actionable tasks: 78 executed, 11 from cache

* What went wrong:
Execution failed for task ':app:publishReleaseBundle' (registered by plugin 'com.android.internal.application').
> A failure occurred while executing com.github.triplet.gradle.play.tasks.PublishBundle$Processor
   > There was a failure while executing work items
      > A failure occurred while executing com.github.triplet.gradle.play.tasks.PublishBundle$BundleUploader
         > 503 Service Unavailable
           PUT https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/com.cabalmail.android/edits/15779250351168544743/bundles?uploadType=resumable&upload_id=AJjja9aDSwIHNTXOsrFnMqw06M9mQ9iZYua4P9mfPHtdTHBtBEdLll8ox-pfM_jXRXznZB7UN3O3GrWLDcDEE328G8Grh7Q9_KPgGUxnLHvmwA

* Try:
> Run with --stacktrace option to get the stack trace.
> Run with --info or --debug option to get more log output.
> Run with --scan to get full insights from a Build Scan (powered by Develocity).
> Get more help at https://help.gradle.org.
"""


#: The same run with the upload accepted: the commit task carries no
#: outcome word, which is how Gradle renders a task that ran.
SUCCEEDED = REPORTED_FAILURE.replace(
    "> Task :app:publishReleaseBundle FAILED\n"
    "> Task :commitEditForComDotCabalmailDotAndroid SKIPPED",
    "> Task :app:publishReleaseBundle\n"
    "> Task :commitEditForComDotCabalmailDotAndroid",
)

#: A transient refusal raised after the edit had been committed. This is
#: the shape a retry must never act on.
COMMITTED_THEN_FAILED = REPORTED_FAILURE.replace(
    "> Task :commitEditForComDotCabalmailDotAndroid SKIPPED",
    "> Task :commitEditForComDotCabalmailDotAndroid",
)

#: A failure early enough that Gradle never listed the commit task at all.
#: Indistinguishable, from the log alone, from one that committed.
NO_COMMIT_TASK_LINE = REPORTED_FAILURE.replace(
    "> Task :commitEditForComDotCabalmailDotAndroid SKIPPED\n", ""
)

#: A permanent refusal: the credential is wrong, and re-sending it three
#: times only makes the job slower.
PERMANENT_REFUSAL = REPORTED_FAILURE.replace(
    "         > 503 Service Unavailable",
    "         > 401 Unauthorized",
)


class Runner:
    """A `run_gradle` stub driven by a list of (rc, output); last repeats."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def __call__(self, args):
        self.calls.append(list(args))
        return self.outcomes[min(len(self.calls) - 1, len(self.outcomes) - 1)]

    @property
    def attempts(self):
        return len(self.calls)


class TransienceTests(unittest.TestCase):
    """Which failures are worth re-sending."""

    def test_the_reported_503_is_transient(self):
        self.assertTrue(module.transient_refusal(REPORTED_FAILURE))

    def test_every_retryable_status_is_recognised(self):
        for status in module.TRANSIENT_STATUSES:
            with self.subTest(status=status):
                log = REPORTED_FAILURE.replace(
                    "> 503 Service Unavailable", f"> {status} Something"
                )
                self.assertTrue(module.transient_refusal(log))

    def test_a_401_is_not_transient(self):
        self.assertFalse(module.transient_refusal(PERMANENT_REFUSAL))

    def test_a_status_inside_the_edit_id_does_not_count(self):
        # The reported log's edit id is 15779250351168544743, which contains
        # the digits 503. `"503" in output` answers True on a run with no
        # transient refusal in it at all; the rule has to be anchored.
        without = REPORTED_FAILURE.replace(
            "         > 503 Service Unavailable\n", ""
        )
        self.assertIn("503", without, "the fixture must still bait the naive check")
        self.assertFalse(module.transient_refusal(without))


class CommitDetectionTests(unittest.TestCase):
    """Whether the Play edit went public — the double-publish guard."""

    def test_a_skipped_commit_task_reads_as_uncommitted(self):
        self.assertIs(module.edit_was_committed(REPORTED_FAILURE), False)

    def test_a_commit_task_with_no_outcome_word_reads_as_committed(self):
        self.assertIs(module.edit_was_committed(SUCCEEDED), True)
        self.assertIs(module.edit_was_committed(COMMITTED_THEN_FAILED), True)

    def test_an_absent_commit_task_reads_as_unknown(self):
        self.assertIsNone(module.edit_was_committed(NO_COMMIT_TASK_LINE))


class ShouldRetryTests(unittest.TestCase):
    """The decision is the pair, and each half alone has to say no."""

    def test_the_reported_failure_is_retried(self):
        self.assertTrue(module.should_retry(REPORTED_FAILURE))

    def test_a_transient_failure_after_the_commit_is_not_retried(self):
        self.assertFalse(module.should_retry(COMMITTED_THEN_FAILED))
        self.assertIn("already committed", module.reason_not_to_retry(COMMITTED_THEN_FAILED))

    def test_an_unreadable_commit_outcome_is_not_retried(self):
        self.assertFalse(module.should_retry(NO_COMMIT_TASK_LINE))
        self.assertIn(
            "does not say whether", module.reason_not_to_retry(NO_COMMIT_TASK_LINE)
        )

    def test_a_permanent_refusal_is_not_retried(self):
        self.assertFalse(module.should_retry(PERMANENT_REFUSAL))
        self.assertIn("not a transient", module.reason_not_to_retry(PERMANENT_REFUSAL))


class PublishLoopTests(unittest.TestCase):
    """What the wrapper actually does around the invocation."""

    def drive(self, runner):
        sleeps = []
        rc = module.publish(["-Pa=1"], runner=runner, sleep=sleeps.append)
        return rc, sleeps

    def test_a_clean_publish_runs_once(self):
        runner = Runner((0, SUCCEEDED))
        rc, sleeps = self.drive(runner)
        self.assertEqual(rc, 0)
        self.assertEqual(runner.attempts, 1)
        self.assertEqual(sleeps, [])

    def test_the_reported_failure_then_success_publishes(self):
        runner = Runner((1, REPORTED_FAILURE), (0, SUCCEEDED))
        rc, sleeps = self.drive(runner)
        self.assertEqual(rc, 0)
        self.assertEqual(runner.attempts, 2)
        self.assertEqual(sleeps, [15.0])

    def test_a_persistent_transient_failure_is_bounded(self):
        runner = Runner((1, REPORTED_FAILURE))
        rc, sleeps = self.drive(runner)
        self.assertEqual(rc, 1)
        self.assertEqual(runner.attempts, module.RETRY_ATTEMPTS)
        self.assertEqual(sleeps, [15.0, 30.0])

    def test_a_failure_that_may_have_committed_stops_at_once(self):
        # The whole reason the wrapper is allowed to exist.
        for name, log in (
            ("committed", COMMITTED_THEN_FAILED),
            ("unknown", NO_COMMIT_TASK_LINE),
        ):
            with self.subTest(commit_outcome=name):
                runner = Runner((1, log), (0, SUCCEEDED))
                rc, sleeps = self.drive(runner)
                self.assertEqual(rc, 1)
                self.assertEqual(runner.attempts, 1)
                self.assertEqual(sleeps, [])

    def test_a_permanent_refusal_stops_at_once(self):
        runner = Runner((1, PERMANENT_REFUSAL), (0, SUCCEEDED))
        rc, sleeps = self.drive(runner)
        self.assertEqual(rc, 1)
        self.assertEqual(runner.attempts, 1)

    def test_the_gradle_arguments_are_passed_through_unchanged(self):
        runner = Runner((1, REPORTED_FAILURE), (0, SUCCEEDED))
        module.publish(
            ["-Pcabalmail.fcmApiKey=k", "-Pcabalmail.fcmSenderId=s"],
            runner=runner,
            sleep=lambda _s: None,
        )
        self.assertEqual(
            runner.calls,
            [["-Pcabalmail.fcmApiKey=k", "-Pcabalmail.fcmSenderId=s"]] * 2,
        )


class RunGradleTests(unittest.TestCase):
    """The one part the loop tests stub out: actually invoking Gradle.

    Everything above drives `publish()` over a fake runner, so nothing there
    would notice if the invocation, the streaming or the exit code were
    wrong. A fake `gradlew` on disk covers that seam without an Android SDK,
    which this machine cannot reach anyway.
    """

    def run_with_fake_gradlew(self, script):
        previous = os.getcwd()
        with tempfile.TemporaryDirectory() as workdir:
            wrapper = os.path.join(workdir, "gradlew")
            with open(wrapper, "w", encoding="utf-8") as handle:
                handle.write(script)
            os.chmod(wrapper, 0o755)
            os.chdir(workdir)
            try:
                return module.run_gradle(["-Pa=1", "-Pb=2"])
            finally:
                os.chdir(previous)

    def test_a_clean_run_reports_zero_and_captures_its_output(self):
        rc, output = self.run_with_fake_gradlew(
            "#!/bin/sh\necho \"args: $*\"\necho '> Task :commitEditForX'\n"
        )
        self.assertEqual(rc, 0)
        self.assertIn("args: publishBundle -Pa=1 -Pb=2", output)
        self.assertIs(module.edit_was_committed(output), True)

    def test_a_failing_run_reports_its_code_and_captures_stderr_too(self):
        # Gradle writes the `What went wrong` block to stderr, and that block
        # carries the status line the transience rule reads — so merging the
        # streams is load-bearing, not tidiness.
        rc, output = self.run_with_fake_gradlew(
            "#!/bin/sh\n"
            "echo '> Task :app:publishReleaseBundle FAILED'\n"
            "echo '> Task :commitEditForX SKIPPED'\n"
            "echo '         > 503 Service Unavailable' >&2\n"
            "exit 1\n"
        )
        self.assertEqual(rc, 1)
        self.assertTrue(module.should_retry(output), output)


if __name__ == "__main__":
    unittest.main()
