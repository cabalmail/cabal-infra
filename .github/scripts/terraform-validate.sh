#!/usr/bin/env bash
#
# Validate a Terraform stack's configuration: `terraform init -backend=false`
# followed by `terraform validate`.
#
# The scanners (checkov, tflint, trivy) read the committed source without ever
# initialising Terraform, so they see each file on its own terms and are blind
# to configuration errors that only exist *between* files - a module argument
# with no matching variable, a reference to an output the module doesn't
# declare, a wrong type. #962: a merge-conflict resolution dropped the elb
# module's `control_domain` variable while `main.tf` still passed the argument,
# and every PR check stayed green even though the stage apply would have failed
# on "An argument named \"control_domain\" is not expected here".
#
# This needs no credentials and no backend: `-backend=false` skips backend
# initialisation entirely (so no generated backend.tf from make-terraform.sh is
# required), and `validate` is a static check that never contacts AWS. It does
# reach the provider registry to install the pinned providers, as init always
# does.
#
# Usage: terraform-validate.sh <stack-dir> [<stack-dir> ...]
# Exits non-zero if any stack fails to initialise or validate.

set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <stack-dir> [<stack-dir> ...]" >&2; exit 2; }

status=0

for stack in "$@"; do
  if [ ! -d "$stack" ]; then
    echo "[tf-validate] no such stack directory: $stack" >&2
    status=1
    continue
  fi

  echo "[tf-validate] init $stack (no backend)"
  if ! terraform -chdir="$stack" init -backend=false -input=false -no-color; then
    echo "[tf-validate] FAILED to initialise $stack" >&2
    status=1
    continue
  fi

  echo "[tf-validate] validate $stack"
  if ! terraform -chdir="$stack" validate -no-color; then
    echo "[tf-validate] FAILED validation of $stack" >&2
    status=1
  fi
done

exit "$status"
