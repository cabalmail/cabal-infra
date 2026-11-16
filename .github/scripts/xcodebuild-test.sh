#!/usr/bin/env bash
#
# Run an `xcodebuild test` command for apple.yml, with its raw output kept in
# a file and the readable output on the job log, and, when asked, run it once
# more if the test runner never connected.
#
# Usage:
#   xcodebuild-test.sh [--retry-hung-runner] <raw-log> <command> [args...]
#     --retry-hung-runner  run the command a second time when the first run
#                          failed without starting a test, as judged by
#                          runner-hung-before-tests.py (which has the story)
#     <raw-log>            where the command's raw output goes; a later step
#                          dumps it on failure (dump-xcodebuild-raw.sh)
#     <command> [args...]  the test command, e.g. gtimeout ... xcodebuild test ...
#
# The command's output is piped through xcbeautify. The exit status is the
# command's own: of its second run, when there was one.
#
# One retry and no more. The failure this is for happens before any test
# runs, and each hung try costs about 13 minutes, so a run that hangs twice
# is reported as it is. Every retry leaves a warning annotation on the run,
# so it stays countable, and the first try's raw output is kept beside the
# second's as <raw-log>-first-try.log for the same dump.

set -euo pipefail

USAGE="usage: xcodebuild-test.sh [--retry-hung-runner] <raw-log> <command> [args...]"
RETRY=0
if [ "${1:-}" = "--retry-hung-runner" ]; then
  RETRY=1
  shift
fi
RAW_LOG="${1:?$USAGE}"
shift
[ "$#" -gt 0 ] || { echo "$USAGE" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run() {
  "$@" 2>&1 | tee "$RAW_LOG" | xcbeautify --renderer github-actions
}

status=0
run "$@" || status=$?

if [ "$status" -ne 0 ] && [ "$RETRY" -eq 1 ] && python3 "$here/runner-hung-before-tests.py" "$RAW_LOG"; then
  echo "::warning title=Test runner never connected::xcodebuild reported \"The test runner hung before establishing connection\" and no test ran (#2436). Running the tests once more on the same simulator."
  mv "$RAW_LOG" "${RAW_LOG%.log}-first-try.log"
  status=0
  run "$@" || status=$?
fi

exit "$status"
