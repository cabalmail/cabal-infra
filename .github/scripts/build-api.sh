#!/usr/bin/env bash
#
# Build and upload every lambda/api/<func>.zip in parallel. The
# per-function logic lives in build-api-one.sh; this driver just
# enumerates dirs and dispatches them under xargs -P. The python dir
# is the shared Lambda layer source - it gets the same per-function
# treatment so the layer's source_code_hash stays byte-stable across
# CI runs (see build-api-one.sh and the 0.9.3 follow-up CHANGELOG
# entry for why determinism matters there).
#
# Build concurrency defaults to 8, override with BUILD_JOBS=N. Going
# above the runner's vCPU count is fine because each function spends
# most of its time blocked on pip's network/disk I/O.

set -euo pipefail

cd ./lambda/api

JOBS="${BUILD_JOBS:-8}"

funcs=()
for FUNC in */ ; do
  FUNC="${FUNC%/}"
  [ -d "${FUNC}" ] || continue
  funcs+=("${FUNC}")
done

if [ "${#funcs[@]}" -eq 0 ]; then
  echo "[build-api] no function dirs under lambda/api/"
  exit 0
fi

printf '%s\n' "${funcs[@]}" | LC_ALL=C sort | xargs -P "${JOBS}" -I {} ../../.github/scripts/build-api-one.sh {}
