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

cat << EO_TF > ./terraform/${TF_MODULE}/backend.tf
terraform {
  backend "s3" {
    bucket = "cabal-tf-backend"
    key    = "$TF_KEY"
    region = "$TF_VAR_AWS_REGION"
  }
}
EO_TF
