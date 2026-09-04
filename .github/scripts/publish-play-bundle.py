#!/usr/bin/env python3
"""Run `./gradlew publishBundle`, retrying a transient Play Console refusal.

android.yml's upload step had no retry anywhere on the path, so a single
503 from `androidpublisher.googleapis.com` failed the whole job after the
bundle had already been built and signed — the artifact dies with the
runner, so the recourse is a re-run, and stage carries no internal-track
build for that commit until the next push (#1442). The plugin cannot help:
`gradle-play-publisher` 4.1.1's `play { }` extension exposes no retry or
backoff setting, so the retry has to wrap the invocation.

Wrapping it is the blunt remedy, and the blunt remedy has a hazard the
narrow one would not: `publishBundle` creates a Play *edit*, uploads into
it and commits it, so re-running one that already committed publishes the
bundle twice. This script therefore refuses to retry unless it can read,
out of Gradle's own task output, that the commit did **not** happen. An
unreadable outcome is treated as "may have committed" and fails, because
the cost of being wrong in that direction is a double publish and the cost
of being wrong in the other is a red run that a human re-runs by hand —
which is exactly today's behaviour.

Usage (from the `android/` directory):

    publish-play-bundle.py -Pfoo=bar -Pbaz=qux

Every argument is passed through to `./gradlew publishBundle`.
"""

import re
import subprocess
import sys
import time

# The statuses Google returns when it is declining momentarily rather than
# rejecting the artifact or the credential. Gradle renders the uploader's
# cause chain as indented `> ` lines, so `> 503 Service Unavailable` is the
# shape this has to match.
TRANSIENT_STATUSES = (429, 500, 502, 503, 504)
_TRANSIENT = re.compile(
    r"^\s*>\s*(?:%s)\b" % "|".join(str(s) for s in TRANSIENT_STATUSES),
    re.MULTILINE,
)

# `> Task :commitEditForComDotCabalmailDotAndroid SKIPPED` — the task that
# makes an upload public. Gradle appends an outcome word to a task line only
# when the task did not execute; a bare task line means it ran.
_COMMIT_TASK = re.compile(
    r"^>\s+Task\s+:\S*commitEdit\S*(?P<outcome>.*)$",
    re.MULTILINE | re.IGNORECASE,
)

# Outcomes that mean the task did not do its work. Anything else after the
# task name — including nothing at all — means it ran, or means we cannot
# tell, and both are handled the same way: do not retry.
_DID_NOT_RUN = ("SKIPPED", "NO-SOURCE")

RETRY_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = 15.0


def warn(message):
    """Emit a GitHub Actions warning annotation."""
    print(f"::warning::{message}")


def transient_refusal(output):
    """True when Google declined with a status worth re-sending against."""
    return bool(_TRANSIENT.search(output))


def edit_was_committed(output):
    """Whether the Play edit was committed: True, False, or None for unknown.

    None is the important case. It means the run said nothing about the
    commit task — a failure early enough that Gradle never listed it, or a
    future rename of the task — and a caller must treat it exactly as it
    treats True.
    """
    matches = _COMMIT_TASK.findall(output)
    if not matches:
        return None
    return not all(
        any(word in outcome.upper() for word in _DID_NOT_RUN) for outcome in matches
    )


def should_retry(output):
    """Whether re-running the publish is both worthwhile and safe.

    Both halves are required. Transience alone is not enough: a 503 raised
    *after* the edit committed would re-publish on a retry. And a confirmed
    uncommitted edit is not enough either — a permanent refusal (a bad
    credential, a rejected artifact) would just fail three times slower.
    """
    return transient_refusal(output) and edit_was_committed(output) is False


def reason_not_to_retry(output):
    """A line for the log saying which half of `should_retry` said no."""
    if not transient_refusal(output):
        return (
            "the failure is not a transient Play Console refusal "
            f"(no {'/'.join(str(s) for s in TRANSIENT_STATUSES)} in the output)"
        )
    committed = edit_was_committed(output)
    if committed is None:
        return (
            "the output does not say whether the Play edit was committed, and "
            "re-running a publish that committed would publish the bundle twice"
        )
    return "the Play edit was already committed; re-running would publish twice"


def run_gradle(args):
    """Run the publish, streaming to the job log, and return (rc, output)."""
    command = ["./gradlew", "publishBundle", *args]
    print(f"+ {' '.join(command)}", flush=True)
    captured = []
    with subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    ) as process:
        for line in process.stdout:
            captured.append(line)
            sys.stdout.write(line)
            sys.stdout.flush()
        rc = process.wait()
    return rc, "".join(captured)


def publish(args, runner=run_gradle, sleep=time.sleep):
    """Publish, retrying a transient refusal that left the edit uncommitted."""
    attempt = 0
    while True:
        attempt += 1
        rc, output = runner(args)
        if rc == 0:
            return 0
        if attempt >= RETRY_ATTEMPTS:
            warn(
                f"Play Console publish failed on attempt {attempt} of "
                f"{RETRY_ATTEMPTS}; giving up."
            )
            return rc
        if not should_retry(output):
            print(f"Not retrying: {reason_not_to_retry(output)}.")
            return rc
        delay = RETRY_BACKOFF_SECONDS * attempt
        warn(
            "Play Console declined the bundle upload transiently and the edit "
            f"was not committed; retrying in {delay:.0f}s (attempt {attempt} "
            f"of {RETRY_ATTEMPTS})."
        )
        sleep(delay)


def main():
    return publish(sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
