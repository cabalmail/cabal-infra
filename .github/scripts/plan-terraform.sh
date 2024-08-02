#!/bin/bash

set +e
terraform state rm module.cert.acme_registration.reg
terraform state rm module.cert.acme_certificate.cert
terraform plan -lock-timeout=30m -detailed-exitcode -var-file="terraform.tfvars"
EXIT_CODE=$?
echo ">$EXIT_CODE<"
echo "exit_code=$EXIT_CODE" >> "$GITHUB_OUTPUT"
cat $GITHUB_OUTPUT
if [[ $EXIT_CODE -eq 2 ]]; then
  exit 0
else
  exit $EXIT_CODE
fi
