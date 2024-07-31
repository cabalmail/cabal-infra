#!/bin/bash

set +e
terraform plan -lock-timeout=30m -detailed-exitcode -var-file="terraform.tfvars" -replace="module.cert.acme_registration.reg" -replace="module.cert.acme_certificate.cert"
EXIT_CODE=$?
echo ">$EXIT_CODE<"
echo "exit_code=$EXIT_CODE" >> "$GITHUB_OUTPUT"
cat $GITHUB_OUTPUT
if [[ $EXIT_CODE -eq 2 ]]; then
  exit 0
else
  exit $EXIT_CODE
fi
