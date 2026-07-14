#!/usr/bin/env bash
#
# Dump the raw xcodebuild logs tee'd by apple.yml's build/test/archive steps.
#
# The workflow pipes xcodebuild through xcbeautify for readable annotations,
# but xcbeautify swallows the stderr of crashing subtools — an actool crash
# (dyld override mismatch on the macOS 15 image) once surfaced as nothing but
# "CompileAssetCatalogVariant failed" across two runs. Each xcodebuild step
# therefore tees its raw output to $RUNNER_TEMP/xcodebuild-raw-<step>.log,
# and this script runs on failure to surface the detail: a grep'd error
# context first, then the tail, each in a collapsed log group.

set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must be set (GitHub Actions runner env)}"

shopt -s nullglob
logs=("${RUNNER_TEMP}"/xcodebuild-raw-*.log)

if [ "${#logs[@]}" -eq 0 ]; then
  echo "[raw-log] no raw xcodebuild logs in RUNNER_TEMP (failure predates the first xcodebuild step)"
  exit 0
fi

for f in "${logs[@]}"; do
  name="${f##*/}"
  echo "::group::[raw-log] ${name} — error context"
  # Subtool crashes don't always say "error:": match exceptions, dyld
  # complaints, and assertion text too. Cap the output so a pathological log
  # doesn't flood the job annotation view.
  grep -n -B2 -A20 -E "error:|[Ee]xception|dyld\[|Assertion|Terminating|fatal" "$f" | tail -n 300 \
    || echo "[raw-log] no error-pattern matches in ${name}"
  echo "::endgroup::"
  echo "::group::[raw-log] ${name} — last 120 lines"
  tail -n 120 "$f"
  echo "::endgroup::"
done
