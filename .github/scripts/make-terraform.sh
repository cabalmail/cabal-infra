#!/bin/bash
cat << EO_TF > terraform/infra/versions.tf
terraform {
  cloud {
    organization = "cabal"
    workspaces {
      tags = ["infra","$TF_ENVIRONMENT"]
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.32"
    }
    acme = {
      source  = "vancluever/acme"
      version = "2.2.0"
    }
  }
  required_version = ">= 1.1.2"
}
EO_TF