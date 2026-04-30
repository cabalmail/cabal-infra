#!/usr/bin/env bash
#
# Upload a placeholder zip + base64sha256 sidecar for every Lambda
# function in this repo whose pair is missing in S3. Phase 4 of
# docs/0.9.0/build-deploy-simplification-plan.md uses these stubs to
# break the bootstrap chicken-and-egg: Terraform reads
# lambda/<name>.zip.base64sha256 at plan time and refuses to create an
# aws_lambda_function whose s3_key does not exist. On a brand-new
# environment app.yml has never run, so neither artifact exists yet -
# this script materialises just enough to let infra.yml's first apply
# succeed. Real zips arrive on the next app.yml run; the phase 2
# lifecycle clause (ignore_changes on s3_key, s3_object_version,
# source_code_hash) keeps that update from being rolled back.
#
# Steady-state behaviour: every required zip pair is already in S3, so
# every key check is a head-object hit and nothing is uploaded.
#
# The stub is a single function.py whose handler raises
# NotImplementedError - if it ever runs in production, CloudWatch
# surfaces the failure rather than silently 200-OKing.
#
# Usage:
#   BUCKET=admin.example.com upload-stub-lambdas.sh
#
# Run from repo root. Requires aws CLI, openssl, zip.
#
# Exit codes:
#   0  done (with or without uploads)
#   1  required env var missing or repo layout unexpected
#   non-0 from aws CLI on upload failure

set -euo pipefail

BUCKET="${BUCKET:?BUCKET env var required (typically admin.\${TF_VAR_CONTROL_DOMAIN})}"

log() { echo "[upload-stub-lambdas] $*"; }

if [ ! -d lambda/api ] || [ ! -d lambda/counter ]; then
  log "expected lambda/api and lambda/counter dirs in CWD - run from repo root" >&2
  exit 1
fi

# Enumerate the function names that need a zip in S3. Each subdir of
# lambda/api/ corresponds to s3://${BUCKET}/lambda/<dirname>.zip,
# including the shared "python" layer dir whose zip is consumed by
# terraform/infra/modules/lambda_layers. lambda/counter/ contributes
# assign_osid (and any future counter functions).
names=()
for d in lambda/api/*/ lambda/counter/*/; do
  [ -d "${d}" ] || continue
  names+=("$(basename "${d%/}")")
done

if [ "${#names[@]}" -eq 0 ]; then
  log "no Lambda function dirs found under lambda/api or lambda/counter; nothing to do"
  exit 0
fi

# Determinism: pin mtimes and zip metadata so reruns produce byte-stable
# stub zips. Same knobs as build-api-one.sh.
export SOURCE_DATE_EPOCH=946684800

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cat > "${tmpdir}/function.py" <<'PY'
def handler(event, context):
    raise NotImplementedError(
        "placeholder Lambda - replace with real deploy via app.yml"
    )
PY

stub_zip="${tmpdir}/stub.zip"
stub_sha_file="${tmpdir}/stub.zip.base64sha256"

(
  cd "${tmpdir}"
  touch -h -d "@${SOURCE_DATE_EPOCH}" function.py
  zip -X -D stub.zip function.py >/dev/null
)
openssl dgst -sha256 -binary "${stub_zip}" | openssl enc -base64 | tr -d "\n" > "${stub_sha_file}"

uploaded=0
skipped=0
for name in "${names[@]}"; do
  zip_key="lambda/${name}.zip"
  sha_key="lambda/${name}.zip.base64sha256"

  zip_present=0
  sha_present=0
  aws s3api head-object --bucket "${BUCKET}" --key "${zip_key}" >/dev/null 2>&1 && zip_present=1
  aws s3api head-object --bucket "${BUCKET}" --key "${sha_key}" >/dev/null 2>&1 && sha_present=1

  if [ "${zip_present}" -eq 1 ] && [ "${sha_present}" -eq 1 ]; then
    skipped=$((skipped + 1))
    continue
  fi

  log "uploading stub for ${name} -> s3://${BUCKET}/${zip_key} (zip_present=${zip_present} sha_present=${sha_present})"
  aws s3 cp "${stub_zip}" "s3://${BUCKET}/${zip_key}" \
    --no-progress --acl private >/dev/null
  aws s3 cp "${stub_sha_file}" "s3://${BUCKET}/${sha_key}" \
    --no-progress --acl private --content-type text/plain >/dev/null
  uploaded=$((uploaded + 1))
done

log "uploaded=${uploaded} skipped=${skipped}"
