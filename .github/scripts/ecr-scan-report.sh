#!/usr/bin/env bash
#
# Surface the ECR scan-on-push result for a freshly pushed image.
#
# Every cabal-* ECR repo is created with image_scanning_configuration
# { scan_on_push = true } (terraform/infra/modules/ecr/main.tf), so AWS
# basic scanning runs automatically when app.yml pushes a new image. The
# findings, however, only live in the ECR console unless something reads
# them. This script polls the scan to completion and reports the severity
# counts into the GitHub job summary, emitting a ::warning:: (NOT a
# failure) when CRITICAL or HIGH findings are present.
#
# Soft-fail is deliberate for the initial rollout (Phase 3 of
# docs/0.10.x/container-runtime-hardening-plan.md): the AL2023 base
# routinely carries a tail of HIGH CVEs with no fixed version, and we do
# not want those to block mail deploys. Once a baseline is established the
# threshold can be flipped to a hard gate.
#
# Usage:
#   ecr-scan-report.sh <tier> <image_tag>
#
# Args:
#   tier       e.g. imap, smtp-in, prometheus. Maps to ECR repo cabal-<tier>.
#   image_tag  e.g. sha-abc12345. Must already exist in ECR.
#
# Always exits 0: this is advisory. A scan that is slow, unsupported, or
# errors must never break the deploy pipeline.

# Intentionally no `set -e`: every failure path here is non-fatal.
set -uo pipefail

TIER="${1:?tier required}"
TAG="${2:?image_tag required}"
REPO="cabal-${TIER}"

log() { echo "[ecr-scan-report] $*"; }

# Basic scans usually finish in well under a minute. Bound our own wait so
# an in-progress or stuck scan can never stall the pipeline; a timeout is
# reported as "unknown", not a failure.
log "waiting for scan of ${REPO}:${TAG}"
if ! timeout 180 aws ecr wait image-scan-complete \
      --repository-name "${REPO}" \
      --image-id imageTag="${TAG}" 2>/dev/null; then
  log "scan of ${REPO}:${TAG} did not complete in time (or scanning is unavailable); skipping report"
  exit 0
fi

counts="$(aws ecr describe-image-scan-findings \
  --repository-name "${REPO}" \
  --image-id imageTag="${TAG}" \
  --query 'imageScanFindings.findingSeverityCounts' \
  --output json 2>/dev/null || echo '{}')"

crit="$(echo "${counts}" | jq -r '.CRITICAL // 0')"
high="$(echo "${counts}" | jq -r '.HIGH // 0')"
med="$(echo "${counts}" | jq -r '.MEDIUM // 0')"
low="$(echo "${counts}" | jq -r '.LOW // 0')"

log "${REPO}:${TAG} findings -> CRITICAL=${crit} HIGH=${high} MEDIUM=${med} LOW=${low}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ECR scan: \`${REPO}:${TAG}\`"
    echo ""
    echo "| CRITICAL | HIGH | MEDIUM | LOW |"
    echo "| -------- | ---- | ------ | --- |"
    echo "| ${crit} | ${high} | ${med} | ${low} |"
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if [ "${crit}" -gt 0 ] || [ "${high}" -gt 0 ]; then
  echo "::warning title=ECR image scan::${REPO}:${TAG} has ${crit} CRITICAL / ${high} HIGH findings (soft-fail; see job summary)"
fi

exit 0
