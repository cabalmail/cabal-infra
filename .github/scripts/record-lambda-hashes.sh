#!/usr/bin/env bash
#
# Record the currently-deployed CodeSha256 of every S3-source Lambda
# function in this AWS account and write the result as a Terraform
# tfvars file at terraform/infra/.terraform/lambda-pinned.tfvars,
# consumed by terraform plan and terraform apply.
#
# Phase 2 of docs/0.9.0/build-deploy-simplification-plan.md adds
# lifecycle { ignore_changes = [s3_key, s3_object_version,
# source_code_hash] } to the Lambda fleet so out-of-band app deploys
# (which mutate code via aws lambda update-function-code in phase 3+)
# are not rolled back by a topology-only Terraform apply. The
# ignore_changes clause covers steady-state updates; this file pins the
# deployed CodeSha256 so Terraform's plan output reflects what is
# actually running, and so any legitimate Lambda recreate (Terraform
# replaces the resource for some other reason) starts from the running
# code identity rather than whatever happens to be in S3.
#
# The lambda_pinned_hashes variable is declared at the root module
# (terraform/infra/variables.tf) with default {}; it is not yet
# consumed by individual Lambda resources. Phase 3 wires consumption
# alongside the new app.yml that performs the out-of-band deploys.
#
# Until phase 3 lands this script is a steady-state no-op: every
# Lambda's deployed CodeSha256 already matches what Terraform last
# applied, so populating the var has no effect.
#
# Failure modes:
#   - aws lambda list-functions returns nothing (first run, fresh
#     account): exit 0 with an empty map written to OUTPUT.
#   - jq missing: exit non-zero (jq is part of the GitHub-hosted
#     ubuntu-latest image, so this only happens locally).
#   - aws CLI fails for any other reason: exit non-zero.

set -euo pipefail

# Path is relative to the working directory of the calling step, which
# in infra.yml is ./terraform/infra. Override with the OUTPUT env
# var when invoking from elsewhere.
OUTPUT="${OUTPUT:-.terraform/lambda-pinned.tfvars}"

log() { echo "[record-lambda-hashes] $*"; }

mkdir -p "$(dirname "${OUTPUT}")"

# --output json is critical: --output text collapses multi-row results
# into tab-separated values that are awkward to parse with jq. The
# query restricts to S3-source (zip) functions; container-image
# Lambdas like cabal-certbot-renewal use ImageUri, not CodeSha256, and
# are handled separately at phase 3 cutover.
functions_json="$(aws lambda list-functions \
  --output json \
  --query 'Functions[?PackageType==`Zip`].{name:FunctionName,sha:CodeSha256}' \
  2>/dev/null || echo '[]')"

if [ -z "${functions_json}" ] || [ "${functions_json}" = "null" ] || [ "${functions_json}" = "[]" ]; then
  log "no S3-source Lambda functions found; writing empty map to ${OUTPUT}"
  echo "lambda_pinned_hashes = {}" > "${OUTPUT}"
  exit 0
fi

count="$(echo "${functions_json}" | jq 'length')"

{
  echo "lambda_pinned_hashes = {"
  echo "${functions_json}" | jq -r '.[] | "  \"\(.name)\" = \"\(.sha)\""'
  echo "}"
} > "${OUTPUT}"

log "wrote ${count} CodeSha256 entries to ${OUTPUT}"
