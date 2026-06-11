#!/usr/bin/env python3
"""Drift detection for the IaC quality gates (Phase 3 of
docs/0.10.x/iac-quality-gates-plan.md).

`checkov --baseline` and `trivy --trivyignores` already fail CI on a NEW
finding. This catches the other direction: a baseline / ignore entry that no
longer matches any current finding - a "stale" entry left behind when the
underlying code was fixed but the grandfather entry was not removed. A stale
entry silently re-allows that finding if it is ever reintroduced, so the
ratchet only holds if the baseline shrinks as findings are fixed.

Usage:
  baseline-diff.py checkov <current-findings.json> <.checkov.baseline>
  baseline-diff.py trivy   <current-findings.json> <.trivyignore>

<current-findings.json> is the UNFILTERED scanner output (no baseline/ignore):
  checkov -d <stack> --config-file <stack>/.checkov.yaml -o json
  trivy config <stack> --format json

Exits 1 (and lists them) if any entry is stale; 0 otherwise.
"""
import json
import re
import sys


def load_json(path):
    with open(path) as fh:
        return json.load(fh)


def checkov_current_pairs(data):
    blocks = data if isinstance(data, list) else [data]
    pairs = set()
    for block in blocks:
        for fc in block.get("results", {}).get("failed_checks", []):
            pairs.add((fc.get("resource"), fc.get("check_id")))
    return pairs


def checkov_baseline_pairs(baseline):
    pairs = set()
    for entry in baseline.get("failed_checks", []):
        resource = entry.get("resource")
        for cid in entry.get("check_ids", []):
            pairs.add((resource, cid))
    return pairs


def trivy_current_ids(data):
    ids = set()
    for result in data.get("Results", []):
        for mis in result.get("Misconfigurations", []):
            ids.add(mis.get("ID"))
            ids.add(mis.get("AVDID"))
    ids.discard(None)
    return ids


def trivy_ignore_ids(path):
    # Active (uncommented) ignore ids only; a line is "AWS-#### # comment".
    ids = []
    with open(path) as fh:
        for line in fh:
            match = re.match(r"\s*(AVD-AWS-\d+|AWS-\d+)\b", line)
            if match:
                ids.append(match.group(1))
    return ids


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    tool, findings_path, entry_path = sys.argv[1:4]

    if tool == "checkov":
        current = checkov_current_pairs(load_json(findings_path))
        entries = checkov_baseline_pairs(load_json(entry_path))
        stale = sorted(e for e in entries if e not in current)
        render = lambda e: f"{e[1]} on {e[0]}"
    elif tool == "trivy":
        current = trivy_current_ids(load_json(findings_path))
        entries = trivy_ignore_ids(entry_path)
        stale = sorted(i for i in entries if i not in current)
        render = lambda i: i
    else:
        sys.exit(f"unknown tool '{tool}' (expected 'checkov' or 'trivy')")

    if stale:
        print(f"STALE entries in {entry_path} - the finding is gone; "
              f"remove the entry so the baseline keeps shrinking:")
        for entry in stale:
            print(f"  {render(entry)}")
        sys.exit(1)
    print(f"OK: no stale entries in {entry_path}.")


if __name__ == "__main__":
    main()
