#!/bin/bash

if [ -z "$TF_MODULE" ]; then
  echo "TF_MODULE is not set" >&2
  exit 1
fi

if [ "$TF_MODULE" = "dns" ]; then
  TF_KEY="${TF_ENVIRONMENT}-bootstrap"
else
  TF_KEY="$TF_ENVIRONMENT"
fi

# When STATE_KMS_KEY_ID is set (to the ARN of a customer-managed KMS key),
# generate an encrypted backend: state objects are written with SSE-KMS
# under that key, so reading state requires kms:Decrypt in addition to
# s3:GetObject. The key lives in the state bucket's account; cross-account
# deploy principals are granted use of it through the key policy.
#
# When STATE_KMS_KEY_ID is empty/unset, emit the historical plaintext-SSE-S3
# backend unchanged, so an environment that has not been migrated (or that
# has been rolled back) behaves exactly as before. Activation is a single
# per-environment GitHub variable, set once the environment's CMK and IAM
# grant exist. See docs/terraform-state-encryption.md.
if [ -n "${STATE_KMS_KEY_ID:-}" ]; then
  cat << EO_TF > ./terraform/${TF_MODULE}/backend.tf
terraform {
  backend "s3" {
    bucket     = "cabal-tf-backend"
    key        = "$TF_KEY"
    region     = "$TF_VAR_AWS_REGION"
    encrypt    = true
    kms_key_id = "$STATE_KMS_KEY_ID"
  }
}
EO_TF
else
  cat << EO_TF > ./terraform/${TF_MODULE}/backend.tf
terraform {
  backend "s3" {
    bucket = "cabal-tf-backend"
    key    = "$TF_KEY"
    region = "$TF_VAR_AWS_REGION"
  }
}
EO_TF
fi
