#!/usr/bin/env bash
#
# Out-of-band Lambda deploy for S3-source (zip) functions. Calls
# aws lambda update-function-code with the freshly-uploaded S3 key,
# then waits for the function update to finish so the caller can roll
# the next deploy without racing against an in-flight publish.
#
# Phase 3 of docs/0.9.0/build-deploy-simplification-plan.md introduces
# this path: app.yml mutates the running function directly instead of
# letting Terraform pick up the new code on the next plan. The phase 2
# lifecycle clause (ignore_changes on s3_key, s3_object_version,
# source_code_hash) protects the new code from being clobbered by a
# topology-only Terraform apply, and the phase 2
# .github/scripts/record-lambda-hashes.sh records the deployed
# CodeSha256 so a Terraform-driven recreate starts from the running
# code identity.
#
# The zip and its sidecar checksum must already be at
#   s3://${bucket}/lambda/${function}.zip
#   s3://${bucket}/lambda/${function}.zip.base64sha256
# build-api.sh and build-counter.sh both produce that layout.
#
# Usage:
#   deploy-lambda-zip.sh <function_name> <s3_bucket> [s3_key]
#
# Args:
#   function_name  Lambda function name in AWS (often matches the
#                  source dir, but not always - e.g. cabal-healthchecks-iac
#                  vs lambda/api/healthchecks_iac).
#   s3_bucket      Bucket the zip is in. Typically admin.${TF_VAR_CONTROL_DOMAIN}.
#   s3_key         Optional; defaults to lambda/<function_name>.zip.
#
# Exit codes:
#   0  function updated successfully
#   1  required arg missing or function does not exist in AWS
#   non-0 from aws CLI on any other failure

set -euo pipefail

FUNC="${1:?function_name required}"
BUCKET="${2:?s3_bucket required}"
KEY="${3:-lambda/${FUNC}.zip}"

log() { echo "[deploy-lambda-zip] $*"; }

if ! aws lambda get-function --function-name "${FUNC}" >/dev/null 2>&1; then
  log "function ${FUNC} does not exist in this account; refusing to deploy"
  exit 1
fi

log "updating ${FUNC} from s3://${BUCKET}/${KEY}"

aws lambda update-function-code \
  --function-name "${FUNC}" \
  --s3-bucket "${BUCKET}" \
  --s3-key "${KEY}" \
  --no-publish \
  --output text \
  --query 'LastUpdateStatus' >/dev/null

aws lambda wait function-updated --function-name "${FUNC}"

new_sha="$(aws lambda get-function-configuration \
  --function-name "${FUNC}" \
  --query 'CodeSha256' \
  --output text)"
log "${FUNC} now at CodeSha256=${new_sha}"
