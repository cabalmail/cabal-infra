#!/usr/bin/env python3
"""Say whether a failed `xcodebuild test` never got as far as running a test.

apple.yml's Kit simulator jobs sometimes fail like this, with no test run:

    Testing failed:
        xctest (5308) encountered an error (The test runner hung before
        establishing connection.)

xcodebuild boots a shut-down simulator only when testing starts, and a new
device's first boot keeps a three-core runner saturated for minutes. The
bare `xctest` runner these suites use is launched into that, xcodebuild's
connection to the device's service hub is refused ("DTServiceHubClient
failed to bless service hub"), and after three refusals it gives up (#2436).
Nothing about the code under test is involved, and the device is booted by
then, so the job runs the test command once more.

That second run is only safe when the first can not have hidden a result.
This script is the test for that: it exits 0 only when the raw xcodebuild
log (the one the test step tees) has the hung-runner error for `xctest` and
shows no test suite or test case starting and no "Executed N tests" line.
Anything else exits 1: a failed test, a crash part-way, a build error, a
hang inside an app that hosts the tests (the same sentence with the app's
name, which a real bug in the app has produced), or a log it can not read.

Usage: runner-hung-before-tests.py <raw xcodebuild log>
"""

import re
import sys

HUNG = re.compile(
    r"^\s*xctest \(\d+\) encountered an error "
    r"\(The test runner hung before establishing connection\.\)\s*$", re.M)
# What XCTest prints once a runner has connected and started work.
RAN = re.compile(r"^\s*(Test Suite '|Test Case '|Executed \d+ tests?\b)", re.M)


def hung_before_tests(text):
    """True when the log is the hung-runner failure and no test started."""
    return bool(HUNG.search(text)) and not RAN.search(text)


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 1
    try:
        with open(argv[1], encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as error:
        print("[hung-runner] cannot read %s: %s" % (argv[1], error), file=sys.stderr)
        return 1
    return 0 if hung_before_tests(text) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
