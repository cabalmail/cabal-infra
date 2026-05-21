#!/usr/bin/env bash
#
# Build a deterministic zip for the sms_sender Cognito custom SMS
# sender trigger and upload it to
#   s3://admin.${TF_VAR_CONTROL_DOMAIN}/lambda/
# alongside a base64sha256 sidecar. See build-api.sh for the rationale
# behind each determinism knob.
#
# Layout note: the twilio SDK ships inside the function zip itself.
# pip therefore installs into the zip root (next to function.py)
# rather than into a ./python/ subdir - Lambda's module search path
# for a plain zip-source function is the zip root, and ./python/ is
# only on sys.path when delivered as a layer mounted at /opt/python.
# The api Lambdas follow the same root-install pattern after the
# 0.9.x layer removal (see build-api-one.sh).
#
# Builds are staged in a tmp dir so this script is safe to re-run
# locally without polluting the source tree.

set -euo pipefail

cd ./lambda/sms-sender
SRC_DIR="${PWD}"
AWS_S3_BUCKET="admin.${TF_VAR_CONTROL_DOMAIN}"

export SOURCE_DATE_EPOCH=946684800
export PYTHONDONTWRITEBYTECODE=1

FUNC=sms_sender

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

cp "${SRC_DIR}/function.py" "${STAGING}/"
# aws-encryption-sdk pulls cryptography, which has native code. The
# GHA build host is x86_64 but the Lambda runs on arm64, so we have
# to ask pip for arm64 manylinux wheels explicitly - otherwise pip
# either grabs the x86_64 wheel (won't run on the Lambda) or tries
# to build from sdist (fails without dev headers). --only-binary
# refuses sdist fallback so a missing wheel surfaces loudly rather
# than as a runtime ImportError.
pip install --no-compile \
  --platform manylinux2014_aarch64 \
  --only-binary=:all: \
  --python-version 3.13 \
  --implementation cp \
  -r "${SRC_DIR}/requirements.txt" \
  -t "${STAGING}"

pushd "${STAGING}" >/dev/null
find . -depth -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find . -name '*.pyc' -delete 2>/dev/null || true
find . -name 'direct_url.json' -delete 2>/dev/null || true
find . -type d -exec chmod 0755 {} +
find . -type f -exec chmod 0644 {} +
find . -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
find . -type f -print | LC_ALL=C sort | zip -X -D -@ "${SRC_DIR}/${FUNC}.zip" >/dev/null
popd >/dev/null

openssl dgst -sha256 -binary "${SRC_DIR}/${FUNC}.zip" | openssl enc -base64 | tr -d "\n" > "${SRC_DIR}/${FUNC}.zip.base64sha256"
aws s3 cp "${SRC_DIR}/${FUNC}.zip.base64sha256" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip.base64sha256" --profile deploy_lambda --no-progress --acl private --content-type text/plain
aws s3 cp "${SRC_DIR}/${FUNC}.zip" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip" --profile deploy_lambda --no-progress --acl private
