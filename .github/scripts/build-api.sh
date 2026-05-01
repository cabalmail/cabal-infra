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
# The "python" dir is the shared Lambda layer; its zip becomes a new
# aws_lambda_layer_version every time its sha256 changes, which then
# forces every aws_lambda_function that consumes the layer to rotate
# its `layers` attribute. The build therefore has to be byte-stable
# - same source in, same zip out - or every CI run produces a layer
# version bump and Terraform churns through 30+ in-place Lambda
# updates on the next plan.
#
# Sources of non-determinism we control here:
#   - SOURCE_DATE_EPOCH: honored by zip, pip wheel builds, and most
#     reproducible-build tooling.
#   - --no-compile: stops pip from generating .pyc files, whose binary
#     headers contain magic numbers that vary across Python builds.
#   - PYTHONDONTWRITEBYTECODE=1: belt-and-braces against any import
#     during install that might trigger compilation.
#   - __pycache__/*.pyc purge: removes anything pip compiled despite
#     the flags above.
#   - direct_url.json purge: pip writes this per-package and it
#     records the wheel's source URL, which differs between cache hits
#     and cache misses.
#   - chmod normalisation: ensures the zip's external-attribute field
#     is identical regardless of what umask the runner started with.
#   - LC_ALL=C sort: locale-stable filename ordering inside the zip.
#   - touch -h: sets every entry's mtime to SOURCE_DATE_EPOCH without
#     following symlinks.
#
# `./python` is wiped before every pip install so that stale files from
# a previous build cannot leak into the layer. The shared layer
# (lambda/api/python) keeps its own first-party module sources under
# ./src/ so that the wipe only removes pip-managed artefacts; ./src/.
# is copied into ./python/ after pip install so the layer ends up with
# both the third-party deps and helper.py side-by-side.

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
