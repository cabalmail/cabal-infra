#!/usr/bin/env bash
#
# Build and upload one lambda/api/<func> zip. Factored out of
# build-api.sh so build-api.sh can run multiple of these in parallel
# under xargs -P. See build-api.sh for the determinism rationale.
#
# Caller must:
#   - cd to lambda/api/ before invoking
#   - set TF_VAR_CONTROL_DOMAIN
#   - have an aws CLI profile named deploy_lambda configured
#
# Usage:
#   build-api-one.sh <func_dir>
#
# Args:
#   func_dir  Directory name (not path) under lambda/api/, e.g. "list".

set -euo pipefail

FUNC="${1:?function dir required}"
AWS_S3_BUCKET="admin.${TF_VAR_CONTROL_DOMAIN}"

export SOURCE_DATE_EPOCH=946684800
export PYTHONDONTWRITEBYTECODE=1

[ -d "${FUNC}" ] || { echo "[build-api-one] missing dir ${FUNC}" >&2; exit 1; }

# Determinism scrubber applied to whichever staging dir we end up
# zipping from. See build-api.sh header for what each step removes.
scrub() {
  find . -depth -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
  find . -name '*.pyc' -delete 2>/dev/null || true
  find . -name 'direct_url.json' -delete 2>/dev/null || true
  find . -type d -exec chmod 0755 {} +
  find . -type f -exec chmod 0644 {} +
  find . -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
}

pushd "${FUNC}" >/dev/null

if [ "${FUNC}" = "python" ]; then
  # Shared Lambda layer build. The layer zip is structured as
  # python/<modules> so that when AWS Lambda extracts it to /opt/,
  # /opt/python/ lands on sys.path. helper.py is sourced from
  # ../_shared so the layer's copy stays byte-identical with the
  # function-bundled copy throughout the layer-removal migration
  # (docs/0.9.0/lambda-layer-removal-plan.md). Removed entirely in
  # phase 3.
  rm -rf ./python
  pip install --no-compile -r requirements.txt -t ./python 2>/dev/null || true
  cp ../_shared/helper.py ./python/helper.py
  scrub
  find . -type f -print | LC_ALL=C sort | zip -X -D -@ ../"${FUNC}.zip" >/dev/null
else
  # API function build. The zip is extracted to /var/task/, which is
  # on sys.path; deps and helper.py therefore go at the zip root, not
  # under a python/ subdir. Staged in ./build/ so reruns do not leave
  # cruft in the source tree.
  rm -rf ./build
  mkdir -p ./build
  cp function.py ./build/
  if [ -s requirements.txt ]; then
    pip install --no-compile -r requirements.txt -t ./build 2>/dev/null || true
  fi
  if grep -qE '^[[:space:]]*(from|import)[[:space:]]+helper' function.py 2>/dev/null; then
    cp ../_shared/helper.py ./build/helper.py
  fi
  pushd ./build >/dev/null
  scrub
  find . -type f -print | LC_ALL=C sort | zip -X -D -@ ../../"${FUNC}.zip" >/dev/null
  popd >/dev/null
  rm -rf ./build
fi
popd >/dev/null

openssl dgst -sha256 -binary "${FUNC}.zip" | openssl enc -base64 | tr -d "\n" > "${FUNC}.zip.base64sha256"
aws s3 cp "${FUNC}.zip.base64sha256" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip.base64sha256" --profile deploy_lambda --no-progress --acl private --content-type text/plain
aws s3 cp "${FUNC}.zip" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip" --profile deploy_lambda --no-progress --acl private
