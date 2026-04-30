#!/usr/bin/env bash
#
# Out-of-band Lambda deploy for container-image functions. Calls
# aws lambda update-function-code --image-uri to point the function at
# the freshly-pushed image, then waits for the update to complete.
#
# Phase 3 of docs/0.9.0/build-deploy-simplification-plan.md uses this
# for cabal-certbot-renewal. The phase 2 lifecycle clause on that
# function (ignore_changes = [image_uri]) protects the new image from
# being clobbered by a topology-only Terraform apply.
#
# Usage:
#   deploy-lambda-image.sh <function_name> <image_uri>
#
# Args:
#   function_name  e.g. cabal-certbot-renewal
#   image_uri      Full image URI including tag, e.g.
#                  123.dkr.ecr.us-west-2.amazonaws.com/cabal/certbot-renewal:sha-abc12345
#
# Exit codes:
#   0  function updated successfully
#   1  required arg missing or function does not exist in AWS
#   non-0 from aws CLI on any other failure

set -euo pipefail

FUNC="${1:?function_name required}"
URI="${2:?image_uri required}"

log() { echo "[deploy-lambda-image] $*"; }

if ! aws lambda get-function --function-name "${FUNC}" >/dev/null 2>&1; then
  log "function ${FUNC} does not exist in this account; refusing to deploy"
  exit 1
fi

log "updating ${FUNC} -> ${URI}"

aws lambda update-function-code \
  --function-name "${FUNC}" \
  --image-uri "${URI}" \
  --no-publish \
  --output text \
  --query 'LastUpdateStatus' >/dev/null

aws lambda wait function-updated --function-name "${FUNC}"
log "${FUNC} update complete"
