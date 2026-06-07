# Shared by both stacks (terraform/dns and terraform/infra). tflint does
# not search parent directories for config, so the CI jobs and the local
# `make scan` runner point TFLINT_CONFIG_FILE at this absolute path.
#
# Phase 1 of docs/0.10.x/iac-quality-gates-plan.md: enable the bundled
# terraform language ruleset (recommended preset - unused declarations,
# required_version, pinned module sources, etc.) and bump the AWS ruleset
# from the stale 0.20.0 to the current 0.40 line. Versions are pinned so
# the gate's strictness only changes by deliberate PR.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.40.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
