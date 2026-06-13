#!/usr/bin/env bash
#
# Build and upload one lambda/api/<func> zip. Factored out of
# build-api.sh so build-api.sh can run multiple of these in parallel
# under xargs -P. See build-api.sh for the determinism rationale.
#
# Each function zip is self-contained: third-party deps from
# requirements.txt and helper.py (when imported) are bundled at the
# zip root. No Lambda layers.
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

# Account that must own AWS_S3_BUCKET; --expected-bucket-owner fails the
# upload closed if a leaked credential ever points deploy_lambda at a
# same-named bucket in another account. build-api.sh exports this once for
# all parallel children; resolve it here too for standalone invocations.
EXPECTED_BUCKET_OWNER="${EXPECTED_BUCKET_OWNER:-$(aws sts get-caller-identity --profile deploy_lambda --query Account --output text)}"

export SOURCE_DATE_EPOCH=946684800
export PYTHONDONTWRITEBYTECODE=1

[ -d "${FUNC}" ] || { echo "[build-api-one] missing dir ${FUNC}" >&2; exit 1; }

pushd "${FUNC}" >/dev/null

# Function build. The zip is extracted to /var/task/, which is on
# sys.path; deps and helper.py therefore go at the zip root, not
# under a python/ subdir. Staged in ./build/ so reruns do not leave
# cruft in the source tree.
#
# Every *.py at the function dir root is shipped (function.py plus
# any sibling modules like healthchecks_iac/config.py that the
# handler imports). requirements.txt is intentionally excluded - it
# is a build input, not runtime code.
rm -rf ./build
mkdir -p ./build
find . -maxdepth 1 -type f -name '*.py' -exec cp {} ./build/ \;
# Only invoke pip when there is a real requirement (a non-blank,
# non-comment line); a whitespace-only requirements.txt would otherwise
# make pip error. --require-hashes makes a missing or mismatched hash fail
# the build instead of silently shipping a drifted wheel, so errors are
# no longer swallowed.
if grep -qE '^[[:space:]]*[^[:space:]#]' requirements.txt 2>/dev/null; then
  pip install --no-compile --require-hashes -r requirements.txt -t ./build
fi
if grep -qE '^[[:space:]]*(from|import)[[:space:]]+compose' function.py 2>/dev/null; then
  cp ../_shared/compose.py ./build/compose.py
fi
# compose.py itself imports helper, so scan the staged copy too: a handler
# that only imports compose still needs helper.py in its zip.
if grep -qE '^[[:space:]]*(from|import)[[:space:]]+helper' function.py ./build/compose.py 2>/dev/null; then
  cp ../_shared/helper.py ./build/helper.py
fi
if grep -qE '^[[:space:]]*(from|import)[[:space:]]+admin_limits' function.py 2>/dev/null; then
  cp ../_shared/admin_limits.py ./build/admin_limits.py
fi

pushd ./build >/dev/null
find . -depth -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find . -name '*.pyc' -delete 2>/dev/null || true
find . -name 'direct_url.json' -delete 2>/dev/null || true
find . -type d -exec chmod 0755 {} +
find . -type f -exec chmod 0644 {} +
find . -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
find . -type f -print | LC_ALL=C sort | zip -X -D -@ ../../"${FUNC}.zip" >/dev/null
popd >/dev/null
rm -rf ./build

popd >/dev/null

openssl dgst -sha256 -binary "${FUNC}.zip" | openssl enc -base64 | tr -d "\n" > "${FUNC}.zip.base64sha256"
aws s3 cp "${FUNC}.zip.base64sha256" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip.base64sha256" --profile deploy_lambda --no-progress --acl private --content-type text/plain --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}"
aws s3 cp "${FUNC}.zip" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip" --profile deploy_lambda --no-progress --acl private --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}"

# Build-provenance manifest (sha256 + git commit + builder identity) next
# to the zip in S3. See .github/scripts/emit-lambda-manifest.sh.
../../.github/scripts/emit-lambda-manifest.sh "${FUNC}" "${FUNC}.zip" "${AWS_S3_BUCKET}"
