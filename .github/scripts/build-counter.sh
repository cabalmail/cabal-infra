#!/usr/bin/env bash
#
# Build a deterministic zip for the assign_osid Cognito post-confirm
# trigger and upload it to s3://admin.${TF_VAR_CONTROL_DOMAIN}/lambda/
# alongside a base64sha256 sidecar. See build-api.sh for the rationale
# behind each determinism knob.

set -euo pipefail

cd ./lambda/counter
AWS_S3_BUCKET="admin.${TF_VAR_CONTROL_DOMAIN}"

export SOURCE_DATE_EPOCH=946684800
export PYTHONDONTWRITEBYTECODE=1

FUNC=assign_osid
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
