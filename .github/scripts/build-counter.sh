#!/usr/bin/env bash
#
# Build deterministic zips for every Cognito trigger Lambda under
# lambda/counter/ and upload them to
# s3://admin.${TF_VAR_CONTROL_DOMAIN}/lambda/ alongside a base64sha256
# sidecar. See build-api.sh for the rationale behind each determinism
# knob.

set -euo pipefail

cd ./lambda/counter
AWS_S3_BUCKET="admin.${TF_VAR_CONTROL_DOMAIN}"

# Account that must own AWS_S3_BUCKET; --expected-bucket-owner fails each
# upload closed if a leaked credential ever points deploy_lambda at a
# same-named bucket in another account.
EXPECTED_BUCKET_OWNER="${EXPECTED_BUCKET_OWNER:-$(aws sts get-caller-identity --profile deploy_lambda --query Account --output text)}"

export SOURCE_DATE_EPOCH=946684800
export PYTHONDONTWRITEBYTECODE=1

for FUNC in */ ; do
  FUNC="${FUNC%/}"
  [ -d "${FUNC}" ] || continue
  pushd "${FUNC}" >/dev/null
  rm -rf ./python
  # Only invoke pip when there is a real requirement; --require-hashes
  # fails the build on any unpinned or hash-mismatched package rather than
  # silently shipping a drifted wheel.
  if grep -qE '^[[:space:]]*[^[:space:]#]' requirements.txt 2>/dev/null; then
    pip install --no-compile --require-hashes -r requirements.txt -t ./python
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
  aws s3 cp "${FUNC}.zip.base64sha256" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip.base64sha256" --profile deploy_lambda --no-progress --acl private --content-type text/plain --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}"
  aws s3 cp "${FUNC}.zip" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip" --profile deploy_lambda --no-progress --acl private --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}"
  # Build-provenance manifest next to the zip in S3.
  ../../.github/scripts/emit-lambda-manifest.sh "${FUNC}" "${FUNC}.zip" "${AWS_S3_BUCKET}"
done
