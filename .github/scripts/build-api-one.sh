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
