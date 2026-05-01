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
  pushd "${FUNC}" >/dev/null
  rm -rf ./python
  pip install --no-compile -r requirements.txt -t ./python 2>/dev/null || true
  if [ -d ./src ]; then
    mkdir -p ./python
    cp -a ./src/. ./python/
  fi
  find . -depth -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
  find . -name '*.pyc' -delete 2>/dev/null || true
  find . -name 'direct_url.json' -delete 2>/dev/null || true
  find . -type d -exec chmod 0755 {} +
  find . -type f -exec chmod 0644 {} +
  find . -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
  find . -type f -print | LC_ALL=C sort | zip -X -D -@ ../"${FUNC}.zip" >/dev/null
  popd >/dev/null
  openssl dgst -sha256 -binary "${FUNC}.zip" | openssl enc -base64 | tr -d "\n" > "${FUNC}.zip.base64sha256"
  aws s3 cp "${FUNC}.zip.base64sha256" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip.base64sha256" --profile deploy_lambda --no-progress --acl private --content-type text/plain
  aws s3 cp "${FUNC}.zip" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip" --profile deploy_lambda --no-progress --acl private
done

if [ "${#funcs[@]}" -eq 0 ]; then
  echo "[build-api] no function dirs under lambda/api/"
  exit 0
fi

printf '%s\n' "${funcs[@]}" | LC_ALL=C sort | xargs -P "${JOBS}" -I {} ../../.github/scripts/build-api-one.sh {}
