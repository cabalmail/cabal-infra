#!/usr/bin/env bash
#
# Build a deterministic zip per lambda/api/<func> dir and upload it
# to s3://admin.${TF_VAR_CONTROL_DOMAIN}/lambda/<func>.zip alongside
# a base64sha256 sidecar.
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

set -euo pipefail

cd ./lambda/api
AWS_S3_BUCKET="admin.${TF_VAR_CONTROL_DOMAIN}"

# 2000-01-01 00:00 UTC. Any value past 1980 (zip's lower bound) works.
export SOURCE_DATE_EPOCH=946684800
export PYTHONDONTWRITEBYTECODE=1

for FUNC in * ; do
  [ -d "${FUNC}" ] || continue
  pushd "${FUNC}" >/dev/null
  rm -rf ./python
  pip install --no-compile -r requirements.txt -t ./python 2>/dev/null || true
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
