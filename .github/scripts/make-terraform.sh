#!/bin/bash
cat << EO_TF > terraform/infra/versions.tf
terraform {
  cloud {
    organization = "cabal"
    workspaces {
      tags = ["infra","$TF_ENVIRONMENT"]
    }
  }
}
EO_TF