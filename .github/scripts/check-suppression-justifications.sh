#!/usr/bin/env bash
#
# Phase 3 of docs/0.10.x/iac-quality-gates-plan.md.
#
# Fail if any inline scanner suppression in a Terraform stack lacks a written
# justification. Without this, "checkov:skip=CKV_AWS_n" with no reason after it
# silently disables a rule - the shrug-emoji silencing the rationale-capture
# goal is meant to prevent. A suppression must say *why*.
#
# Recognised directives (justification is the text after the id):
#   #checkov:skip=<ID>:<justification>
#   #trivy:ignore:<ID> <justification>
#   # tflint-ignore: <rule> # <justification>
#
# Usage: check-suppression-justifications.sh <dir> [<dir> ...]
# Exits non-zero and prints each offending line if any are unjustified.

set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <dir> [<dir> ...]" >&2; exit 2; }

status=0

# A directive is OK only if it matches "<directive><id-stuff><separator><text>"
# with at least one non-space character of justification. We grep for every
# occurrence of the directive, then subtract the well-formed ones; whatever is
# left is unjustified.
check() {
  local label="$1" find_re="$2" ok_re="$3"
  shift 3
  local offenders
  offenders="$(grep -rInE "$find_re" "$@" --include='*.tf' 2>/dev/null \
    | grep -vE "$ok_re" || true)"
  if [ -n "$offenders" ]; then
    echo "Unjustified ${label} suppression(s) - add a reason after the id:"
    echo "$offenders" | sed 's/^/  /'
    status=1
  fi
}

# checkov:skip=<ID>:<non-space>
check "checkov:skip" \
  'checkov:skip=' \
  'checkov:skip=[A-Za-z0-9_]+:[[:space:]]*[^[:space:]]'

# trivy:ignore:<ID> followed by some justification text (any non-space after
# the id, e.g. "# reason")
check "trivy:ignore" \
  'trivy:ignore:' \
  'trivy:ignore:[A-Za-z0-9-]+[[:space:]]+#?[[:space:]]*[^[:space:]]'

# tflint-ignore: <rule> # <reason>
check "tflint-ignore" \
  'tflint-ignore:' \
  'tflint-ignore:[[:space:]]*[A-Za-z0-9_]+[[:space:]]+#[[:space:]]*[^[:space:]]'

if [ "$status" -eq 0 ]; then
  echo "OK: every inline scanner suppression in $* carries a justification."
fi
exit "$status"
