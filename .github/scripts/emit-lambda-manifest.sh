#!/usr/bin/env bash
#
# Emit and upload a build-provenance manifest for one Lambda zip.
#
# Phase 3c of docs/0.10.x/supply-chain-hardening-plan.md: alongside the
# deterministic zip and its base64sha256 sidecar, record who built the
# artefact, from which commit, and when. The manifest is uploaded to S3
# next to the zip as lambda/<func>.zip.manifest.json. Terraform does not
# yet consume it; this lays the data so a future plan step can cross-check
# the running Lambda's source_code_hash against a signed build record.
#
# The hex sha256 in the manifest is the same digest as the adjacent
# .base64sha256 sidecar, re-encoded as hex to match common tooling.
#
# git_dirty reflects tracked-file modifications only (git diff HEAD);
# untracked build outputs like the zip itself are intentionally ignored,
# so a clean CI checkout always reports git_dirty=false.
#
# Usage:
#   emit-lambda-manifest.sh <func> <zip_path> <s3_bucket>
#
# Requires: aws CLI (default credential chain), openssl, git.
# The caller (build-api.sh / build-counter.sh) verifies bucket ownership
# before invoking this; see .github/scripts/verify-bucket-owner.sh.

set -euo pipefail

FUNC="${1:?function name required}"
ZIP="${2:?zip path required}"
BUCKET="${3:?s3 bucket required}"

[ -f "${ZIP}" ] || { echo "[emit-lambda-manifest] missing zip ${ZIP}" >&2; exit 1; }

SHA256="$(openssl dgst -sha256 "${ZIP}" | awk '{print $NF}')"

GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if git diff --quiet HEAD 2>/dev/null; then
  GIT_DIRTY=false
else
  GIT_DIRTY=true
fi

BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILDER="${GITHUB_ACTIONS:+github-actions}"
BUILDER="${BUILDER:-local}"
RUNNER_OS_VALUE="${RUNNER_OS:-$(uname -s)}"
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  WORKFLOW_RUN="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
else
  WORKFLOW_RUN=""
fi

MANIFEST="${ZIP}.manifest.json"
cat > "${MANIFEST}" <<JSON
{
  "name": "${FUNC}",
  "sha256": "${SHA256}",
  "git_commit": "${GIT_COMMIT}",
  "git_dirty": ${GIT_DIRTY},
  "built_at": "${BUILT_AT}",
  "builder": "${BUILDER}",
  "runner_os": "${RUNNER_OS_VALUE}",
  "workflow_run": "${WORKFLOW_RUN}"
}
JSON

aws s3 cp "${MANIFEST}" "s3://${BUCKET}/lambda/${FUNC}.zip.manifest.json" \
  --no-progress --acl private \
  --content-type application/json
