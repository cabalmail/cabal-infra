#!/bin/bash

# Run terraform plan with -detailed-exitcode and publish the exit code
# (0 = no changes, 1 = error, 2 = changes pending) to GITHUB_OUTPUT so
# downstream jobs (approval, apply) can gate on it. Invoked from the
# stack directory (terraform/dns or terraform/infra) by infra.yml.
#
# When the plan has changes, re-render the saved plan file with
# `terraform show`, which prints only the change set (none of the
# "Refreshing state..." chatter), and emit it as a notice annotation
# so the pending delta is readable from the run summary page before
# the approval gate.

PLAN_FILE="${RUNNER_TEMP:-/tmp}/tf.plan"
STACK="$(basename "$(pwd)")"

set +e
PLAN_ARGS=(-lock-timeout=30m -detailed-exitcode -var-file="terraform.tfvars")
# record-lambda-hashes.sh writes this file in the infra-stage jobs only; the
# dns stack has no lambda code to pin, so the file is absent there.
if [[ -f ".terraform/lambda-pinned.tfvars" ]]; then
  PLAN_ARGS+=(-var-file=".terraform/lambda-pinned.tfvars")
fi
terraform plan "${PLAN_ARGS[@]}"
EXIT_CODE=$?
echo ">$EXIT_CODE<"
echo "exit_code=$EXIT_CODE" >> "$GITHUB_OUTPUT"
cat $GITHUB_OUTPUT
if [[ $EXIT_CODE -eq 2 ]]; then
  PLAN_TEXT="$(terraform show -no-color "$PLAN_FILE" 2>/dev/null)"
  if [[ -z "$PLAN_TEXT" ]]; then
    PLAN_TEXT="(could not render the saved plan file - see the plan-terraform step log for the full plan)"
  fi
  # GitHub truncates annotation messages around 4096 characters of the
  # escaped command line; stay well short of that and point at the
  # step log, which always has the full plan.
  MAX=3000
  if [[ ${#PLAN_TEXT} -gt $MAX ]]; then
    PLAN_TEXT="${PLAN_TEXT:0:$MAX}
... (truncated - see the plan-terraform step log for the full plan)"
  fi
  # Escape for the ::notice workflow command: literal %, CR, LF.
  PLAN_TEXT="${PLAN_TEXT//'%'/%25}"
  PLAN_TEXT="${PLAN_TEXT//$'\r'/%0D}"
  PLAN_TEXT="${PLAN_TEXT//$'\n'/%0A}"
  echo "::notice title=Terraform plan ($STACK)::${PLAN_TEXT}"
  exit 0
else
  exit $EXIT_CODE
fi
