#!/bin/bash
#
# Render `terraform output` as a notice annotation so the stack's
# outputs land on the workflow run summary page after an apply instead
# of being buried in the apply log. Invoked from the stack directory
# (terraform/dns or terraform/infra) by the bootstrap_apply and apply
# jobs in infra.yml, after terraform apply succeeds.
#
# Requires terraform_wrapper: false on the job's setup-terraform step:
# the wrapper interleaves its own bookkeeping lines into terraform's
# stdout, which would corrupt the command substitution below.

set -euo pipefail

log() { echo "[annotate-terraform-outputs] $*"; }

STACK="$(basename "$(pwd)")"
OUTPUT_TEXT="$(terraform output -no-color)"

if [[ -z "$OUTPUT_TEXT" ]]; then
  log "stack has no outputs; skipping annotation"
  exit 0
fi

# Full text in the step log regardless of annotation truncation below.
echo "$OUTPUT_TEXT"

# GitHub truncates annotation messages around 4096 characters of the
# escaped command line; stay well short of that and point at the step
# log, which always has the full output.
MAX=3000
if [[ ${#OUTPUT_TEXT} -gt $MAX ]]; then
  OUTPUT_TEXT="${OUTPUT_TEXT:0:$MAX}
... (truncated - see the annotate-outputs step log for the full output)"
fi

# Escape for the ::notice workflow command: literal %, CR, LF.
OUTPUT_TEXT="${OUTPUT_TEXT//'%'/%25}"
OUTPUT_TEXT="${OUTPUT_TEXT//$'\r'/%0D}"
OUTPUT_TEXT="${OUTPUT_TEXT//$'\n'/%0A}"
echo "::notice title=Terraform outputs ($STACK)::${OUTPUT_TEXT}"
