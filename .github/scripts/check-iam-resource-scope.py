#!/usr/bin/env python3
"""Fail on unjustified IAM resource wildcards in Terraform.

Phase 4 of docs/0.10.x/identity-iam-hardening-plan.md. The repo's IAM
policies use two wildcard shapes:

  - a literal "*" resource (Resource = "*" in jsonencode() policies,
    "Resource": "*" in heredoc JSON, resources = ["*"] in
    aws_iam_policy_document data sources), and
  - the local.wildcard indirection, where local.wildcard = "*" is
    interpolated into an ARN so IaC scanners (which look for the literal
    string "*") do not flag it.

Some of these are legitimate: a handful of AWS service grammars have no
resource-level scoping (ssmmessages channels, route53 List*, sns:Publish
to a phone number), and log-stream / object-key segments are runtime
values that cannot be enumerated at plan time. The rest are blast-radius
bugs waiting to be cited in a postmortem - the assign_osid Lambda could
AdminUpdateUserAttributes any user in any pool in the account until
0.10.x narrowed it.

This check makes the distinction explicit: every wildcard resource must
carry a written justification, on the same line or within LOOKBACK lines
above it. Recognised justifications:

  # iam-wildcard-ok: <reason>          (this check's own directive)
  #checkov:skip=<ID>:<reason>          (justification enforced by
  #tfsec:ignore:<rule>                  check-suppression-justifications.sh)
  #trivy:ignore:<ID> <reason>

Heredoc policies (policy = <<EOF ... EOF) are JSON, which cannot carry
comments; for a wildcard inside a heredoc the justification is looked up
above the heredoc *opener* instead. One directive there covers every
wildcard in that policy document - coarser than per-line, so prefer
jsonencode() for new policies.

Usage: check-iam-resource-scope.py <dir> [<dir> ...]
Exits non-zero and prints each offending line if any are unjustified.
"""

import re
import sys
from pathlib import Path

# Window above a flagged line searched for a justification directive. Six
# lines fits the common shape: a multi-line statement-level comment above
# Effect/Action/Resource attribute lines.
LOOKBACK = 6

WILDCARD_PATTERNS = [
    # Resource = "*" / Resource = ["*"] in jsonencode() policies
    re.compile(r'Resource\s*=\s*(\[\s*)?"\*"'),
    # "Resource": "*" in heredoc JSON policies
    re.compile(r'"Resource"\s*:\s*(\[\s*)?"\*"'),
    # resources = ["*"] in aws_iam_policy_document data sources
    re.compile(r'resources\s*=\s*\[\s*"\*"\s*\]'),
    # the scanner-evading indirection, wherever it is interpolated
    re.compile(r'local\.wildcard'),
]

# A bare "*" element on its own line inside a multi-line Resource list.
# Only flagged when a Resource/resources opener appears just above, so a
# wildcard Action element does not false-positive.
BARE_ELEMENT = re.compile(r'^\s*"\*"\s*,?\s*$')
RESOURCE_OPENER = re.compile(r'(Resource\s*=|"Resource"\s*:|resources\s*=)')

JUSTIFIED = re.compile(
    r'iam-wildcard-ok:\s*\S|checkov:skip=|tfsec:ignore:|trivy:ignore:'
)

HEREDOC_OPENER = re.compile(r'<<-?"?([A-Za-z][A-Za-z0-9_]*)"?\s*$')


def heredoc_openers(lines):
    """Map each line index inside a heredoc to its opener's index."""
    opener_for = {}
    terminator = None
    opener_idx = None
    for i, line in enumerate(lines):
        if terminator is not None:
            opener_for[i] = opener_idx
            if line.strip() == terminator:
                terminator = None
            continue
        m = HEREDOC_OPENER.search(line)
        if m:
            terminator = m.group(1)
            opener_idx = i
    return opener_for


def offenders_in(path):
    lines = path.read_text().splitlines()
    opener_for = heredoc_openers(lines)
    found = []
    for i, line in enumerate(lines):
        hit = any(p.search(line) for p in WILDCARD_PATTERNS)
        if not hit and BARE_ELEMENT.match(line):
            hit = any(
                RESOURCE_OPENER.search(lines[j])
                for j in range(max(0, i - 3), i)
            )
        if not hit:
            continue
        # JSON heredocs cannot carry comments: look above the opener.
        anchor = opener_for.get(i, i)
        window = lines[max(0, anchor - LOOKBACK):anchor + 1]
        if anchor != i:
            window.append(line)
        if not any(JUSTIFIED.search(w) for w in window):
            found.append((i + 1, line.rstrip()))
    return found


def main(argv):
    if len(argv) < 2:
        print(f"usage: {argv[0]} <dir> [<dir> ...]", file=sys.stderr)
        return 2

    status = 0
    for d in argv[1:]:
        for tf in sorted(Path(d).rglob("*.tf")):
            if ".terraform" in tf.parts:
                continue
            for lineno, text in offenders_in(tf):
                if status == 0:
                    print(
                        "Unjustified IAM wildcard resource(s) - narrow the"
                        " ARN, or add '# iam-wildcard-ok: <reason>' within"
                        f" {LOOKBACK} lines above:"
                    )
                    status = 1
                print(f"  {tf}:{lineno}: {text.strip()}")

    if status == 0:
        print(
            "OK: every IAM wildcard resource in"
            f" {' '.join(argv[1:])} carries a justification."
        )
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
