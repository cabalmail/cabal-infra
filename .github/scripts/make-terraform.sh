#!/bin/bash
cat << EO_TF > "backend.tf
terraform {
  backend "s3" {
    bucket = "cabal-tf-backend"
    key    = "$TF_ENVIRONMENT"
    region = "$TF_VAR_AWS_REGION"
  }
}
EO_TF
