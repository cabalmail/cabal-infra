#!/usr/bin/env bash
#
# Fail closed unless <bucket> is owned by the calling account.
#
# Phase 2a of docs/0.10.x/supply-chain-hardening-plan.md wants every CI
# upload target verified, so a leaked credential cannot silently push
# artefacts to a same-named bucket in another account. The high-level
# `aws s3 cp` / `aws s3 sync` commands the deploy path uses do NOT accept
# --expected-bucket-owner (only the low-level s3api operations do), so we
# assert ownership once here -- before the upload -- via
# `aws s3api head-bucket --expected-bucket-owner`, which returns non-zero
# (403) when the bucket lives in another account. Under the caller's
# `set -e` that aborts the run before anything is written.
#
# Usage:
#   verify-bucket-owner.sh <bucket> [aws_profile]
#
# Requires: aws CLI. Permission needed: s3:ListBucket on the bucket.

set -euo pipefail

BUCKET="${1:?bucket name required}"
PROFILE="${2:-}"

if [ -n "${PROFILE}" ]; then
  ACCOUNT="$(aws sts get-caller-identity --profile "${PROFILE}" --query Account --output text)"
  aws s3api head-bucket --bucket "${BUCKET}" --profile "${PROFILE}" --expected-bucket-owner "${ACCOUNT}"
else
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
  aws s3api head-bucket --bucket "${BUCKET}" --expected-bucket-owner "${ACCOUNT}"
fi
