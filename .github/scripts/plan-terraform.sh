#!/bin/bash

terraform plan -lock-timeout=30m -detailed-exitcode -out tmp
terraform show tmp -no-color -json >tmp.json 
EXIT_CODE=$?
echo "exit_code=$EXIT_CODE" >> "$GITHUB_OUTPUT"
cat $GITHUB_OUTPUT
cat tmp.json | jq '.'
case $EXIT_CODE in
  '2')
    exit 0
    ;;
  '1')
    exit 1
    ;;
  '0')
    exit 0
    ;;
esac