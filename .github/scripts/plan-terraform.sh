#!/bin/bash

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
  exit 0
else
  exit $EXIT_CODE
fi
